#############################################
# Naming / placement
#############################################

variable "org_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "location" {
  description = "Azure region for this identity instance."
  type        = string
}

variable "region_short" {
  description = "Short region code used in names (e.g. neu)."
  type        = string
}

variable "subscription_id" {
  description = "Identity subscription ID (used to make global names unique)."
  type        = string
}

variable "tags" {
  type = map(string)
}

#############################################
# Network
#############################################

variable "address_space" {
  description = "Identity VNet CIDR. The DC subnet is its first eighth."
  type        = string
}

variable "dns_servers" {
  description = "Custom DNS for the identity VNet. Leave [] (Azure DNS) until the DCs are promoted, then set to the DC IPs."
  type        = list(string)
  default     = []
}

variable "hub_vnet_id" {
  description = "Hub VNet to peer with (may be in another subscription)."
  type        = string
}

variable "next_hop_ip" {
  description = "NVA/firewall IP that 0.0.0.0/0 is routed to."
  type        = string
}

variable "ad_client_cidrs" {
  description = "Networks allowed to reach AD DS ports (all landing-zone address spaces)."
  type        = list(string)
}

variable "admin_source_cidrs" {
  description = "Networks allowed to RDP to the DCs (e.g. Bastion subnet, PAW subnet)."
  type        = list(string)
  default     = []
}

variable "ddos_protection_plan_id" {
  type    = string
  default = null
}

#############################################
# Domain controllers
#############################################

variable "dc_zones" {
  description = "One DC is deployed per zone."
  type        = list(string)
}

variable "dc_size" {
  type = string
}

variable "dc_admin_username" {
  type = string
}

variable "dc_image_sku" {
  description = "WindowsServer image SKU (Gen2)."
  type        = string
}

variable "dc_data_disk_size_gb" {
  description = "Data disk for NTDS, logs and SYSVOL."
  type        = number
}

variable "dc_hybrid_benefit" {
  description = "Apply Azure Hybrid Benefit (Windows_Server licence)."
  type        = bool
}

variable "encryption_at_host" {
  type = bool
}

variable "key_vault_id" {
  description = "Tier-0 Key Vault where the generated DC admin passwords are stored."
  type        = string
}

variable "data_collection_rule_id" {
  description = "DCR (Windows events + perf) associated with every DC."
  type        = string
}

#############################################
# Backup
#############################################

variable "backup_storage_mode" {
  description = "Recovery Services vault redundancy: ZoneRedundant or GeoRedundant."
  type        = string
}

variable "backup_time_utc" {
  description = "Daily backup time (HH:MM, UTC)."
  type        = string
  default     = "22:00"
}

#############################################
# Monitoring / governance
#############################################

variable "log_analytics_workspace_id" {
  description = "Resource ID of the tier-0 Log Analytics workspace."
  type        = string
}

variable "log_analytics_workspace_guid" {
  description = "Workspace (customer) ID of the tier-0 Log Analytics workspace."
  type        = string
}

variable "log_analytics_workspace_location" {
  type = string
}

variable "enable_flow_logs" {
  type = bool
}

variable "flow_log_retention_days" {
  type = number
}

variable "network_watcher_resource_group" {
  type = string
}

variable "enable_resource_locks" {
  type = bool
}
