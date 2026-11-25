#############################################
# General / governance
#############################################

variable "subscription_id" {
  description = "Target subscription ID. Leave null to use ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "org_prefix" {
  description = "Short org/workload prefix used in every resource name (e.g. \"contoso\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.org_prefix))
    error_message = "org_prefix must be 2-15 chars, lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name; used in resource names and the mandatory environment tag."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "nonprod", "uat", "test", "dev", "sandbox"], var.environment)
    error_message = "environment must be one of prod, nonprod, uat, test, dev, sandbox."
  }
}

variable "location" {
  description = "Azure region. Must support Availability Zones."
  type        = string
  default     = "northeurope"
}

variable "owner" {
  description = "[Cost/OpEx] Accountable owner (team or email). Applied as the mandatory owner tag."
  type        = string
}

variable "cost_center" {
  description = "[Cost] Cost center for chargeback. Applied as the mandatory cost-center tag."
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto every taggable resource."
  type        = map(string)
  default     = {}
}

#############################################
# Address spaces
#
# Hub subnets, NVA IPs and the ILB frontend are derived from
# hub_address_space, so changing it re-addresses everything consistently.
#############################################

variable "hub_address_space" {
  description = "Hub VNet CIDR, split into four equal subnets (NVA external, NVA internal, mgmt, Bastion). Must be /24 or larger."
  type        = string
  default     = "10.145.0.0/24"

  validation {
    condition     = can(cidrhost(var.hub_address_space, 0)) && tonumber(split("/", var.hub_address_space)[1]) <= 24
    error_message = "hub_address_space must be a valid CIDR of /24 or larger (AzureBastionSubnet needs at least /27)."
  }
}

variable "shared_services_subscription_id" {
  description = "[Security] Landing-zone subscription for shared-services spokes (subscription = \"shared\"). Required when any spoke uses it."
  type        = string
  default     = null

  validation {
    condition     = var.shared_services_subscription_id == null || can(regex("^[0-9a-fA-F-]{36}$", var.shared_services_subscription_id))
    error_message = "shared_services_subscription_id must be a subscription GUID."
  }

  validation {
    condition     = var.shared_services_subscription_id != null || !anytrue([for s in values(var.spokes) : s.subscription == "shared"])
    error_message = "A spoke uses subscription = \"shared\" – set shared_services_subscription_id."
  }

  validation {
    condition = var.shared_services_subscription_id == null || !contains(
      [for x in [var.subscription_id, var.identity_subscription_id, var.production_subscription_id, var.avd_subscription_id] : lower(x) if x != null],
    lower(coalesce(var.shared_services_subscription_id, "-")))
    error_message = "The shared-services subscription must be its own subscription (not connectivity, identity, production or AVD)."
  }
}

variable "production_subscription_id" {
  description = "[Security] Landing-zone subscription for production spokes (subscription = \"prod\"). Required when any spoke uses it."
  type        = string
  default     = null

  validation {
    condition     = var.production_subscription_id == null || can(regex("^[0-9a-fA-F-]{36}$", var.production_subscription_id))
    error_message = "production_subscription_id must be a subscription GUID."
  }

  validation {
    condition     = var.production_subscription_id != null || !anytrue([for s in values(var.spokes) : s.subscription == "prod"])
    error_message = "A spoke uses subscription = \"prod\" – set production_subscription_id."
  }

  validation {
    condition = var.production_subscription_id == null || !contains(
      [for x in [var.subscription_id, var.identity_subscription_id, var.avd_subscription_id] : lower(x) if x != null],
    lower(coalesce(var.production_subscription_id, "-")))
    error_message = "The production subscription must be its own subscription (not connectivity, identity or AVD)."
  }
}

variable "avd_subscription_id" {
  description = "[Security] Landing-zone subscription for Azure Virtual Desktop spokes (subscription = \"avd\"). Required when any spoke uses it."
  type        = string
  default     = null

  validation {
    condition     = var.avd_subscription_id == null || can(regex("^[0-9a-fA-F-]{36}$", var.avd_subscription_id))
    error_message = "avd_subscription_id must be a subscription GUID."
  }

  validation {
    condition     = var.avd_subscription_id != null || !anytrue([for s in values(var.spokes) : s.subscription == "avd"])
    error_message = "A spoke uses subscription = \"avd\" – set avd_subscription_id."
  }

  validation {
    condition = var.avd_subscription_id == null || !contains(
      [for x in [var.subscription_id, var.identity_subscription_id] : lower(x) if x != null],
    lower(coalesce(var.avd_subscription_id, "-")))
    error_message = "The AVD subscription must be its own subscription (not connectivity or identity)."
  }
}

variable "spokes" {
  description = <<-EOT
    Workload spokes, keyed by a short name used in resource names. Each spoke
    gets its own resource group, VNet (one subnet spanning it), NSG, route
    table to the NVAs and hub peering, in the subscription named by
    `subscription`: "connectivity", "shared" (shared_services_subscription_id),
    "prod" (production_subscription_id) or "avd" (avd_subscription_id).
    nsg_rules are added to the
    baseline NSG (Bastion + VNet in, AzureLoadBalancer, deny-all) and must use
    priorities 300-3900.
  EOT
  type = map(object({
    address_space = string
    subscription  = optional(string, "connectivity")
    subnet_name   = optional(string)
    nsg_rules = optional(list(object({
      name                    = string
      priority                = number
      direction               = optional(string, "Inbound")
      access                  = optional(string, "Allow")
      protocol                = optional(string, "Tcp")
      source_address_prefixes = list(string)
      destination_port_ranges = list(string)
    })), [])
  }))
  default = {
    shared = { address_space = "10.145.1.0/24", subscription = "shared", subnet_name = "snet-shared-app" }
    prod   = { address_space = "10.145.2.0/24", subscription = "prod", subnet_name = "snet-prod-app" }
    avd    = { address_space = "10.145.3.0/24", subscription = "avd", subnet_name = "snet-avd-sessionhosts" }
  }

  validation {
    condition     = alltrue([for s in values(var.spokes) : contains(["connectivity", "shared", "prod", "avd"], s.subscription)])
    error_message = "Spoke subscription must be connectivity, shared, prod or avd."
  }

  validation {
    condition     = alltrue([for k in keys(var.spokes) : can(regex("^[a-z][a-z0-9]{1,15}$", k))])
    error_message = "Spoke names must be 2-16 lowercase letters/digits, starting with a letter."
  }

  validation {
    condition     = alltrue([for s in values(var.spokes) : can(cidrhost(s.address_space, 0))])
    error_message = "Every spoke address_space must be a valid CIDR."
  }

  validation {
    condition = alltrue(flatten([for s in values(var.spokes) : [
      for r in s.nsg_rules : r.priority >= 300 && r.priority <= 3900
      && contains(["Inbound", "Outbound"], r.direction)
      && contains(["Allow", "Deny"], r.access)
      && contains(["Tcp", "Udp", "Icmp", "*"], r.protocol)
    ]]))
    error_message = "Spoke NSG rules need priority 300-3900, direction Inbound/Outbound, access Allow/Deny and protocol Tcp/Udp/Icmp/*."
  }

  validation {
    condition     = alltrue([for s in values(var.spokes) : length(distinct([for r in s.nsg_rules : "${r.direction}-${r.priority}"])) == length(s.nsg_rules)])
    error_message = "NSG rule priorities must be unique per direction within a spoke."
  }

  validation {
    condition = alltrue(flatten([for s in values(var.spokes) : [
      for r in s.nsg_rules : r.direction == "Outbound" || r.access == "Deny"
      || !anytrue([for p in r.source_address_prefixes : contains(["*", "0.0.0.0/0", "Internet", "Any"], p)])
    ]]))
    error_message = "[Security] Spoke NSG rules must not allow inbound traffic from the Internet."
  }
}

#############################################
# Identity (tier-0) – dedicated subscription, region + zone redundant
#############################################

variable "identity_subscription_id" {
  description = "[Security] Dedicated tier-0 subscription for domain controllers, their vaults, Key Vault and Log Analytics. Must differ from the connectivity subscription."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.identity_subscription_id))
    error_message = "identity_subscription_id must be a subscription GUID."
  }

  validation {
    condition     = var.subscription_id == null || lower(coalesce(var.subscription_id, "-")) != lower(var.identity_subscription_id)
    error_message = "Tier-0 identity must live in its own subscription, separate from connectivity."
  }
}

variable "identity_regions" {
  description = <<-EOT
    [Reliability] Identity deployments, one per region. Each region gets its own
    VNet, one DC per zone in dc_zones, and its own Recovery Services vault.
    next_hop_ip defaults to the hub NVA ILB (set it to a regional hub's
    firewall when you add one).
  EOT
  type = map(object({
    location      = string
    address_space = string
    dc_zones      = optional(list(string), ["1", "2"])
    next_hop_ip   = optional(string)
  }))
  default = {
    primary = {
      location      = "northeurope"
      address_space = "10.145.4.0/24"
    }
    secondary = {
      location      = "westeurope"
      address_space = "10.146.4.0/24"
    }
  }

  validation {
    condition     = length(var.identity_regions) >= 2 && length(distinct([for r in values(var.identity_regions) : r.location])) == length(var.identity_regions)
    error_message = "Identity needs at least two entries in different regions for regional redundancy."
  }

  validation {
    condition     = alltrue([for r in values(var.identity_regions) : length(r.dc_zones) >= 2 && length(distinct(r.dc_zones)) == length(r.dc_zones)])
    error_message = "Each identity region needs at least two DCs in distinct zones."
  }

  validation {
    condition     = alltrue([for r in values(var.identity_regions) : can(cidrhost(r.address_space, 0))])
    error_message = "Every identity address_space must be a valid CIDR."
  }
}

variable "dc_size" {
  description = "Domain controller VM size (Trusted Launch + accelerated networking capable)."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "dc_admin_username" {
  description = "Local admin on the DC build. The generated password is stored in the tier-0 Key Vault."
  type        = string
  default     = "dcadmin"

  validation {
    condition     = !contains(["administrator", "admin", "user", "guest", "root"], lower(var.dc_admin_username))
    error_message = "dc_admin_username cannot be a reserved Windows name."
  }
}

variable "dc_image_sku" {
  description = "WindowsServer Gen2 image SKU for DCs."
  type        = string
  default     = "2025-datacenter-azure-edition"
}

variable "dc_data_disk_size_gb" {
  description = "Size of the NTDS/SYSVOL data disk."
  type        = number
  default     = 64
}

variable "dc_hybrid_benefit" {
  description = "[Cost] Apply Azure Hybrid Benefit to the DCs (requires eligible Windows Server licences)."
  type        = bool
  default     = false
}

variable "identity_admin_source_cidrs" {
  description = "[Security] Extra networks allowed to RDP to DCs, e.g. a PAW subnet."
  type        = list(string)
  default     = []
}

variable "identity_allow_hub_bastion" {
  description = "[Security] Allow RDP to DCs from the shared hub Bastion. Disable when tier-0 admins use dedicated PAWs."
  type        = bool
  default     = true
}

variable "identity_dns_servers" {
  description = "DNS servers for the identity VNets. Leave [] for the build, then set to the DC IPs after promotion."
  type        = list(string)
  default     = []
}

variable "identity_key_vault_allowed_ips" {
  description = "[Security] Public IPs/CIDRs (e.g. the deployment agent) allowed to the tier-0 Key Vault. Empty = public access allowed (RBAC still required)."
  type        = list(string)
  default     = []
}

variable "identity_backup_storage_mode" {
  description = "[Reliability] Recovery Services vault redundancy. ZoneRedundant protects against zone loss; each region already has its own vault for regional loss. GeoRedundant adds Cross Region Restore."
  type        = string
  default     = "ZoneRedundant"

  validation {
    condition     = contains(["ZoneRedundant", "GeoRedundant"], var.identity_backup_storage_mode)
    error_message = "identity_backup_storage_mode must be ZoneRedundant or GeoRedundant."
  }
}

#############################################
# Reliability
#############################################

variable "zones" {
  description = "[Reliability] Zones for zone-redundant resources (ILB frontend, Bastion and its public IP). Set to [] only in regions without zones."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "nva_zones" {
  description = "[Reliability/Perf] One NVA is deployed per entry. Add zones to scale out."
  type        = list(string)
  default     = ["1", "2"]

  validation {
    condition     = length(var.nva_zones) >= 2 && length(distinct(var.nva_zones)) == length(var.nva_zones)
    error_message = "At least two distinct zones are required for an HA NVA pair."
  }
}

variable "nva_vendor" {
  description = "Firewall appliance in the hub: linux (built-in Ubuntu router/SNAT) | fortigate | sonicwall | paloalto | pfsense."
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "fortigate", "sonicwall", "paloalto", "pfsense"], var.nva_vendor)
    error_message = "nva_vendor must be linux, fortigate, sonicwall, paloalto or pfsense."
  }
}

variable "nva_ha_mode" {
  description = "single | active-standby (Azure API failover, no LB) | active-active (internal LB, HA Ports). The built-in Linux NVA supports active-active only."
  type        = string
  default     = "active-active"

  validation {
    condition     = contains(["single", "active-standby", "active-active"], var.nva_ha_mode)
    error_message = "nva_ha_mode must be single, active-standby or active-active."
  }

  validation {
    condition     = var.nva_vendor != "linux" || var.nva_ha_mode == "active-active"
    error_message = "The built-in Linux NVA runs active-active behind the internal load balancer only."
  }

  validation {
    condition     = !(var.nva_vendor == "pfsense" && var.nva_ha_mode == "active-standby")
    error_message = "pfSense active-standby needs CARP multicast, which Azure doesn't carry. Use active-active or single."
  }
}

variable "nva_license_type" {
  description = "Third-party NVAs: null = vendor default (byol; payg for pfSense). FortiGate/SonicWall byol|payg · Palo Alto byol|bundle1|bundle2|bundle3 · pfSense payg|byol."
  type        = string
  default     = null
}

variable "nva_accept_marketplace_terms" {
  description = "Third-party NVAs: accept the image's Marketplace terms in the connectivity subscription (first deployment)."
  type        = bool
  default     = false
}

variable "nva_marketplace_offer" {
  description = "Third-party NVAs: override the Marketplace offer."
  type        = string
  default     = null
}

variable "nva_marketplace_sku" {
  description = "Third-party NVAs: override the Marketplace SKU/plan."
  type        = string
  default     = null
}

variable "nva_admin_password" {
  description = "Third-party NVAs: admin password. Null = generated and stored in the connectivity Key Vault (no pipeline secret needed)."
  type        = string
  default     = null
  sensitive   = true
}

variable "nva_fortigate_license_tokens" {
  description = "FortiGate BYOL: FortiFlex tokens, one per firewall."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "nva_paloalto_bootstrap" {
  description = "Palo Alto: bootstrap Azure Files share (access key in nva_paloalto_bootstrap_access_key)."
  type = object({
    storage_account = string
    file_share      = string
    share_directory = optional(string)
  })
  default = null
}

variable "nva_paloalto_bootstrap_access_key" {
  type      = string
  default   = null
  sensitive = true
}

variable "nva_paloalto_mgmt_interface_swap" {
  type    = bool
  default = false
}

variable "nva_custom_data" {
  description = "SonicWall / pfSense: optional custom data for the image."
  type        = string
  default     = null
}

variable "enable_resource_locks" {
  description = "[Reliability] CanNotDelete locks on the hub VNet and Log Analytics workspace. Disable before a deliberate teardown."
  type        = bool
  default     = true
}

#############################################
# Security
#############################################

variable "nva_admin_username" {
  description = "Admin username for the NVAs."
  type        = string
  default     = "nvaadmin"

  validation {
    condition     = !contains(["admin", "root", "administrator"], lower(var.nva_admin_username))
    error_message = "nva_admin_username can't be admin, root or administrator (Marketplace firewall images reject them)."
  }
}

variable "nva_admin_ssh_public_key" {
  description = "SSH public key for the NVA admin account."
  type        = string
}

variable "nva_mgmt_source_cidrs" {
  description = "Additional CIDRs allowed to SSH to the NVAs. The Bastion and mgmt subnets are always allowed."
  type        = list(string)
  default     = []
}

variable "nva_encryption_at_host" {
  description = "[Security] Encrypt temp disk and caches on the host. Requires the Microsoft.Compute/EncryptionAtHost feature registered on the subscription."
  type        = bool
  default     = false
}

variable "ddos_protection_plan_id" {
  description = "[Security] Existing DDoS Network Protection plan ID to attach to all VNets. Null = DDoS Infrastructure Protection only (cost trade-off)."
  type        = string
  default     = null
}

variable "bastion_sku" {
  description = "Azure Bastion SKU. Standard adds native-client SSH/RDP, IP-based connect and scale units."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.bastion_sku)
    error_message = "bastion_sku must be Basic, Standard or Premium."
  }
}

#############################################
# Operational excellence / monitoring
#############################################

variable "log_analytics_sku" {
  type    = string
  default = "PerGB2018"
}

variable "log_retention_days" {
  description = "Log Analytics interactive retention in days."
  type        = number
  default     = 90

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "log_daily_quota_gb" {
  description = "[Cost] Daily ingestion cap for Log Analytics in GB. -1 = unlimited."
  type        = number
  default     = -1
}

variable "enable_flow_logs" {
  description = "[Security/OpEx] VNet flow logs + Traffic Analytics for the hub and every spoke."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Days to keep raw flow logs in storage."
  type        = number
  default     = 30
}

variable "network_watcher_name" {
  description = "Network Watcher for this region. Null = the one Azure creates automatically (NetworkWatcher_<location>)."
  type        = string
  default     = null
}

variable "network_watcher_resource_group" {
  description = "Resource group of the Network Watcher."
  type        = string
  default     = "NetworkWatcherRG"
}

variable "alert_email_addresses" {
  description = "[OpEx] Recipients for platform alerts and budget notifications. Empty = alerts fire in the portal only and no budget is created."
  type        = list(string)
  default     = []
}

#############################################
# Cost optimization
#############################################

variable "monthly_budget_amount" {
  description = "[Cost] Monthly budget (billing currency) across the landing zone RGs. 0 disables. Needs alert_email_addresses."
  type        = number
  default     = 0
}

variable "enable_nat_gateway" {
  description = "Attach a NAT Gateway to the NVA external subnet for deterministic Internet egress (default outbound access is retired)."
  type        = bool
  default     = true
}

#############################################
# Performance efficiency
#############################################

variable "nva_size" {
  description = "[Perf/Cost] NVA VM size. Must support 2+ NICs and accelerated networking. Third-party NVAs need >= 4 vCPUs (e.g. Standard_D4s_v5)."
  type        = string
  default     = "Standard_D2s_v5"

  validation {
    condition = var.nva_vendor == "linux" || (can(regex("^Standard_[A-Za-z]+[0-9]+", var.nva_size)) &&
    tonumber(regex("^Standard_[A-Za-z]+([0-9]+)", var.nva_size)[0]) >= 4)
    error_message = "Third-party firewall NVAs need at least 4 vCPUs (e.g. Standard_D4s_v5 or Standard_F4s_v2) for accelerated networking."
  }
}

variable "nva_cpu_alert_threshold" {
  description = "[Perf] Average CPU % across the NVAs that raises a scale-up/out alert."
  type        = number
  default     = 75
}
