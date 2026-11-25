#############################################
# Internal Standard Load Balancer (HA Ports)
#############################################

resource "azurerm_lb" "nva_internal" {
  name                = "${var.org_prefix}-nva-int-lb"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  sku                 = "Standard"
  tags                = local.tags

  frontend_ip_configuration {
    name                          = "internal-frontend"
    subnet_id                     = azurerm_subnet.hub_nva_internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.nva_ilb_frontend_ip
    zones                         = ["1", "2", "3"] # zone-redundant frontend
  }
}

resource "azurerm_lb_backend_address_pool" "nva" {
  name            = "nva-bepool"
  loadbalancer_id = azurerm_lb.nva_internal.id
}

resource "azurerm_lb_probe" "nva" {
  name                = "nva-probe"
  loadbalancer_id     = azurerm_lb.nva_internal.id
  protocol            = "Tcp"
  port                = 22
  interval_in_seconds = 5
}

resource "azurerm_lb_rule" "nva_ha_ports" {
  name                           = "nva-ha-ports"
  loadbalancer_id                = azurerm_lb.nva_internal.id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "internal-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.nva.id]
  probe_id                       = azurerm_lb_probe.nva.id
  enable_floating_ip             = true
  load_distribution              = "Default"
}

#############################################
# NVA NICs (one external + one internal per NVA)
#############################################

resource "azurerm_network_interface" "nva_external" {
  count = local.nva_count

  name                           = "${var.org_prefix}-nva${count.index + 1}-ext-nic"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.connectivity.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = local.tags

  ip_configuration {
    name                          = "external"
    subnet_id                     = azurerm_subnet.hub_nva_external.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.nva_external_ips[count.index]
  }
}

resource "azurerm_network_interface" "nva_internal" {
  count = local.nva_count

  name                           = "${var.org_prefix}-nva${count.index + 1}-int-nic"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.connectivity.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hub_nva_internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.nva_internal_ips[count.index]
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "nva_internal" {
  count = local.nva_count

  network_interface_id    = azurerm_network_interface.nva_internal[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.nva.id
}

#############################################
# Linux NVAs (one per zone)
#############################################

resource "azurerm_linux_virtual_machine" "nva" {
  count = local.nva_count

  name                            = "${var.org_prefix}-nva-${count.index + 1}"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.connectivity.name
  size                            = var.nva_size
  zone                            = var.nva_zones[count.index]
  admin_username                  = var.nva_admin_username
  disable_password_authentication = true
  tags                            = local.tags

  # First NIC in the list is the primary (eth0 = external, eth1 = internal).
  network_interface_ids = [
    azurerm_network_interface.nva_external[count.index].id,
    azurerm_network_interface.nva_internal[count.index].id,
  ]

  # Enables kernel forwarding, routes spoke prefixes back via the internal
  # NIC and SNATs Internet-bound traffic out of the external NIC.
  custom_data = base64encode(templatefile("${path.module}/templates/nva-cloud-init.yaml.tftpl", {
    internal_gateway = local.nva_internal_gw
    spoke_prefixes   = local.spoke_address_spaces
  }))

  admin_ssh_key {
    username   = var.nva_admin_username
    public_key = var.nva_admin_ssh_public_key
  }

  os_disk {
    name                 = "${var.org_prefix}-nva-osdisk-${count.index + 1}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {} # managed storage account

  # NIC associations must exist before the VM boots so the probe succeeds
  # and the NSG is in place from first boot.
  depends_on = [
    azurerm_network_interface_security_group_association.nva_external,
    azurerm_network_interface_security_group_association.nva_internal,
    azurerm_network_interface_backend_address_pool_association.nva_internal,
  ]
}

#############################################
# Azure Bastion
#############################################

resource "azurerm_public_ip" "bastion" {
  name                = "${var.org_prefix}-bastion-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "bastion" {
  name                = "${var.org_prefix}-bastion"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  sku                 = var.bastion_sku
  tunneling_enabled   = var.bastion_sku == "Standard"
  ip_connect_enabled  = var.bastion_sku == "Standard"
  tags                = local.tags

  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.hub_bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}
