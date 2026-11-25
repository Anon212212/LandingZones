output "instances" {
  description = "Per firewall: name, VM id, zone and every interface (NIC id + private IP) by role."
  value = [
    for k, inst in local.instances : {
      name  = inst.name
      vm_id = azurerm_linux_virtual_machine.this[k].id
      zone  = inst.zone
      interfaces = tomap({
        for role in local.nic_roles : role => {
          nic_id     = module.nic["${k}-${role}"].id
          nic_name   = module.nic["${k}-${role}"].name
          private_ip = module.nic["${k}-${role}"].private_ip
        }
      })
    }
  ]
}

output "vm_ids" {
  value = [for k in sort(keys(local.instances)) : azurerm_linux_virtual_machine.this[k].id]
}

output "nic_order" {
  description = "NIC roles in attachment order (first = primary NIC)."
  value       = local.nic_roles
}

output "interface_names" {
  description = "How each NIC role appears inside the firewall OS."
  value       = tomap({ for role in local.nic_roles : role => local.interface_names[role] })
}

output "nic_settings" {
  description = "IP forwarding / accelerated networking per NIC role (for verification)."
  value = tomap({
    for role in local.nic_roles : role => {
      ip_forwarding_enabled          = module.nic["0-${role}"].ip_forwarding_enabled
      accelerated_networking_enabled = module.nic["0-${role}"].accelerated_networking_enabled
    }
  })
}

output "marketplace" {
  value = { publisher = local.publisher, offer = local.offer, sku = local.sku, license_type = var.license_type }
}

output "health_probe_port" {
  description = "Port the firewall answers load balancer probes on."
  value       = local.health_probe_port
}

output "admin_username" {
  value = var.admin_username
}

output "management_ips" {
  description = "Where to reach each firewall's admin UI."
  value       = [for k in sort(keys(local.instances)) : module.nic["${k}-${local.management_role}"].private_ip]
}
