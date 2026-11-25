locals {
  #############################################
  # Naming – Cloud Adoption Framework convention
  #   <resource-abbr>-<org>-<component>-<env>-<region>
  #############################################
  region_short_map = {
    northeurope        = "neu"
    westeurope         = "weu"
    uksouth            = "uks"
    ukwest             = "ukw"
    swedencentral      = "sdc"
    germanywestcentral = "gwc"
    francecentral      = "frc"
    eastus             = "eus"
    eastus2            = "eus2"
    westus2            = "wus2"
    westus3            = "wus3"
    centralus          = "cus"
    australiaeast      = "aue"
    southeastasia      = "sea"
  }
  region_short = lookup(local.region_short_map, var.location, var.location)

  suffix = "${var.environment}-${local.region_short}"

  names = {
    rg_connectivity = "rg-${var.org_prefix}-connectivity-${local.suffix}"
    rg_management   = "rg-${var.org_prefix}-management-${local.suffix}"
    law             = "log-${var.org_prefix}-${local.suffix}"
    hub_vnet        = "vnet-${var.org_prefix}-hub-${local.suffix}"
    ilb             = "lbi-${var.org_prefix}-nva-${local.suffix}"
    nat             = "ng-${var.org_prefix}-${local.suffix}"
    nat_pip         = "pip-${var.org_prefix}-ng-${local.suffix}"
    bastion         = "bas-${var.org_prefix}-${local.suffix}"
    bastion_pip     = "pip-${var.org_prefix}-bas-${local.suffix}"
    action_group    = "ag-${var.org_prefix}-platform-${local.suffix}"
    dcr_nva         = "dcr-${var.org_prefix}-nva-${local.suffix}"
    # Storage names: 3-24 lowercase alphanumerics, globally unique.
    flowlog_storage = substr("stfl${replace(var.org_prefix, "-", "")}${substr(md5(data.azurerm_subscription.current.id), 0, 5)}", 0, 24)
  }

  nva_names = [for i in range(local.nva_count) : "vm-${var.org_prefix}-nva${i + 1}-${local.suffix}"]

  network_watcher_name = coalesce(var.network_watcher_name, "NetworkWatcher_${var.location}")

  #############################################
  # Tagging – mandatory tags for cost allocation and ownership
  #############################################
  tags = merge(var.tags, {
    environment = var.environment
    owner       = var.owner
    cost-center = var.cost_center
    workload    = "landing-zone"
    managed-by  = "terraform"
  })

  zones = length(var.zones) > 0 ? var.zones : null

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
  # Spokes – VNet, subnet, NSG, peering pair and route table are all
  # generated from this map.
  #############################################
  spokes = {
    for k, v in var.spokes : k => {
      address_space = v.address_space
      subnet_name   = coalesce(v.subnet_name, "snet-${k}")
      subnet_prefix = v.address_space
      nsg_rules     = v.nsg_rules
    }
  }

  # Everything the NVAs must route back through their internal NIC.
  spoke_address_spaces = concat(
    [for s in local.spokes : s.address_space],
    [for r in values(var.identity_regions) : r.address_space],
  )

  # Every VNet (hub + spokes) – used for flow logs and diagnostics.
  all_vnet_ids = merge(
    { hub = azurerm_virtual_network.hub.id },
    { for k, v in azurerm_virtual_network.spoke : k => v.id },
  )
}
