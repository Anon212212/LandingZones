output "id" {
  value = local.nic.id
}

output "name" {
  value = local.nic.name
}

output "private_ip" {
  value = var.private_ip
}

output "ip_forwarding_enabled" {
  value = var.data_plane
}

output "accelerated_networking_enabled" {
  value = var.data_plane
}

output "has_vip" {
  value = var.vip != null
}
