data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "mgmt" {
  name     = "${var.org_prefix}-mgmt-rg"
  location = var.location
}

resource "azurerm_resource_group" "connectivity" {
  name     = "${var.org_prefix}-conn-rg"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.org_prefix}-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.mgmt.name
  sku                 = var.log_analytics_sku
  retention_in_days   = 30
}

resource "azurerm_virtual_network" "hub" {
  name                = "${var.org_prefix}-hub-vnet"
  address_space       = [var.hub_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
}

# PROD VNet
resource "azurerm_virtual_network" "prod" {
  name                = "${var.org_prefix}-prod-vnet"
  address_space       = [var.prod_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
}

# PROD app subnet (inside 10.145.2.0/24)
resource "azurerm_subnet" "prod_app" {
  name                 = "prod-app-snet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.prod.name
  address_prefixes     = ["10.145.2.0/24"] # or /25,/26 if you want to carve it up later
}

# AVD VNet
resource "azurerm_virtual_network" "avd" {
  name                = "${var.org_prefix}-avd-vnet"
  address_space       = [var.avd_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
}
# AVD session hosts subnet
resource "azurerm_subnet" "avd_sessionhosts" {
  name                 = "avd-sessionhosts-snet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.avd.name
  address_prefixes     = ["10.145.3.0/24"]
}
# Hub subnets inside 10.145.0.0/24

# NVA external subnet: 10.145.0.0/27
resource "azurerm_subnet" "hub_nva_external" {
  name                 = "nva-external-snet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.145.0.0/27"]
}

# NVA internal subnet: 10.145.0.32/27
resource "azurerm_subnet" "hub_nva_internal" {
  name                 = "nva-internal-snet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.145.0.32/27"]
}

# Management subnet: 10.145.0.64/27
resource "azurerm_subnet" "hub_mgmt" {
  name                 = "mgmt-snet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.145.0.64/27"]
}

# Azure Bastion subnet: 10.145.0.96/27
resource "azurerm_subnet" "hub_bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.connectivity.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.145.0.96/27"]
}

# NSG for NVA NICs
resource "azurerm_network_security_group" "nva" {
  name                = "${var.org_prefix}-nva-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name

  security_rule {
    name                       = "Allow-SSH-Management"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.nva_mgmt_source_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Vnet-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

# NSG for management subnet
resource "azurerm_network_security_group" "mgmt" {
  name                = "${var.org_prefix}-mgmt-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name

  security_rule {
    name                       = "Allow-VNet-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "hub_mgmt" {
  subnet_id                 = azurerm_subnet.hub_mgmt.id
  network_security_group_id = azurerm_network_security_group.mgmt.id
}

# -------------------------
# Internal Standard Load Balancer for NVA HA (HA Ports)
# -------------------------

resource "azurerm_lb" "nva_internal" {
  name                = "${var.org_prefix}-nva-int-lb"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "internal-frontend"
    subnet_id                     = azurerm_subnet.hub_nva_internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.145.0.34" # within 10.145.0.32/27
  }
}

resource "azurerm_lb_backend_address_pool" "nva" {
  name            = "nva-bepool"
  loadbalancer_id = azurerm_lb.nva_internal.id
}

resource "azurerm_lb_probe" "nva" {
  name            = "nva-probe"
  loadbalancer_id = azurerm_lb.nva_internal.id
  protocol        = "Tcp"
  port            = 22
}

resource "azurerm_lb_rule" "nva_ha_ports" {
  name                           = "nva-ha-ports"
  loadbalancer_id                = azurerm_lb.nva_internal.id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "internal-frontend"
  backend_address_pool_id        = azurerm_lb_backend_address_pool.nva.id
  probe_id                       = azurerm_lb_probe.nva.id
  enable_floating_ip             = true
}

# -------------------------
# NVA NICs (2 NVAs, 2 NICs each)
# -------------------------

# External NICs (no public IP, mgmt via Bastion)
resource "azurerm_network_interface" "nva_external" {
  count                = 2
  name                 = "${var.org_prefix}-nva${count.index + 1}-ext-nic"
  location             = var.location
  resource_group_name  = azurerm_resource_group.connectivity.name
  enable_ip_forwarding = true

  ip_configuration {
    name                          = "external"
    subnet_id                     = azurerm_subnet.hub_nva_external.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.145.0.${4 + count.index}" # .4, .5
  }
}

# Internal NICs (behind internal LB)
resource "azurerm_network_interface" "nva_internal" {
  count                = 2
  name                 = "${var.org_prefix}-nva${count.index + 1}-int-nic"
  location             = var.location
  resource_group_name  = azurerm_resource_group.connectivity.name
  enable_ip_forwarding = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hub_nva_internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.145.0.${36 + count.index}" # .36, .37
  }
}

# Attach NSG to both NVA NIC types
resource "azurerm_network_interface_security_group_association" "nva_external" {
  count                    = 2
  network_interface_id     = azurerm_network_interface.nva_external[count.index].id
  network_security_group_id = azurerm_network_security_group.nva.id
}

resource "azurerm_network_interface_security_group_association" "nva_internal" {
  count                    = 2
  network_interface_id     = azurerm_network_interface.nva_internal[count.index].id
  network_security_group_id = azurerm_network_security_group.nva.id
}

# Associate internal NICs with LB backend pool
resource "azurerm_network_interface_backend_address_pool_association" "nva_internal" {
  count                   = 2
  network_interface_id    = azurerm_network_interface.nva_internal[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.nva.id
}

# -------------------------
# Dual-NIC Linux NVAs (2 instances, zones 1 & 2)
# -------------------------

resource "azurerm_linux_virtual_machine" "nva" {
  count                           = 2
  name                            = "${var.org_prefix}-nva-${count.index + 1}"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.connectivity.name
  size                            = var.nva_size
  admin_username                  = var.nva_admin_username
  disable_password_authentication = true

  # Spread across zones 1 and 2
  zone = tostring(count.index + 1)

  primary_network_interface_id = azurerm_network_interface.nva_external[count.index].id
  network_interface_ids = [
    azurerm_network_interface.nva_external[count.index].id,
    azurerm_network_interface.nva_internal[count.index].id,
  ]

  admin_ssh_key {
    username   = var.nva_admin_username
    public_key = var.nva_admin_ssh_public_key
  }

  os_disk {
    name                 = "${var.org_prefix}-nva-osdisk-${count.index + 1}"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# -------------------------
# Azure Bastion
# -------------------------

resource "azurerm_public_ip" "bastion" {
  name                = "${var.org_prefix}-bastion-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "bastion" {
  name                = "${var.org_prefix}-bastion"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name

  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.hub_bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# -------------------------
# Shared VNet and peering
# -------------------------

resource "azurerm_virtual_network" "shared" {
  name                = "${var.org_prefix}-shared-vnet"
  address_space       = [var.spoke_address_space]
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
}

resource "azurerm_virtual_network_peering" "hub_to_shared" {
  name                         = "hub-to-shared"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.shared.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "shared_to_hub" {
  name                         = "shared-to-hub"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.shared.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}
# Hub ↔ PROD peering
resource "azurerm_virtual_network_peering" "hub_to_prod" {
  name                         = "hub-to-prod"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.prod.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "prod_to_hub" {
  name                         = "prod-to-hub"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.prod.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

# Hub ↔ AVD peering
resource "azurerm_virtual_network_peering" "hub_to_avd" {
  name                         = "hub-to-avd"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.avd.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "avd_to_hub" {
  name                         = "avd-to-hub"
  resource_group_name          = azurerm_resource_group.connectivity.name
  virtual_network_name         = azurerm_virtual_network.avd.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_route_table" "prod_rt" {
  name                = "${var.org_prefix}-prod-rt"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name

  route {
    name                   = "default-to-nva"
    address_prefix         = "0.0.0.0/0"          # or on-prem ranges
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = "10.145.0.34"       # internal LB frontend
  }
}

resource "azurerm_subnet_route_table_association" "prod_app" {
  subnet_id      = azurerm_subnet.prod_app.id   # your prod subnet
  route_table_id = azurerm_route_table.prod_rt.id
}
