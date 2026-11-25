#############################################
# Palo Alto Networks VM-Series (vmseries-flex) on Azure
#
# NIC order:  NIC0 mgmt · NIC1 untrust (ethernet1/1) · NIC2 trust (ethernet1/2)
#             · NIC3 hasync (ethernet1/3, HA2) in active-standby.
# With mgmt_interface_swap = true NIC0 and NIC1 swap roles (untrust first),
# matching `mgmt-interface-swap=enable` in the day-0 custom data.
# Day-0: custom_data carries the bootstrap Azure Files share parameters.
#############################################

locals {
  default_publisher = "paloaltonetworks"
  default_offer     = "vmseries-flex"
  # List current SKUs:
  #   az vm image list --publisher paloaltonetworks --offer vmseries-flex --all -o table
  default_skus = {
    byol    = "byol"
    bundle1 = "bundle1"
    bundle2 = "bundle2"
    bundle3 = "bundle3"
  }

  ha         = var.ha_mode == "active-standby"
  base_roles = var.mgmt_interface_swap ? ["untrust", "mgmt", "trust"] : ["mgmt", "untrust", "trust"]
  nic_roles  = concat(local.base_roles, local.ha ? ["hasync"] : [])
  interface_names = {
    mgmt    = "management"
    untrust = "ethernet1/1"
    trust   = "ethernet1/2"
    hasync  = "ethernet1/3 (HA2)"
  }
  management_role   = "mgmt"
  health_probe_port = 443

  bootstrap_pairs = compact([
    var.bootstrap_storage_account == null ? "" : "storage-account=${var.bootstrap_storage_account}",
    var.bootstrap_access_key == null ? "" : "access-key=${var.bootstrap_access_key}",
    var.bootstrap_file_share == null ? "" : "file-share=${var.bootstrap_file_share}",
    var.bootstrap_share_directory == null ? "" : "share-directory=${var.bootstrap_share_directory}",
    var.mgmt_interface_swap ? "mgmt-interface-swap=enable" : "",
  ])
  custom_data = length(local.bootstrap_pairs) == 0 ? null : join(";", local.bootstrap_pairs)
}

locals {
  publisher = coalesce(var.marketplace_publisher, local.default_publisher)
  offer     = coalesce(var.marketplace_offer, local.default_offer)
  sku       = coalesce(var.marketplace_sku, local.default_skus[var.license_type])

  instances = { for inst in var.network.instances : tostring(inst.index) => inst }
  cluster   = try(var.network.cluster, null)
  lbs       = try(var.network.load_balancers, null)

  # One entry per firewall × NIC role, in the vendor's NIC order.
  nics = merge([
    for inst in var.network.instances : {
      for pos, role in local.nic_roles : "${inst.index}-${role}" => {
        instance = inst
        role     = role
        position = pos
        name     = "nic-${inst.name}-${pos}-${role}"
      }
    }
  ]...)
}

resource "azurerm_marketplace_agreement" "this" {
  count = var.accept_marketplace_terms ? 1 : 0

  publisher = local.publisher
  offer     = local.offer
  plan      = local.sku
}

module "nic" {
  source   = "../_nic"
  for_each = local.nics

  name                = each.value.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  subnet_id  = var.network.subnet_ids[each.value.role]
  private_ip = each.value.instance["${each.value.role}_ip"]
  data_plane = contains(["untrust", "trust"], each.value.role)

  public_ip_id = (
    each.value.role == "untrust" ? each.value.instance.untrust_public_ip_id :
    each.value.role == "mgmt" ? each.value.instance.mgmt_public_ip_id : null
  )

  # active-standby: floating VIPs start on node 0 and are moved by the firewall.
  vip = (
    var.ha_mode == "active-standby" && each.value.instance.index == 0 && contains(["untrust", "trust"], each.value.role) ? {
      private_ip   = each.value.role == "trust" ? local.cluster.trust_vip : local.cluster.untrust_vip
      public_ip_id = each.value.role == "untrust" ? local.cluster.public_ip_id : null
    } : null
  )
  floating = var.ha_mode == "active-standby" && contains(["untrust", "trust"], each.value.role)

  join_lb_pool = var.ha_mode == "active-active" && contains(["untrust", "trust"], each.value.role)
  lb_backend_pool_id = (
    var.ha_mode != "active-active" ? null :
    each.value.role == "trust" ? local.lbs.internal_backend_pool_id :
    each.value.role == "untrust" ? local.lbs.external_backend_pool_id : null
  )
}

resource "azurerm_linux_virtual_machine" "this" {
  for_each = local.instances

  name                            = each.value.name
  computer_name                   = each.value.name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  zone                            = each.value.zone
  availability_set_id             = each.value.zone == null ? var.network.availability_set_id : null
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  tags                            = merge(var.tags, { firewall-vendor = "paloalto", ha-mode = var.ha_mode })

  # Order matters: the first NIC is the VM's primary NIC (NIC 0 = management, or untrust when mgmt_interface_swap is on).
  network_interface_ids = [for role in local.nic_roles : module.nic["${each.key}-${role}"].id]

  custom_data = local.custom_data == null ? null : base64encode(local.custom_data)

  dynamic "admin_ssh_key" {
    for_each = var.admin_ssh_public_key == null ? [] : [var.admin_ssh_public_key]
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  dynamic "identity" {
    for_each = var.ha_mode == "active-standby" && local.cluster != null ? [local.cluster.managed_identity_id] : []
    content {
      type         = "UserAssigned"
      identity_ids = [identity.value]
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
  }

  source_image_reference {
    publisher = local.publisher
    offer     = local.offer
    sku       = local.sku
    version   = var.image_version
  }

  plan {
    name      = local.sku
    product   = local.offer
    publisher = local.publisher
  }

  boot_diagnostics {}

  depends_on = [azurerm_marketplace_agreement.this]
}
