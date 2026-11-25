# Offline tests: `terraform test` in modules/nva-firewall (mocked azurerm).

mock_provider "azurerm" {}

variables {
  client_name       = "acme"
  location          = "northeurope"
  address_space     = "10.20.0.0/24"
  admin_password    = "Not-a-real-Passw0rd!"
  mgmt_source_cidrs = ["10.0.0.0/8"]
}

run "sonicwall_single" {
  command = plan

  variables {
    vendor  = "sonicwall"
    ha_mode = "single"
  }

  assert {
    condition     = join(",", output.nic_order) == "trust,untrust"
    error_message = "SonicWall: X0 (trust) must be the primary NIC, X1 (untrust) second."
  }

  assert {
    condition     = output.next_hop_ip == "10.20.0.36" && length(output.firewalls) == 1
    error_message = "single: one firewall and the UDR must point at its trust IP."
  }

  assert {
    condition     = output.load_balancers == null && output.cluster == null
    error_message = "single: no load balancers and no cluster."
  }

  assert {
    condition     = alltrue([for r in ["untrust", "trust"] : output.nic_settings[r].ip_forwarding_enabled && output.nic_settings[r].accelerated_networking_enabled])
    error_message = "IP forwarding and accelerated networking must be on for untrust and trust."
  }

  assert {
    condition     = output.admin_username == "nsvadmin" && output.marketplace.publisher == "sonicwall-inc"
    error_message = "Vendor defaults not applied."
  }
}

run "fortigate_active_standby" {
  command = plan

  variables {
    vendor                   = "fortigate"
    ha_mode                  = "active-standby"
    zones                    = ["1", "2"]
    fortigate_license_tokens = ["TOKEN-A", "TOKEN-B"]
  }

  assert {
    condition     = join(",", output.nic_order) == "untrust,trust,hasync,mgmt"
    error_message = "FortiGate A-P: port1 untrust, port2 trust, port3 hasync, port4 mgmt."
  }

  assert {
    condition     = length(output.firewalls) == 2 && output.firewalls[0].zone == "1" && output.firewalls[1].zone == "2"
    error_message = "Active-standby needs two firewalls in different zones."
  }

  assert {
    condition     = output.load_balancers == null && output.cluster != null
    error_message = "Active-standby uses Azure API failover, not a load balancer."
  }

  assert {
    condition     = output.next_hop_ip == output.cluster.trust_vip && output.next_hop_ip == "10.20.0.36"
    error_message = "The UDR must target the floating trust VIP."
  }

  assert {
    condition     = output.nic_settings["mgmt"].accelerated_networking_enabled == false && output.nic_settings["hasync"].ip_forwarding_enabled == false
    error_message = "Only untrust/trust NICs get IP forwarding and accelerated networking."
  }

  assert {
    condition     = output.marketplace.sku == "fortinet_fg-vm_g2"
    error_message = "BYOL must select the BYOL SKU."
  }
}

run "fortigate_single_three_nics" {
  command = plan

  variables {
    vendor       = "fortigate"
    ha_mode      = "single"
    license_type = "payg"
  }

  assert {
    condition     = join(",", output.nic_order) == "untrust,trust,mgmt" && output.marketplace.sku == "fortinet_fg-vm_payg_2023_g2"
    error_message = "FortiGate single: 3 NICs and the PAYG SKU."
  }
}

run "pfsense_active_active" {
  command = plan

  variables {
    vendor         = "pfsense"
    ha_mode        = "active-active"
    instance_count = 3
    inbound_rules  = [{ name = "https", protocol = "Tcp", port = 443 }]
  }

  assert {
    condition     = join(",", output.nic_order) == "untrust,trust" && output.interface_names["untrust"] == "hn0 (WAN)"
    error_message = "pfSense: WAN (hn0) must be the primary NIC."
  }

  assert {
    condition     = length(output.firewalls) == 3 && output.load_balancers != null && output.cluster == null
    error_message = "Active-active: N firewalls behind internal + external load balancers."
  }

  assert {
    condition     = output.next_hop_ip == output.load_balancers.internal_frontend_ip
    error_message = "Active-active UDR must target the internal LB frontend."
  }

  assert {
    condition     = output.admin_username == "pfsenseadmin" && output.marketplace.license_type == "payg"
    error_message = "pfSense defaults: pfsenseadmin and PAYG."
  }
}

run "paloalto_active_standby_with_swap" {
  command = plan

  variables {
    vendor                       = "paloalto"
    ha_mode                      = "active-standby"
    paloalto_mgmt_interface_swap = true
  }

  assert {
    condition     = join(",", output.nic_order) == "untrust,mgmt,trust,hasync"
    error_message = "mgmt-interface-swap puts untrust on NIC0; hasync is NIC3."
  }
}

run "paloalto_active_active_default_order" {
  command = plan

  variables {
    vendor  = "paloalto"
    ha_mode = "active-active"
  }

  assert {
    condition     = join(",", output.nic_order) == "mgmt,untrust,trust"
    error_message = "VM-Series default order: mgmt, untrust, trust."
  }
}

run "availability_set_fallback" {
  command = plan

  variables {
    vendor  = "sonicwall"
    ha_mode = "active-active"
    zones   = []
  }

  assert {
    condition     = alltrue([for f in output.firewalls : f.zone == null])
    error_message = "No zones → firewalls go into an availability set."
  }
}

run "rejects_pfsense_active_standby" {
  command = plan

  variables {
    vendor  = "pfsense"
    ha_mode = "active-standby"
  }

  expect_failures = [var.ha_mode]
}

run "rejects_small_vm" {
  command = plan

  variables {
    vendor  = "fortigate"
    ha_mode = "single"
    vm_size = "Standard_D2s_v5"
  }

  expect_failures = [var.vm_size]
}

run "rejects_reserved_admin" {
  command = plan

  variables {
    vendor         = "pfsense"
    ha_mode        = "single"
    admin_username = "admin"
  }

  expect_failures = [var.admin_username]
}
