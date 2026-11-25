#############################################
# Identity – tier-0, dedicated subscription
#
# Shared tier-0 services (Log Analytics, Key Vault, DCR) live in the primary
# location. Domain controllers and their Recovery Services vaults are
# deployed per region by modules/identity-region.
#############################################

data "azurerm_client_config" "identity" {
  provider = azurerm.identity
}

data "azurerm_subscription" "identity" {
  provider = azurerm.identity
}

locals {
  identity_suffix = "identity-${var.environment}-${local.region_short}"

  identity_names = {
    rg  = "rg-${var.org_prefix}-identity-mgmt-${var.environment}-${local.region_short}"
    law = "log-${var.org_prefix}-${local.identity_suffix}"
    dcr = "dcr-${var.org_prefix}-dc-${var.environment}-${local.region_short}"
    kv  = "${substr("kv${replace(var.org_prefix, "-", "")}id", 0, 17)}${substr(md5(data.azurerm_subscription.identity.id), 0, 7)}"
  }

  identity_tags = merge(local.tags, { tier = "0", workload = "identity" })

  # All landing-zone networks that may talk to AD DS.
  ad_client_cidrs = distinct(concat(
    [var.hub_address_space],
    [for s in local.spokes : s.address_space],
    [for r in values(var.identity_regions) : r.address_space],
  ))

  identity_admin_cidrs = concat(
    var.identity_allow_hub_bastion ? [local.hub_subnets.bastion] : [],
    var.identity_admin_source_cidrs,
  )

  # Full mesh between identity VNets for direct DC-to-DC replication.
  identity_peerings = {
    for pair in setproduct(keys(var.identity_regions), keys(var.identity_regions)) :
    "${pair[0]}-to-${pair[1]}" => { src = pair[0], dst = pair[1] }
    if pair[0] != pair[1]
  }
}

resource "azurerm_resource_group" "identity_mgmt" {
  provider = azurerm.identity

  name     = local.identity_names.rg
  location = var.location
  tags     = local.identity_tags
}

#############################################
# Tier-0 Log Analytics – kept separate so lower-tier admins can't read or
# tamper with tier-0 security logs.
#############################################

resource "azurerm_log_analytics_workspace" "identity" {
  provider = azurerm.identity

  name                         = local.identity_names.law
  location                     = var.location
  resource_group_name          = azurerm_resource_group.identity_mgmt.name
  sku                          = var.log_analytics_sku
  retention_in_days            = max(var.log_retention_days, 365) # tier-0 audit
  local_authentication_enabled = false
  tags                         = local.identity_tags
}

# Identity subscription activity log → tier-0 workspace.
resource "azurerm_monitor_diagnostic_setting" "identity_activity_log" {
  provider = azurerm.identity

  name                       = "diag-activitylog-to-law"
  target_resource_id         = data.azurerm_subscription.identity.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.identity.id

  dynamic "enabled_log" {
    for_each = ["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"]
    content {
      category = enabled_log.value
    }
  }
}

#############################################
# Tier-0 Key Vault – generated DC admin passwords
#############################################

resource "azurerm_key_vault" "identity" {
  provider = azurerm.identity

  name                          = local.identity_names.kv
  location                      = var.location
  resource_group_name           = azurerm_resource_group.identity_mgmt.name
  tenant_id                     = data.azurerm_client_config.identity.tenant_id
  sku_name                      = "premium"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = true
  tags                          = local.identity_tags

  network_acls {
    bypass         = "AzureServices"
    default_action = length(var.identity_key_vault_allowed_ips) > 0 ? "Deny" : "Allow"
    ip_rules       = var.identity_key_vault_allowed_ips
  }
}

# The deploying identity needs to write the DC secrets.
resource "azurerm_role_assignment" "identity_kv_deployer" {
  provider = azurerm.identity

  scope                = azurerm_key_vault.identity.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.identity.object_id
}

resource "azurerm_monitor_diagnostic_setting" "identity_kv" {
  provider = azurerm.identity

  name                           = "diag-to-law"
  target_resource_id             = azurerm_key_vault.identity.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.identity.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "audit"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_management_lock" "identity_kv" {
  provider = azurerm.identity
  count    = var.enable_resource_locks ? 1 : 0

  name       = "lock-kv"
  scope      = azurerm_key_vault.identity.id
  lock_level = "CanNotDelete"
  notes      = "Tier-0 secrets."
}

resource "azurerm_management_lock" "identity_law" {
  provider = azurerm.identity
  count    = var.enable_resource_locks ? 1 : 0

  name       = "lock-law"
  scope      = azurerm_log_analytics_workspace.identity.id
  lock_level = "CanNotDelete"
  notes      = "Tier-0 audit logs."
}

#############################################
# DC guest telemetry (AMA → DCR → tier-0 workspace)
# Security event collection belongs to Defender for Identity / Sentinel.
#############################################

resource "azurerm_monitor_data_collection_rule" "dc" {
  provider = azurerm.identity

  name                = local.identity_names.dcr
  resource_group_name = azurerm_resource_group.identity_mgmt.name
  location            = var.location
  kind                = "Windows"
  description         = "AD DS, DNS, DFSR and system events plus core performance counters from domain controllers."
  tags                = local.identity_tags

  destinations {
    log_analytics {
      name                  = "law"
      workspace_resource_id = azurerm_log_analytics_workspace.identity.id
    }
  }

  data_flow {
    streams      = ["Microsoft-Event", "Microsoft-Perf"]
    destinations = ["law"]
  }

  data_sources {
    windows_event_log {
      name    = "ad-events"
      streams = ["Microsoft-Event"]
      x_path_queries = [
        "Directory Service!*[System[(Level=1 or Level=2 or Level=3)]]",
        "DNS Server!*[System[(Level=1 or Level=2 or Level=3)]]",
        "DFS Replication!*[System[(Level=1 or Level=2 or Level=3)]]",
        "System!*[System[(Level=1 or Level=2 or Level=3)]]",
        "Application!*[System[(Level=1 or Level=2)]]",
      ]
    }

    performance_counter {
      name                          = "perf-core"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        "\\Processor Information(_Total)\\% Processor Time",
        "\\Memory\\Available MBytes",
        "\\LogicalDisk(*)\\% Free Space",
        "\\NTDS\\LDAP Searches/sec",
        "\\NTDS\\DRA Pending Replication Synchronizations",
      ]
    }
  }
}

#############################################
# Per-region identity deployments
#############################################

module "identity" {
  source   = "./modules/identity-region"
  for_each = var.identity_regions

  providers = {
    azurerm = azurerm.identity
  }

  org_prefix      = var.org_prefix
  environment     = var.environment
  location        = each.value.location
  region_short    = lookup(local.region_short_map, each.value.location, each.value.location)
  subscription_id = data.azurerm_subscription.identity.subscription_id
  tags            = merge(local.identity_tags, { identity-region = each.key })

  address_space           = each.value.address_space
  dns_servers             = var.identity_dns_servers
  hub_vnet_id             = azurerm_virtual_network.hub.id
  next_hop_ip             = coalesce(each.value.next_hop_ip, local.nva_next_hop_ip)
  ad_client_cidrs         = local.ad_client_cidrs
  admin_source_cidrs      = local.identity_admin_cidrs
  ddos_protection_plan_id = var.ddos_protection_plan_id

  dc_zones                = each.value.dc_zones
  dc_size                 = var.dc_size
  dc_admin_username       = var.dc_admin_username
  dc_image_sku            = var.dc_image_sku
  dc_data_disk_size_gb    = var.dc_data_disk_size_gb
  dc_hybrid_benefit       = var.dc_hybrid_benefit
  encryption_at_host      = var.nva_encryption_at_host
  key_vault_id            = azurerm_key_vault.identity.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.dc.id

  backup_storage_mode = var.identity_backup_storage_mode

  log_analytics_workspace_id       = azurerm_log_analytics_workspace.identity.id
  log_analytics_workspace_guid     = azurerm_log_analytics_workspace.identity.workspace_id
  log_analytics_workspace_location = azurerm_log_analytics_workspace.identity.location
  enable_flow_logs                 = var.enable_flow_logs
  flow_log_retention_days          = var.flow_log_retention_days
  network_watcher_resource_group   = var.network_watcher_resource_group
  enable_resource_locks            = var.enable_resource_locks

  # Secrets can only be written once the deployer holds the KV role.
  depends_on = [azurerm_role_assignment.identity_kv_deployer]
}

#############################################
# Peerings
#############################################

# Hub → identity (connectivity subscription side).
resource "azurerm_virtual_network_peering" "hub_to_identity" {
  for_each = var.identity_regions

  name                         = "peer-hub-to-identity-${each.key}"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = module.identity[each.key].vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# Identity ↔ identity (direct DC replication, survives an NVA outage).
resource "azurerm_virtual_network_peering" "identity_mesh" {
  provider = azurerm.identity
  for_each = local.identity_peerings

  name                         = "peer-identity-${each.key}"
  resource_group_name          = module.identity[each.value.src].resource_group_name
  virtual_network_name         = module.identity[each.value.src].vnet_name
  remote_virtual_network_id    = module.identity[each.value.dst].vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

#############################################
# Alerts – DC availability per region
#############################################

resource "azurerm_monitor_metric_alert" "dc_availability" {
  provider = azurerm.identity
  for_each = var.identity_regions

  name                     = "alert-${var.org_prefix}-dc-availability-${each.key}-${var.environment}"
  resource_group_name      = azurerm_resource_group.identity_mgmt.name
  scopes                   = module.identity[each.key].dc_vm_ids
  target_resource_type     = "Microsoft.Compute/virtualMachines"
  target_resource_location = each.value.location
  description              = "A domain controller in ${each.value.location} is unavailable."
  severity                 = 1
  frequency                = "PT1M"
  window_size              = "PT5M"
  tags                     = local.identity_tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "VmAvailabilityMetric"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  dynamic "action" {
    for_each = local.action_group_ids
    content {
      action_group_id = action.value
    }
  }
}
