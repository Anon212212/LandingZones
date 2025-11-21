ariable "org_prefix"           { type = string }
variable "location"             { type = string  default = "northeurope" }
variable "hub_address_space"    { type = string  default = "10.145.0.0/24" }
variable "spoke_address_space"  { type = string  default = "10.145.0.0/24" }
variable "log_analytics_sku"    { type = string  default = "PerGB2018" }