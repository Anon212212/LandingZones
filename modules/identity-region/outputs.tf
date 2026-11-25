output "vnet_id" {
  value = azurerm_virtual_network.identity.id
}

output "vnet_name" {
  value = azurerm_virtual_network.identity.name
}

output "resource_group_name" {
  value = azurerm_resource_group.identity.name
}

output "dc_subnet_id" {
  value = azurerm_subnet.dc.id
}

output "domain_controllers" {
  description = "DC name, NetBIOS computer name, zone and static IP."
  value = [
    for i in range(local.dc_count) : {
      name          = azurerm_windows_virtual_machine.dc[i].name
      computer_name = local.dc_computer_names[i]
      zone          = azurerm_windows_virtual_machine.dc[i].zone
      private_ip    = local.dc_ips[i]
      secret_name   = azurerm_key_vault_secret.dc_admin[i].name
    }
  ]
}

output "dc_ips" {
  value = local.dc_ips
}

output "recovery_services_vault_id" {
  value = azurerm_recovery_services_vault.identity.id
}

output "dc_vm_ids" {
  value = azurerm_windows_virtual_machine.dc[*].id
}
