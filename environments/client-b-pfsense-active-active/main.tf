# Client B – pfSense Plus, active-active behind Azure Load Balancers
#
# Two standalone pfSense instances (CARP isn't possible on Azure). Configure outbound NAT on WAN on both so return traffic stays on the same firewall; the external LB outbound rule provides egress SNAT.

module "firewall" {
  source = "../../modules/nva-firewall"

  client_name   = "clientb"
  environment   = "prod"
  location      = "northeurope"
  address_space = "10.120.0.0/24"

  vendor         = "pfsense"
  ha_mode        = "active-active"
  vm_size        = "Standard_D4s_v5"
  admin_password = var.admin_password

  instance_count           = 2
  zones                    = ["1", "2", "3"]
  accept_marketplace_terms = true

  # Published through the external LB (floating IP); pfSense port-forwards it.
  inbound_rules = [
    { name = "https", protocol = "Tcp", port = 443 },
    { name = "wireguard", protocol = "Udp", port = 51820 },
  ]

  tags = {
    owner       = "clientb-it"
    cost-center = "clientb-network"
  }
}
