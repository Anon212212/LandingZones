# Vendor modules tested directly (day-0 content, pfSense precondition).

mock_provider "azurerm" {}

variables {
  name_prefix         = "acme-fw-prod"
  location            = "northeurope"
  resource_group_name = "rg-acme"
  admin_password      = "Not-a-real-Passw0rd!"
  network = {
    subnet_ids      = { untrust = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme/providers/Microsoft.Network/virtualNetworks/vnet-acme/subnets/snet-untrust", trust = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme/providers/Microsoft.Network/virtualNetworks/vnet-acme/subnets/snet-trust", mgmt = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme/providers/Microsoft.Network/virtualNetworks/vnet-acme/subnets/snet-mgmt", hasync = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme/providers/Microsoft.Network/virtualNetworks/vnet-acme/subnets/snet-hasync" }
    subnet_prefixes = { untrust = "10.20.0.0/27", trust = "10.20.0.32/27", mgmt = "10.20.0.64/27", hasync = "10.20.0.96/27" }
    gateways        = { untrust = "10.20.0.1", trust = "10.20.0.33", mgmt = "10.20.0.65", hasync = "10.20.0.97" }
    instances = [
      { index = 0, name = "acme-fw-prod-fw01", zone = "1", untrust_ip = "10.20.0.5", trust_ip = "10.20.0.37", mgmt_ip = "10.20.0.68", hasync_ip = "10.20.0.100", priority = 255, mgmt_public_ip_id = null, untrust_public_ip_id = null },
      { index = 1, name = "acme-fw-prod-fw02", zone = "2", untrust_ip = "10.20.0.6", trust_ip = "10.20.0.38", mgmt_ip = "10.20.0.69", hasync_ip = "10.20.0.101", priority = 200, mgmt_public_ip_id = null, untrust_public_ip_id = null },
    ]
    cluster = {
      trust_vip             = "10.20.0.36", untrust_vip = "10.20.0.4", public_ip_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme/providers/Microsoft.Network/publicIPAddresses/pip-acme-cluster", public_ip_name = "pip-acme-cluster",
      vip_ip_config_name    = "ipconfig-vip", route_table_name = "rt-acme-trust", managed_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-acme",
      managed_identity_name = "id-acme", managed_identity_principal_id = "p", managed_identity_client_id = "c"
    }
    load_balancers         = null
    availability_set_id    = null
    trust_route_table_name = "rt-acme-trust"
  }
}

run "fortigate_day0_mime" {
  command = plan

  module {
    source = "./../vendors/fortigate"
  }

  variables {
    ha_mode        = "active-standby"
    license_tokens = ["TOKEN-A", "TOKEN-B"]
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this["0"].custom_data), "Content-Type: multipart/mixed")
    error_message = "FortiGate custom data must be MIME multipart."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this["1"].custom_data), "LICENSE-TOKEN:TOKEN-B")
    error_message = "Each FortiGate gets its own licence token."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this["0"].custom_data), "set unicast-hb-peerip 10.20.0.101") && strcontains(base64decode(azurerm_linux_virtual_machine.this["0"].custom_data), "set type azure")
    error_message = "A-P config needs unicast heartbeat to the peer and the Azure SDN connector."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this["0"].plan[0].publisher == "fortinet" && azurerm_linux_virtual_machine.this["0"].plan[0].product == "fortinet_fortigate-vm_v5"
    error_message = "VM plan block must match the Marketplace image."
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.this["0"].identity) == 1
    error_message = "Active-standby firewalls need the failover managed identity."
  }
}

run "paloalto_bootstrap_custom_data" {
  command = plan

  module {
    source = "./../vendors/paloalto"
  }

  variables {
    ha_mode                   = "active-standby"
    mgmt_interface_swap       = true
    bootstrap_storage_account = "stbootstrap"
    bootstrap_access_key      = "secretkey"
    bootstrap_file_share      = "bootstrap"
  }

  assert {
    condition     = base64decode(azurerm_linux_virtual_machine.this["0"].custom_data) == "storage-account=stbootstrap;access-key=secretkey;file-share=bootstrap;mgmt-interface-swap=enable"
    error_message = "VM-Series custom data must carry the bootstrap share and the interface swap."
  }
}

run "paloalto_bootstrap_requires_all_parts" {
  command = plan

  module {
    source = "./../vendors/paloalto"
  }

  variables {
    ha_mode                   = "single"
    bootstrap_storage_account = "stbootstrap"
  }

  expect_failures = [var.bootstrap_file_share]
}

run "pfsense_blocks_active_standby" {
  command = plan

  module {
    source = "./../vendors/pfsense"
  }

  variables {
    ha_mode = "active-standby"
  }

  expect_failures = [azurerm_linux_virtual_machine.this]
}

run "pfsense_rejects_root_admin" {
  command = plan

  module {
    source = "./../vendors/pfsense"
  }

  variables {
    ha_mode        = "single"
    admin_username = "root"
  }

  expect_failures = [var.admin_username]
}
