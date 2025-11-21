# Assumes variables:
# - var.org_prefix
# - var.location
# - var.hub_address_space   = "10.145.0.0/24"
# - var.spoke_address_space = "10.145.1.0/24"
# - var.log_analytics_sku

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

# Azure Bastion subnet: 10.145.0.96/27 (name must be AzureBastionSubnet)
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

# Public IP for NVA external NIC
resource "azurerm_public_ip" "nva" {
  name                = "${var.org_prefix}-nva-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.connectivity.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# NVA external NIC (with public IP)
resource "azurerm_network_interface" "nva_external" {
  name                 = "${var.org_prefix}-nva-ext-nic"
  location             = var.location
  resource_group_name  = azurerm_resource_group.connectivity.name
  enable_ip_forwarding = true

  ip_configuration {
    name                          = "external"
    subnet_id                     = azurerm_subnet.hub_nva_external.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.145.0.4"
    public_ip_address_id          = azurerm_public_ip.nva.id
  }
}

# NVA internal NIC
resource "azurerm_network_interface" "nva_internal" {
  name                 = "${var.org_prefix}-nva-int-nic"
  location             = var.location
  resource_group_name  = azurerm_resource_group.connectivity.name
  enable_ip_forwarding = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hub_nva_internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.145.0.36"
  }
}

# Attach NSG to both NVA NICs
resource "azurerm_network_interface_security_group_association" "nva_external" {
  network_interface_id      = azurerm_network_interface.nva_external.id
  network_security_group_id = azurerm_network_security_group.nva.id
}

resource "azurerm_network_interface_security_group_association" "nva_internal" {
  network_interface_id      = azurerm_network_interface.nva_internal.id
  network_security_group_id = azurerm_network_security_group.nva.id
}

# Dual-NIC Linux NVA VM
resource "azurerm_linux_virtual_machine" "nva" {
  name                            = "${var.org_prefix}-nva"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.connectivity.name
  size                            = var.nva_size
  admin_username                  = var.nva_admin_username
  disable_password_authentication = true

  primary_network_interface_id = azurerm_network_interface.nva_external.id
  network_interface_ids = [
    azurerm_network_interface.nva_external.id,
    azurerm_network_interface.nva_internal.id,
  ]

  admin_ssh_key {
    username   = var.nva_admin_username
    public_key = var.nva_admin_ssh_public_key
  }

  os_disk {
    name                 = "${var.org_prefix}-nva-osdisk"
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

# Azure Bastion

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

# Shared VNet and peering

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

# NVA-related variables (can live in variables.tf, included here for completeness)

variable "nva_admin_username" {
  description = "Admin username for the NVA."
  type        = string
  default     = "nvaadmin"
}

variable "nva_admin_ssh_public_key" {
  description = "SSH public key for the NVA admin account."
  type        = string
}

variable "nva_mgmt_source_cidr" {
  description = "CIDR allowed to SSH to the NVA."
  type        = string
  default     = "0.0.0.0/0"
}

variable "nva_size" {
  description = "VM size for the NVA appliance."
  type        = string
  default     = "Standard_B2s"
}
