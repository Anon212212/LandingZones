#############################################
# Third-party firewall NVAs in the hub (nva_vendor != "linux").
#
# Reuses the hub plumbing (subnets, NSGs, NAT Gateway, route tables,
# internal LB) and plugs in modules/vendors/<vendor> through the same
# `network` interface that modules/network-ha-pattern produces.
#
#   active-active   internal LB (HA Ports) → UDR next hop = ILB frontend
#   active-standby  no LB; floating trust VIP (= same address) moved by the
#                   firewalls via the Azure API with a managed identity
#   single          one firewall; UDR next hop = its trust IP
# Egress for every mode leaves through the NAT Gateway on snet-nva-external.
#############################################

data "azurerm_client_config" "current" {}

locals {
  nva_vendor_defaults = {
    fortigate = { license = "byol" }
    paloalto  = { license = "byol" }
    sonicwall = { license = "byol" }
    pfsense   = { license = "payg" }
  }

  nva_kv_name = "${substr("kv${replace(var.org_prefix, "-", "")}nva", 0, 17)}${substr(md5(data.azurerm_subscription.current.id), 0, 7)}"

  # Same shape as modules/network-ha-pattern outputs (consumed by the vendor modules).
  nva_vendor_network = {
    subnet_ids = merge(
      {
        untrust = azurerm_subnet.hub_nva_external.id
        trust   = azurerm_subnet.hub_nva_internal.id
        mgmt    = azurerm_subnet.hub_mgmt.id
      },
      local.nva_hasync ? { hasync = azurerm_subnet.hub_hasync[0].id } : {},
    )
    subnet_prefixes = {
      untrust = local.hub_subnets.nva_external
      trust   = local.hub_subnets.nva_internal
      mgmt    = local.hub_subnets.mgmt
      hasync  = local.hub_subnets.hasync
    }
    gateways = {
      untrust = cidrhost(local.hub_subnets.nva_external, 1)
      trust   = cidrhost(local.hub_subnets.nva_internal, 1)
      mgmt    = cidrhost(local.hub_subnets.mgmt, 1)
      hasync  = cidrhost(local.hub_subnets.hasync, 1)
    }
    instances = [
      for i in range(local.nva_count) : {
        index                = i
        name                 = local.nva_names[i]
        zone                 = var.nva_zones[i % length(var.nva_zones)]
        untrust_ip           = cidrhost(local.hub_subnets.nva_external, 5 + i)
        trust_ip             = cidrhost(local.hub_subnets.nva_internal, 5 + i)
        mgmt_ip              = cidrhost(local.hub_subnets.mgmt, 20 + i) # .4-.19 left for management VMs
        hasync_ip            = cidrhost(local.hub_subnets.hasync, 4 + i)
        priority             = 255 - i * 55
        mgmt_public_ip_id    = null
        untrust_public_ip_id = null # egress via the NAT Gateway
      }
    ]
    cluster = local.nva_ha_mode == "active-standby" && !local.nva_linux ? {
      trust_vip                     = local.nva_ilb_frontend_ip
      untrust_vip                   = cidrhost(local.hub_subnets.nva_external, 4)
      public_ip_id                  = null
      public_ip_name                = ""
      vip_ip_config_name            = "ipconfig-vip"
      route_table_name              = ""
      managed_identity_id           = azurerm_user_assigned_identity.nva_failover[0].id
      managed_identity_name         = azurerm_user_assigned_identity.nva_failover[0].name
      managed_identity_principal_id = azurerm_user_assigned_identity.nva_failover[0].principal_id
      managed_identity_client_id    = azurerm_user_assigned_identity.nva_failover[0].client_id
    } : null
    load_balancers = local.nva_ha_mode == "active-active" && !local.nva_linux ? {
      internal_frontend_ip     = local.nva_ilb_frontend_ip
      internal_backend_pool_id = azurerm_lb_backend_address_pool.nva[0].id
      external_backend_pool_id = null
      external_public_ip_id    = null
    } : null
    # Only the trust NICs join a pool: the hub has no external LB (egress uses the NAT Gateway).
    lb_join                = { trust = local.nva_ha_mode == "active-active", untrust = false }
    availability_set_id    = null
    trust_route_table_name = ""
  }

  nva_vendor_common = {
    license_type = coalesce(var.nva_license_type, try(local.nva_vendor_defaults[var.nva_vendor].license, "byol"))
  }

  # Firewall VM IDs, whichever appliance is deployed (alerts, outputs).
  nva_vm_ids = (
    local.nva_linux ? azurerm_linux_virtual_machine.nva[*].id :
    var.nva_vendor == "fortigate" ? module.nva_fortigate[0].vm_ids :
    var.nva_vendor == "paloalto" ? module.nva_paloalto[0].vm_ids :
    var.nva_vendor == "sonicwall" ? module.nva_sonicwall[0].vm_ids : module.nva_pfsense[0].vm_ids
  )
}

#############################################
# HA sync subnet (active-standby)
#############################################

resource "azurerm_subnet" "hub_hasync" {
  count = local.nva_hasync ? 1 : 0

  name                            = "snet-nva-hasync"
  resource_group_name             = azurerm_resource_group.connectivity.name
  virtual_network_name            = azurerm_virtual_network.hub.name
  address_prefixes                = [local.hub_subnets.hasync]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet_network_security_group_association" "hub_hasync" {
  count = local.nva_hasync ? 1 : 0

  subnet_id                 = azurerm_subnet.hub_hasync[0].id
  network_security_group_id = azurerm_network_security_group.nva.id
}

#############################################
# Admin password – generated and kept in a connectivity Key Vault
#############################################

resource "random_password" "nva_admin" {
  count = local.nva_linux ? 0 : 1

  length           = 32
  special          = true
  override_special = "!#%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_key_vault" "nva" {
  count = local.nva_linux ? 0 : 1

  name                          = local.nva_kv_name
  location                      = var.location
  resource_group_name           = azurerm_resource_group.management.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_role_assignment" "nva_kv_deployer" {
  count = local.nva_linux ? 0 : 1

  scope                = azurerm_key_vault.nva[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "nva_admin" {
  count = local.nva_linux ? 0 : 1

  name         = "nva-${var.nva_vendor}-admin"
  key_vault_id = azurerm_key_vault.nva[0].id
  value        = coalesce(var.nva_admin_password, random_password.nva_admin[0].result)
  content_type = "username=${var.nva_admin_username}"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.nva_kv_deployer]
}

#############################################
# active-standby: failover identity + least-privilege role (connectivity RG)
#############################################

resource "azurerm_user_assigned_identity" "nva_failover" {
  count = local.nva_hasync ? 1 : 0

  name                = "id-${var.org_prefix}-nva-failover-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  tags                = local.tags
}

resource "azurerm_role_definition" "nva_failover" {
  count = local.nva_hasync ? 1 : 0

  name        = "${var.org_prefix}-${var.environment} NVA HA failover"
  scope       = azurerm_resource_group.connectivity.id
  description = "Lets the hub firewall pair move the floating trust VIP between NICs and update UDRs on failover."

  permissions {
    actions = [
      "Microsoft.Network/routeTables/routes/write",
      "Microsoft.Network/networkInterfaces/write",
      "Microsoft.Network/publicIPAddresses/write",
      "Microsoft.Network/publicIPAddresses/join/action",
      "Microsoft.Network/virtualNetworks/subnets/join/action",
      "Microsoft.Network/networkSecurityGroups/join/action",
      "Microsoft.Network/routeTables/read",
      "Microsoft.Network/routeTables/routes/read",
      "Microsoft.Network/networkInterfaces/read",
      "Microsoft.Network/publicIPAddresses/read",
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/subnets/read",
      "Microsoft.Compute/virtualMachines/read",
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.connectivity.id]
}

resource "azurerm_role_assignment" "nva_failover" {
  count = local.nva_hasync ? 1 : 0

  scope              = azurerm_resource_group.connectivity.id
  role_definition_id = azurerm_role_definition.nva_failover[0].role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.nva_failover[0].principal_id
  principal_type     = "ServicePrincipal"
}

#############################################
# Vendor modules (exactly one is created)
#############################################

module "nva_fortigate" {
  source = "./modules/vendors/fortigate"
  count  = var.nva_vendor == "fortigate" ? 1 : 0

  name_prefix              = "${var.org_prefix}-nva-${local.suffix}"
  location                 = var.location
  resource_group_name      = azurerm_resource_group.connectivity.name
  tags                     = local.tags
  ha_mode                  = local.nva_ha_mode
  network                  = local.nva_vendor_network
  vm_size                  = var.nva_size
  admin_username           = var.nva_admin_username
  admin_password           = azurerm_key_vault_secret.nva_admin[0].value
  admin_ssh_public_key     = var.nva_admin_ssh_public_key
  license_type             = local.nva_vendor_common.license_type
  accept_marketplace_terms = var.nva_accept_marketplace_terms
  marketplace_offer        = var.nva_marketplace_offer
  marketplace_sku          = var.nva_marketplace_sku
  license_tokens           = var.nva_fortigate_license_tokens
  internal_cidrs           = distinct(concat([var.hub_address_space], local.spoke_address_spaces))
}

module "nva_paloalto" {
  source = "./modules/vendors/paloalto"
  count  = var.nva_vendor == "paloalto" ? 1 : 0

  name_prefix               = "${var.org_prefix}-nva-${local.suffix}"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.connectivity.name
  tags                      = local.tags
  ha_mode                   = local.nva_ha_mode
  network                   = local.nva_vendor_network
  vm_size                   = var.nva_size
  admin_username            = var.nva_admin_username
  admin_password            = azurerm_key_vault_secret.nva_admin[0].value
  admin_ssh_public_key      = var.nva_admin_ssh_public_key
  license_type              = local.nva_vendor_common.license_type
  accept_marketplace_terms  = var.nva_accept_marketplace_terms
  marketplace_offer         = var.nva_marketplace_offer
  marketplace_sku           = var.nva_marketplace_sku
  mgmt_interface_swap       = var.nva_paloalto_mgmt_interface_swap
  bootstrap_storage_account = try(var.nva_paloalto_bootstrap.storage_account, null)
  bootstrap_file_share      = try(var.nva_paloalto_bootstrap.file_share, null)
  bootstrap_share_directory = try(var.nva_paloalto_bootstrap.share_directory, null)
  bootstrap_access_key      = var.nva_paloalto_bootstrap_access_key
}

module "nva_sonicwall" {
  source = "./modules/vendors/sonicwall"
  count  = var.nva_vendor == "sonicwall" ? 1 : 0

  name_prefix              = "${var.org_prefix}-nva-${local.suffix}"
  location                 = var.location
  resource_group_name      = azurerm_resource_group.connectivity.name
  tags                     = local.tags
  ha_mode                  = local.nva_ha_mode
  network                  = local.nva_vendor_network
  vm_size                  = var.nva_size
  admin_username           = var.nva_admin_username
  admin_password           = azurerm_key_vault_secret.nva_admin[0].value
  admin_ssh_public_key     = var.nva_admin_ssh_public_key
  license_type             = local.nva_vendor_common.license_type
  accept_marketplace_terms = var.nva_accept_marketplace_terms
  marketplace_offer        = var.nva_marketplace_offer
  marketplace_sku          = var.nva_marketplace_sku
  custom_data              = var.nva_custom_data
}

module "nva_pfsense" {
  source = "./modules/vendors/pfsense"
  count  = var.nva_vendor == "pfsense" ? 1 : 0

  name_prefix              = "${var.org_prefix}-nva-${local.suffix}"
  location                 = var.location
  resource_group_name      = azurerm_resource_group.connectivity.name
  tags                     = local.tags
  ha_mode                  = local.nva_ha_mode
  network                  = local.nva_vendor_network
  vm_size                  = var.nva_size
  admin_username           = var.nva_admin_username
  admin_password           = azurerm_key_vault_secret.nva_admin[0].value
  admin_ssh_public_key     = var.nva_admin_ssh_public_key
  license_type             = local.nva_vendor_common.license_type
  accept_marketplace_terms = var.nva_accept_marketplace_terms
  marketplace_offer        = var.nva_marketplace_offer
  marketplace_sku          = var.nva_marketplace_sku
  custom_data              = var.nva_custom_data
}
