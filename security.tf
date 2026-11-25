#############################################
# NVA NSG (applied to both NVA NICs)
#############################################

resource "azurerm_network_security_group" "nva" {
  name                = "${var.org_prefix}-nva-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

  # SSH only from Bastion, the mgmt subnet and any explicitly allowed CIDRs.
  # (Previously defaulted to 0.0.0.0/0.)
  security_rule {
    name                       = "Allow-SSH-Management"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = concat([local.hub_subnets.bastion, local.hub_subnets.mgmt], var.nva_mgmt_source_cidrs)
    destination_address_prefix = "*"
  }

  # Transit traffic from spokes / hub that the NVAs forward.
  security_rule {
    name                       = "Allow-VNet-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # ILB health probes are permitted by the default AllowAzureLoadBalancerInBound rule.
}

resource "azurerm_network_interface_security_group_association" "nva_external" {
  count                     = local.nva_count
  network_interface_id      = azurerm_network_interface.nva_external[count.index].id
  network_security_group_id = azurerm_network_security_group.nva.id
}

resource "azurerm_network_interface_security_group_association" "nva_internal" {
  count                     = local.nva_count
  network_interface_id      = azurerm_network_interface.nva_internal[count.index].id
  network_security_group_id = azurerm_network_security_group.nva.id
}

#############################################
# Management subnet NSG
#############################################

resource "azurerm_network_security_group" "mgmt" {
  name                = "${var.org_prefix}-mgmt-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

  security_rule {
    name                       = "Allow-VNet-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "hub_mgmt" {
  subnet_id                 = azurerm_subnet.hub_mgmt.id
  network_security_group_id = azurerm_network_security_group.mgmt.id
}

#############################################
# Identity / DC subnet NSG
#############################################

resource "azurerm_network_security_group" "id_dc" {
  name                = "${var.org_prefix}-id-dc-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

  # Full AD DS port set (client logon, Kerberos pw change, LDAPS, GC,
  # ADWS, NTP and dynamic RPC used by replication/DFSR/netlogon).
  security_rule {
    name                       = "Allow-AD-TCP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["53", "88", "135", "389", "445", "464", "636", "3268-3269", "9389", "49152-65535"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-AD-UDP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_ranges    = ["53", "88", "123", "389", "464"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # RDP arrives from the AzureBastionSubnet (not mgmt-snet) when using
  # Bastion, so both must be allowed.
  security_rule {
    name                       = "Allow-RDP-From-Bastion-Mgmt"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefixes    = [local.hub_subnets.bastion, local.hub_subnets.mgmt]
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "id_dc" {
  subnet_id                 = azurerm_subnet.spoke["identity"].id
  network_security_group_id = azurerm_network_security_group.id_dc.id
}
