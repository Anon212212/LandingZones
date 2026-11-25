# LandingZones

Terraform for an Azure **hub & spoke** network with a **highly available NVA pair** behind an internal Standard Load Balancer (HA Ports), Azure Bastion, NAT Gateway egress, and Log Analytics.

Good fit for enterprise landing zones, AVD, segmented shared/prod workloads, and labs that need appliance-based routing.

---

## Architecture

```
                         Internet
                            ▲
                    NAT Gateway (egress)
                            │
 ┌──────────────── Hub VNet 10.145.0.0/24 ─────────────────┐
 │ nva-external-snet .0/27   [NVA-1 .4]   [NVA-2 .5]       │
 │                              │ eth0        │ eth0        │
 │                              │ eth1        │ eth1        │
 │ nva-internal-snet .32/27  [NVA-1 .37]  [NVA-2 .38]      │
 │                         ILB frontend .36 (HA Ports)      │
 │ mgmt-snet .64/27          AzureBastionSubnet .96/27      │
 └─────────────┬──────────┬──────────┬──────────┬──────────┘
          peering    peering    peering    peering
               │          │          │          │
           Shared       Prod        AVD      Identity
        10.145.1/24  10.145.2/24 10.145.3/24 10.145.4/24
```

Every spoke subnet has a UDR sending `0.0.0.0/0` to the ILB frontend, so spoke↔spoke and spoke→Internet traffic is inspected by the NVAs.

### Address plan (defaults)

All hub subnets, NVA IPs and the ILB frontend are **derived** from `hub_address_space` with `cidrsubnet`/`cidrhost`, so changing the variable re-addresses everything consistently.

| VNet | CIDR | Subnet | CIDR | Purpose |
|---|---|---|---|---|
| Hub | `10.145.0.0/24` | `nva-external-snet` | `10.145.0.0/27` | NVA untrusted side, NAT Gateway |
| | | `nva-internal-snet` | `10.145.0.32/27` | NVA trusted side, ILB |
| | | `mgmt-snet` | `10.145.0.64/27` | Management |
| | | `AzureBastionSubnet` | `10.145.0.96/27` | Bastion |
| Shared | `10.145.1.0/24` | `shared-app-snet` | `10.145.1.0/24` | Shared workloads |
| Prod | `10.145.2.0/24` | `prod-app-snet` | `10.145.2.0/24` | Production apps |
| AVD | `10.145.3.0/24` | `avd-sessionhosts-snet` | `10.145.3.0/24` | AVD session hosts |
| Identity | `10.145.4.0/24` | `dc-snet` | `10.145.4.0/27` | Domain controllers |

### NVA pair

| | NVA-1 (zone 1) | NVA-2 (zone 2) |
|---|---|---|
| External NIC (eth0, primary) | `10.145.0.4` | `10.145.0.5` |
| Internal NIC (eth1, LB backend) | `10.145.0.37` | `10.145.0.38` |

- Ubuntu 22.04 LTS (Gen2), IP forwarding + accelerated networking on both NICs.
- **cloud-init** (`templates/nva-cloud-init.yaml.tftpl`) turns on kernel forwarding, adds return routes for every spoke via eth1, and SNATs Internet-bound traffic out of eth0. Swap the image/cloud-init for a vendor firewall image as needed.
- Scale out by adding zones to `nva_zones`.

### Internal Load Balancer

- Frontend `10.145.0.36` (zone-redundant). Azure reserves the first four IPs of each subnet, so `.32`–`.35` can't be used.
- HA Ports rule (all protocols, all ports) → both internal NICs.
- Health probe TCP 22 every 5 s.

### Security

| NSG | Applied to | Rules |
|---|---|---|
| `nva-nsg` | Both NVA NICs | SSH from Bastion + mgmt subnets (+ `nva_mgmt_source_cidrs`), all VNet transit traffic |
| `mgmt-nsg` | `mgmt-snet` | VNet inbound |
| `id-dc-nsg` | `dc-snet` | Full AD DS TCP/UDP port set (incl. Kerberos, LDAPS, GC, ADWS, NTP, dynamic RPC) from VNet; RDP from Bastion + mgmt |

Spoke route tables have BGP route propagation turned off, so a VPN/ExpressRoute gateway added later can't bypass the NVAs.

### Operations

- **Bastion** (`bastion_sku`: Basic/Standard) for SSH/RDP with no public IPs on VMs.
- **Log Analytics** workspace with diagnostics from Bastion (audit logs) and the ILB (metrics).
- **NAT Gateway** on the external subnet gives a fixed egress IP (Azure default outbound access is being retired).

---

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # set org_prefix + SSH key
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

Uncomment the `backend "azurerm"` block in `providers.tf` to keep state remotely.

### Key variables

| Variable | Default | Notes |
|---|---|---|
| `org_prefix` | — | Required. 2–15 lowercase chars. |
| `nva_admin_ssh_public_key` | — | Required. |
| `location` | `northeurope` | Must support Availability Zones. |
| `hub_address_space` | `10.145.0.0/24` | /24 or larger. |
| `spoke_address_space` / `prod_` / `avd_` / `id_address_space` | `10.145.1-4.0/24` | |
| `nva_zones` | `["1","2"]` | One NVA per zone. |
| `nva_size` | `Standard_D2s_v3` | |
| `nva_mgmt_source_cidrs` | `[]` | Extra SSH sources beyond Bastion/mgmt. |
| `enable_nat_gateway` | `true` | |
| `bastion_sku` | `Basic` | |
| `tags` | `{}` | Merged onto every resource. |

### Outputs

`hub_vnet_id`, `spoke_vnet_ids`, `spoke_subnet_ids`, `hub_subnet_ids`, `nva_ilb_frontend_ip`, `nva_private_ips`, `nat_gateway_public_ip`, `bastion_name`, `log_analytics_workspace_id`.

## File layout

| File | Contents |
|---|---|
| `providers.tf` | Terraform/provider versions, optional backend |
| `variables.tf` | Inputs with validation |
| `locals.tf` | Derived addressing and the spoke map |
| `main.tf` | Resource groups, Log Analytics, diagnostics |
| `network.tf` | VNets, subnets, peerings, route tables, NAT Gateway |
| `security.tf` | NSGs and associations |
| `nva.tf` | ILB, NVA NICs/VMs, Bastion |
| `outputs.tf` | Outputs |
