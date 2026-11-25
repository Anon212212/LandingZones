# Identity (tier-0)

Domain controllers are **tier-0**: anyone who controls them controls the whole forest. They're deployed in a **dedicated identity subscription**, isolated from connectivity and workloads, and are **zone-redundant within each region and redundant across regions**.

## Layout

Full diagram: [architecture.drawio.svg](architecture.drawio.svg), editable in draw.io. Identity detail:

```
 Identity subscription (tier-0)                       Connectivity subscription
 ┌───────────────────────────────────────────────┐    ┌─────────────────────────┐
 │ rg-<org>-identity-mgmt-<env>-<region>         │    │  vnet-<org>-hub-...     │
 │   log-…-identity  (tier-0 workspace, 365 d)   │    │   NVA ILB 10.145.0.36   │
 │   kv…id…          (DC admin secrets, premium) │    │   Bastion               │
 │   dcr-…-dc        (AD/DNS/DFSR events + perf) │    └──────▲──────────▲───────┘
 │                                               │      peering    global peering
 │ primary – northeurope  10.145.4.0/24 ─────────┼───────┘             │
 │   vnet-…-identity-…-neu / snet-dc /27         │                    │
 │   DC01 zone 1  10.145.4.4                     │                    │
 │   DC02 zone 2  10.145.4.5                     │◄── identity mesh   │
 │   rsv-…-identity-…-neu  (ZRS, immutable)      │    peering         │
 │                                               │       │            │
 │ secondary – westeurope 10.146.4.0/24 ─────────┼───────┴────────────┘
 │   DC01 zone 1  10.146.4.4                     │
 │   DC02 zone 2  10.146.4.5                     │
 │   rsv-…-identity-…-weu  (ZRS, immutable)      │
 └───────────────────────────────────────────────┘
```

| Failure | What keeps working |
|---|---|
| One zone | The other DC(s) in the region, ZRS vault and disks in other zones |
| One region | The DCs and vault in the other region (separate VNet, separate vault) |
| Hub NVAs | DC↔DC replication over the direct identity mesh peering |
| Accidental deletion | Delete locks on DCs, VNets, vaults, Key Vault and workspace; vault soft delete + immutability; Key Vault purge protection |
| Ransomware / bad change | Immutable backups, 30 daily / 12 weekly / 5 monthly recovery points |

Add regions or zones in `identity_regions`. Every region needs at least two zones, and you need at least two regions (both enforced by validation).

## Tier-0 controls

- **Own subscription**: `identity_subscription_id` is validated to differ from the connectivity subscription. Grant RBAC on it only to tier-0 admins.
- **Own Log Analytics and Key Vault**: lower-tier admins with access to the platform workspace can't read or alter tier-0 logs or secrets.
- **Generated admin passwords** (32 chars) go straight into the tier-0 Key Vault (RBAC, purge protection, premium SKU). Nobody types them.
- **AD DS ports open only to landing-zone CIDRs**, not the `VirtualNetwork` tag (which also contains the UDR `0.0.0.0/0`).
- **RDP only from the hub Bastion subnet and `identity_admin_source_cidrs`.** Set `identity_allow_hub_bastion = false` once tier-0 admins use dedicated PAWs or a tier-0 Bastion.
- **Hardened VMs**: Trusted Launch, no public IPs, private subnets, platform patching (one DC at a time), host caching **off** on the NTDS disk.
- Identity subscription activity log, Key Vault audit, NSG, VNet and vault diagnostics, and VNet flow logs all go to the tier-0 workspace.

## Backup (Recovery Services vault per region)

- **ZoneRedundant** storage by default. Each region has its own vault, so losing a region never loses all backups. Set `identity_backup_storage_mode = "GeoRedundant"` for Cross Region Restore as well.
- **Enhanced (V2) policy** (required for Trusted Launch), daily at 22:00 UTC with 7 days of instant restore.
- **Retention stays within the 180-day AD tombstone lifetime**: older system-state backups can't be restored into a live forest.
- **Immutability is `Unlocked`.** Lock it in the portal once retention is final. Locking is irreversible.
- Built-in Azure Monitor alerts for job failures and critical operations are on.

## Build → promote → cut over

Terraform builds the servers ready for promotion: the `F:` data disk is initialised, and the AD DS + DNS role binaries are installed. Promotion is a deliberate, audited step, not something Terraform re-runs.

1. **Apply** the configuration. Retrieve the build admin password from Key Vault: `terraform output identity_domain_controllers` lists each secret name.

2. **First DC (new forest)**: connect through Bastion, then run:

   ```powershell
   Install-ADDSForest -DomainName corp.contoso.com -DomainNetbiosName CORP `
     -DatabasePath F:\NTDS -LogPath F:\NTDS -SysvolPath F:\SYSVOL `
     -InstallDns -SafeModeAdministratorPassword (Read-Host -AsSecureString "DSRM")
   ```

   Store the DSRM password in the tier-0 Key Vault.

3. **Remaining DCs** (other zone, then the secondary region):

   ```powershell
   Install-ADDSDomainController -DomainName corp.contoso.com -InstallDns `
     -DatabasePath F:\NTDS -LogPath F:\NTDS -SysvolPath F:\SYSVOL `
     -SiteName <region-site> -Credential (Get-Credential) `
     -SafeModeAdministratorPassword (Read-Host -AsSecureString "DSRM")
   ```

4. **Sites and Services**: create one AD site per region with the identity subnets (`10.145.4.0/24`, `10.146.4.0/24`) and a site link between them. Map the spoke subnets to the primary site.

5. **DNS cutover**: set `identity_dns_servers` to the output `identity_dc_ips` (local region first) and apply. Then point the spoke VNets at the DCs (or a DNS Private Resolver forwarding to them).

6. **After promotion**:
   - Rotate the build admin password (it's now a domain account).
   - Lock vault immutability.
   - Deploy **Defender for Identity** sensors.
   - Enable Defender for Servers on the identity subscription.

## Restore

- **Lost one DC**: build a replacement (let Terraform recreate it after removing the lock) and promote it as an additional DC. Don't restore a DC from backup when healthy DCs remain.
- **Forest recovery**: restore one DC per domain from the vault (system state, authoritative restore per the [AD Forest Recovery guide](https://learn.microsoft.com/windows-server/identity/ad-ds/manage/forest-recovery-guide/ad-forest-recovery-guide)), then re-promote the others.

## Not covered here

- Dedicated tier-0 Bastion or PAW network (recommended for mature tiering).
- Azure Policy on the identity subscription/management group (deny public IPs, require Trusted Launch, restrict RBAC).
- Entra Connect / Cloud Sync servers. They are tier-0 too and belong in this subscription.
