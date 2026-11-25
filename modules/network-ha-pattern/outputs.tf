output "vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "vnet_name" {
  value = azurerm_virtual_network.hub.name
}

output "subnet_ids" {
  description = "untrust, trust and (when created) mgmt, hasync."
  value = merge(
    { untrust = azurerm_subnet.untrust.id, trust = azurerm_subnet.trust.id },
    var.enable_mgmt_subnet ? { mgmt = azurerm_subnet.mgmt[0].id } : {},
    local.hasync ? { hasync = azurerm_subnet.hasync[0].id } : {},
  )
}

output "subnet_prefixes" {
  value = local.subnets
}

output "gateways" {
  description = "Azure subnet gateway (.1) per subnet – the next hop the firewalls use on each interface."
  value       = local.gateways
}

output "instances" {
  description = "Per-firewall placement and addressing, consumed by the vendor modules."
  value = [
    for i in local.instances : merge(i, {
      mgmt_public_ip_id    = var.enable_mgmt_subnet && var.management_egress == "public_ip" ? azurerm_public_ip.mgmt[i.index].id : null
      untrust_public_ip_id = var.ha_mode == "single" ? azurerm_public_ip.single[0].id : null
    })
  ]
}

output "cluster" {
  description = "active-standby floating addresses (start on node 0; moved by the firewalls on failover)."
  value = var.ha_mode == "active-standby" ? {
    trust_vip                     = local.vip.trust
    untrust_vip                   = local.vip.untrust
    public_ip_id                  = azurerm_public_ip.cluster[0].id
    public_ip_name                = azurerm_public_ip.cluster[0].name
    vip_ip_config_name            = "ipconfig-vip"
    route_table_name              = azurerm_route_table.trust.name
    managed_identity_id           = azurerm_user_assigned_identity.failover[0].id
    managed_identity_name         = azurerm_user_assigned_identity.failover[0].name
    managed_identity_principal_id = azurerm_user_assigned_identity.failover[0].principal_id
    managed_identity_client_id    = azurerm_user_assigned_identity.failover[0].client_id
  } : null
}

output "load_balancers" {
  description = "active-active load balancer details."
  value = var.ha_mode == "active-active" ? {
    internal_frontend_ip     = local.vip.trust
    internal_backend_pool_id = azurerm_lb_backend_address_pool.internal[0].id
    external_backend_pool_id = azurerm_lb_backend_address_pool.external[0].id
    external_public_ip_id    = azurerm_public_ip.elb[0].id
  } : null
}

output "trust_route_table_id" {
  description = "Associate this with every protected subnet (0.0.0.0/0 → firewall)."
  value       = azurerm_route_table.trust.id
}

output "trust_route_table_name" {
  value = azurerm_route_table.trust.name
}

output "next_hop_ip" {
  description = "Where protected subnets send traffic: firewall trust IP (single), trust VIP (active-standby) or internal LB frontend (active-active)."
  value       = local.next_hop_ip
}

output "availability_set_id" {
  value = length(azurerm_availability_set.fw) > 0 ? azurerm_availability_set.fw[0].id : null
}

output "public_ip_ids" {
  description = "Public IPs created for the data plane."
  value = compact([
    try(azurerm_public_ip.single[0].id, ""),
    try(azurerm_public_ip.cluster[0].id, ""),
    try(azurerm_public_ip.elb[0].id, ""),
  ])
}

output "ha_mode" {
  value = var.ha_mode
}

output "lb_join" {
  description = "Which NIC roles join a load balancer backend pool (plan-time known)."
  value       = { trust = var.ha_mode == "active-active", untrust = var.ha_mode == "active-active" }
}
