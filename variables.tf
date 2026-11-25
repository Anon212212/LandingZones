#############################################
# General
#############################################

variable "org_prefix" {
  description = "Short prefix used in every resource name (e.g. \"contoso\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.org_prefix))
    error_message = "org_prefix must be 2-15 chars, lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "location" {
  description = "Azure region. Must support Availability Zones for the HA NVA pair."
  type        = string
  default     = "northeurope"
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}

#############################################
# Address spaces
#
# Hub subnets, NVA IPs and the ILB frontend are all derived from
# hub_address_space, so changing it re-addresses everything consistently.
#############################################

variable "hub_address_space" {
  description = "Hub VNet CIDR. Split into four equal subnets: NVA external, NVA internal, mgmt, Bastion. Must be /24 or larger."
  type        = string
  default     = "10.145.0.0/24"

  validation {
    condition     = can(cidrhost(var.hub_address_space, 0)) && tonumber(split("/", var.hub_address_space)[1]) <= 24
    error_message = "hub_address_space must be a valid CIDR of /24 or larger (each hub subnet is 1/8 of it and AzureBastionSubnet needs at least /27)."
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
  description = "Identity (domain controller) spoke VNet CIDR. The DC subnet is the first /27 (relative) of it."
  type        = string
  default     = "10.145.4.0/24"

  validation {
    condition     = can(cidrhost(var.id_address_space, 0))
    error_message = "id_address_space must be a valid CIDR."
  }
}

#############################################
# Management / logging
#############################################

variable "log_analytics_sku" {
  type    = string
  default = "PerGB2018"
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

variable "bastion_sku" {
  description = "Azure Bastion SKU. \"Standard\" enables native-client SSH/RDP and IP-based connect."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard"], var.bastion_sku)
    error_message = "bastion_sku must be Basic or Standard."
  }
}

#############################################
# NVA
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

variable "nva_size" {
  description = "VM size for the NVAs (must support 2+ NICs and accelerated networking is recommended)."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "nva_zones" {
  description = "Availability Zones for the NVA pair; one NVA is deployed per entry."
  type        = list(string)
  default     = ["1", "2"]

  validation {
    condition     = length(var.nva_zones) >= 2
    error_message = "At least two zones are required for an HA NVA pair."
  }
}

variable "enable_nat_gateway" {
  description = "Attach a NAT Gateway to the NVA external subnet for deterministic Internet egress (recommended: Azure default outbound access is being retired)."
  type        = bool
  default     = true
}
