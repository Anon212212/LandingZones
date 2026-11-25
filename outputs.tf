output "resource_group_names" {
  value = {
    connectivity = azurerm_resource_group.connectivity.name
    management   = azurerm_resource_group.management.name
  }
}

output "hub_vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "spoke_vnet_ids" {
  description = "Spoke VNet IDs keyed by spoke name."
  value       = { for k, v in azurerm_virtual_network.spoke : k => v.id }
}

output "spoke_subnet_ids" {
  description = "Workload subnet IDs keyed by spoke name."
  value       = { for k, v in azurerm_subnet.spoke : k => v.id }
}

output "hub_subnet_ids" {
  value = {
    nva_external = azurerm_subnet.hub_nva_external.id
    nva_internal = azurerm_subnet.hub_nva_internal.id
    mgmt         = azurerm_subnet.hub_mgmt.id
    bastion      = azurerm_subnet.hub_bastion.id
  }
}

output "nva_ilb_frontend_ip" {
  description = "Next-hop IP used by every spoke route table."
  value       = local.nva_ilb_frontend_ip
}

output "nva_private_ips" {
  value = [
    for i in range(local.nva_count) : {
      name     = azurerm_linux_virtual_machine.nva[i].name
      zone     = azurerm_linux_virtual_machine.nva[i].zone
      external = local.nva_external_ips[i]
      internal = local.nva_internal_ips[i]
    }
  ]
}

output "nat_gateway_public_ip" {
  description = "Egress IP for Internet-bound traffic (null if NAT Gateway disabled)."
  value       = var.enable_nat_gateway ? azurerm_public_ip.nat[0].ip_address : null
}

output "bastion_name" {
  value = azurerm_bastion_host.bastion.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.law.id
}

output "action_group_id" {
  description = "Platform alert action group (null when no alert_email_addresses)."
  value       = one(local.action_group_ids)
}
