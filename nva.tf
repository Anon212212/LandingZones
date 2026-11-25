#############################################
# Internal Standard Load Balancer (HA Ports)
#############################################

resource "azurerm_lb" "nva_internal" {
  count = local.nva_ha_mode == "active-active" ? 1 : 0

  name                = local.names.ilb
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  sku                 = "Standard"
  tags                = local.tags

  frontend_ip_configuration {
    name                          = "fe-internal"
    subnet_id                     = azurerm_subnet.hub_nva_internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.nva_ilb_frontend_ip
    zones                         = local.zones # [Reliability] zone-redundant frontend
  }
}

resource "azurerm_lb_backend_address_pool" "nva" {
  count = local.nva_ha_mode == "active-active" ? 1 : 0

  name            = "be-nva"
  loadbalancer_id = azurerm_lb.nva_internal[0].id
}

resource "azurerm_lb_probe" "nva" {
  count = local.nva_ha_mode == "active-active" ? 1 : 0

  name                = "probe-nva"
  loadbalancer_id     = azurerm_lb.nva_internal[0].id
  protocol            = "Tcp"
  port                = local.nva_probe_port
  interval_in_seconds = 5
  probe_threshold     = 2
}

resource "azurerm_lb_rule" "nva_ha_ports" {
  count = local.nva_ha_mode == "active-active" ? 1 : 0

  name                           = "rule-ha-ports"
  loadbalancer_id                = azurerm_lb.nva_internal[0].id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "fe-internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.nva[0].id]
  probe_id                       = azurerm_lb_probe.nva[0].id
  floating_ip_enabled            = true
  load_distribution              = "Default" # 5-tuple; HA Ports keeps flows symmetric
}

#############################################
# NVA NICs (one external + one internal per NVA)
#############################################

resource "azurerm_network_interface" "nva_external" {
  count = local.nva_linux ? local.nva_count : 0

  name                           = "nic-${local.nva_names[count.index]}-ext"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.connectivity.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true # [Perf]
  tags                           = local.tags

  ip_configuration {
    name                          = "external"
    subnet_id                     = azurerm_subnet.hub_nva_external.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.nva_external_ips[count.index]
  }
}

resource "azurerm_network_interface" "nva_internal" {
  count = local.nva_linux ? local.nva_count : 0

  name                           = "nic-${local.nva_names[count.index]}-int"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.connectivity.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true # [Perf]
  tags                           = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hub_nva_internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.nva_internal_ips[count.index]
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "nva_internal" {
  count = local.nva_linux ? local.nva_count : 0

  network_interface_id    = azurerm_network_interface.nva_internal[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.nva[0].id
}

#############################################
# Built-in Linux NVAs (nva_vendor = "linux"), one per zone. Third-party
# firewalls are in firewall.tf.
#############################################

resource "azurerm_linux_virtual_machine" "nva" {
  count = local.nva_linux ? local.nva_count : 0

  name                            = local.nva_names[count.index]
  computer_name                   = "nva${count.index + 1}"
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

  # [Security] Trusted Launch + optional host encryption.
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = var.nva_encryption_at_host

  # [Security/OpEx] Identity for Azure Monitor Agent; no stored credentials.
  identity {
    type = "SystemAssigned"
  }

  # [Reliability/Security] Platform-orchestrated patching: safe deployment
  # across zones, so both NVAs are never rebooted together.
  patch_mode            = "AutomaticByPlatform"
  patch_assessment_mode = "AutomaticByPlatform"
  reboot_setting        = "IfRequired"
  provision_vm_agent    = true

  os_disk {
    name                 = "osdisk-${local.nva_names[count.index]}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS" # stateless appliance: rebuilt from code
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
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
# Azure Monitor Agent → DCR (syslog + perf) → Log Analytics
#############################################

resource "azurerm_virtual_machine_extension" "nva_ama" {
  count = local.nva_linux ? local.nva_count : 0

  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.nva[count.index].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  tags                       = local.tags
}

resource "azurerm_monitor_data_collection_rule_association" "nva" {
  count = local.nva_linux ? local.nva_count : 0

  name                    = "dcra-${local.nva_names[count.index]}"
  target_resource_id      = azurerm_linux_virtual_machine.nva[count.index].id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.nva.id
}
