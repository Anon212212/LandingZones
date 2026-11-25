# LandingZones

Terraform for an Azure **hub & spoke** network with a **highly available NVA pair** behind an internal Standard Load Balancer (HA Ports), aligned to the **Azure Well-Architected Framework** and Cloud Adoption Framework naming.

➡️ **[Well-Architected alignment, pillar by pillar](docs/well-architected.md)**

---

## Architecture

```
                         Internet
                            ▲
                    NAT Gateway (egress)
                            │
 ┌──────────── vnet-<org>-hub-<env>-<region>  10.145.0.0/24 ────────────┐
 │ snet-nva-external .0/27     [NVA-1 .4 z1]   [NVA-2 .5 z2]            │
 │                                 │ eth0           │ eth0               │
 │                                 │ eth1           │ eth1               │
 │ snet-nva-internal .32/27    [NVA-1 .37]     [NVA-2 .38]              │
 │                        ILB frontend .36 (HA Ports, zone-redundant)   │
 │ snet-mgmt .64/27            AzureBastionSubnet .96/27 (zone-redundant)│
 └──────────────┬───────────┬───────────┬───────────┬───────────────────┘
           peering     peering     peering     peering
                │           │           │           │
            shared        prod         avd       identity
         10.145.1/24  10.145.2/24  10.145.3/24  10.145.4/24
```

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
| identity | `10.145.4.0/24` | `snet-dc` | `/27` | AD DS |

### What's deployed

| Area | Resources |
|---|---|
| Connectivity | Hub + 4 spokes, peerings, route tables, NAT Gateway |
| NVA | 2+ Ubuntu 24.04 VMs (one per zone, Trusted Launch, accelerated networking, platform patching), HA Ports ILB, cloud-init router/SNAT config |
| Access | Azure Bastion (zone-redundant) |
| Security | NSGs on every subnet + NVA NICs, optional DDoS plan, optional encryption at host |
| Monitoring | Log Analytics, diagnostics on all network resources, VNet flow logs + Traffic Analytics, Azure Monitor Agent + DCR on NVAs |
| Alerting | ILB health/data path, NVA availability and CPU, NAT SNAT failures, Service Health, Resource Health |
| Governance | Mandatory tags, delete locks, monthly budget |

---

## Usage

Prerequisites: Terraform ≥ 1.9 and Azure CLI login (or a service principal / OIDC).

```bash
cp terraform.tfvars.example terraform.tfvars   # set org_prefix, owner, cost_center, SSH key
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

### Testing

`terraform test` plans against a mocked provider (no credentials needed) and asserts the WAF guardrails: addressing, zones, NSG coverage, private subnets, Trusted Launch, flow logs, diagnostics, tags, budget and naming. CI (`.github/workflows/terraform.yml`) runs `fmt`, `validate`, `test`, `tflint` and `checkov` on every PR.

```bash
terraform test
```

### Key variables

| Variable | Default | Notes |
|---|---|---|
| `org_prefix` | — | **Required.** 2–15 lowercase chars. |
| `owner`, `cost_center` | — | **Required.** Mandatory tags. |
| `nva_admin_ssh_public_key` | — | **Required.** |
| `subscription_id` | `null` | Falls back to `ARM_SUBSCRIPTION_ID`. |
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
| `outputs.tf` | Outputs |
| `tests/` | `terraform test` guardrails |
| `docs/well-architected.md` | WAF pillar mapping, trade-offs, gaps |
