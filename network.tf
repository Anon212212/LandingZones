#############################################
# Hub VNet & subnets
#############################################

resource "azurerm_virtual_network" "hub" {
  name                = "${var.org_prefix}-hub-vnet"
  address_space       = [var.hub_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags
}

resource "azurerm_subnet" "hub_nva_external" {
  name                 = "nva-external-snet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.hub_subnets.nva_external]
}

resource "azurerm_subnet" "hub_nva_internal" {
  name                 = "nva-internal-snet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.hub_subnets.nva_internal]
}

resource "azurerm_subnet" "hub_mgmt" {
  name                 = "mgmt-snet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.hub_subnets.mgmt]
}

resource "azurerm_subnet" "hub_bastion" {
  name                 = "AzureBastionSubnet" # name mandated by Azure
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.hub_subnets.bastion]
}

#############################################
# Spoke VNets & subnets
#############################################

resource "azurerm_virtual_network" "spoke" {
  for_each = local.spokes

  name                = each.value.vnet_name
  address_space       = [each.value.address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags
}

resource "azurerm_subnet" "spoke" {
  for_each = local.spokes

  name                 = each.value.subnet_name
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.spoke[each.key].name
  address_prefixes     = [each.value.subnet_prefix]
}

#############################################
# Peerings (hub ↔ each spoke)
#############################################

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each = local.spokes

  name                         = "hub-to-${each.key}"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke[each.key].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each = local.spokes

  name                         = "${each.key}-to-hub"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.spoke[each.key].name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

#############################################
# Route tables (spokes → NVA ILB)
#############################################

resource "azurerm_route_table" "spoke" {
  for_each = local.spokes

  name                = "${var.org_prefix}-${each.key}-rt"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

  # Stop on-prem/gateway routes from bypassing the NVAs if a VPN/ER
  # gateway is added to the hub later.
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-nva"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.nva_ilb_frontend_ip
  }
}

resource "azurerm_subnet_route_table_association" "spoke" {
  for_each = local.spokes

  subnet_id      = azurerm_subnet.spoke[each.key].id
  route_table_id = azurerm_route_table.spoke[each.key].id
}

#############################################
# NAT Gateway (NVA Internet egress)
#############################################

resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "${var.org_prefix}-nat-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "nva" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "${var.org_prefix}-nat"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "nva" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.nva[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "nva_external" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.hub_nva_external.id
  nat_gateway_id = azurerm_nat_gateway.nva[0].id
}
