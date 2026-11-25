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

variable "spoke_address_space" {
  description = "Shared-services spoke VNet CIDR."
  type        = string
  default     = "10.145.1.0/24"

  validation {
    condition     = can(cidrhost(var.spoke_address_space, 0))
    error_message = "spoke_address_space must be a valid CIDR."
  }
}

variable "prod_address_space" {
  description = "Production spoke VNet CIDR."
  type        = string
  default     = "10.145.2.0/24"

  validation {
    condition     = can(cidrhost(var.prod_address_space, 0))
    error_message = "prod_address_space must be a valid CIDR."
  }
}

variable "avd_address_space" {
  description = "Azure Virtual Desktop spoke VNet CIDR."
  type        = string
  default     = "10.145.3.0/24"

  validation {
    condition     = can(cidrhost(var.avd_address_space, 0))
    error_message = "avd_address_space must be a valid CIDR."
  }
}

variable "id_address_space" {
  description = "Identity (domain controller) spoke VNet CIDR. The DC subnet is its first eighth (/27 for a /24)."
  type        = string
  default     = "10.145.4.0/24"

  validation {
    condition     = can(cidrhost(var.id_address_space, 0))
    error_message = "id_address_space must be a valid CIDR."
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
  description = "[Perf/Cost] NVA VM size. Must support 2+ NICs, accelerated networking and Trusted Launch."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "nva_cpu_alert_threshold" {
  description = "[Perf] Average CPU % across the NVAs that raises a scale-up/out alert."
  type        = number
  default     = 75
}
