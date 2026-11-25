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

variables {
  org_prefix               = "contoso"
  owner                    = "platform-team"
  cost_center              = "cc-1234"
  nva_admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFeCVmPtwa8s2OJxK8oxA3Mnzmw+eIcgY0VvmSuMVUM5 test-only" # random test-only key
  alert_email_addresses    = ["ops@example.com"]
  monthly_budget_amount    = 1000
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
    condition     = alltrue([for r in azurerm_route_table.spoke : one(r.route).next_hop_in_ip_address == "10.145.0.36"])
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
    condition     = alltrue([for s in concat([azurerm_subnet.hub_nva_external, azurerm_subnet.hub_nva_internal, azurerm_subnet.hub_mgmt], values(azurerm_subnet.spoke)) : s.default_outbound_access_enabled == false])
    error_message = "All workload subnets must be private (no default outbound access)."
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.spoke) == 3
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
    condition     = length(azurerm_network_watcher_flow_log.vnet) == 5
    error_message = "Hub and all four spokes need VNet flow logs."
  }

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.platform) >= 15
    error_message = "Diagnostic settings are missing for platform resources."
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
