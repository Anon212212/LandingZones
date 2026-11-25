#############################################
# Hub VNet & subnets
#############################################

resource "azurerm_virtual_network" "hub" {
  name                = local.names.hub_vnet
  address_space       = [var.hub_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags

  dynamic "ddos_protection_plan" {
    for_each = var.ddos_protection_plan_id == null ? [] : [var.ddos_protection_plan_id]
    content {
      id     = ddos_protection_plan.value
      enable = true
    }
  }
}

# [Security] default_outbound_access_enabled = false makes every subnet
# private: egress only via the NVAs / NAT Gateway, never implicit SNAT.
resource "azurerm_subnet" "hub_nva_external" {
  name                            = "snet-nva-external"
  resource_group_name             = azurerm_resource_group.connectivity.name
  virtual_network_name            = azurerm_virtual_network.hub.name
  address_prefixes                = [local.hub_subnets.nva_external]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "hub_nva_internal" {
  name                            = "snet-nva-internal"
  resource_group_name             = azurerm_resource_group.connectivity.name
  virtual_network_name            = azurerm_virtual_network.hub.name
  address_prefixes                = [local.hub_subnets.nva_internal]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "hub_mgmt" {
  name                            = "snet-mgmt"
  resource_group_name             = azurerm_resource_group.connectivity.name
  virtual_network_name            = azurerm_virtual_network.hub.name
  address_prefixes                = [local.hub_subnets.mgmt]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "hub_bastion" {
  name                 = "AzureBastionSubnet" # name mandated by Azure
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.hub_subnets.bastion]
}

#############################################
# Workload spokes – one module instance per spoke, in the subscription the
# spoke names (Terraform can't pick a provider per for_each item, so there
# is one module block per subscription).
#############################################

locals {
  spoke_module_inputs = {
    org_prefix                       = var.org_prefix
    environment                      = var.environment
    location                         = var.location
    region_short                     = local.region_short
    hub_vnet_id                      = azurerm_virtual_network.hub.id
    next_hop_ip                      = local.nva_ilb_frontend_ip
    bastion_subnet_cidr              = local.hub_subnets.bastion
    ddos_protection_plan_id          = var.ddos_protection_plan_id
    log_analytics_workspace_id       = azurerm_log_analytics_workspace.law.id
    log_analytics_workspace_guid     = azurerm_log_analytics_workspace.law.workspace_id
    log_analytics_workspace_location = azurerm_log_analytics_workspace.law.location
    enable_flow_logs                 = var.enable_flow_logs
    flow_log_storage_account_id      = var.enable_flow_logs ? azurerm_storage_account.flowlogs[0].id : null
    flow_log_retention_days          = var.flow_log_retention_days
    network_watcher_resource_group   = var.network_watcher_resource_group
  }
}

module "spokes_connectivity" {
  source   = "./modules/spoke"
  for_each = local.spokes_by_subscription["connectivity"]

  name          = each.key
  address_space = each.value.address_space
  subnet_name   = each.value.subnet_name
  nsg_rules     = each.value.nsg_rules
  tags          = merge(local.tags, { landing-zone = "connectivity", spoke = each.key })

  org_prefix                       = local.spoke_module_inputs.org_prefix
  environment                      = local.spoke_module_inputs.environment
  location                         = local.spoke_module_inputs.location
  region_short                     = local.spoke_module_inputs.region_short
  hub_vnet_id                      = local.spoke_module_inputs.hub_vnet_id
  next_hop_ip                      = local.spoke_module_inputs.next_hop_ip
  bastion_subnet_cidr              = local.spoke_module_inputs.bastion_subnet_cidr
  ddos_protection_plan_id          = local.spoke_module_inputs.ddos_protection_plan_id
  log_analytics_workspace_id       = local.spoke_module_inputs.log_analytics_workspace_id
  log_analytics_workspace_guid     = local.spoke_module_inputs.log_analytics_workspace_guid
  log_analytics_workspace_location = local.spoke_module_inputs.log_analytics_workspace_location
  enable_flow_logs                 = local.spoke_module_inputs.enable_flow_logs
  flow_log_storage_account_id      = local.spoke_module_inputs.flow_log_storage_account_id
  flow_log_retention_days          = local.spoke_module_inputs.flow_log_retention_days
  network_watcher_resource_group   = local.spoke_module_inputs.network_watcher_resource_group
}

module "spokes_shared" {
  source   = "./modules/spoke"
  for_each = local.spokes_by_subscription["shared"]
  providers = {
    azurerm = azurerm.shared
  }

  name          = each.key
  address_space = each.value.address_space
  subnet_name   = each.value.subnet_name
  nsg_rules     = each.value.nsg_rules
  tags          = merge(local.tags, { landing-zone = "shared-services", spoke = each.key })

  org_prefix                       = local.spoke_module_inputs.org_prefix
  environment                      = local.spoke_module_inputs.environment
  location                         = local.spoke_module_inputs.location
  region_short                     = local.spoke_module_inputs.region_short
  hub_vnet_id                      = local.spoke_module_inputs.hub_vnet_id
  next_hop_ip                      = local.spoke_module_inputs.next_hop_ip
  bastion_subnet_cidr              = local.spoke_module_inputs.bastion_subnet_cidr
  ddos_protection_plan_id          = local.spoke_module_inputs.ddos_protection_plan_id
  log_analytics_workspace_id       = local.spoke_module_inputs.log_analytics_workspace_id
  log_analytics_workspace_guid     = local.spoke_module_inputs.log_analytics_workspace_guid
  log_analytics_workspace_location = local.spoke_module_inputs.log_analytics_workspace_location
  enable_flow_logs                 = local.spoke_module_inputs.enable_flow_logs
  flow_log_storage_account_id      = local.spoke_module_inputs.flow_log_storage_account_id
  flow_log_retention_days          = local.spoke_module_inputs.flow_log_retention_days
  network_watcher_resource_group   = local.spoke_module_inputs.network_watcher_resource_group
}

module "spokes_prod" {
  source   = "./modules/spoke"
  for_each = local.spokes_by_subscription["prod"]
  providers = {
    azurerm = azurerm.prod
  }

  name          = each.key
  address_space = each.value.address_space
  subnet_name   = each.value.subnet_name
  nsg_rules     = each.value.nsg_rules
  tags          = merge(local.tags, { landing-zone = "production", spoke = each.key })

  org_prefix                       = local.spoke_module_inputs.org_prefix
  environment                      = local.spoke_module_inputs.environment
  location                         = local.spoke_module_inputs.location
  region_short                     = local.spoke_module_inputs.region_short
  hub_vnet_id                      = local.spoke_module_inputs.hub_vnet_id
  next_hop_ip                      = local.spoke_module_inputs.next_hop_ip
  bastion_subnet_cidr              = local.spoke_module_inputs.bastion_subnet_cidr
  ddos_protection_plan_id          = local.spoke_module_inputs.ddos_protection_plan_id
  log_analytics_workspace_id       = local.spoke_module_inputs.log_analytics_workspace_id
  log_analytics_workspace_guid     = local.spoke_module_inputs.log_analytics_workspace_guid
  log_analytics_workspace_location = local.spoke_module_inputs.log_analytics_workspace_location
  enable_flow_logs                 = local.spoke_module_inputs.enable_flow_logs
  flow_log_storage_account_id      = local.spoke_module_inputs.flow_log_storage_account_id
  flow_log_retention_days          = local.spoke_module_inputs.flow_log_retention_days
  network_watcher_resource_group   = local.spoke_module_inputs.network_watcher_resource_group
}

module "spokes_avd" {
  source   = "./modules/spoke"
  for_each = local.spokes_by_subscription["avd"]
  providers = {
    azurerm = azurerm.avd
  }

  name          = each.key
  address_space = each.value.address_space
  subnet_name   = each.value.subnet_name
  nsg_rules     = each.value.nsg_rules
  tags          = merge(local.tags, { landing-zone = "avd", spoke = each.key })

  org_prefix                       = local.spoke_module_inputs.org_prefix
  environment                      = local.spoke_module_inputs.environment
  location                         = local.spoke_module_inputs.location
  region_short                     = local.spoke_module_inputs.region_short
  hub_vnet_id                      = local.spoke_module_inputs.hub_vnet_id
  next_hop_ip                      = local.spoke_module_inputs.next_hop_ip
  bastion_subnet_cidr              = local.spoke_module_inputs.bastion_subnet_cidr
  ddos_protection_plan_id          = local.spoke_module_inputs.ddos_protection_plan_id
  log_analytics_workspace_id       = local.spoke_module_inputs.log_analytics_workspace_id
  log_analytics_workspace_guid     = local.spoke_module_inputs.log_analytics_workspace_guid
  log_analytics_workspace_location = local.spoke_module_inputs.log_analytics_workspace_location
  enable_flow_logs                 = local.spoke_module_inputs.enable_flow_logs
  flow_log_storage_account_id      = local.spoke_module_inputs.flow_log_storage_account_id
  flow_log_retention_days          = local.spoke_module_inputs.flow_log_retention_days
  network_watcher_resource_group   = local.spoke_module_inputs.network_watcher_resource_group
}

# Hub → spoke peerings (connectivity subscription side).
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each = local.spokes

  name                         = "peer-hub-to-${each.key}"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = local.spoke_modules[each.key].vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

#############################################
# NAT Gateway (NVA Internet egress)
#
# Standard NAT Gateway is a zonal resource; left non-zonal here so Azure
# places it. See docs/well-architected.md for the reliability trade-off.
#############################################

resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = local.names.nat_pip
  location                = var.location
  resource_group_name     = azurerm_resource_group.connectivity.name
  allocation_method       = "Static"
  sku                     = "Standard"
  ddos_protection_mode    = var.ddos_protection_plan_id == null ? "VirtualNetworkInherited" : "Enabled"
  ddos_protection_plan_id = var.ddos_protection_plan_id
  tags                    = local.tags
}

resource "azurerm_nat_gateway" "nva" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = local.names.nat
  location                = var.location
  resource_group_name     = azurerm_resource_group.connectivity.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = local.tags
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
