# Client A – SonicWall NSv, single instance
#
# Single NSv: X0 trust (management) + X1 untrust with a public IP. Spokes send 0.0.0.0/0 to the NSv trust IP.

module "firewall" {
  source = "../../modules/nva-firewall"

  client_name   = "clienta"
  environment   = "prod"
  location      = "westeurope"
  address_space = "10.110.0.0/24"

  vendor         = "sonicwall"
  ha_mode        = "single"
  vm_size        = "Standard_D4s_v5"
  admin_password = var.admin_password

  license_type             = "payg"
  accept_marketplace_terms = true

  # Branch-office style: one NSv, managed on X0 from the client's VPN range.
  mgmt_source_cidrs = ["10.200.0.0/16"]
  inbound_rules     = [{ name = "ssl-vpn", protocol = "Tcp", port = 4433 }]

  tags = {
    owner       = "clienta-it"
    cost-center = "clienta-network"
  }
}
