#############################################
# Netgate pfSense Plus on Azure
#
# NIC order:  NIC0 = WAN / untrust → hn0
#             NIC1 = LAN / trust   → hn1
# pfSense assigns hn0 to the primary NIC, so WAN must be attached first.
#
# HA: CARP needs multicast, which Azure VNets don't carry, so
# active-standby is blocked (see the precondition on the VM). Use
# active-active: standalone pfSense instances behind the internal/external
# Standard LBs, with outbound NAT on WAN so return traffic stays symmetric.
#############################################

locals {
  default_publisher = "netgate"
  # Netgate publishes several pfSense Plus offers/plans; confirm for your region:
  #   az vm image list --publisher netgate --all -o table
  #   az vm image list-skus --publisher netgate --offer <offer> --location <region> -o table
  default_offer = "pfsense-plus-public-cloud-fw-vpn-router"
  default_skus = {
    payg = "pfsense-plus-public-tac-lite"
    byol = "pfsense-plus-public-tac-lite"
  }

  nic_roles         = ["untrust", "trust"]
  interface_names   = { untrust = "hn0 (WAN)", trust = "hn1 (LAN)" }
  management_role   = "trust"
  health_probe_port = 443
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

  join_lb_pool = var.ha_mode == "active-active" && try(var.network.lb_join[each.value.role], false)
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
  tags                            = merge(var.tags, { firewall-vendor = "pfsense", ha-mode = var.ha_mode })

  # Order matters: the first NIC is the VM's primary NIC (NIC 0 = WAN/untrust → hn0; NIC 1 = LAN/trust → hn1).
  network_interface_ids = [for role in local.nic_roles : module.nic["${each.key}-${role}"].id]

  custom_data = var.custom_data == null ? null : base64encode(var.custom_data)

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

  lifecycle {
    precondition {
      condition     = var.ha_mode != "active-standby"
      error_message = "pfSense active-standby relies on CARP, which needs multicast – Azure VNets don't carry multicast. Use ha_mode = \"active-active\" (two standalone pfSense instances behind the internal/external Standard Load Balancers with outbound SNAT) or \"single\"."
    }
  }

  depends_on = [azurerm_marketplace_agreement.this]
}
