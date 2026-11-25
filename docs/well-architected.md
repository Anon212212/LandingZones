# Azure Well-Architected Framework alignment

This maps the landing zone against the five [Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/) pillars. Resources are named with the [Cloud Adoption Framework](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming) convention. Every control marked ✅ is enforced in code, and `terraform test` (`tests/landing_zone.tftest.hcl`) checks most of them on every PR.

Legend: ✅ implemented · ⚙️ implemented, off by default (cost or prerequisite) · ⚠️ accepted trade-off · ⛔ out of scope for this repo

---

## 1. Reliability

| Control | Status | Where |
|---|---|---|
| NVAs spread across Availability Zones (one per zone, ≥ 2 enforced by validation) | ✅ | `nva.tf`, `var.nva_zones` |
| Zone-redundant ILB frontend | ✅ | `nva.tf` |
| Zone-redundant Bastion host and public IP | ✅ | `bastion.tf` |
| HA Ports ILB with 5 s probe / 2 failures (fails over in about 10 s) | ✅ | `nva.tf` |
| Platform-orchestrated patching (`AutomaticByPlatform`), so both NVAs are never rebooted together | ✅ | `nva.tf` |
| NVAs are stateless and rebuilt from code + cloud-init (no backup needed) | ✅ | `templates/nva-cloud-init.yaml.tftpl` |
| `CanNotDelete` locks on hub VNet and Log Analytics | ✅ | `main.tf` |
| Terraform refuses to delete RGs that contain unmanaged resources | ✅ | `providers.tf` |
| ZRS storage for flow logs | ✅ | `monitoring.tf` |
| Alerts: ILB backend health, ILB data path, NVA availability, Service Health (region + global), Resource Health | ✅ | `monitoring.tf` |
| Standard NAT Gateway is a zonal resource and is left non-zonal | ⚠️ | A zone outage could interrupt Internet egress. Mitigate with StandardV2 NAT Gateway once it's available in your region, or one NAT per zone with zonal NVAs. |
| The health probe (TCP 22) proves `sshd` is up, not that forwarding works | ⚠️ | Replace with an HTTP probe that checks `ip_forward` and upstream reachability for a vendor appliance. |
| **Identity**: DCs in ≥ 2 regions × ≥ 2 zones (enforced), direct identity mesh peering for replication | ✅ | `identity.tf`, `modules/identity-region` |
| **Identity**: Recovery Services vault per region, ZRS, Enhanced daily policy, immutability, soft delete | ✅ | `modules/identity-region` |
| **Identity**: DC availability alert per region | ✅ | `identity.tf` |
| Secondary-region DCs route Internet egress through the primary hub NVAs | ⚠️ | When a secondary hub is added, set `identity_regions.secondary.next_hop_ip` to it. |
| Multi-region DR for workloads (secondary hub) | ⛔ | Add a second hub per region. |

## 2. Security

| Control | Status | Where |
|---|---|---|
| NSG on every subnet (incl. the full Microsoft rule set on `AzureBastionSubnet`) and NIC-level NSG on the NVAs, each ending in an explicit Deny-All | ✅ | `security.tf` |
| Private subnets (`default_outbound_access_enabled = false`); egress only through NVA → NAT Gateway | ✅ | `network.tf` |
| All spoke traffic forced through the NVAs; BGP propagation off so gateway routes can't bypass them | ✅ | `network.tf` |
| No public IPs on VMs; SSH/RDP only through Bastion or the mgmt subnet | ✅ | `security.tf`, `bastion.tf` |
| Bastion shareable links off | ✅ | `bastion.tf` |
| Trusted Launch (Secure Boot + vTPM), SSH-key-only auth | ✅ | `nva.tf` |
| System-assigned managed identity (no stored credentials for monitoring) | ✅ | `nva.tf` |
| Log Analytics local auth off (Entra ID only) | ✅ | `main.tf` |
| Storage: TLS 1.2, HTTPS only, no public blobs, firewall default-deny with trusted-services bypass, Terraform uses Entra ID / management plane only | ✅ | `monitoring.tf`, `providers.tf` |
| Full AD DS port set on the DC subnet, scoped to `VirtualNetwork` | ✅ | `security.tf` |
| VNet flow logs + Traffic Analytics on every VNet | ✅ | `monitoring.tf` |
| Encryption at host | ⚙️ | `var.nva_encryption_at_host` (register the subscription feature first) |
| DDoS Network Protection | ⚙️ | `var.ddos_protection_plan_id`. A plan is about USD 2.9k/month, so share one across the tenant. |
| The `VirtualNetwork` service tag also includes UDR prefixes, so with `0.0.0.0/0 → NVA`, spoke "Allow-VNet-Inbound" rules effectively allow any source that reaches the NVA | ⚠️ | Acceptable because the NVA is the only path in. Tighten spoke rules to explicit CIDRs for production workloads. |
| Flow-log storage keeps shared-key access enabled | ⚠️ | Kept for Network Watcher compatibility. Terraform never uses keys. |
| The Linux NVA is a router/SNAT, **not** an inspecting firewall (no IDPS, TLS inspection or FQDN filtering) | ⚠️ | For production, swap the image for a vendor NGFW or replace the pair with Azure Firewall Premium. The ILB/UDR design stays the same. |
| **Identity is tier-0 in its own subscription** with its own Key Vault (premium, RBAC, purge protection) and Log Analytics (365 days, Entra-only) | ✅ | `identity.tf`, `providers.tf` |
| DC admin passwords generated and stored only in the tier-0 Key Vault | ✅ | `modules/identity-region` |
| AD DS ports open to landing-zone CIDRs only; RDP only from approved admin sources | ✅ | `modules/identity-region` |
| NTDS on a data disk with host caching off; static IPs | ✅ | `modules/identity-region` |
| Tier-0 RDP through the shared hub Bastion by default | ⚠️ | Set `identity_allow_hub_bastion = false` and use PAWs / a tier-0 Bastion. |
| Tier-0 Key Vault firewall open unless `identity_key_vault_allowed_ips` is set | ⚠️ | Set it to the deployment agent's egress IPs. |
| Azure Policy (ALZ policy set), Defender for Cloud / Defender for Identity, RBAC/PIM, Private DNS | ⛔ | Belongs to the platform/management-group layer. See `docs/identity.md`. |

## 3. Cost Optimization

| Control | Status | Where |
|---|---|---|
| Mandatory `environment`, `owner`, `cost-center` tags on every resource | ✅ | `locals.tf`, `variables.tf` |
| Monthly budget across the landing-zone RGs (80 % actual, 100 % forecast, 100 % actual) | ⚙️ | `cost.tf`. Set `monthly_budget_amount` and `alert_email_addresses`. |
| Log Analytics retention and optional daily cap | ✅ | `var.log_retention_days`, `var.log_daily_quota_gb` |
| Resource-specific diagnostic tables (cheaper than `AzureDiagnostics`) | ✅ | `monitoring.tf` |
| Raw flow-log retention capped | ✅ | `var.flow_log_retention_days` |
| Right-sized current-gen NVA (`D2s_v5`), StandardSSD OS disk for a stateless appliance | ✅ | `variables.tf`, `nva.tf` |
| Optional cost levers: NAT Gateway, Bastion SKU, DDoS, NVA count | ✅ | `variables.tf` |
| Azure Hybrid Benefit for DCs | ⚙️ | `var.dc_hybrid_benefit` |
| Reservations / savings plan for the NVA and DC VMs | ⛔ | Purchase decision. Always-on VMs are a good candidate. |

## 4. Operational Excellence

| Control | Status | Where |
|---|---|---|
| Everything as code, CAF naming, files split by concern | ✅ | repo |
| CI: `fmt`, `validate`, `terraform test`, `tflint` (azurerm ruleset), `checkov` | ✅ | `.github/workflows/terraform.yml` |
| Offline guardrail tests for WAF and tier-0 controls (mocked provider, no credentials) | ✅ | `tests/` |
| Reusable per-region identity module | ✅ | `modules/identity-region` |
| Documented build → promote → DNS cutover → restore runbook | ✅ | `docs/identity.md` |
| Input validation on prefix, environment, CIDRs, zones, SKUs, retention | ✅ | `variables.tf` |
| Central Log Analytics with diagnostics from Bastion, ILB, NSGs, VNets, public IPs, NAT Gateway | ✅ | `monitoring.tf` |
| Guest telemetry (syslog auth + system, CPU/memory/network/disk) through Azure Monitor Agent + DCR | ✅ | `monitoring.tf`, `nva.tf` |
| Common-schema action group for all alerts | ✅ | `monitoring.tf` |
| Remote state with Entra ID auth | ⚙️ | `providers.tf` (uncomment the backend) |
| Commit `.terraform.lock.hcl` for all platforms (`terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64`) | ⚙️ | Run once where the registry is reachable. |
| Plan/apply pipeline with OIDC and environment approvals | ⛔ | Add when a deployment identity exists. |

## 5. Performance Efficiency

| Control | Status | Where |
|---|---|---|
| Accelerated networking on all NVA NICs | ✅ | `nva.tf` |
| Horizontal scale-out: add zones to `nva_zones` (ILB spreads flows with HA Ports) | ✅ | `variables.tf` |
| Vertical scale: `nva_size` (D-series v5 network bandwidth scales with size) | ✅ | `variables.tf` |
| CPU alert as the scaling signal (`nva_cpu_alert_threshold`) | ✅ | `monitoring.tf` |
| SNAT exhaustion alert on the NAT Gateway (add public IPs when it fires) | ✅ | `monitoring.tf` |
| Traffic Analytics for top talkers and capacity planning | ✅ | `monitoring.tf` |
| Load testing of NVA throughput | ⛔ | Validate with `iperf3`/`ntttcp` across zones before production. |

---

## Breaking changes from the previous version

- **CAF names**: every resource is renamed (e.g. `contoso-hub-vnet` → `vnet-contoso-hub-prod-neu`), so this is a re-deploy rather than an in-place upgrade.
- **New required variables**: `owner`, `cost_center` and `identity_subscription_id`. azurerm 4.x also needs `subscription_id` or `ARM_SUBSCRIPTION_ID`.
- **Identity moved** out of the connectivity subscription into a dedicated tier-0 subscription. `id_address_space` is replaced by `identity_regions`.
- **Provider**: azurerm `~> 4.70` (needed for VNet flow logs), Terraform `>= 1.9`.
- **Defaults changed**: Bastion `Standard`, NVA `Standard_D2s_v5`, Ubuntu 24.04 LTS, log retention 90 days.
