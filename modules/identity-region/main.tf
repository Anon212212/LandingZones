#############################################
# Identity (tier-0) – one region
#
# Domain controllers spread across Availability Zones, protected by a
# zone-redundant Recovery Services vault in the same region. Deploy this
# module once per region for regional redundancy.
#############################################

locals {
  suffix   = "identity-${var.environment}-${var.region_short}"
  dc_count = length(var.dc_zones)

  dc_subnet = cidrsubnet(var.address_space, 3, 0)
  # First assignable host is .4 (Azure reserves .0-.3).
  dc_ips = [for i in range(local.dc_count) : cidrhost(local.dc_subnet, 4 + i)]

  dc_names = [for i in range(local.dc_count) : format("vm-%s-dc%02d-%s-%s", var.org_prefix, i + 1, var.environment, var.region_short)]
  # NetBIOS limit: 15 chars → <org(7)><region(4)>DC<nn>
  dc_computer_names = [for i in range(local.dc_count) : upper(format("%s%sdc%02d", substr(replace(var.org_prefix, "-", ""), 0, 7), substr(var.region_short, 0, 4), i + 1))]

  # Prepare the data disk (F:) for NTDS/SYSVOL and install the AD DS + DNS
  # role binaries. Promotion is a deliberate, separate step (see docs).
  dc_prep_command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -DriveLetter F -UseMaximumSize | Format-Volume -FileSystem NTFS -NewFileSystemLabel ADDS -Confirm:$false; Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools\""

  storage_name = "${substr("stid${replace(var.org_prefix, "-", "")}", 0, 17)}${substr(md5("${var.subscription_id}-${var.location}"), 0, 7)}"
}

#############################################
# Resource groups – DCs and their backups are separated so backup
# operators can be granted access to the vault only.
#############################################

resource "azurerm_resource_group" "identity" {
  name     = "rg-${var.org_prefix}-${local.suffix}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "backup" {
  name     = "rg-${var.org_prefix}-identity-backup-${var.environment}-${var.region_short}"
  location = var.location
  tags     = var.tags
}

#############################################
# Network
#############################################

resource "azurerm_virtual_network" "identity" {
  name                = "vnet-${var.org_prefix}-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.identity.name
  address_space       = [var.address_space]
  dns_servers         = var.dns_servers
  tags                = var.tags

  dynamic "ddos_protection_plan" {
    for_each = var.ddos_protection_plan_id == null ? [] : [var.ddos_protection_plan_id]
    content {
      id     = ddos_protection_plan.value
      enable = true
    }
  }
}

resource "azurerm_subnet" "dc" {
  name                            = "snet-dc"
  resource_group_name             = azurerm_resource_group.identity.name
  virtual_network_name            = azurerm_virtual_network.identity.name
  address_prefixes                = [local.dc_subnet]
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "dc" {
  name                = "nsg-${var.org_prefix}-dc-${var.environment}-${var.region_short}"
  location            = var.location
  resource_group_name = azurerm_resource_group.identity.name
  tags                = var.tags

  # Explicit landing-zone CIDRs rather than the VirtualNetwork tag: that tag
  # also includes UDR prefixes (0.0.0.0/0 here), which would open AD DS to
  # anything routed through the NVA.
  security_rule {
    name                       = "Allow-AD-TCP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["53", "88", "135", "389", "445", "464", "636", "3268-3269", "9389", "49152-65535"]
    source_address_prefixes    = var.ad_client_cidrs
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
    source_address_prefixes    = var.ad_client_cidrs
    destination_address_prefix = "*"
  }

  dynamic "security_rule" {
    for_each = length(var.admin_source_cidrs) > 0 ? [var.admin_source_cidrs] : []
    content {
      name                       = "Allow-RDP-Admin"
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefixes    = security_rule.value
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

resource "azurerm_subnet_network_security_group_association" "dc" {
  subnet_id                 = azurerm_subnet.dc.id
  network_security_group_id = azurerm_network_security_group.dc.id
}

resource "azurerm_route_table" "dc" {
  name                          = "rt-${var.org_prefix}-dc-${var.environment}-${var.region_short}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.identity.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "default-to-nva"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.next_hop_ip
  }
}

resource "azurerm_subnet_route_table_association" "dc" {
  subnet_id      = azurerm_subnet.dc.id
  route_table_id = azurerm_route_table.dc.id
}

# Identity → hub (the hub → identity side lives in the connectivity subscription).
resource "azurerm_virtual_network_peering" "to_hub" {
  name                         = "peer-identity-${var.region_short}-to-hub"
  resource_group_name          = azurerm_resource_group.identity.name
  virtual_network_name         = azurerm_virtual_network.identity.name
  remote_virtual_network_id    = var.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

#############################################
# Domain controllers (one per zone)
#############################################

resource "random_password" "dc_admin" {
  count = local.dc_count

  length           = 32
  special          = true
  override_special = "!#%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_key_vault_secret" "dc_admin" {
  count = local.dc_count

  name         = "${local.dc_names[count.index]}-admin"
  key_vault_id = var.key_vault_id
  value        = random_password.dc_admin[count.index].result
  content_type = "username=${var.dc_admin_username}"
  tags         = var.tags
}

resource "azurerm_network_interface" "dc" {
  count = local.dc_count

  name                           = "nic-${local.dc_names[count.index]}"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.identity.name
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.dc.id
    private_ip_address_allocation = "Static" # DCs must keep their IPs
    private_ip_address            = local.dc_ips[count.index]
  }
}

resource "azurerm_windows_virtual_machine" "dc" {
  count = local.dc_count

  name                  = local.dc_names[count.index]
  computer_name         = local.dc_computer_names[count.index]
  location              = var.location
  resource_group_name   = azurerm_resource_group.identity.name
  size                  = var.dc_size
  zone                  = var.dc_zones[count.index]
  admin_username        = var.dc_admin_username
  admin_password        = random_password.dc_admin[count.index].result
  network_interface_ids = [azurerm_network_interface.dc[count.index].id]
  license_type          = var.dc_hybrid_benefit ? "Windows_Server" : null
  timezone              = "UTC"
  tags                  = merge(var.tags, { tier = "0", role = "domain-controller" })

  # Trusted Launch.
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = var.encryption_at_host

  identity {
    type = "SystemAssigned"
  }

  # Platform-orchestrated patching (zone/region aware, never both DCs at once).
  patch_mode                = "AutomaticByPlatform"
  patch_assessment_mode     = "AutomaticByPlatform"
  reboot_setting            = "IfRequired"
  automatic_updates_enabled = true
  provision_vm_agent        = true

  os_disk {
    name                 = "osdisk-${local.dc_names[count.index]}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.dc_image_sku
    version   = "latest"
  }

  boot_diagnostics {}

  depends_on = [azurerm_subnet_network_security_group_association.dc]
}

# NTDS.dit, logs and SYSVOL live on a data disk with host caching OFF –
# a Microsoft requirement for AD DS on Azure to avoid database corruption.
resource "azurerm_managed_disk" "ntds" {
  count = local.dc_count

  name                 = "disk-${local.dc_names[count.index]}-ntds"
  location             = var.location
  resource_group_name  = azurerm_resource_group.identity.name
  zone                 = var.dc_zones[count.index]
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.dc_data_disk_size_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "ntds" {
  count = local.dc_count

  managed_disk_id    = azurerm_managed_disk.ntds[count.index].id
  virtual_machine_id = azurerm_windows_virtual_machine.dc[count.index].id
  lun                = 0
  caching            = "None"
}

resource "azurerm_virtual_machine_extension" "dc_prep" {
  count = local.dc_count

  name                       = "dc-prep"
  virtual_machine_id         = azurerm_windows_virtual_machine.dc[count.index].id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  tags                       = var.tags

  protected_settings = jsonencode({
    commandToExecute = local.dc_prep_command
  })

  depends_on = [azurerm_virtual_machine_data_disk_attachment.ntds]

  lifecycle {
    # Runs once at build; never re-run against a promoted DC.
    ignore_changes = [protected_settings]
  }
}

resource "azurerm_virtual_machine_extension" "dc_ama" {
  count = local.dc_count

  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.dc[count.index].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  tags                       = var.tags

  depends_on = [azurerm_virtual_machine_extension.dc_prep]
}

resource "azurerm_monitor_data_collection_rule_association" "dc" {
  count = local.dc_count

  name                    = "dcra-${local.dc_names[count.index]}"
  target_resource_id      = azurerm_windows_virtual_machine.dc[count.index].id
  data_collection_rule_id = var.data_collection_rule_id
}

#############################################
# Recovery Services vault (zone-redundant, immutable, soft delete)
#############################################

resource "azurerm_recovery_services_vault" "identity" {
  name                         = "rsv-${var.org_prefix}-${local.suffix}"
  location                     = var.location
  resource_group_name          = azurerm_resource_group.backup.name
  sku                          = "Standard"
  storage_mode_type            = var.backup_storage_mode
  cross_region_restore_enabled = var.backup_storage_mode == "GeoRedundant"
  # Soft delete is always on for new vaults; immutability blocks reducing
  # retention or deleting recovery points early. Lock it ("Locked") once
  # the retention policy is final – that step is irreversible.
  immutability = "Unlocked"
  tags         = var.tags

  identity {
    type = "SystemAssigned"
  }

  monitoring {
    alerts_for_all_job_failures_enabled            = true
    alerts_for_critical_operation_failures_enabled = true
  }
}

# Enhanced (V2) policy – required for Trusted Launch VMs. Retention stays
# inside the AD tombstone lifetime (180 days): older system-state backups
# cannot be restored into a live forest.
resource "azurerm_backup_policy_vm" "dc" {
  name                           = "bkpol-dc-daily"
  resource_group_name            = azurerm_resource_group.backup.name
  recovery_vault_name            = azurerm_recovery_services_vault.identity.name
  policy_type                    = "V2"
  timezone                       = "UTC"
  instant_restore_retention_days = 7

  backup {
    frequency = "Daily"
    time      = var.backup_time_utc
  }

  retention_daily {
    count = 30
  }

  retention_weekly {
    count    = 12
    weekdays = ["Sunday"]
  }

  retention_monthly {
    count    = 5
    weekdays = ["Sunday"]
    weeks    = ["First"]
  }
}

resource "azurerm_backup_protected_vm" "dc" {
  count = local.dc_count

  resource_group_name = azurerm_resource_group.backup.name
  recovery_vault_name = azurerm_recovery_services_vault.identity.name
  source_vm_id        = azurerm_windows_virtual_machine.dc[count.index].id
  backup_policy_id    = azurerm_backup_policy_vm.dc.id
}

#############################################
# Locks – DCs and backups must never be deleted casually
#############################################

resource "azurerm_management_lock" "dc" {
  count = var.enable_resource_locks ? local.dc_count : 0

  name       = "lock-${local.dc_names[count.index]}"
  scope      = azurerm_windows_virtual_machine.dc[count.index].id
  lock_level = "CanNotDelete"
  notes      = "Tier-0 domain controller. Demote before removal."
}

resource "azurerm_management_lock" "vault" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-rsv"
  scope      = azurerm_recovery_services_vault.identity.id
  lock_level = "CanNotDelete"
  notes      = "Tier-0 backups."
}

resource "azurerm_management_lock" "vnet" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-identity-vnet"
  scope      = azurerm_virtual_network.identity.id
  lock_level = "CanNotDelete"
  notes      = "Tier-0 network."
}

#############################################
# Monitoring – diagnostics and VNet flow logs to the tier-0 workspace
#############################################

resource "azurerm_monitor_diagnostic_setting" "this" {
  for_each = {
    vnet  = { id = azurerm_virtual_network.identity.id, metrics = true }
    nsg   = { id = azurerm_network_security_group.dc.id, metrics = false }
    vault = { id = azurerm_recovery_services_vault.identity.id, metrics = true }
  }

  name                           = "diag-to-law"
  target_resource_id             = each.value.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  dynamic "enabled_metric" {
    for_each = each.value.metrics ? ["AllMetrics"] : []
    content {
      category = enabled_metric.value
    }
  }
}

resource "azurerm_storage_account" "flowlogs" {
  count = var.enable_flow_logs ? 1 : 0

  name                             = local.storage_name
  resource_group_name              = azurerm_resource_group.identity.name
  location                         = var.location
  account_kind                     = "StorageV2"
  account_tier                     = "Standard"
  account_replication_type         = "ZRS"
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  default_to_oauth_authentication  = true
  shared_access_key_enabled        = true
  public_network_access_enabled    = true

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices", "Logging", "Metrics"]
  }

  tags = var.tags
}

resource "azurerm_network_watcher_flow_log" "identity" {
  count = var.enable_flow_logs ? 1 : 0

  name                 = "fl-${var.org_prefix}-${local.suffix}"
  network_watcher_name = "NetworkWatcher_${var.location}"
  resource_group_name  = var.network_watcher_resource_group
  location             = var.location
  target_resource_id   = azurerm_virtual_network.identity.id
  storage_account_id   = azurerm_storage_account.flowlogs[0].id
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
