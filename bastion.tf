#############################################
# Azure Bastion – the only management entry point (no VM public IPs)
#############################################

resource "azurerm_public_ip" "bastion" {
  name                    = local.names.bastion_pip
  location                = var.location
  resource_group_name     = azurerm_resource_group.connectivity.name
  allocation_method       = "Static"
  sku                     = "Standard"
  zones                   = local.zones # [Reliability] zone-redundant
  ddos_protection_mode    = var.ddos_protection_plan_id == null ? "VirtualNetworkInherited" : "Enabled"
  ddos_protection_plan_id = var.ddos_protection_plan_id
  tags                    = local.tags
}

resource "azurerm_bastion_host" "bastion" {
  name                = local.names.bastion
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  sku                 = var.bastion_sku
  zones               = local.zones # [Reliability] zone-redundant
  tags                = local.tags

  # Standard/Premium features. Shareable links stay off ([Security]).
  tunneling_enabled      = var.bastion_sku != "Basic"
  ip_connect_enabled     = var.bastion_sku != "Basic"
  shareable_link_enabled = false
  scale_units            = 2 # Standard+ can scale to 50 for more concurrent sessions

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = azurerm_subnet.hub_bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  depends_on = [azurerm_subnet_network_security_group_association.hub_bastion]
}
