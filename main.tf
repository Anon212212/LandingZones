#############################################
# Resource Groups
#############################################

resource "azurerm_resource_group" "mgmt" {
  name     = "${var.org_prefix}-mgmt-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "connectivity" {
  name     = "${var.org_prefix}-conn-rg"
  location = var.location
  tags     = local.tags
}

#############################################
# Log Analytics
#############################################

resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.org_prefix}-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.mgmt.name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "bastion" {
  name                       = "to-law"
  target_resource_id         = azurerm_bastion_host.bastion.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log {
    category = "BastionAuditLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "nva_lb" {
  name                       = "to-law"
  target_resource_id         = azurerm_lb.nva_internal.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  metric {
    category = "AllMetrics"
  }
}
