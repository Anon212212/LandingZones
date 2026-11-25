#############################################
# Workload spoke – deployed into whichever subscription the root passes
# as this module's azurerm provider (connectivity, shared services or
# production landing zone).
#############################################

locals {
  suffix = "${var.environment}-${var.region_short}"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.org_prefix}-${var.name}-network-${local.suffix}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.org_prefix}-${var.name}-${local.suffix}"
  address_space       = [var.address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  dynamic "ddos_protection_plan" {
    for_each = var.ddos_protection_plan_id == null ? [] : [var.ddos_protection_plan_id]
    content {
      id     = ddos_protection_plan.value
      enable = true
    }
  }
}

resource "azurerm_subnet" "this" {
  name                            = var.subnet_name
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.address_space]
  default_outbound_access_enabled = false
}

# Baseline: Bastion + VNet in, AzureLoadBalancer, deny-all. Per-spoke rules
# (priority 300-3900) slot in between.
resource "azurerm_network_security_group" "this" {
  name                = "nsg-${var.org_prefix}-${var.name}-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  security_rule {
    name                       = "Allow-SSH-RDP-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = var.bastion_subnet_cidr
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
    for_each = var.nsg_rules
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

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = azurerm_subnet.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_route_table" "this" {
  name                          = "rt-${var.org_prefix}-${var.name}-${local.suffix}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "default-to-nva"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.next_hop_ip
  }
}

resource "azurerm_subnet_route_table_association" "this" {
  subnet_id      = azurerm_subnet.this.id
  route_table_id = azurerm_route_table.this.id
}

# Spoke → hub (the hub → spoke side lives in the connectivity subscription).
resource "azurerm_virtual_network_peering" "to_hub" {
  name                         = "peer-${var.name}-to-hub"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.this.name
  remote_virtual_network_id    = var.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

#############################################
# Monitoring – to the platform workspace
#############################################

resource "azurerm_monitor_diagnostic_setting" "vnet" {
  name                           = "diag-to-law"
  target_resource_id             = azurerm_virtual_network.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "nsg" {
  name                           = "diag-to-law"
  target_resource_id             = azurerm_network_security_group.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_network_watcher_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  name                 = "fl-${var.org_prefix}-${var.name}-${local.suffix}"
  network_watcher_name = "NetworkWatcher_${var.location}"
  resource_group_name  = var.network_watcher_resource_group
  location             = var.location
  target_resource_id   = azurerm_virtual_network.this.id
  storage_account_id   = var.flow_log_storage_account_id
  enabled              = true
  version              = 2
  tags                 = var.tags

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = var.log_analytics_workspace_guid
    workspace_region      = var.log_analytics_workspace_location
    workspace_resource_id = var.log_analytics_workspace_id
    interval_in_minutes   = 10
  }
}
