data "azurerm_subscription" "current" {}

#############################################
# Resource Groups
#############################################

resource "azurerm_resource_group" "connectivity" {
  name     = local.names.rg_connectivity
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "management" {
  name     = local.names.rg_management
  location = var.location
  tags     = local.tags
}

#############################################
# Log Analytics (central platform workspace)
#############################################

resource "azurerm_log_analytics_workspace" "law" {
  name                = local.names.law
  location            = var.location
  resource_group_name = azurerm_resource_group.management.name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_retention_days
  daily_quota_gb      = var.log_daily_quota_gb

  # [Security] Entra ID-only ingestion and query (no workspace keys).
  local_authentication_enabled = false

  tags = local.tags
}

#############################################
# [Reliability] Delete locks on shared, hard-to-rebuild resources
#############################################

resource "azurerm_management_lock" "hub_vnet" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-hub-vnet"
  scope      = azurerm_virtual_network.hub.id
  lock_level = "CanNotDelete"
  notes      = "Hub VNet carries all spoke connectivity. Disable enable_resource_locks to tear down."
}

resource "azurerm_management_lock" "law" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-law"
  scope      = azurerm_log_analytics_workspace.law.id
  lock_level = "CanNotDelete"
  notes      = "Platform audit and security logs. Disable enable_resource_locks to tear down."
}
