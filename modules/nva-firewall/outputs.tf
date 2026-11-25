output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vnet_id" {
  value = module.network.vnet_id
}

output "subnet_ids" {
  value = module.network.subnet_ids
}

output "trust_route_table_id" {
  description = "Associate with protected subnets in other VNets/subscriptions (0.0.0.0/0 → firewall)."
  value       = module.network.trust_route_table_id
}

output "next_hop_ip" {
  description = "Firewall next hop for spoke UDRs."
  value       = module.network.next_hop_ip
}

output "public_ip_ids" {
  value = module.network.public_ip_ids
}

output "firewalls" {
  description = "Per firewall: name, VM id, zone and interfaces by role."
  value = (
    var.vendor == "fortigate" ? module.fortigate[0].instances : var.vendor == "paloalto" ? module.paloalto[0].instances : var.vendor == "sonicwall" ? module.sonicwall[0].instances : module.pfsense[0].instances
  )
}

output "nic_order" {
  value = (
    var.vendor == "fortigate" ? module.fortigate[0].nic_order : var.vendor == "paloalto" ? module.paloalto[0].nic_order : var.vendor == "sonicwall" ? module.sonicwall[0].nic_order : module.pfsense[0].nic_order
  )
}

output "interface_names" {
  value = (
    var.vendor == "fortigate" ? module.fortigate[0].interface_names : var.vendor == "paloalto" ? module.paloalto[0].interface_names : var.vendor == "sonicwall" ? module.sonicwall[0].interface_names : module.pfsense[0].interface_names
  )
}

output "nic_settings" {
  value = (
    var.vendor == "fortigate" ? module.fortigate[0].nic_settings : var.vendor == "paloalto" ? module.paloalto[0].nic_settings : var.vendor == "sonicwall" ? module.sonicwall[0].nic_settings : module.pfsense[0].nic_settings
  )
}

output "management_ips" {
  value = (
    var.vendor == "fortigate" ? module.fortigate[0].management_ips : var.vendor == "paloalto" ? module.paloalto[0].management_ips : var.vendor == "sonicwall" ? module.sonicwall[0].management_ips : module.pfsense[0].management_ips
  )
}

output "marketplace" {
  value = (
    var.vendor == "fortigate" ? module.fortigate[0].marketplace : var.vendor == "paloalto" ? module.paloalto[0].marketplace : var.vendor == "sonicwall" ? module.sonicwall[0].marketplace : module.pfsense[0].marketplace
  )
}

output "admin_username" {
  value = (
    var.vendor == "fortigate" ? module.fortigate[0].admin_username : var.vendor == "paloalto" ? module.paloalto[0].admin_username : var.vendor == "sonicwall" ? module.sonicwall[0].admin_username : module.pfsense[0].admin_username
  )
}

output "load_balancers" {
  value = module.network.load_balancers
}

output "cluster" {
  description = "active-standby floating addresses and failover identity."
  value       = module.network.cluster
}
