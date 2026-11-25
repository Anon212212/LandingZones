#############################################
# [OpEx/Security] Diagnostic settings → Log Analytics for every
# platform resource that emits logs or metrics.
#############################################

locals {
  diagnostic_targets = merge(
    {
      bastion      = { id = azurerm_bastion_host.bastion.id, logs = true, metrics = true }
      pip_bastion  = { id = azurerm_public_ip.bastion.id, logs = true, metrics = true }
      ilb          = { id = azurerm_lb.nva_internal.id, logs = false, metrics = true }
      nsg_nva      = { id = azurerm_network_security_group.nva.id, logs = true, metrics = false }
      nsg_mgmt     = { id = azurerm_network_security_group.mgmt.id, logs = true, metrics = false }
      nsg_bastion  = { id = azurerm_network_security_group.bastion.id, logs = true, metrics = false }
      nsg_identity = { id = azurerm_network_security_group.id_dc.id, logs = true, metrics = false }
    },
    { for k, v in azurerm_network_security_group.spoke : "nsg_${k}" => { id = v.id, logs = true, metrics = false } },
    { for k, id in local.all_vnet_ids : "vnet_${k}" => { id = id, logs = true, metrics = true } },
    var.enable_nat_gateway ? {
      nat     = { id = azurerm_nat_gateway.nva[0].id, logs = false, metrics = true }
      pip_nat = { id = azurerm_public_ip.nat[0].id, logs = true, metrics = true }
    } : {},
  )

  action_group_ids = azurerm_monitor_action_group.platform[*].id
}

data "azurerm_location" "current" {
  location = var.location
}

resource "azurerm_monitor_diagnostic_setting" "platform" {
  for_each = local.diagnostic_targets

  name                       = "diag-to-law"
  target_resource_id         = each.value.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  # Resource-specific tables are cheaper to query and retain than AzureDiagnostics.
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = each.value.logs ? ["allLogs"] : []
    content {
      category_group = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = each.value.metrics ? ["AllMetrics"] : []
    content {
      category = enabled_metric.value
    }
  }
}

#############################################
# [Security/OpEx] VNet flow logs + Traffic Analytics
# (NSG flow logs are retired; VNet flow logs replace them.)
#############################################

resource "azurerm_storage_account" "flowlogs" {
  count = var.enable_flow_logs ? 1 : 0

  name                     = local.names.flowlog_storage
  resource_group_name      = azurerm_resource_group.management.name
  location                 = var.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS" # [Reliability] survives a zone outage

  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  default_to_oauth_authentication  = true
  # Network Watcher writes flow logs as a trusted Azure service; account keys
  # are left enabled for flow-log compatibility but never used by Terraform.
  shared_access_key_enabled     = true
  public_network_access_enabled = true

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices", "Logging", "Metrics"]
  }

  tags = local.tags
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  for_each = var.enable_flow_logs ? local.all_vnet_ids : {}

  name                 = "fl-${var.org_prefix}-${each.key}-${local.suffix}"
  network_watcher_name = local.network_watcher_name
  resource_group_name  = var.network_watcher_resource_group
  location             = var.location
  target_resource_id   = each.value
  storage_account_id   = azurerm_storage_account.flowlogs[0].id
  enabled              = true
  version              = 2
  tags                 = local.tags

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.law.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.law.location
    workspace_resource_id = azurerm_log_analytics_workspace.law.id
    interval_in_minutes   = 10
  }
}

#############################################
# [OpEx] Guest telemetry from the NVAs (via Azure Monitor Agent)
#############################################

resource "azurerm_monitor_data_collection_rule" "nva" {
  name                = local.names.dcr_nva
  resource_group_name = azurerm_resource_group.management.name
  location            = var.location
  kind                = "Linux"
  description         = "Syslog and performance counters from the NVAs."
  tags                = local.tags

  destinations {
    log_analytics {
      name                  = "law"
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog", "Microsoft-Perf"]
    destinations = ["law"]
  }

  data_sources {
    # Sign-ins / sudo at Info and above for audit.
    syslog {
      name           = "syslog-auth"
      facility_names = ["auth", "authpriv"]
      log_levels     = ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
      streams        = ["Microsoft-Syslog"]
    }

    syslog {
      name           = "syslog-system"
      facility_names = ["daemon", "kern", "syslog", "user"]
      log_levels     = ["Warning", "Error", "Critical", "Alert", "Emergency"]
      streams        = ["Microsoft-Syslog"]
    }

    performance_counter {
      name                          = "perf-core"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        "Processor(*)\\% Processor Time",
        "Memory(*)\\% Used Memory",
        "Network(*)\\Total Bytes Transmitted",
        "Network(*)\\Total Bytes Received",
        "Logical Disk(*)\\% Used Space",
      ]
    }
  }
}

#############################################
# [OpEx] Alerting
#############################################

resource "azurerm_monitor_action_group" "platform" {
  count = length(var.alert_email_addresses) > 0 ? 1 : 0

  name                = local.names.action_group
  resource_group_name = azurerm_resource_group.management.name
  short_name          = "lz-platform"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_addresses
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# [Reliability] An NVA failed its health probe (capacity halved).
resource "azurerm_monitor_metric_alert" "ilb_backend_health" {
  name                = "alert-${var.org_prefix}-ilb-backend-health-${local.suffix}"
  resource_group_name = azurerm_resource_group.management.name
  scopes              = [azurerm_lb.nva_internal.id]
  description         = "One or more NVAs are failing the ILB health probe."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Network/loadBalancers"
    metric_name      = "DipAvailability"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
  }

  dynamic "action" {
    for_each = local.action_group_ids
    content {
      action_group_id = action.value
    }
  }
}

# [Reliability] ILB data path degraded – spoke traffic is affected.
resource "azurerm_monitor_metric_alert" "ilb_datapath" {
  name                = "alert-${var.org_prefix}-ilb-datapath-${local.suffix}"
  resource_group_name = azurerm_resource_group.management.name
  scopes              = [azurerm_lb.nva_internal.id]
  description         = "ILB data path availability below 100%."
  severity            = 0
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Network/loadBalancers"
    metric_name      = "VipAvailability"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
  }

  dynamic "action" {
    for_each = local.action_group_ids
    content {
      action_group_id = action.value
    }
  }
}

# [Reliability] NVA VM unavailable.
resource "azurerm_monitor_metric_alert" "nva_availability" {
  name                     = "alert-${var.org_prefix}-nva-availability-${local.suffix}"
  resource_group_name      = azurerm_resource_group.management.name
  scopes                   = azurerm_linux_virtual_machine.nva[*].id
  target_resource_type     = "Microsoft.Compute/virtualMachines"
  target_resource_location = var.location
  description              = "An NVA VM is reporting unavailable."
  severity                 = 1
  frequency                = "PT1M"
  window_size              = "PT5M"
  tags                     = local.tags

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

# [Perf] Sustained NVA CPU – scale up (nva_size) or out (nva_zones).
resource "azurerm_monitor_metric_alert" "nva_cpu" {
  name                     = "alert-${var.org_prefix}-nva-cpu-${local.suffix}"
  resource_group_name      = azurerm_resource_group.management.name
  scopes                   = azurerm_linux_virtual_machine.nva[*].id
  target_resource_type     = "Microsoft.Compute/virtualMachines"
  target_resource_location = var.location
  description              = "NVA CPU above ${var.nva_cpu_alert_threshold}% for 15 minutes – consider scaling."
  severity                 = 2
  frequency                = "PT5M"
  window_size              = "PT15M"
  tags                     = local.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.nva_cpu_alert_threshold
  }

  dynamic "action" {
    for_each = local.action_group_ids
    content {
      action_group_id = action.value
    }
  }
}

# [Reliability/Perf] SNAT port exhaustion on the NAT Gateway.
resource "azurerm_monitor_metric_alert" "nat_snat_failures" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "alert-${var.org_prefix}-nat-snat-failures-${local.suffix}"
  resource_group_name = azurerm_resource_group.management.name
  scopes              = [azurerm_nat_gateway.nva[0].id]
  description         = "NAT Gateway is dropping connections (SNAT exhaustion) – add public IPs."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Network/natGateways"
    metric_name      = "SNATConnectionCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0

    dimension {
      name     = "ConnectionState"
      operator = "Include"
      values   = ["Failed"]
    }
  }

  dynamic "action" {
    for_each = local.action_group_ids
    content {
      action_group_id = action.value
    }
  }
}

# [Reliability] Azure Service Health incidents/maintenance for this region.
resource "azurerm_monitor_activity_log_alert" "service_health" {
  name                = "alert-${var.org_prefix}-service-health-${local.suffix}"
  resource_group_name = azurerm_resource_group.management.name
  location            = "global"
  scopes              = [data.azurerm_subscription.current.id]
  description         = "Service Health events affecting ${data.azurerm_location.current.display_name}."
  tags                = local.tags

  criteria {
    category = "ServiceHealth"

    service_health {
      locations = [data.azurerm_location.current.display_name, "Global"]
    }
  }

  dynamic "action" {
    for_each = local.action_group_ids
    content {
      action_group_id = action.value
    }
  }
}

# [Reliability] Resource Health degradation of anything in the connectivity RG.
resource "azurerm_monitor_activity_log_alert" "resource_health" {
  name                = "alert-${var.org_prefix}-resource-health-${local.suffix}"
  resource_group_name = azurerm_resource_group.management.name
  location            = "global"
  scopes              = [azurerm_resource_group.connectivity.id]
  description         = "A connectivity resource became Degraded or Unavailable."
  tags                = local.tags

  criteria {
    category = "ResourceHealth"

    resource_health {
      current  = ["Degraded", "Unavailable"]
      previous = ["Available"]
    }
  }

  dynamic "action" {
    for_each = local.action_group_ids
    content {
      action_group_id = action.value
    }
  }
}
