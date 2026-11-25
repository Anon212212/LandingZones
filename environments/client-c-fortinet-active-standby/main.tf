# Client C – FortiGate active-standby with Azure SDN failover
#
# Two FortiGates (zones 1 and 2) in an FGCP A-P cluster over port3. The Azure SDN connector (managed identity) moves the cluster public IP and trust VIP to the new primary; spokes route to the trust VIP.

module "firewall" {
  source = "../../modules/nva-firewall"

  client_name   = "clientc"
  environment   = "prod"
  location      = "northeurope"
  address_space = "10.130.0.0/24"

  vendor         = "fortigate"
  ha_mode        = "active-standby"
  vm_size        = "Standard_D4s_v5"
  admin_password = var.admin_password

  zones                    = ["1", "2"]
  license_type             = "byol"
  accept_marketplace_terms = true

  mgmt_source_cidrs = ["10.200.0.0/16"]
  management_egress = "nat_gateway"
  inbound_rules     = [{ name = "https", protocol = "Tcp", port = 443 }]

  # Spokes / on-prem routed via port2 (trust).
  fortigate_internal_cidrs = ["10.0.0.0/8"]
  fortigate_license_tokens = var.fortigate_license_tokens

  tags = {
    owner       = "clientc-it"
    cost-center = "clientc-network"
  }
}
