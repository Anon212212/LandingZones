#!/usr/bin/env bash
# Bootstrap remote state and passwordless (OIDC) GitHub Actions identities for
# the landing zone pipeline. Idempotent: safe to re-run.
#
# Creates:
#   * a resource group + storage account for Terraform state (ZRS, TLS 1.2,
#     Entra ID auth only, versioning, 30-day soft delete, delete lock)
#   * two Entra ID applications with GitHub federated credentials:
#       <prefix>-plan   Reader on both subscriptions; state read/lock (PR plans)
#       <prefix>-apply  Contributor + User Access Administrator on both
#                       subscriptions; state write (runs only after approval)
#
# Requires: az CLI logged in as someone who can create app registrations and
# assign roles on both subscriptions. Use --dry-run to print what would run.

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --location LOC --state-rg NAME --state-account NAME
          --connectivity-sub GUID --identity-sub GUID
          --github-repo OWNER/REPO [--environment production]
          [--name-prefix lz-pipeline] [--state-sub GUID] [--dry-run]
USAGE
  exit 1
}

LOCATION="" STATE_RG="" STATE_ACCOUNT="" CONN_SUB="" ID_SUB="" REPO=""
GH_ENV="production" PREFIX="lz-pipeline" STATE_SUB="" DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --location) LOCATION="$2"; shift 2 ;;
    --state-rg) STATE_RG="$2"; shift 2 ;;
    --state-account) STATE_ACCOUNT="$2"; shift 2 ;;
    --connectivity-sub) CONN_SUB="$2"; shift 2 ;;
    --identity-sub) ID_SUB="$2"; shift 2 ;;
    --github-repo) REPO="$2"; shift 2 ;;
    --environment) GH_ENV="$2"; shift 2 ;;
    --name-prefix) PREFIX="$2"; shift 2 ;;
    --state-sub) STATE_SUB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done
[[ -n "$LOCATION" && -n "$STATE_RG" && -n "$STATE_ACCOUNT" && -n "$CONN_SUB" && -n "$ID_SUB" && -n "$REPO" ]] || usage
[[ "$REPO" == */* ]] || { echo "--github-repo must be OWNER/REPO" >&2; exit 1; }
STATE_SUB="${STATE_SUB:-$CONN_SUB}"

# run CMD... – executes, or prints in --dry-run mode.
# Dry-run traces go to stderr so they never pollute captured output.
trace() { echo "+ $(printf '%q ' "$@")" >&2; }
run() {
  if [[ $DRY_RUN -eq 1 ]]; then trace "$@"; else "$@"; fi
}
# q CMD... – runs a query and prints its output; placeholder in --dry-run mode.
q() {
  if [[ $DRY_RUN -eq 1 ]]; then trace "$@"; echo "dry-run-${2:-id}"; else "$@"; fi
}
retry() {  # role assignments take a while to propagate
  local n=0
  until "$@"; do n=$((n + 1)); [[ $n -ge 10 ]] && return 1; echo "  retrying in 15s…" >&2; sleep 15; done
}

echo "== Terraform state: $STATE_ACCOUNT in $STATE_RG ($LOCATION, subscription $STATE_SUB)"
run az account set --subscription "$STATE_SUB"
run az group create --name "$STATE_RG" --location "$LOCATION" --tags workload=landing-zone purpose=terraform-state managed-by=bootstrap -o none
if [[ $DRY_RUN -eq 1 ]] || ! az storage account show --name "$STATE_ACCOUNT" --resource-group "$STATE_RG" -o none 2>/dev/null; then
  run az storage account create --name "$STATE_ACCOUNT" --resource-group "$STATE_RG" --location "$LOCATION" \
    --sku Standard_ZRS --kind StorageV2 --min-tls-version TLS1_2 --https-only true \
    --allow-blob-public-access false --allow-shared-key-access false --allow-cross-tenant-replication false -o none
fi
run az storage account blob-service-properties update --account-name "$STATE_ACCOUNT" --resource-group "$STATE_RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 -o none
SA_ID=$(q az storage account show --name "$STATE_ACCOUNT" --resource-group "$STATE_RG" --query id -o tsv)
ME=$(q az ad signed-in-user show --query id -o tsv)
run az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$SA_ID" -o none
if [[ $DRY_RUN -eq 1 ]]; then
  run az storage container create --name tfstate --account-name "$STATE_ACCOUNT" --auth-mode login -o none
else
  retry az storage container create --name tfstate --account-name "$STATE_ACCOUNT" --auth-mode login -o none
fi
run az lock create --name lock-tfstate --resource-group "$STATE_RG" --lock-type CanNotDelete \
  --notes "Terraform state for the landing zone" -o none

TENANT=$(q az account show --query tenantId -o tsv)

ensure_identity() {  # name subject-name subject
  local name="$1" fic_name="$2" subject="$3" app sp
  app=$(q az ad app list --display-name "$name" --query "[0].appId" -o tsv)
  if [[ -z "$app" ]]; then app=$(q az ad app create --display-name "$name" --query appId -o tsv); fi
  sp=$(q az ad sp list --filter "appId eq '$app'" --query "[0].id" -o tsv)
  if [[ -z "$sp" ]]; then sp=$(q az ad sp create --id "$app" --query id -o tsv); fi
  if [[ $DRY_RUN -eq 1 ]] || [[ -z "$(az ad app federated-credential list --id "$app" --query "[?name=='$fic_name'].name" -o tsv)" ]]; then
    run az ad app federated-credential create --id "$app" --parameters \
      "{\"name\":\"$fic_name\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$subject\",\"audiences\":[\"api://AzureADTokenExchange\"]}" -o none
  fi
  echo "$app $sp"
}

assign() {  # sp-object-id role scope
  run az role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
    --role "$2" --scope "$3" -o none
}

echo "== Plan identity (pull requests, read-only)"
read -r PLAN_APP PLAN_SP < <(ensure_identity "$PREFIX-plan" "github-pr" "repo:$REPO:pull_request")
for sub in "$CONN_SUB" "$ID_SUB"; do assign "$PLAN_SP" "Reader" "/subscriptions/$sub"; done
assign "$PLAN_SP" "Storage Blob Data Contributor" "$SA_ID"   # state locking needs write

echo "== Apply identity (environment '$GH_ENV', after approval)"
read -r APPLY_APP APPLY_SP < <(ensure_identity "$PREFIX-apply" "github-env-$GH_ENV" "repo:$REPO:environment:$GH_ENV")
for sub in "$CONN_SUB" "$ID_SUB"; do
  assign "$APPLY_SP" "Contributor" "/subscriptions/$sub"
  assign "$APPLY_SP" "User Access Administrator" "/subscriptions/$sub"
done
assign "$APPLY_SP" "Storage Blob Data Contributor" "$SA_ID"

cat <<OUT

== Done. Set these GitHub repository variables (Settings → Secrets and variables → Actions → Variables):

  AZURE_TENANT_ID              $TENANT
  AZURE_PLAN_CLIENT_ID         $PLAN_APP
  AZURE_APPLY_CLIENT_ID        $APPLY_APP
  CONNECTIVITY_SUBSCRIPTION_ID $CONN_SUB
  TFSTATE_SUBSCRIPTION_ID      $STATE_SUB
  TFSTATE_RESOURCE_GROUP       $STATE_RG
  TFSTATE_STORAGE_ACCOUNT      $STATE_ACCOUNT
  TF_ENVIRONMENT               $GH_ENV

Then create the GitHub environment '$GH_ENV' with required reviewers
(Settings → Environments) so every apply needs an approval.
No secrets are needed: the workflow signs in with OIDC.
OUT
