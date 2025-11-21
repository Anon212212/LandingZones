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

variable "log_analytics_sku" {
  type    = string
  default = "PerGB2018"
}