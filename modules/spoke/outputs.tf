output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "subnet_id" {
  value = azurerm_subnet.this.id
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "nsg_id" {
  value = azurerm_network_security_group.this.id
}

# Plan-time facts used by the guardrail tests.
output "next_hop_ip" {
  value = one(azurerm_route_table.this.route).next_hop_in_ip_address
}

output "subnet_name" {
  value = azurerm_subnet.this.name
}

output "default_outbound_access_enabled" {
  value = azurerm_subnet.this.default_outbound_access_enabled
}

output "nsg_rule_names" {
  value = [for r in azurerm_network_security_group.this.security_rule : r.name]
}

output "flow_log_enabled" {
  value = length(azurerm_network_watcher_flow_log.this) == 1
}
