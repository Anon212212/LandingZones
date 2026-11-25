#############################################
# [Security] NSG on every subnet (Bastion included) plus NIC-level NSG on
# the NVAs. Default rules already deny Internet inbound; explicit rules
# document intent and make the policy auditable.
#############################################

#############################################
# NVA NSG (both NVA NICs)
#############################################

resource "azurerm_network_security_group" "nva" {
  name                = "nsg-${var.org_prefix}-nva-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

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

  security_rule {
    name                       = "Allow-AzureLoadBalancer-Probe"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Transit traffic from spokes / hub that the NVAs forward.
  security_rule {
    name                       = "Allow-VNet-Transit"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
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

# Subnet-level NSG on both NVA subnets (same policy) so every subnet is covered.
resource "azurerm_subnet_network_security_group_association" "hub_nva_external" {
  subnet_id                 = azurerm_subnet.hub_nva_external.id
  network_security_group_id = azurerm_network_security_group.nva.id
}

resource "azurerm_subnet_network_security_group_association" "hub_nva_internal" {
  subnet_id                 = azurerm_subnet.hub_nva_internal.id
  network_security_group_id = azurerm_network_security_group.nva.id
}

#############################################
# Management subnet NSG
#############################################

resource "azurerm_network_security_group" "mgmt" {
  name                = "nsg-${var.org_prefix}-mgmt-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

  security_rule {
    name                       = "Allow-SSH-RDP-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = local.hub_subnets.bastion
    destination_address_prefix = "*"
  }

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
}

resource "azurerm_subnet_network_security_group_association" "hub_mgmt" {
  subnet_id                 = azurerm_subnet.hub_mgmt.id
  network_security_group_id = azurerm_network_security_group.mgmt.id
}

#############################################
# AzureBastionSubnet NSG – rule set required by Azure Bastion
# https://learn.microsoft.com/azure/bastion/bastion-nsg
#############################################

resource "azurerm_network_security_group" "bastion" {
  name                = "nsg-${var.org_prefix}-bastion-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

  # Inbound
  security_rule {
    name                       = "AllowHttpsInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowGatewayManagerInbound"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowBastionHostCommunication"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Outbound
  security_rule {
    name                       = "AllowSshRdpOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureCloudOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureCloud"
  }

  security_rule {
    name                       = "AllowBastionCommunication"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowHttpOutbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  security_rule {
    name                       = "DenyAllOutbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "hub_bastion" {
  subnet_id                 = azurerm_subnet.hub_bastion.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

#############################################
# Workload spoke NSGs – baseline: Bastion + VNet in, AzureLoadBalancer,
# everything else denied. Per-spoke rules from var.spokes[*].nsg_rules
# (priorities 300-3900) slot in between.
#############################################

resource "azurerm_network_security_group" "spoke" {
  for_each = local.spokes

  name                = "nsg-${var.org_prefix}-${each.key}-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

  security_rule {
    name                       = "Allow-SSH-RDP-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = local.hub_subnets.bastion
    destination_address_prefix = "*"
  }

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

  dynamic "security_rule" {
    for_each = each.value.nsg_rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = security_rule.value.direction
      access                     = security_rule.value.access
      protocol                   = security_rule.value.protocol
      source_port_range          = "*"
      destination_port_ranges    = security_rule.value.destination_port_ranges
      source_address_prefixes    = security_rule.value.source_address_prefixes
      destination_address_prefix = "*"
    }
  }

  # Default AllowAzureLoadBalancerInBound sits below Deny-All, so restate it.
  security_rule {
    name                       = "Allow-AzureLoadBalancer"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "spoke" {
  for_each = azurerm_network_security_group.spoke

  subnet_id                 = azurerm_subnet.spoke[each.key].id
  network_security_group_id = each.value.id
}
