variable "name" {
  description = "Spoke key, used in resource names."
  type        = string
}

variable "org_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "location" {
  type = string
}

variable "region_short" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "address_space" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "nsg_rules" {
  description = "Extra NSG rules (priority 300-3900), validated at the root."
  type = list(object({
    name                    = string
    priority                = number
    direction               = string
    access                  = string
    protocol                = string
    source_address_prefixes = list(string)
    destination_port_ranges = list(string)
  }))
  default = []
}

variable "hub_vnet_id" {
  type = string
}

variable "next_hop_ip" {
  description = "NVA ILB frontend that 0.0.0.0/0 is routed to."
  type        = string
}

variable "bastion_subnet_cidr" {
  type = string
}

variable "ddos_protection_plan_id" {
  type    = string
  default = null
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "log_analytics_workspace_guid" {
  type = string
}

variable "log_analytics_workspace_location" {
  type = string
}

variable "enable_flow_logs" {
  type = bool
}

variable "flow_log_storage_account_id" {
  description = "Platform flow-log storage account (same region; may be in another subscription of the tenant)."
  type        = string
  default     = null
}

variable "flow_log_retention_days" {
  type = number
}

variable "network_watcher_resource_group" {
  type = string
}
