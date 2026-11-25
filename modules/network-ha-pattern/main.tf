#############################################
# Azure plumbing for a third-party firewall cluster.
#
#   single          1 firewall, public IP on untrust, UDR → firewall trust IP
#   active-standby  2 firewalls (zones / availability set), no data-plane LB.
#                   Floating trust VIP + cluster public IP start on node 0;
#                   the firewalls move them via the Azure API using a managed
#                   identity with a narrowly scoped custom role. UDR → trust VIP.
#   active-active   2+ firewalls behind an internal Standard LB (HA Ports) and
#                   an external Standard LB (ingress + outbound SNAT).
#                   UDR → internal LB frontend.
#############################################

locals {
  instance_count = var.ha_mode == "single" ? 1 : (var.ha_mode == "active-standby" ? 2 : var.instance_count)
  use_zones      = length(var.zones) > 0
  hasync         = var.ha_mode == "active-standby" && var.enable_hasync

  subnets = {
    untrust = cidrsubnet(var.address_space, 3, 0)
    trust   = cidrsubnet(var.address_space, 3, 1)
    mgmt    = cidrsubnet(var.address_space, 3, 2)
    hasync  = cidrsubnet(var.address_space, 3, 3)
  }
  gateways = { for k, v in local.subnets : k => cidrhost(v, 1) } # Azure subnet gateway (.1)

  # Host index 4 is the first assignable address (Azure reserves .0-.3).
  # single: node uses .4 · active-standby: VIP .4, nodes .5/.6 · active-active: ILB .4, nodes .5+
  node_offset = var.ha_mode == "single" ? 4 : 5
  vip         = { trust = cidrhost(local.subnets.trust, 4), untrust = cidrhost(local.subnets.untrust, 4) }

  next_hop_ip = (var.ha_mode == "single" ? cidrhost(local.subnets.trust, 4) : local.vip.trust)

  instances = [
    for i in range(local.instance_count) : {
      index      = i
      name       = format("%s-fw%02d", var.name_prefix, i + 1)
      zone       = local.use_zones ? var.zones[i % length(var.zones)] : null
      untrust_ip = cidrhost(local.subnets.untrust, local.node_offset + i)
      trust_ip   = cidrhost(local.subnets.trust, local.node_offset + i)
      mgmt_ip    = cidrhost(local.subnets.mgmt, 4 + i)
      hasync_ip  = cidrhost(local.subnets.hasync, 4 + i)
      priority   = 255 - i * 55 # higher wins (vendors that use HA priority)
    }
  ]

  all_zones = local.use_zones ? var.zones : null
}

#############################################
# VNet + subnets
#############################################

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "untrust" {
  name                 = "snet-untrust"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.subnets.untrust]
}

resource "azurerm_subnet" "trust" {
  name                 = "snet-trust"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.subnets.trust]
}

resource "azurerm_subnet" "mgmt" {
  count = var.enable_mgmt_subnet ? 1 : 0

  name                 = "snet-mgmt"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.subnets.mgmt]
}

resource "azurerm_subnet" "hasync" {
  count = local.hasync ? 1 : 0

  name                 = "snet-hasync"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.subnets.hasync]
}

#############################################
# NSGs – firewalls do the real inspection; NSGs keep the Azure edge tight.
#############################################

resource "azurerm_network_security_group" "untrust" {
  name                = "nsg-${var.name_prefix}-untrust"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  dynamic "security_rule" {
    for_each = { for i, r in var.inbound_rules : r.name => merge(r, { priority = 100 + i * 10 }) }
    content {
      name                       = "Allow-${security_rule.key}"
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = security_rule.value.protocol
      source_port_range          = "*"
      destination_port_range     = tostring(security_rule.value.port)
      source_address_prefix      = "Internet"
      destination_address_prefix = "*"
    }
  }

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

resource "azurerm_network_security_group" "trust" {
  name                = "nsg-${var.name_prefix}-trust"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  # Everything routed to the firewalls from the spokes arrives here.
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

resource "azurerm_network_security_group" "mgmt" {
  count = var.enable_mgmt_subnet ? 1 : 0

  name                = "nsg-${var.name_prefix}-mgmt"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  dynamic "security_rule" {
    for_each = length(var.mgmt_source_cidrs) > 0 ? [1] : []
    content {
      name                       = "Allow-Management"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = var.mgmt_ports
      source_address_prefixes    = var.mgmt_source_cidrs
      destination_address_prefix = "*"
    }
  }

  # HA peers exchange management/heartbeat traffic over mgmt in some vendors.
  security_rule {
    name                       = "Allow-Mgmt-Subnet"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.subnets.mgmt
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

resource "azurerm_network_security_group" "hasync" {
  count = local.hasync ? 1 : 0

  name                = "nsg-${var.name_prefix}-hasync"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HA-Peers"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.subnets.hasync
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

resource "azurerm_subnet_network_security_group_association" "untrust" {
  subnet_id                 = azurerm_subnet.untrust.id
  network_security_group_id = azurerm_network_security_group.untrust.id
}

resource "azurerm_subnet_network_security_group_association" "trust" {
  subnet_id                 = azurerm_subnet.trust.id
  network_security_group_id = azurerm_network_security_group.trust.id
}

resource "azurerm_subnet_network_security_group_association" "mgmt" {
  count = var.enable_mgmt_subnet ? 1 : 0

  subnet_id                 = azurerm_subnet.mgmt[0].id
  network_security_group_id = azurerm_network_security_group.mgmt[0].id
}

resource "azurerm_subnet_network_security_group_association" "hasync" {
  count = local.hasync ? 1 : 0

  subnet_id                 = azurerm_subnet.hasync[0].id
  network_security_group_id = azurerm_network_security_group.hasync[0].id
}

#############################################
# Public IPs
#############################################

# single: the firewall's own untrust public IP
resource "azurerm_public_ip" "single" {
  count = var.ha_mode == "single" ? 1 : 0

  name                = "pip-${var.name_prefix}-untrust"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.all_zones
  tags                = var.tags
}

# active-standby: cluster public IP, moved between nodes on failover
resource "azurerm_public_ip" "cluster" {
  count = var.ha_mode == "active-standby" ? 1 : 0

  name                = "pip-${var.name_prefix}-cluster"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.all_zones
  tags                = var.tags
}

# active-active: external load balancer frontend
resource "azurerm_public_ip" "elb" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name                = "pip-${var.name_prefix}-elb"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.all_zones
  tags                = var.tags
}

resource "azurerm_public_ip" "mgmt" {
  count = var.enable_mgmt_subnet && var.management_egress == "public_ip" ? local.instance_count : 0

  name                = format("pip-%s-fw%02d-mgmt", var.name_prefix, count.index + 1)
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.all_zones
  tags                = var.tags
}

#############################################
# Management egress via NAT Gateway
#############################################

resource "azurerm_public_ip" "mgmt_nat" {
  count = var.enable_mgmt_subnet && var.management_egress == "nat_gateway" ? 1 : 0

  name                = "pip-${var.name_prefix}-mgmt-nat"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "mgmt" {
  count = var.enable_mgmt_subnet && var.management_egress == "nat_gateway" ? 1 : 0

  name                = "ng-${var.name_prefix}-mgmt"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "mgmt" {
  count = var.enable_mgmt_subnet && var.management_egress == "nat_gateway" ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.mgmt[0].id
  public_ip_address_id = azurerm_public_ip.mgmt_nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "mgmt" {
  count = var.enable_mgmt_subnet && var.management_egress == "nat_gateway" ? 1 : 0

  subnet_id      = azurerm_subnet.mgmt[0].id
  nat_gateway_id = azurerm_nat_gateway.mgmt[0].id
}

#############################################
# Trust route table – associate it with every protected (spoke) subnet.
#############################################

resource "azurerm_route_table" "trust" {
  name                          = "rt-${var.name_prefix}-trust"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.next_hop_ip
  }
}

#############################################
# Availability Set fallback (regions without zones)
#############################################

resource "azurerm_availability_set" "fw" {
  count = !local.use_zones && local.instance_count > 1 ? 1 : 0

  name                         = "avail-${var.name_prefix}"
  location                     = var.location
  resource_group_name          = var.resource_group_name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 5
  managed                      = true
  tags                         = var.tags
}

#############################################
# active-active: internal LB (HA Ports) + external LB (ingress, SNAT)
#############################################

resource "azurerm_lb" "internal" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name                = "lbi-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "fe-trust"
    subnet_id                     = azurerm_subnet.trust.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.vip.trust
    zones                         = local.all_zones
  }
}

resource "azurerm_lb_backend_address_pool" "internal" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name            = "be-trust"
  loadbalancer_id = azurerm_lb.internal[0].id
}

resource "azurerm_lb_probe" "internal" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name                = "probe-fw"
  loadbalancer_id     = azurerm_lb.internal[0].id
  protocol            = var.health_probe_protocol
  port                = var.health_probe_port
  request_path        = var.health_probe_protocol == "Tcp" ? null : var.health_probe_path
  interval_in_seconds = 5
  probe_threshold     = 2
}

resource "azurerm_lb_rule" "ha_ports" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name                           = "ha-ports"
  loadbalancer_id                = azurerm_lb.internal[0].id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "fe-trust"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.internal[0].id]
  probe_id                       = azurerm_lb_probe.internal[0].id
  load_distribution              = "Default"
}

resource "azurerm_lb" "external" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name                = "lbe-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "fe-public"
    public_ip_address_id = azurerm_public_ip.elb[0].id
  }
}

resource "azurerm_lb_backend_address_pool" "external" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name            = "be-untrust"
  loadbalancer_id = azurerm_lb.external[0].id
}

resource "azurerm_lb_probe" "external" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name                = "probe-fw"
  loadbalancer_id     = azurerm_lb.external[0].id
  protocol            = var.health_probe_protocol
  port                = var.health_probe_port
  request_path        = var.health_probe_protocol == "Tcp" ? null : var.health_probe_path
  interval_in_seconds = 5
  probe_threshold     = 2
}

# Floating IP: the firewalls see the public frontend IP as destination and
# DNAT it themselves (vendor-recommended for NVAs behind an external LB).
resource "azurerm_lb_rule" "inbound" {
  for_each = var.ha_mode == "active-active" ? { for r in var.inbound_rules : r.name => r } : {}

  name                           = each.key
  loadbalancer_id                = azurerm_lb.external[0].id
  protocol                       = each.value.protocol
  frontend_port                  = each.value.port
  backend_port                   = each.value.port
  frontend_ip_configuration_name = "fe-public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.external[0].id]
  probe_id                       = azurerm_lb_probe.external[0].id
  floating_ip_enabled            = true
  disable_outbound_snat          = true
}

# Egress SNAT through the external LB public IP (keeps return traffic on
# the firewall that sent it).
resource "azurerm_lb_outbound_rule" "egress" {
  count = var.ha_mode == "active-active" ? 1 : 0

  name                     = "egress"
  loadbalancer_id          = azurerm_lb.external[0].id
  protocol                 = "All"
  backend_address_pool_id  = azurerm_lb_backend_address_pool.external[0].id
  allocated_outbound_ports = var.outbound_ports_per_instance
  idle_timeout_in_minutes  = 4

  frontend_ip_configuration {
    name = "fe-public"
  }
}

#############################################
# active-standby: managed identity + least-privilege failover role
#############################################

resource "azurerm_user_assigned_identity" "failover" {
  count = var.ha_mode == "active-standby" ? 1 : 0

  name                = "id-${var.name_prefix}-failover"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_role_definition" "failover" {
  count = var.ha_mode == "active-standby" ? 1 : 0

  name        = "${var.name_prefix} firewall HA failover"
  scope       = var.resource_group_id
  description = "Lets the ${var.name_prefix} firewall pair move floating IPs / public IPs and update UDRs on failover."

  permissions {
    actions = [
      # Required by the brief
      "Microsoft.Network/routeTables/routes/write",
      "Microsoft.Network/networkInterfaces/write",
      "Microsoft.Network/publicIPAddresses/write",
      # Needed to actually move an IP config / public IP between NICs
      "Microsoft.Network/publicIPAddresses/join/action",
      "Microsoft.Network/virtualNetworks/subnets/join/action",
      "Microsoft.Network/networkSecurityGroups/join/action",
      # Read what is being moved
      "Microsoft.Network/routeTables/read",
      "Microsoft.Network/routeTables/routes/read",
      "Microsoft.Network/networkInterfaces/read",
      "Microsoft.Network/publicIPAddresses/read",
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/subnets/read",
      "Microsoft.Compute/virtualMachines/read",
    ]
    not_actions = []
  }

  assignable_scopes = [var.resource_group_id]
}

resource "azurerm_role_assignment" "failover" {
  count = var.ha_mode == "active-standby" ? 1 : 0

  scope              = var.resource_group_id
  role_definition_id = azurerm_role_definition.failover[0].role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.failover[0].principal_id
  principal_type     = "ServicePrincipal"
}
