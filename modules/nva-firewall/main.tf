#############################################
# Client firewall hub: Azure plumbing (network-ha-pattern) + one vendor
# module. Clients only call this module (see environments/client-*).
#############################################

locals {
  name_prefix         = "${var.client_name}-fw-${var.environment}"
  resource_group_name = coalesce(var.resource_group_name, "rg-${var.client_name}-fw-${var.environment}")

  vendor_defaults = {
    fortigate = { admin = "fgtadmin", license = "byol", probe = 8008, mgmt_nic = true, hasync = true }
    paloalto  = { admin = "panadmin", license = "byol", probe = 443, mgmt_nic = true, hasync = true }
    sonicwall = { admin = "nsvadmin", license = "byol", probe = 443, mgmt_nic = false, hasync = true }
    pfsense   = { admin = "pfsenseadmin", license = "payg", probe = 443, mgmt_nic = false, hasync = false }
  }
  v = local.vendor_defaults[var.vendor]

  tags = merge(var.tags, {
    client          = var.client_name
    environment     = var.environment
    firewall-vendor = var.vendor
    ha-mode         = var.ha_mode
    managed-by      = "terraform"
  })

  common = {
    name_prefix              = local.name_prefix
    location                 = var.location
    resource_group_name      = azurerm_resource_group.this.name
    tags                     = local.tags
    ha_mode                  = var.ha_mode
    vm_size                  = var.vm_size
    admin_username           = coalesce(var.admin_username, local.v.admin)
    license_type             = coalesce(var.license_type, local.v.license)
    accept_marketplace_terms = var.accept_marketplace_terms
  }
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

module "network" {
  source = "../network-ha-pattern"

  name_prefix         = local.name_prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  resource_group_id   = azurerm_resource_group.this.id
  tags                = local.tags

  ha_mode            = var.ha_mode
  instance_count     = var.instance_count
  address_space      = var.address_space
  zones              = var.zones
  enable_mgmt_subnet = local.v.mgmt_nic
  enable_hasync      = local.v.hasync
  mgmt_source_cidrs  = var.mgmt_source_cidrs
  management_egress  = var.management_egress
  inbound_rules      = var.inbound_rules
  health_probe_port  = local.v.probe
}

module "fortigate" {
  source = "../vendors/fortigate"
  count  = var.vendor == "fortigate" ? 1 : 0

  name_prefix              = local.common.name_prefix
  location                 = local.common.location
  resource_group_name      = local.common.resource_group_name
  tags                     = local.common.tags
  ha_mode                  = local.common.ha_mode
  network                  = module.network
  vm_size                  = local.common.vm_size
  admin_username           = local.common.admin_username
  admin_password           = var.admin_password
  admin_ssh_public_key     = var.admin_ssh_public_key
  license_type             = local.common.license_type
  accept_marketplace_terms = local.common.accept_marketplace_terms
  marketplace_publisher    = var.marketplace_publisher
  marketplace_offer        = var.marketplace_offer
  marketplace_sku          = var.marketplace_sku
  image_version            = var.image_version

  license_tokens = var.fortigate_license_tokens
  license_files  = var.fortigate_license_files
  internal_cidrs = var.fortigate_internal_cidrs
  extra_config   = var.fortigate_extra_config
}

module "paloalto" {
  source = "../vendors/paloalto"
  count  = var.vendor == "paloalto" ? 1 : 0

  name_prefix              = local.common.name_prefix
  location                 = local.common.location
  resource_group_name      = local.common.resource_group_name
  tags                     = local.common.tags
  ha_mode                  = local.common.ha_mode
  network                  = module.network
  vm_size                  = local.common.vm_size
  admin_username           = local.common.admin_username
  admin_password           = var.admin_password
  admin_ssh_public_key     = var.admin_ssh_public_key
  license_type             = local.common.license_type
  accept_marketplace_terms = local.common.accept_marketplace_terms
  marketplace_publisher    = var.marketplace_publisher
  marketplace_offer        = var.marketplace_offer
  marketplace_sku          = var.marketplace_sku
  image_version            = var.image_version

  mgmt_interface_swap       = var.paloalto_mgmt_interface_swap
  bootstrap_storage_account = try(var.paloalto_bootstrap.storage_account, null)
  bootstrap_file_share      = try(var.paloalto_bootstrap.file_share, null)
  bootstrap_share_directory = try(var.paloalto_bootstrap.share_directory, null)
  bootstrap_access_key      = var.paloalto_bootstrap_access_key
}

module "sonicwall" {
  source = "../vendors/sonicwall"
  count  = var.vendor == "sonicwall" ? 1 : 0

  name_prefix              = local.common.name_prefix
  location                 = local.common.location
  resource_group_name      = local.common.resource_group_name
  tags                     = local.common.tags
  ha_mode                  = local.common.ha_mode
  network                  = module.network
  vm_size                  = local.common.vm_size
  admin_username           = local.common.admin_username
  admin_password           = var.admin_password
  admin_ssh_public_key     = var.admin_ssh_public_key
  license_type             = local.common.license_type
  accept_marketplace_terms = local.common.accept_marketplace_terms
  marketplace_publisher    = var.marketplace_publisher
  marketplace_offer        = var.marketplace_offer
  marketplace_sku          = var.marketplace_sku
  image_version            = var.image_version

  custom_data = var.custom_data
}

module "pfsense" {
  source = "../vendors/pfsense"
  count  = var.vendor == "pfsense" ? 1 : 0

  name_prefix              = local.common.name_prefix
  location                 = local.common.location
  resource_group_name      = local.common.resource_group_name
  tags                     = local.common.tags
  ha_mode                  = local.common.ha_mode
  network                  = module.network
  vm_size                  = local.common.vm_size
  admin_username           = local.common.admin_username
  admin_password           = var.admin_password
  admin_ssh_public_key     = var.admin_ssh_public_key
  license_type             = local.common.license_type
  accept_marketplace_terms = local.common.accept_marketplace_terms
  marketplace_publisher    = var.marketplace_publisher
  marketplace_offer        = var.marketplace_offer
  marketplace_sku          = var.marketplace_sku
  image_version            = var.image_version

  custom_data = var.custom_data
}

# Protected subnets in this subscription: send 0.0.0.0/0 to the firewall.
resource "azurerm_subnet_route_table_association" "protected" {
  for_each = var.protected_subnet_ids

  subnet_id      = each.value
  route_table_id = module.network.trust_route_table_id
}

# Exactly one vendor module exists. Outputs are selected per attribute (the
# vendor modules share one output interface with identical types), which keeps
# plan-time values known – try() over whole module objects would not.
