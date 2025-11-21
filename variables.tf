variable "org_prefix" {
  type = string
}

variable "location" {
  type    = string
  default = "northeurope"
}

# Hub VNet (space for NVA + Bastion + mgmt)
variable "hub_address_space" {
  type    = string
  default = "10.145.0.0/24"
}

# Spoke VNet (must NOT overlap hub)
variable "spoke_address_space" {
  type    = string
  default = "10.145.1.0/24"

}

# New prod VNet
variable "prod_address_space" {
  type    = string
  default = "10.145.2.0/24"
}

# New AVD VNet
variable "avd_address_space" {
  type    = string
  default = "10.145.3.0/24"
}

variable "log_analytics_sku" {
  type    = string
  default = "PerGB2018"
}
variable "nva_admin_username" {
  description = "Admin username for the NVA."
  type        = string
  default     = "nvaadmin"
}

variable "nva_admin_ssh_public_key" {
  description = "SSH public key for the NVA admin account."
  type        = string
}

variable "nva_mgmt_source_cidr" {
  description = "CIDR allowed to SSH to the NVA."
  type        = string
  default     = "0.0.0.0/0"
}

variable "nva_size" {
  description = "VM size for the NVA appliance."
  type        = string
  # Consider bumping to a D-series that supports zones and multiple NICs well
  default     = "Standard_D2s_v3"
}