#############################################
# Client / placement
#############################################

variable "client_name" {
  description = "Short client identifier used in every name (e.g. \"clienta\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,15}$", var.client_name))
    error_message = "client_name must be 2-16 lowercase letters/digits, starting with a letter."
  }
}

variable "environment" {
  type    = string
  default = "prod"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.environment))
    error_message = "environment must be 2-8 lowercase letters/digits."
  }
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  description = "Resource group to create. Null = rg-<client>-fw-<environment>."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

#############################################
# Firewall choice
#############################################

variable "vendor" {
  description = "fortigate | sonicwall | paloalto | pfsense"
  type        = string

  validation {
    condition     = contains(["fortigate", "sonicwall", "paloalto", "pfsense"], var.vendor)
    error_message = "vendor must be fortigate, sonicwall, paloalto or pfsense."
  }
}

variable "ha_mode" {
  description = "single | active-standby | active-active"
  type        = string

  validation {
    condition     = contains(["single", "active-standby", "active-active"], var.ha_mode)
    error_message = "ha_mode must be single, active-standby or active-active."
  }

  validation {
    condition     = !(var.vendor == "pfsense" && var.ha_mode == "active-standby")
    error_message = "pfSense active-standby needs CARP multicast, which Azure doesn't support. Use active-active (load-balanced standalone pfSense) or single."
  }
}

variable "instance_count" {
  description = "Firewalls in active-active (>= 2)."
  type        = number
  default     = 2
}

variable "vm_size" {
  description = ">= 4 vCPUs for accelerated networking, e.g. Standard_D4s_v5 or Standard_F4s_v2."
  type        = string
  default     = "Standard_D4s_v5"

  validation {
    condition     = can(regex("^Standard_[A-Za-z]+[0-9]+", var.vm_size)) && tonumber(regex("^Standard_[A-Za-z]+([0-9]+)", var.vm_size)[0]) >= 4
    error_message = "vm_size must have at least 4 vCPUs (e.g. Standard_F4s_v2, Standard_D4s_v5) so accelerated networking can be enabled on untrust/trust."
  }
}

variable "license_type" {
  description = "Null = vendor default (byol; payg for pfSense). FortiGate/SonicWall: byol|payg · Palo Alto: byol|bundle1|bundle2|bundle3 · pfSense: payg|byol."
  type        = string
  default     = null
}

variable "accept_marketplace_terms" {
  description = "Accept the image's Marketplace terms in this subscription (first deployment per subscription/plan)."
  type        = bool
  default     = false
}

variable "marketplace_publisher" {
  type    = string
  default = null
}

variable "marketplace_offer" {
  type    = string
  default = null
}

variable "marketplace_sku" {
  type    = string
  default = null
}

variable "image_version" {
  type    = string
  default = "latest"
}

variable "admin_username" {
  description = "Null = vendor default (fgtadmin, nsvadmin, panadmin, pfsenseadmin)."
  type        = string
  default     = null

  validation {
    condition     = var.admin_username == null || !contains(["admin", "root", "administrator"], lower(coalesce(var.admin_username, "-")))
    error_message = "admin_username can't be admin, root or administrator (Azure Marketplace images – notably pfSense – reject them)."
  }
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "admin_ssh_public_key" {
  type    = string
  default = null
}

#############################################
# Network
#############################################

variable "address_space" {
  description = "Firewall hub VNet CIDR (/24 or larger)."
  type        = string
}

variable "zones" {
  description = "Availability Zones; [] = Availability Set (regions without zones)."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "mgmt_source_cidrs" {
  description = "Networks allowed to the management interfaces."
  type        = list(string)
  default     = []
}

variable "management_egress" {
  description = "nat_gateway | public_ip | none (management-NIC vendors: FortiGate, Palo Alto)."
  type        = string
  default     = "nat_gateway"
}

variable "inbound_rules" {
  description = "Published services (NSG + external LB rules in active-active)."
  type = list(object({
    name     = string
    protocol = string
    port     = number
  }))
  default = []
}

variable "protected_subnet_ids" {
  description = "Subnets (same subscription) to associate with the trust route table, keyed by a friendly name."
  type        = map(string)
  default     = {}
}

#############################################
# Vendor-specific (ignored by other vendors)
#############################################

variable "fortigate_license_tokens" {
  description = "FortiGate BYOL: FortiFlex tokens, one per firewall."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "fortigate_license_files" {
  description = "FortiGate BYOL: .lic contents, one per firewall."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "fortigate_internal_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "fortigate_extra_config" {
  type    = string
  default = ""
}

variable "paloalto_mgmt_interface_swap" {
  type    = bool
  default = false
}

variable "paloalto_bootstrap" {
  description = "Palo Alto bootstrap Azure Files share (access key passed separately)."
  type = object({
    storage_account = string
    file_share      = string
    share_directory = optional(string)
  })
  default = null
}

variable "paloalto_bootstrap_access_key" {
  type      = string
  default   = null
  sensitive = true
}

variable "custom_data" {
  description = "SonicWall / pfSense: optional custom data passed to the image."
  type        = string
  default     = null
}
