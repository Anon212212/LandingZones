#############################################
# Standard interface – identical in every vendor module
#############################################

variable "name_prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "ha_mode" {
  description = "single | active-standby | active-active (must match the network-ha-pattern module)."
  type        = string

  validation {
    condition     = contains(["single", "active-standby", "active-active"], var.ha_mode)
    error_message = "ha_mode must be single, active-standby or active-active."
  }
}

variable "network" {
  description = "The network-ha-pattern module's outputs: subnet_ids, instances, cluster, load_balancers, gateways, subnet_prefixes, availability_set_id, trust_route_table_name."
  type        = any
}

variable "vm_size" {
  description = "VM size. Accelerated networking on untrust/trust needs >= 4 vCPUs (e.g. Standard_F4s_v2, Standard_D4s_v5, Standard_D8s_v5)."
  type        = string
  default     = "Standard_D4s_v5"

  validation {
    condition     = can(regex("^Standard_[A-Za-z]+[0-9]+", var.vm_size)) && tonumber(regex("^Standard_[A-Za-z]+([0-9]+)", var.vm_size)[0]) >= 4
    error_message = "vm_size must have at least 4 vCPUs (e.g. Standard_F4s_v2, Standard_D4s_v5) so accelerated networking can be enabled."
  }
}

variable "admin_username" {
  description = "Initial administrator account."
  type        = string
  default     = "nsvadmin"

  validation {
    condition     = !contains(["admin", "root", "administrator"], lower(var.admin_username)) && can(regex("^[a-z][a-z0-9_-]{2,31}$", var.admin_username))
    error_message = "admin_username must be 3-32 chars (lowercase letter first) and not a reserved name: admin, root, administrator."
  }
}

variable "admin_password" {
  description = "Initial administrator password (Azure complexity rules apply). Pass via TF_VAR_admin_password or a secret store."
  type        = string
  sensitive   = true
}

variable "admin_ssh_public_key" {
  description = "Optional SSH public key for the admin account."
  type        = string
  default     = null
}

variable "license_type" {
  description = "byol | payg"
  type        = string
  default     = "byol"

  validation {
    condition     = contains(["byol", "payg"], var.license_type)
    error_message = "license_type must be one of byol, payg."
  }
}

variable "accept_marketplace_terms" {
  description = "Accept the Marketplace legal terms for the image in this subscription (needed once per subscription and plan). Leave false if they're already accepted – the resource then errors as 'already exists' unless imported."
  type        = bool
  default     = false
}

variable "marketplace_publisher" {
  description = "Override the Marketplace publisher (default: sonicwall-inc)."
  type        = string
  default     = null
}

variable "marketplace_offer" {
  description = "Override the Marketplace offer (default: sonicwall-nsz-azure)."
  type        = string
  default     = null
}

variable "marketplace_sku" {
  description = "Override the Marketplace SKU/plan (default depends on license_type – see locals in main.tf)."
  type        = string
  default     = null
}

variable "image_version" {
  description = "Image version, or \"latest\". Pin a version for repeatable builds."
  type        = string
  default     = "latest"
}

variable "os_disk_storage_account_type" {
  type    = string
  default = "Premium_LRS"
}

#############################################
# SonicWall-specific
#############################################

variable "custom_data" {
  description = "Optional day-0 custom data passed to NSv (most NSv settings are done in the first-boot wizard / Network Security Manager)."
  type        = string
  default     = null
}
