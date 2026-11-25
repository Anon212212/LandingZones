#############################################
# FortiGate-VM on Azure
#
# NIC order (port numbering inside FortiOS follows attachment order):
#   active-standby : port1 untrust · port2 trust · port3 hasync · port4 mgmt
#   single / A-A   : port1 untrust · port2 trust · port3 mgmt
# Day-0: CLI config + licence (FortiFlex token or .lic) as MIME multipart
# custom_data. In active-standby the Azure SDN connector (managed identity)
# moves the cluster public IP and trust VIP to the new primary.
#############################################

locals {
  default_publisher = "fortinet"
  default_offer     = "fortinet_fortigate-vm_v5"
  # Gen2 images. List current SKUs:
  #   az vm image list --publisher fortinet --offer fortinet_fortigate-vm_v5 --all -o table
  default_skus = {
    byol = "fortinet_fg-vm_g2"
    payg = "fortinet_fg-vm_payg_2023_g2"
  }

  ha                = var.ha_mode == "active-standby"
  nic_roles         = local.ha ? ["untrust", "trust", "hasync", "mgmt"] : ["untrust", "trust", "mgmt"]
  mgmt_port         = local.ha ? "port4" : "port3"
  interface_names   = { for i, role in local.nic_roles : role => "port${i + 1}" }
  management_role   = "mgmt"
  health_probe_port = 8008

  custom_data = {
    for k, inst in local.instances : k => templatefile("${path.module}/templates/mime.tftpl", {
      config = templatefile("${path.module}/templates/fgt-config.tftpl", {
        hostname               = inst.name
        ha                     = local.ha
        mgmt_port              = local.mgmt_port
        untrust_ip             = inst.untrust_ip
        untrust_mask           = cidrnetmask(var.network.subnet_prefixes.untrust)
        trust_ip               = inst.trust_ip
        trust_mask             = cidrnetmask(var.network.subnet_prefixes.trust)
        mgmt_ip                = inst.mgmt_ip
        mgmt_mask              = cidrnetmask(var.network.subnet_prefixes.mgmt)
        hasync_ip              = inst.hasync_ip
        hasync_mask            = cidrnetmask(var.network.subnet_prefixes.hasync)
        untrust_gw             = var.network.gateways.untrust
        trust_gw               = var.network.gateways.trust
        mgmt_gw                = var.network.gateways.mgmt
        probe_port             = local.health_probe_port
        internal_cidrs         = var.internal_cidrs
        cluster_name           = "${var.name_prefix}-ha"
        priority               = inst.priority
        peer_hasync_ip         = local.ha ? [for o in var.network.instances : o.hasync_ip if o.index != inst.index][0] : ""
        untrust_nic_name       = local.nics["${k}-untrust"].name
        trust_nic_name         = local.nics["${k}-trust"].name
        vip_ip_config_name     = local.ha ? local.cluster.vip_ip_config_name : ""
        cluster_public_ip_name = local.ha ? local.cluster.public_ip_name : ""
        trust_vip              = local.ha ? local.cluster.trust_vip : ""
        extra_config           = var.extra_config
      })
      license = (
        length(var.license_tokens) > tonumber(k) ? "LICENSE-TOKEN:${var.license_tokens[tonumber(k)]}" :
        length(var.license_files) > tonumber(k) ? var.license_files[tonumber(k)] : ""
      )
    })
  }
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
  tags                            = merge(var.tags, { firewall-vendor = "fortigate", ha-mode = var.ha_mode })

  # Order matters: the first NIC is the VM's primary NIC (port1 = untrust).
  network_interface_ids = [for role in local.nic_roles : module.nic["${each.key}-${role}"].id]

  custom_data = base64encode(local.custom_data[each.key])

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
