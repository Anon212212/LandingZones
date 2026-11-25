locals {
  tags = merge({ managed-by = "terraform", workload = "landing-zone" }, var.tags)

  #############################################
  # Hub addressing (derived from hub_address_space)
  # Default /24 → four /27s:
  #   .0/27  nva-external   .32/27 nva-internal
  #   .64/27 mgmt           .96/27 AzureBastionSubnet
  #############################################
  hub_subnets = {
    nva_external = cidrsubnet(var.hub_address_space, 3, 0)
    nva_internal = cidrsubnet(var.hub_address_space, 3, 1)
    mgmt         = cidrsubnet(var.hub_address_space, 3, 2)
    bastion      = cidrsubnet(var.hub_address_space, 3, 3)
  }

  # Azure reserves the first four addresses of every subnet (network, gateway,
  # 2x DNS), so host index 4 is the first assignable IP.
  #   ILB frontend        : internal host 4      → 10.145.0.36
  #   NVA-n internal NIC  : internal host 5+n    → 10.145.0.37, .38, ...
  #   NVA-n external NIC  : external host 4+n    → 10.145.0.4,  .5,  ...
  nva_ilb_frontend_ip = cidrhost(local.hub_subnets.nva_internal, 4)
  nva_internal_gw     = cidrhost(local.hub_subnets.nva_internal, 1)
  nva_count           = length(var.nva_zones)
  nva_external_ips    = [for i in range(local.nva_count) : cidrhost(local.hub_subnets.nva_external, 4 + i)]
  nva_internal_ips    = [for i in range(local.nva_count) : cidrhost(local.hub_subnets.nva_internal, 5 + i)]

  #############################################
  # Spokes – everything spoke-shaped (VNet, subnet, peering pair,
  # route table) is generated from this map.
  #############################################
  spokes = {
    shared = {
      vnet_name     = "${var.org_prefix}-shared-vnet"
      address_space = var.spoke_address_space
      subnet_name   = "shared-app-snet"
      subnet_prefix = var.spoke_address_space
    }
    prod = {
      vnet_name     = "${var.org_prefix}-prod-vnet"
      address_space = var.prod_address_space
      subnet_name   = "prod-app-snet"
      subnet_prefix = var.prod_address_space
    }
    avd = {
      vnet_name     = "${var.org_prefix}-avd-vnet"
      address_space = var.avd_address_space
      subnet_name   = "avd-sessionhosts-snet"
      subnet_prefix = var.avd_address_space
    }
    identity = {
      vnet_name     = "${var.org_prefix}-id-vnet"
      address_space = var.id_address_space
      subnet_name   = "dc-snet"
      subnet_prefix = cidrsubnet(var.id_address_space, 3, 0)
    }
  }

  spoke_address_spaces = [for s in local.spokes : s.address_space]
}
