"""Static choices offered to the user: regions, sizes, images and presets."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Region:
    name: str          # Azure location name
    display: str       # human name shown in dropdowns and the diagram
    short: str         # code used in resource names (matches locals.tf)
    secondary: str     # suggested zone-capable secondary region


# Only regions with Availability Zones – the design depends on them.
REGIONS: dict[str, Region] = {r.name: r for r in [
    Region("northeurope", "North Europe", "neu", "westeurope"),
    Region("westeurope", "West Europe", "weu", "northeurope"),
    Region("uksouth", "UK South", "uks", "westeurope"),
    Region("swedencentral", "Sweden Central", "sdc", "northeurope"),
    Region("germanywestcentral", "Germany West Central", "gwc", "westeurope"),
    Region("francecentral", "France Central", "frc", "westeurope"),
    Region("eastus", "East US", "eus", "westus2"),
    Region("eastus2", "East US 2", "eus2", "centralus"),
    Region("centralus", "Central US", "cus", "eastus2"),
    Region("westus2", "West US 2", "wus2", "westus3"),
    Region("westus3", "West US 3", "wus3", "westus2"),
    Region("australiaeast", "Australia East", "aue", "southeastasia"),
    Region("southeastasia", "Southeast Asia", "sea", "australiaeast"),
]}

ENVIRONMENTS = ["prod", "nonprod", "uat", "test", "dev", "sandbox"]

# T-shirt sizes keep the front end simple; the value is the Azure VM size.
VM_SIZES = {
    "Small (2 vCPU)": "Standard_D2s_v5",
    "Medium (4 vCPU)": "Standard_D4s_v5",
    "Large (8 vCPU)": "Standard_D8s_v5",
}

DC_IMAGES = {
    "Windows Server 2025 (Azure Edition)": "2025-datacenter-azure-edition",
    "Windows Server 2022 (Azure Edition)": "2022-datacenter-azure-edition",
}

BASTION_SKUS = {
    "Basic – browser access only": "Basic",
    "Standard – native client, IP connect": "Standard",
    "Premium – adds session recording": "Premium",
}

BACKUP_MODES = {
    "Zone-redundant (ZRS)": "ZoneRedundant",
    "Geo-redundant + Cross Region Restore": "GeoRedundant",
}


@dataclass(frozen=True)
class ResiliencePreset:
    label: str
    description: str
    nva_zones: tuple[str, ...]
    dc_zones: tuple[str, ...]
    backup_mode: str


RESILIENCE_PRESETS: dict[str, ResiliencePreset] = {
    "standard": ResiliencePreset(
        "Standard", "2 NVAs and 2 DCs per region across two zones, zone-redundant backups.",
        ("1", "2"), ("1", "2"), "ZoneRedundant"),
    "high": ResiliencePreset(
        "High", "3 NVAs and 3 DCs per region across all three zones, zone-redundant backups.",
        ("1", "2", "3"), ("1", "2", "3"), "ZoneRedundant"),
    "maximum": ResiliencePreset(
        "Maximum", "All three zones plus geo-redundant backups with Cross Region Restore.",
        ("1", "2", "3"), ("1", "2", "3"), "GeoRedundant"),
}


# --------------------------------------------------------------------------
# Firewall appliance in the hub. Image defaults mirror modules/vendors/*/main.tf
# (tests/test_catalog.py keeps them in sync).
# --------------------------------------------------------------------------

NVA_HA_MODES = {
    "active-active": "Active / active – internal load balancer (HA Ports)",
    "active-standby": "Active / standby – Azure API failover, no load balancer",
    "single": "Single firewall – no high availability",
}


@dataclass(frozen=True)
class NvaVendor:
    label: str
    product: str
    ha_modes: tuple[str, ...]
    licenses: dict            # license_type -> label
    default_license: str | None
    publisher: str | None
    offer: str | None
    skus: dict                # license_type -> Marketplace SKU
    nic_layout: dict          # ha_mode ("*" = any) -> description
    probe_port: int
    management: str
    notes: str


NVA_VENDORS: dict[str, NvaVendor] = {
    "linux": NvaVendor(
        "Built-in Linux router", "Ubuntu 24.04 (IP forwarding + SNAT)", ("active-active",), {}, None,
        None, None, {},
        {"*": "eth0 untrust · eth1 trust"}, 22, "SSH from Bastion",
        "Routes and SNATs but doesn't inspect traffic. Choose a vendor for NGFW features."),
    "fortigate": NvaVendor(
        "Fortinet FortiGate", "FortiGate-VM", ("active-active", "active-standby", "single"),
        {"byol": "BYOL – FortiFlex token / .lic", "payg": "Pay-as-you-go (Marketplace)"}, "byol",
        "fortinet", "fortinet_fortigate-vm_v5", {"byol": "fortinet_fg-vm_g2", "payg": "fortinet_fg-vm_payg_2023_g2"},
        {"active-standby": "port1 untrust · port2 trust · port3 HA sync · port4 mgmt",
         "*": "port1 untrust · port2 trust · port3 mgmt"},
        8008, "HTTPS/SSH on the mgmt NIC",
        "Day-0 config and FortiFlex tokens are injected as MIME custom data (nva_fortigate_license_tokens)."),
    "paloalto": NvaVendor(
        "Palo Alto Networks VM-Series", "VM-Series (vmseries-flex)", ("active-active", "active-standby", "single"),
        {"byol": "BYOL", "bundle1": "PAYG Bundle 1", "bundle2": "PAYG Bundle 2", "bundle3": "PAYG Bundle 3"}, "byol",
        "paloaltonetworks", "vmseries-flex", {"byol": "byol", "bundle1": "bundle1", "bundle2": "bundle2", "bundle3": "bundle3"},
        {"active-standby": "NIC0 mgmt · eth1/1 untrust · eth1/2 trust · eth1/3 HA2",
         "*": "NIC0 mgmt · eth1/1 untrust · eth1/2 trust"},
        443, "HTTPS/SSH on the mgmt NIC",
        "Bootstrap from an Azure Files share via nva_paloalto_bootstrap (optional)."),
    "sonicwall": NvaVendor(
        "SonicWall NSv", "NSv", ("active-active", "active-standby", "single"),
        {"byol": "BYOL", "payg": "Pay-as-you-go (Marketplace)"}, "byol",
        "sonicwall-inc", "sonicwall-nsz-azure", {"byol": "snwl-nsz-byol", "payg": "snwl-nsz-payg"},
        {"active-standby": "X0 trust (mgmt) · X1 untrust · X2 HA sync", "*": "X0 trust (mgmt) · X1 untrust"},
        443, "HTTPS on X0 (trust)",
        "Verify the Marketplace offer/SKU for your region before deploying."),
    "pfsense": NvaVendor(
        "Netgate pfSense Plus", "pfSense Plus", ("active-active", "single"),
        {"payg": "Pay-as-you-go (Marketplace)", "byol": "BYOL"}, "payg",
        "netgate", "pfsense-plus-public-cloud-fw-vpn-router",
        {"payg": "pfsense-plus-public-tac-lite", "byol": "pfsense-plus-public-tac-lite"},
        {"*": "hn0 WAN (untrust) · hn1 LAN (trust)"},
        443, "HTTPS on hn1 (LAN)",
        "No CARP on Azure (no multicast): HA is active/active behind the load balancer. Verify the offer/SKU."),
}

# Sizes offered when a third-party firewall needs >= 4 vCPUs.
NVA_VENDOR_SIZES = {
    "Medium (4 vCPU)": "Standard_D4s_v5",
    "Large (8 vCPU)": "Standard_D8s_v5",
    "Compute-optimised (4 vCPU)": "Standard_F4s_v2",
    "Compute-optimised (8 vCPU)": "Standard_F8s_v2",
}


def vm_vcpus(size: str) -> int:
    import re
    m = re.match(r"^Standard_[A-Za-z]+(\d+)", size or "")
    return int(m.group(1)) if m else 0
