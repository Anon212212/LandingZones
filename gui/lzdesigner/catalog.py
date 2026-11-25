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
