"""Configuration model.

`LandingZoneConfig` mirrors the Terraform input variables one-to-one (same
names), plus a few designer-only helpers (`network_base`, `frameworks`,
`resilience`) that drive the simplified front end.
"""

from __future__ import annotations

import ipaddress
import json
from dataclasses import asdict, dataclass, field, fields

from .catalog import REGIONS, RESILIENCE_PRESETS

FRAMEWORKS = ("WAF", "NIS2", "DORA")


@dataclass
class IdentityRegion:
    key: str
    location: str
    address_space: str
    dc_zones: list[str] = field(default_factory=lambda: ["1", "2"])


@dataclass
class LandingZoneConfig:
    # --- organisation ----------------------------------------------------
    org_prefix: str = "contoso"
    environment: str = "prod"
    location: str = "northeurope"
    owner: str = ""
    cost_center: str = ""
    tags: dict[str, str] = field(default_factory=dict)

    # --- subscriptions / access -----------------------------------------
    subscription_id: str = ""
    identity_subscription_id: str = ""
    nva_admin_username: str = "nvaadmin"
    nva_admin_ssh_public_key: str = ""

    # --- network ---------------------------------------------------------
    network_base: str = "10.145.0.0/16"    # designer helper
    auto_addressing: bool = True             # derive every CIDR from network_base
    hub_address_space: str = "10.145.0.0/24"
    spoke_address_space: str = "10.145.1.0/24"
    prod_address_space: str = "10.145.2.0/24"
    avd_address_space: str = "10.145.3.0/24"
    enable_nat_gateway: bool = True
    nva_mgmt_source_cidrs: list[str] = field(default_factory=list)

    # --- resilience --------------------------------------------------------
    resilience: str = "standard"             # designer helper (preset key or "custom")
    zones: list[str] = field(default_factory=lambda: ["1", "2", "3"])
    nva_zones: list[str] = field(default_factory=lambda: ["1", "2"])
    enable_resource_locks: bool = True

    # --- compute -----------------------------------------------------------
    nva_size: str = "Standard_D2s_v5"
    nva_cpu_alert_threshold: int = 75
    nva_encryption_at_host: bool = False

    # --- security ----------------------------------------------------------
    ddos_protection_plan_id: str = ""
    bastion_sku: str = "Standard"

    # --- identity (tier-0) ------------------------------------------------
    identity_regions: list[IdentityRegion] = field(default_factory=lambda: [
        IdentityRegion("primary", "northeurope", "10.145.4.0/24"),
        IdentityRegion("secondary", "westeurope", "10.146.4.0/24"),
    ])
    dc_size: str = "Standard_D2s_v5"
    dc_admin_username: str = "dcadmin"
    dc_image_sku: str = "2025-datacenter-azure-edition"
    dc_data_disk_size_gb: int = 64
    dc_hybrid_benefit: bool = False
    identity_admin_source_cidrs: list[str] = field(default_factory=list)
    identity_allow_hub_bastion: bool = True
    identity_dns_servers: list[str] = field(default_factory=list)
    identity_key_vault_allowed_ips: list[str] = field(default_factory=list)
    identity_backup_storage_mode: str = "ZoneRedundant"

    # --- operations / cost --------------------------------------------------
    log_retention_days: int = 90
    log_daily_quota_gb: float = -1
    enable_flow_logs: bool = True
    flow_log_retention_days: int = 30
    alert_email_addresses: list[str] = field(default_factory=list)
    monthly_budget_amount: float = 0

    # --- compliance (designer helper) ---------------------------------------
    frameworks: list[str] = field(default_factory=lambda: ["WAF"])

    # ------------------------------------------------------------------ helpers
    @property
    def region(self):
        return REGIONS.get(self.location)

    def derive_addresses(self) -> None:
        """Lay out every address space from `network_base` (a /16).

        hub .0/24 · shared .1/24 · prod .2/24 · avd .3/24 · identity .4/24,
        and each additional identity region takes the next /16.
        """
        try:
            base = ipaddress.IPv4Network(self.network_base, strict=False)
        except ValueError:
            return
        if base.prefixlen > 16:
            return
        base = ipaddress.IPv4Network((int(base.network_address), 16))
        o = str(base.network_address).split(".")

        def net(third: int, b=base) -> str:
            p = str(b.network_address).split(".")
            return f"{p[0]}.{p[1]}.{third}.0/24"

        self.hub_address_space = net(0)
        self.spoke_address_space = net(1)
        self.prod_address_space = net(2)
        self.avd_address_space = net(3)
        for i, r in enumerate(self.identity_regions):
            region_base = ipaddress.IPv4Network((int(base.network_address) + i * 65536, 16))
            r.address_space = net(4, region_base)
        self.network_base = f"{o[0]}.{o[1]}.0.0/16"

    def apply_resilience(self, preset_key: str) -> None:
        preset = RESILIENCE_PRESETS.get(preset_key)
        if not preset:
            self.resilience = "custom"
            return
        self.resilience = preset_key
        self.nva_zones = list(preset.nva_zones)
        for r in self.identity_regions:
            r.dc_zones = list(preset.dc_zones)
        self.identity_backup_storage_mode = preset.backup_mode

    def matching_preset(self) -> str:
        """The preset whose settings the config currently matches, else 'custom'."""
        for key, p in RESILIENCE_PRESETS.items():
            if (sorted(self.nva_zones) == sorted(p.nva_zones)
                    and all(sorted(r.dc_zones) == sorted(p.dc_zones) for r in self.identity_regions)
                    and self.identity_backup_storage_mode == p.backup_mode):
                return key
        return "custom"

    def set_primary_location(self, location: str) -> None:
        """Change the primary region and keep identity regions sensible."""
        self.location = location
        if self.identity_regions:
            self.identity_regions[0].location = location
        if len(self.identity_regions) > 1 and self.identity_regions[1].location == location:
            self.identity_regions[1].location = REGIONS[location].secondary

    def add_identity_region(self) -> None:
        used = {r.location for r in self.identity_regions}
        candidates = [n for n in REGIONS if n not in used]
        if not candidates:
            return
        preferred = REGIONS[self.location].secondary
        loc = preferred if preferred in candidates else candidates[0]
        key = f"region{len(self.identity_regions) + 1}"
        self.identity_regions.append(IdentityRegion(key, loc, "", list(self.identity_regions[0].dc_zones)))
        if self.auto_addressing:
            self.derive_addresses()

    def remove_identity_region(self, key: str) -> None:
        if len(self.identity_regions) > 2:
            self.identity_regions = [r for r in self.identity_regions if r.key != key]
            if self.auto_addressing:
                self.derive_addresses()

    def all_address_spaces(self) -> dict[str, str]:
        spaces = {
            "hub": self.hub_address_space,
            "shared": self.spoke_address_space,
            "prod": self.prod_address_space,
            "avd": self.avd_address_space,
        }
        for r in self.identity_regions:
            spaces[f"identity-{r.key}"] = r.address_space
        return spaces

    # ------------------------------------------------------------------ derived values
    def ilb_ip(self) -> str | None:
        try:
            hub = ipaddress.IPv4Network(self.hub_address_space, strict=False)
            internal = list(hub.subnets(new_prefix=hub.prefixlen + 3))[1]
            return str(internal.network_address + 4)
        except (ValueError, IndexError):
            return None

    def nva_ips(self) -> list[tuple[str, str]]:
        try:
            hub = ipaddress.IPv4Network(self.hub_address_space, strict=False)
            subs = list(hub.subnets(new_prefix=hub.prefixlen + 3))
            return [(str(subs[0].network_address + 4 + i), str(subs[1].network_address + 5 + i))
                    for i in range(len(self.nva_zones))]
        except (ValueError, IndexError):
            return []

    def hub_subnets(self) -> dict[str, str]:
        try:
            hub = ipaddress.IPv4Network(self.hub_address_space, strict=False)
            s = list(hub.subnets(new_prefix=hub.prefixlen + 3))
            return {"nva_external": str(s[0]), "nva_internal": str(s[1]), "mgmt": str(s[2]), "bastion": str(s[3])}
        except (ValueError, IndexError):
            return {}

    @staticmethod
    def dc_subnet(address_space: str) -> str | None:
        try:
            n = ipaddress.IPv4Network(address_space, strict=False)
            return str(next(n.subnets(new_prefix=n.prefixlen + 3)))
        except (ValueError, StopIteration):
            return None

    def dc_ips(self, region: IdentityRegion) -> list[str]:
        sn = self.dc_subnet(region.address_space)
        if not sn:
            return []
        base = ipaddress.IPv4Network(sn).network_address
        return [str(base + 4 + i) for i in range(len(region.dc_zones))]

    # ------------------------------------------------------------------ persistence
    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)

    @classmethod
    def from_json(cls, text: str) -> "LandingZoneConfig":
        data = json.loads(text)
        known = {f.name for f in fields(cls)}
        data = {k: v for k, v in data.items() if k in known}
        regions = [IdentityRegion(**r) for r in data.pop("identity_regions", [])]
        cfg = cls(**data)
        if regions:
            cfg.identity_regions = regions
        return cfg
