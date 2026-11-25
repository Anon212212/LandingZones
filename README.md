# LandingZones

Terraform for an Azure **hub & spoke** network with a **highly available NVA pair** behind an internal Standard Load Balancer (HA Ports), aligned to the **Azure Well-Architected Framework** and Cloud Adoption Framework naming.

➡️ **[Well-Architected alignment, pillar by pillar](docs/well-architected.md)** · **[Identity (tier-0) design & runbook](docs/identity.md)**

Two subscriptions:

| Subscription | Contents |
|---|---|
| Connectivity | Hub, workload spokes (shared, prod, avd), HA NVAs, Bastion, NAT Gateway, platform monitoring |
| Identity (tier-0) | Domain controllers in two regions × two zones, a Recovery Services vault per region, tier-0 Key Vault and Log Analytics |

---

## Architecture

[![Architecture diagram: hub & spoke with HA NVAs in the connectivity subscription and region- and zone-redundant domain controllers in the tier-0 identity subscription](docs/architecture.drawio.svg)](docs/architecture.drawio.svg)

> **Editing the diagram:** `docs/architecture.drawio.svg` is an SVG with the draw.io model embedded. Open it in [diagrams.net](https://app.diagrams.net) (*File → Open from → Device*) or in VS Code with the *Draw.io Integration* extension, edit, and save it in place. GitHub keeps rendering the updated SVG, so there's no separate export step.

Every spoke subnet has a UDR sending `0.0.0.0/0` to the ILB frontend, so spoke↔spoke and spoke→Internet traffic always goes through the NVAs. All workload subnets are private (no default outbound access).

### Address plan (defaults)

Hub subnets, NVA IPs and the ILB frontend are **derived** from `hub_address_space`, so changing the variable re-addresses everything consistently. Azure reserves the first four IPs of each subnet, which is why the ILB uses `.36`.

| VNet | CIDR | Subnet | CIDR | NSG |
|---|---|---|---|---|
| hub | `10.145.0.0/24` | `snet-nva-external` | `.0/27` | nva |
| | | `snet-nva-internal` | `.32/27` | nva |
| | | `snet-mgmt` | `.64/27` | mgmt |
| | | `AzureBastionSubnet` | `.96/27` | bastion (Microsoft rule set) |
| shared | `10.145.1.0/24` | `snet-shared-app` | `/24` | spoke baseline |
| prod | `10.145.2.0/24` | `snet-prod-app` | `/24` | spoke baseline |
| avd | `10.145.3.0/24` | `snet-avd-sessionhosts` | `/24` | spoke baseline |
| identity (primary, identity sub) | `10.145.4.0/24` | `snet-dc` | `/27` | AD DS (landing-zone CIDRs only) |
| identity (secondary, identity sub) | `10.146.4.0/24` | `snet-dc` | `/27` | AD DS (landing-zone CIDRs only) |

### What's deployed

| Area | Resources |
|---|---|
| Connectivity | Hub + 4 spokes, peerings, route tables, NAT Gateway |
| NVA | 2+ Ubuntu 24.04 VMs (one per zone, Trusted Launch, accelerated networking, platform patching), HA Ports ILB, cloud-init router/SNAT config |
| Access | Azure Bastion (zone-redundant) |
| Security | NSGs on every subnet + NVA NICs, optional DDoS plan, optional encryption at host |
| Monitoring | Log Analytics, diagnostics on all network resources, VNet flow logs + Traffic Analytics, Azure Monitor Agent + DCR on NVAs |
| Alerting | ILB health/data path, NVA availability and CPU, NAT SNAT failures, Service Health, Resource Health |
| Identity (tier-0) | Dedicated subscription. Per region: VNet, one Windows Server 2025 DC per zone (static IP, NTDS disk with caching off, Trusted Launch), a ZRS immutable Recovery Services vault with an Enhanced daily policy. Shared: tier-0 Key Vault (generated admin passwords), tier-0 Log Analytics, DCR, identity mesh peering |
| Governance | Mandatory tags, delete locks, monthly budget |

---

## Landing Zone Designer (GUI)

Prefer not to edit variables by hand? `gui/` contains a Python front end. Choose options from dropdowns and presets, watch the architecture diagram update live, switch on **NIS2** / **DORA** to enforce their baseline on top of WAF, and export `terraform.tfvars`, an editable draw.io diagram and a compliance report.

```bash
pip install -r gui/requirements.txt
```

```bash
python gui/app.py
```

[![Landing Zone Designer](docs/images/designer-overview.png)](gui/README.md#screenshots)

See [gui/README.md](gui/README.md) for a screen-by-screen walkthrough.

## Usage

Prerequisites: Terraform ≥ 1.9, Azure CLI login (or a service principal / OIDC), and two subscriptions in the same tenant (connectivity and identity). The deploying identity needs Owner (or Contributor + User Access Administrator) on both, because it peers across them and grants itself Key Vault Secrets Officer on the tier-0 vault.

```bash
cp terraform.tfvars.example terraform.tfvars   # set org_prefix, owner, cost_center, SSH key, identity_subscription_id
```

```bash
export ARM_SUBSCRIPTION_ID=<subscription-id>
```

```bash
terraform init
```

```bash
terraform plan -out tfplan
```

```bash
terraform apply tfplan
```

Uncomment the `backend "azurerm"` block in `providers.tf` to keep state remotely. To tear down, set `enable_resource_locks = false` and apply before running `terraform destroy`.

After the first apply, promote the domain controllers and cut DNS over by following **[docs/identity.md](docs/identity.md)**.

### Testing

`terraform test` plans against a mocked provider (no credentials needed) and asserts the WAF and tier-0 guardrails: addressing, zones, NSG coverage, private subnets, Trusted Launch, flow logs, diagnostics, tags, budget, naming, identity region/zone redundancy, separate subscription, NTDS disk caching, backup policy and tombstone-safe retention. CI (`.github/workflows/terraform.yml`) runs `fmt`, `validate`, `test`, `tflint` and `checkov` on every PR.

```bash
terraform test
```

### Key variables

| Variable | Default | Notes |
|---|---|---|
| `org_prefix` | — | **Required.** 2–15 lowercase chars. |
| `owner`, `cost_center` | — | **Required.** Mandatory tags. |
| `nva_admin_ssh_public_key` | — | **Required.** |
| `subscription_id` | `null` | Connectivity subscription. Falls back to `ARM_SUBSCRIPTION_ID`. |
| `identity_subscription_id` | — | **Required.** Dedicated tier-0 subscription. |
| `identity_regions` | neu `10.145.4.0/24` + weu `10.146.4.0/24`, zones 1–2 | ≥ 2 regions, ≥ 2 zones each. |
| `dc_size` / `dc_image_sku` | `Standard_D2s_v5` / `2025-datacenter-azure-edition` | |
| `identity_backup_storage_mode` | `ZoneRedundant` | `GeoRedundant` adds Cross Region Restore. |
| `identity_dns_servers` | `[]` | Set to `identity_dc_ips` after promotion. |
| `identity_allow_hub_bastion` / `identity_admin_source_cidrs` | `true` / `[]` | Who may RDP to DCs. |
| `identity_key_vault_allowed_ips` | `[]` | Restrict the tier-0 Key Vault firewall. |
| `environment` | `prod` | Used in names and tags. |
| `location` | `northeurope` | Must support Availability Zones. |
| `zones` | `["1","2","3"]` | Zone-redundant ILB, Bastion, public IPs. |
| `nva_zones` | `["1","2"]` | One NVA per zone; add zones to scale out. |
| `nva_size` | `Standard_D2s_v5` | |
| `alert_email_addresses` | `[]` | Action group + budget recipients. |
| `monthly_budget_amount` | `0` | 0 disables the budget. |
| `enable_flow_logs` | `true` | Needs the region's Network Watcher. |
| `enable_nat_gateway` | `true` | |
| `enable_resource_locks` | `true` | |
| `bastion_sku` | `Standard` | `Basic` to save cost. |
| `ddos_protection_plan_id` | `null` | Attach an existing DDoS plan. |
| `nva_encryption_at_host` | `false` | Requires a subscription feature. |
| `log_retention_days` / `log_daily_quota_gb` | `90` / `-1` | |

See `variables.tf` for the full list, all with validation and descriptions.

## File layout

| File | Contents |
|---|---|
| `providers.tf` | Terraform/provider versions, provider features, optional backend |
| `variables.tf` | Inputs with validation, grouped by WAF pillar |
| `locals.tf` | CAF naming, tags, derived addressing, spoke map |
| `main.tf` | Resource groups, Log Analytics, delete locks |
| `network.tf` | VNets, subnets, peerings, route tables, NAT Gateway |
| `security.tf` | NSGs and associations |
| `nva.tf` | ILB, NVA NICs/VMs, Azure Monitor Agent |
| `bastion.tf` | Azure Bastion |
| `monitoring.tf` | Diagnostics, flow logs, DCR, action group, alerts |
| `cost.tf` | Budget |
| `identity.tf` | Tier-0 shared services, identity modules, peerings, DC alerts |
| `modules/identity-region/` | Per-region identity: VNet, NSG, DCs, NTDS disks, Recovery Services vault, flow logs |
| `outputs.tf` | Outputs |
| `tests/` | `terraform test` guardrails |
| `docs/well-architected.md` | WAF pillar mapping, trade-offs, gaps |
| `docs/identity.md` | Tier-0 identity design, backup, promotion and restore runbook |
| `gui/` | Landing Zone Designer: GUI, compliance rules engine (WAF/NIS2/DORA), live diagram, tfvars generator |
