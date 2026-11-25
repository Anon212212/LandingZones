output "next_hop_ip" {
  description = "Point spoke UDRs (0.0.0.0/0) here – or associate trust_route_table_id."
  value       = module.firewall.next_hop_ip
}

output "trust_route_table_id" {
  value = module.firewall.trust_route_table_id
}

output "management_ips" {
  value = module.firewall.management_ips
}

output "public_ip_ids" {
  value = module.firewall.public_ip_ids
}

output "firewalls" {
  value = module.firewall.firewalls
}

output "marketplace" {
  value = module.firewall.marketplace
}
