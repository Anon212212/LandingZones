# Environments

One `<environment>.tfvars` per GitHub environment (e.g. `production.tfvars`). The deploy workflow (`.github/workflows/deploy.yml`) plans and applies `environments/${TF_ENVIRONMENT}.tfvars`.

Generate these files with the Landing Zone Designer: **Export → Write environments/<name>.tfvars**. They contain no secrets (subscription IDs and an SSH *public* key), so they're committed, unlike a local `terraform.tfvars`. Every change goes through a pull request (plan) and an approved apply.

## Client firewall deployments

`client-*/` folders are self-contained Terraform roots that deploy a third-party firewall hub for one client with `modules/nva-firewall`:

| Folder | Vendor | HA mode |
|---|---|---|
| `client-a-sonicwall-single` | SonicWall NSv | single |
| `client-b-pfsense-active-active` | pfSense Plus | active-active (internal + external Standard LB) |
| `client-c-fortinet-active-standby` | FortiGate | active-standby (Azure SDN failover, managed identity) |

To onboard a new client and look up Marketplace SKUs, see [modules/nva-firewall/README.md](../modules/nva-firewall/README.md).
