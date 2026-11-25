# Unit tests for modules/identity-region against a mocked provider.

mock_provider "azurerm" {}

variables {
  org_prefix                       = "contoso"
  environment                      = "prod"
  location                         = "northeurope"
  region_short                     = "neu"
  subscription_id                  = "11111111-1111-1111-1111-111111111111"
  tags                             = { tier = "0" }
  address_space                    = "10.145.4.0/24"
  hub_vnet_id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet-hub"
  next_hop_ip                      = "10.145.0.36"
  ad_client_cidrs                  = ["10.145.0.0/16"]
  admin_source_cidrs               = ["10.145.0.96/27"]
  dc_zones                         = ["1", "2", "3"]
  dc_size                          = "Standard_D2s_v5"
  dc_admin_username                = "dcadmin"
  dc_image_sku                     = "2025-datacenter-azure-edition"
  dc_data_disk_size_gb             = 64
  dc_hybrid_benefit                = false
  encryption_at_host               = false
  key_vault_id                     = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv"
  data_collection_rule_id          = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/dcr"
  backup_storage_mode              = "ZoneRedundant"
  log_analytics_workspace_id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
  log_analytics_workspace_guid     = "44444444-4444-4444-4444-444444444444"
  log_analytics_workspace_location = "northeurope"
  enable_flow_logs                 = true
  flow_log_retention_days          = 30
  network_watcher_resource_group   = "NetworkWatcherRG"
  enable_resource_locks            = true
}

run "dcs_follow_ad_on_azure_guidance" {
  command = plan

  module {
    source = "./modules/identity-region"
  }

  assert {
    condition     = [for vm in azurerm_windows_virtual_machine.dc : vm.zone] == ["1", "2", "3"]
    error_message = "One DC per zone."
  }

  assert {
    condition     = alltrue([for n in azurerm_network_interface.dc : n.ip_configuration[0].private_ip_address_allocation == "Static"])
    error_message = "DCs need static IPs."
  }

  assert {
    condition     = alltrue([for a in azurerm_virtual_machine_data_disk_attachment.ntds : a.caching == "None"])
    error_message = "The NTDS data disk must have host caching disabled."
  }

  assert {
    condition     = alltrue([for vm in azurerm_windows_virtual_machine.dc : vm.secure_boot_enabled && vm.vtpm_enabled && vm.patch_mode == "AutomaticByPlatform"])
    error_message = "DCs need Trusted Launch and platform patching."
  }

  assert {
    condition     = alltrue([for c in local.dc_computer_names : length(c) <= 15])
    error_message = "Computer names exceed the NetBIOS limit."
  }

  assert {
    condition     = length(azurerm_management_lock.dc) == 3
    error_message = "Every DC must be delete-locked."
  }
}

run "backup_is_zone_redundant_and_within_tombstone" {
  command = plan

  module {
    source = "./modules/identity-region"
  }

  assert {
    condition     = azurerm_recovery_services_vault.identity.storage_mode_type == "ZoneRedundant" && azurerm_recovery_services_vault.identity.immutability != "Disabled"
    error_message = "Vault must be zone-redundant with immutability on."
  }

  assert {
    condition     = azurerm_backup_policy_vm.dc.policy_type == "V2"
    error_message = "Trusted Launch VMs require an Enhanced (V2) backup policy."
  }

  assert {
    condition     = azurerm_backup_policy_vm.dc.retention_monthly[0].count * 31 <= 180
    error_message = "Retention must stay within the AD tombstone lifetime (180 days)."
  }

  assert {
    condition     = length(azurerm_backup_protected_vm.dc) == 3
    error_message = "Every DC must be backed up."
  }
}

run "no_rdp_rule_without_admin_sources" {
  command = plan

  module {
    source = "./modules/identity-region"
  }

  variables {
    admin_source_cidrs = []
  }

  assert {
    condition     = length([for r in azurerm_network_security_group.dc.security_rule : r if r.name == "Allow-RDP-Admin"]) == 0
    error_message = "RDP must not be opened when no admin sources are given."
  }
}
