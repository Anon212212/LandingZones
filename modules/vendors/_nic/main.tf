#############################################
# One firewall NIC. Two resource variants because `lifecycle` can't be
# conditional: in active-standby the firewalls move the floating IP config
# between nodes through the Azure API, and Terraform must not move it back.
#############################################

locals {
  configs = concat(
    [{
      name         = "ipconfig1"
      primary      = true
      private_ip   = var.private_ip
      public_ip_id = var.public_ip_id
    }],
    var.vip == null ? [] : [{
      name         = var.vip_ip_config_name
      primary      = false
      private_ip   = var.vip.private_ip
      public_ip_id = var.vip.public_ip_id
    }],
  )
}

resource "azurerm_network_interface" "static" {
  count = var.floating ? 0 : 1

  name                           = var.name
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = var.data_plane
  accelerated_networking_enabled = var.data_plane
  tags                           = var.tags

  dynamic "ip_configuration" {
    for_each = local.configs
    content {
      name                          = ip_configuration.value.name
      primary                       = ip_configuration.value.primary
      subnet_id                     = var.subnet_id
      private_ip_address_allocation = "Static"
      private_ip_address            = ip_configuration.value.private_ip
      public_ip_address_id          = ip_configuration.value.public_ip_id
    }
  }
}

resource "azurerm_network_interface" "floating" {
  count = var.floating ? 1 : 0

  name                           = var.name
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = var.data_plane
  accelerated_networking_enabled = var.data_plane
  tags                           = var.tags

  dynamic "ip_configuration" {
    for_each = local.configs
    content {
      name                          = ip_configuration.value.name
      primary                       = ip_configuration.value.primary
      subnet_id                     = var.subnet_id
      private_ip_address_allocation = "Static"
      private_ip_address            = ip_configuration.value.private_ip
      public_ip_address_id          = ip_configuration.value.public_ip_id
    }
  }

  lifecycle {
    ignore_changes = [ip_configuration]
  }
}

locals {
  nic = var.floating ? azurerm_network_interface.floating[0] : azurerm_network_interface.static[0]
}

resource "azurerm_network_interface_backend_address_pool_association" "this" {
  count = var.join_lb_pool ? 1 : 0

  network_interface_id    = local.nic.id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = var.lb_backend_pool_id
}
