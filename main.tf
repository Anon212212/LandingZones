# Variables: org_prefix, location, hub_address_space, spoke_address_space, log_analytics_sku
data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "mgmt" {
  name     = "${var.org_prefix}-mgmt-rg"
  location = var.location
}

resource "azurerm_resource_group" "connectivity" {
  name     = "${var.org_prefix}-conn-rg"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.org_prefix}-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.mgmt.name
  sku                 = var.log_analytics_sku
  retention_in_days   = 30
}

resource "azurerm_virtual_network" "hub" {
  name                = "${var.org_prefix}-hub-vnet"
  address_space       = [var.hub_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
}

resource "azurerm_subnet" "hub_firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_virtual_network" "shared" {
  name                = "${var.org_prefix}-shared-vnet"
  address_space       = [var.spoke_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
}

resource "azurerm_virtual_network_peering" "hub_to_shared" {
  name                      = "hub-to-shared"
  resource_group_name       = azurerm_resource_group.connectivity.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.shared.id
  allow_forwarded_traffic   = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "shared_to_hub" {
  name                      = "shared-to-hub"
  resource_group_name       = azurerm_resource_group.connectivity.name
  virtual_network_name      = azurerm_virtual_network.shared.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
  allow_virtual_network_access = true
}

# Example policy assignment at subscription (add your policy_definition_id)
# resource "azurerm_subscription_policy_assignment" "allowed_locs" {
#   name                 = "${var.org_prefix}-allowed-locations"
#   policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/LOCATION_POLICY_ID"
#   subscription_id      = data.azurerm_subscription.current.id
#   display_name         = "Allowed locations"
#   parameters           = jsonencode({ listOfAllowedLocations = { value = ["westeurope", "northeurope"] } })
# }