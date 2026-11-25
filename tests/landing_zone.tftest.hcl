# Offline guardrail tests: `terraform test` (no Azure credentials needed).
# Each run plans against a mocked azurerm provider and asserts that the
# Well-Architected controls are present.

mock_provider "azurerm" {
  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_data "azurerm_location" {
    defaults = {
      display_name = "North Europe"
    }
  }
}

mock_provider "azurerm" {
  alias = "identity"

  mock_data "azurerm_subscription" {
    defaults = {
      id              = "/subscriptions/11111111-1111-1111-1111-111111111111"
      subscription_id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      object_id       = "33333333-3333-3333-3333-333333333333"
      subscription_id = "11111111-1111-1111-1111-111111111111"
    }
  }
}

mock_provider "azurerm" {
  alias = "shared"
}

mock_provider "azurerm" {
  alias = "prod"
}

variables {
  subscription_id                 = "00000000-0000-0000-0000-000000000000"
  identity_subscription_id        = "11111111-1111-1111-1111-111111111111"
  shared_services_subscription_id = "44444444-4444-4444-4444-444444444444"
  production_subscription_id      = "55555555-5555-5555-5555-555555555555"
  org_prefix                      = "contoso"
  owner                           = "platform-team"
  cost_center                     = "cc-1234"
  nva_admin_ssh_public_key        = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFeCVmPtwa8s2OJxK8oxA3Mnzmw+eIcgY0VvmSuMVUM5 test-only" # random test-only key
  alert_email_addresses           = ["ops@example.com"]
  monthly_budget_amount           = 1000
}

run "addressing_is_derived_and_avoids_reserved_ips" {
  command = plan

  assert {
    condition     = azurerm_lb.nva_internal.frontend_ip_configuration[0].private_ip_address == "10.145.0.36"
    error_message = "ILB frontend must be the first assignable IP of the internal subnet."
  }

  assert {
    condition     = azurerm_network_interface.nva_internal[0].ip_configuration[0].private_ip_address == "10.145.0.37" && azurerm_network_interface.nva_internal[1].ip_configuration[0].private_ip_address == "10.145.0.38"
    error_message = "NVA internal NIC IPs are wrong."
  }

  assert {
    condition     = alltrue([for m in local.spoke_modules : m.next_hop_ip == "10.145.0.36"])
    error_message = "Every spoke must route 0.0.0.0/0 to the ILB frontend."
  }
}

run "reliability_controls" {
  command = plan

  assert {
    condition     = length(distinct(azurerm_linux_virtual_machine.nva[*].zone)) == 2
    error_message = "NVAs must be spread across distinct zones."
  }

  assert {
    condition     = length(azurerm_lb.nva_internal.frontend_ip_configuration[0].zones) == 3
    error_message = "ILB frontend must be zone-redundant."
  }

  assert {
    condition     = length(azurerm_bastion_host.bastion.zones) == 3 && length(azurerm_public_ip.bastion.zones) == 3
    error_message = "Bastion and its public IP must be zone-redundant."
  }

  assert {
    condition     = alltrue([for vm in azurerm_linux_virtual_machine.nva : vm.patch_mode == "AutomaticByPlatform"])
    error_message = "NVAs must use platform-orchestrated patching."
  }

  assert {
    condition     = length(azurerm_management_lock.hub_vnet) == 1 && length(azurerm_management_lock.law) == 1
    error_message = "Delete locks must be on by default."
  }

  assert {
    condition     = azurerm_storage_account.flowlogs[0].account_replication_type == "ZRS"
    error_message = "Flow-log storage must be zone-redundant."
  }
}

run "security_controls" {
  command = plan

  assert {
    condition     = alltrue([for s in concat([azurerm_subnet.hub_nva_external, azurerm_subnet.hub_nva_internal, azurerm_subnet.hub_mgmt], []) : s.default_outbound_access_enabled == false]) && alltrue([for m in local.spoke_modules : m.default_outbound_access_enabled == false])
    error_message = "All workload subnets must be private (no default outbound access)."
  }

  assert {
    condition     = length(local.spoke_modules) == length(var.spokes) && alltrue([for m in local.spoke_modules : contains(m.nsg_rule_names, "Deny-All-Inbound")])
    error_message = "Every workload spoke subnet needs an NSG (identity has its own)."
  }

  assert {
    condition     = alltrue([for vm in azurerm_linux_virtual_machine.nva : vm.secure_boot_enabled && vm.vtpm_enabled && vm.disable_password_authentication])
    error_message = "NVAs must use Trusted Launch and SSH keys only."
  }

  assert {
    condition     = !contains(one([for r in azurerm_network_security_group.nva.security_rule : r if r.name == "Allow-SSH-Management"]).source_address_prefixes, "0.0.0.0/0")
    error_message = "NVA SSH must not be open to the Internet."
  }

  assert {
    condition     = azurerm_log_analytics_workspace.law.local_authentication_enabled == false
    error_message = "Log Analytics must be Entra ID-only."
  }

  assert {
    condition     = azurerm_storage_account.flowlogs[0].min_tls_version == "TLS1_2" && azurerm_storage_account.flowlogs[0].allow_nested_items_to_be_public == false
    error_message = "Flow-log storage must enforce TLS 1.2 and block public blobs."
  }

  assert {
    condition     = azurerm_bastion_host.bastion.shareable_link_enabled == false
    error_message = "Bastion shareable links must be off."
  }
}

run "operational_excellence_controls" {
  command = plan

  assert {
    condition     = length(azurerm_network_watcher_flow_log.vnet) == 1 && alltrue([for m in local.spoke_modules : m.flow_log_enabled]) && alltrue([for m in module.identity : length(m.dc_ips) > 0])
    error_message = "The hub and every workload spoke need VNet flow logs."
  }

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.platform) >= 9
    error_message = "Diagnostic settings are missing for platform resources (spokes add theirs in modules/spoke)."
  }

  assert {
    condition     = length(azurerm_monitor_action_group.platform) == 1
    error_message = "Action group should exist when alert emails are provided."
  }

  assert {
    condition     = length(azurerm_monitor_data_collection_rule_association.nva) == 2
    error_message = "Each NVA must be associated with the DCR."
  }
}

run "cost_controls" {
  command = plan

  assert {
    condition     = alltrue([for k in ["environment", "owner", "cost-center"] : contains(keys(azurerm_resource_group.connectivity.tags), k)])
    error_message = "Mandatory cost-allocation tags are missing."
  }

  assert {
    condition     = length(azurerm_consumption_budget_subscription.landing_zone) == 1
    error_message = "Budget should be created when an amount and recipients are set."
  }
}

run "caf_naming" {
  command = plan

  assert {
    condition     = azurerm_virtual_network.hub.name == "vnet-contoso-hub-prod-neu"
    error_message = "Hub VNet name does not follow the CAF convention."
  }

  assert {
    condition     = length(local.names.flowlog_storage) <= 24 && can(regex("^[a-z0-9]+$", local.names.flowlog_storage))
    error_message = "Storage account name is invalid."
  }
}

run "rejects_bad_prefix" {
  command = plan

  variables {
    org_prefix = "Bad_Prefix"
  }

  expect_failures = [var.org_prefix]
}

run "rejects_single_zone_nva" {
  command = plan

  variables {
    nva_zones = ["1"]
  }

  expect_failures = [var.nva_zones]
}

run "identity_is_tier0_region_and_zone_redundant" {
  command = plan

  assert {
    condition     = length(module.identity) == 2 && length(distinct([for r in values(var.identity_regions) : r.location])) == 2
    error_message = "Identity must be deployed to two regions."
  }

  assert {
    condition     = alltrue([for k, m in module.identity : length(distinct([for dc in m.domain_controllers : dc.zone])) >= 2])
    error_message = "Each identity region needs DCs in at least two zones."
  }

  assert {
    condition     = output.identity_dc_ips == ["10.145.4.4", "10.145.4.5", "10.146.4.4", "10.146.4.5"]
    error_message = "DC static IPs are wrong."
  }

  assert {
    condition     = length(azurerm_virtual_network_peering.hub_to_identity) == 2 && length(azurerm_virtual_network_peering.identity_mesh) == 2
    error_message = "Each identity VNet must peer with the hub and with every other identity VNet."
  }

  assert {
    condition     = azurerm_key_vault.identity.purge_protection_enabled && azurerm_key_vault.identity.rbac_authorization_enabled
    error_message = "Tier-0 Key Vault needs purge protection and RBAC."
  }

  assert {
    condition     = azurerm_log_analytics_workspace.identity.retention_in_days >= 365 && azurerm_log_analytics_workspace.identity.local_authentication_enabled == false
    error_message = "Tier-0 workspace needs >= 365 days retention and Entra-only auth."
  }

  assert {
    condition     = contains(local.spoke_address_spaces, "10.146.4.0/24")
    error_message = "NVAs must route identity prefixes back via the internal NIC."
  }
}

run "rejects_identity_in_connectivity_subscription" {
  command = plan

  variables {
    identity_subscription_id = "00000000-0000-0000-0000-000000000000"
  }

  expect_failures = [var.identity_subscription_id]
}

run "rejects_single_region_identity" {
  command = plan

  variables {
    identity_regions = {
      primary = { location = "northeurope", address_space = "10.145.4.0/24" }
    }
  }

  expect_failures = [var.identity_regions]
}

run "custom_spokes_and_rules" {
  command = plan

  variables {
    spokes = {
      web  = { address_space = "10.145.1.0/24", nsg_rules = [{ name = "Allow-HTTPS-From-Hub", priority = 300, source_address_prefixes = ["10.145.0.0/24"], destination_port_ranges = ["443"] }] }
      data = { address_space = "10.145.2.0/24" }
    }
  }

  assert {
    condition     = length(local.spoke_modules) == 2 && module.spokes_connectivity["data"].subnet_name == "snet-data"
    error_message = "Spokes must follow var.spokes (default subnet name snet-<key>)."
  }

  assert {
    condition     = contains(module.spokes_connectivity["web"].nsg_rule_names, "Allow-HTTPS-From-Hub")
    error_message = "Custom NSG rules must be added to the spoke NSG."
  }
}

run "rejects_internet_inbound_spoke_rule" {
  command = plan

  variables {
    spokes = {
      web = { address_space = "10.145.1.0/24", nsg_rules = [{ name = "Bad", priority = 300, source_address_prefixes = ["0.0.0.0/0"], destination_port_ranges = ["443"] }] }
    }
  }

  expect_failures = [var.spokes]
}

run "spokes_land_in_their_own_subscriptions" {
  command = plan

  assert {
    condition     = keys(module.spokes_shared) == ["shared"] && keys(module.spokes_prod) == ["prod"] && keys(module.spokes_connectivity) == ["avd"]
    error_message = "Shared services and production spokes must be deployed to their own subscriptions."
  }

  assert {
    condition     = length(azurerm_virtual_network_peering.hub_to_spoke) == 3
    error_message = "The hub must peer with every spoke, whichever subscription it is in."
  }
}

run "rejects_spoke_in_unset_subscription" {
  command = plan

  variables {
    production_subscription_id = null
  }

  expect_failures = [var.production_subscription_id]
}

run "rejects_landing_zone_reusing_identity_subscription" {
  command = plan

  variables {
    shared_services_subscription_id = "11111111-1111-1111-1111-111111111111"
  }

  expect_failures = [var.shared_services_subscription_id]
}
