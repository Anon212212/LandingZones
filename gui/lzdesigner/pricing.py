"""Monthly cost estimate for a LandingZoneConfig.

Two sources:

* BASELINE – bundled approximate pay-as-you-go list prices (USD, typical
  European region). Good enough to compare options; not a quote.
* live     – `refresh_live_prices()` queries the public Azure Retail Prices
  API (https://prices.azure.com, no sign-in) for the VM sizes and regions
  in the design, in the chosen currency, and overrides the VM rates.

Usage-based charges (data processed, egress, peering traffic) depend on
traffic and are estimated from editable assumptions (`UsageAssumptions`).
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

from .model import LandingZoneConfig

HOURS = 730

BASELINE_NOTE = ("Approximate pay-as-you-go list prices in USD for a typical European region, bundled with the "
                 "designer. Use 'Refresh live prices' for current VM prices in your regions and currency.")

# Hourly VM rates (Linux = compute only; Windows includes the licence).
BASELINE_VM_HOURLY = {
    "Standard_D2s_v5": {"linux": 0.107, "windows": 0.199},
    "Standard_D4s_v5": {"linux": 0.214, "windows": 0.398},
    "Standard_D8s_v5": {"linux": 0.428, "windows": 0.796},
}

BASELINE = {
    "bastion_hourly": {"Basic": 0.19, "Standard": 0.29, "Premium": 0.45},
    "nat_gateway_hourly": 0.045,
    "nat_gateway_per_gb": 0.045,
    "public_ip_hourly": 0.005,
    "lb_first5_rules_hourly": 0.025,
    "disk_standardssd_e4": 2.40,      # 32 GB, NVA OS disk
    "disk_premium_p10": 19.71,        # 128 GB, DC OS disk
    "disk_premium_per_gb": 0.135,     # NTDS data disk, approximated per GB
    "law_per_gb": 2.76,               # Analytics logs ingestion
    "law_retention_per_gb_month": 0.10,  # beyond the 31 included days
    "flow_logs_per_gb": 0.50,
    "traffic_analytics_per_gb": 2.30,
    "backup_instance_50_500gb": 10.0,  # protected instance fee per VM
    "backup_storage_per_gb": {"ZoneRedundant": 0.028, "GeoRedundant": 0.045},
    "ddos_plan_month": 2944.0,
    "key_vault_premium_month": 5.0,   # operations + HSM-backed keys, rough
    "monitor_alerts_month": 5.0,
    "storage_flowlogs_month": 10.0,
}


@dataclass
class UsageAssumptions:
    platform_logs_gb_day: float = 2.0
    tier0_logs_gb_day: float = 1.0
    flow_logs_gb_day: float = 1.0
    nat_egress_gb_month: float = 100.0
    backup_gb_per_dc: float = 60.0


@dataclass
class Line:
    category: str
    item: str
    qty: str
    monthly: float
    usage_based: bool = False


@dataclass
class Estimate:
    currency: str
    lines: list[Line]
    source: str
    notes: list[str] = field(default_factory=list)

    @property
    def total(self) -> float:
        return round(sum(line.monthly for line in self.lines), 2)

    @property
    def fixed(self) -> float:
        return round(sum(line.monthly for line in self.lines if not line.usage_based), 2)

    def by_category(self) -> dict[str, float]:
        out: dict[str, float] = {}
        for line in self.lines:
            out[line.category] = round(out.get(line.category, 0) + line.monthly, 2)
        return dict(sorted(out.items(), key=lambda kv: -kv[1]))


@dataclass
class PriceBook:
    """VM hourly rates keyed by (region, size, os). Falls back to BASELINE."""
    currency: str = "USD"
    vm: dict[tuple[str, str, str], float] = field(default_factory=dict)
    live: bool = False
    fx: float = 1.0  # multiplier applied to non-VM baseline items in non-USD currencies

    def vm_hourly(self, region: str, size: str, os_: str) -> float:
        if (region, size, os_) in self.vm:
            return self.vm[(region, size, os_)]
        base = BASELINE_VM_HOURLY.get(size)
        if base:
            return base[os_] * self.fx
        vcpus = int("".join(ch for ch in size.split("_")[1] if ch.isdigit()) or 2)  # crude fallback
        return BASELINE_VM_HOURLY["Standard_D2s_v5"][os_] * vcpus / 2 * self.fx

    def price(self, key: str, sub: str | None = None) -> float:
        v = BASELINE[key]
        if isinstance(v, dict):
            v = v[sub]
        return v * self.fx


def estimate(cfg: LandingZoneConfig, book: PriceBook | None = None,
             usage: UsageAssumptions | None = None) -> Estimate:
    book = book or PriceBook()
    u = usage or UsageAssumptions()
    lines: list[Line] = []

    def add(cat, item, qty, monthly, usage_based=False):
        lines.append(Line(cat, item, qty, round(monthly, 2), usage_based))

    # --- connectivity -----------------------------------------------------
    n_nva = len(cfg.nva_zones)
    add("Compute", f"NVA VMs ({cfg.nva_size.replace('Standard_', '')}, Linux)", f"{n_nva} × {HOURS} h",
        n_nva * HOURS * book.vm_hourly(cfg.location, cfg.nva_size, "linux"))
    add("Storage", "NVA OS disks (StandardSSD E4)", f"{n_nva}", n_nva * book.price("disk_standardssd_e4"))
    add("Networking", "Internal Load Balancer (Standard, HA Ports)", "1", HOURS * book.price("lb_first5_rules_hourly"))
    add("Networking", f"Azure Bastion ({cfg.bastion_sku})", "1",
        HOURS * book.price("bastion_hourly", cfg.bastion_sku) + HOURS * book.price("public_ip_hourly"))
    if cfg.enable_nat_gateway:
        add("Networking", "NAT Gateway + public IP", "1",
            HOURS * (book.price("nat_gateway_hourly") + book.price("public_ip_hourly")))
        add("Networking", "NAT Gateway data processed", f"{u.nat_egress_gb_month:.0f} GB",
            u.nat_egress_gb_month * book.price("nat_gateway_per_gb"), usage_based=True)
    if cfg.ddos_protection_plan_id:
        add("Security", "DDoS Network Protection plan", "1 (shared across the tenant)", book.price("ddos_plan_month"))

    # --- identity ---------------------------------------------------------
    os_ = "linux" if cfg.dc_hybrid_benefit else "windows"
    for r in cfg.identity_regions:
        n = len(r.dc_zones)
        label = "Hybrid Benefit" if cfg.dc_hybrid_benefit else "Windows licence incl."
        add("Compute", f"DC VMs {r.key} ({cfg.dc_size.replace('Standard_', '')}, {label})", f"{n} × {HOURS} h",
            n * HOURS * book.vm_hourly(r.location, cfg.dc_size, os_))
        add("Storage", f"DC disks {r.key} (P10 OS + {cfg.dc_data_disk_size_gb} GB NTDS)", f"{n}",
            n * (book.price("disk_premium_p10") + cfg.dc_data_disk_size_gb * book.price("disk_premium_per_gb")))
        add("Backup", f"Recovery Services vault {r.key} – protected instances", f"{n}",
            n * book.price("backup_instance_50_500gb"))
        add("Backup", f"Recovery Services vault {r.key} – {cfg.identity_backup_storage_mode} storage",
            f"{n * u.backup_gb_per_dc:.0f} GB",
            n * u.backup_gb_per_dc * book.price("backup_storage_per_gb", cfg.identity_backup_storage_mode),
            usage_based=True)
    add("Security", "Tier-0 Key Vault (premium)", "1", book.price("key_vault_premium_month"))

    # --- monitoring -------------------------------------------------------
    platform_gb = u.platform_logs_gb_day * 30
    tier0_gb = u.tier0_logs_gb_day * 30
    add("Monitoring", "Log Analytics ingestion – platform", f"{platform_gb:.0f} GB",
        platform_gb * book.price("law_per_gb"), usage_based=True)
    add("Monitoring", "Log Analytics ingestion – tier-0", f"{tier0_gb:.0f} GB",
        tier0_gb * book.price("law_per_gb"), usage_based=True)
    extra_platform_months = max(cfg.log_retention_days - 31, 0) / 30
    extra_tier0_months = max(max(cfg.log_retention_days, 365) - 31, 0) / 30
    add("Monitoring", f"Log retention beyond 31 days ({cfg.log_retention_days} d platform, "
                      f"{max(cfg.log_retention_days, 365)} d tier-0)", "steady state",
        (platform_gb * extra_platform_months + tier0_gb * extra_tier0_months) * book.price("law_retention_per_gb_month"),
        usage_based=True)
    if cfg.enable_flow_logs:
        fl_gb = u.flow_logs_gb_day * 30
        add("Monitoring", "VNet flow logs + Traffic Analytics", f"{fl_gb:.0f} GB",
            fl_gb * (book.price("flow_logs_per_gb") + book.price("traffic_analytics_per_gb")), usage_based=True)
        add("Storage", "Flow-log storage accounts", f"{1 + len(cfg.identity_regions)}",
            (1 + len(cfg.identity_regions)) * book.price("storage_flowlogs_month") / 2)
    add("Monitoring", "Alert rules", "~10", book.price("monitor_alerts_month"))

    notes = [BASELINE_NOTE if not book.live else
             f"VM prices are live from the Azure Retail Prices API ({book.currency}); other items use the bundled baseline."]
    notes.append("Excludes VNet peering and Internet egress traffic, workload VMs in the spokes, taxes and discounts "
                 "(reservations, savings plans, EA/CSP pricing).")
    if cfg.ddos_protection_plan_id:
        notes.append("A DDoS Network Protection plan is usually shared across many VNets in the tenant.")
    return Estimate(book.currency, lines, "live" if book.live else "baseline", notes)


# ---------------------------------------------------------------- live prices
RETAIL_API = "https://prices.azure.com/api/retail/prices"


def _query(filter_: str, currency: str, opener=urllib.request.urlopen) -> list[dict]:
    items, url = [], f"{RETAIL_API}?currencyCode={currency}&$filter={urllib.parse.quote(filter_)}"
    while url:
        with opener(url, timeout=20) as resp:
            data = json.loads(resp.read())
        items += data.get("Items", [])
        url = data.get("NextPageLink")
    return items


def pick_vm_rate(items: list[dict], os_: str) -> float | None:
    """Choose the plain pay-as-you-go hourly rate for Linux or Windows."""
    candidates = []
    for it in items:
        name = f"{it.get('productName', '')} {it.get('skuName', '')} {it.get('meterName', '')}"
        if it.get("type") != "Consumption" or it.get("unitOfMeasure") != "1 Hour":
            continue
        if any(x in name for x in ("Spot", "Low Priority", "Cloud Services", "DevTest")):
            continue
        is_windows = "Windows" in it.get("productName", "")
        if (os_ == "windows") != is_windows:
            continue
        candidates.append(float(it["retailPrice"]))
    return min(candidates) if candidates else None


def refresh_live_prices(cfg: LandingZoneConfig, currency: str = "USD", opener=urllib.request.urlopen) -> PriceBook:
    """Fetch VM rates for the design's sizes/regions. Raises on network errors."""
    book = PriceBook(currency=currency, live=True)
    wanted = {(cfg.location, cfg.nva_size, "linux")}
    for r in cfg.identity_regions:
        wanted.add((r.location, cfg.dc_size, "linux" if cfg.dc_hybrid_benefit else "windows"))
    usd_ref = None
    for region, size, os_ in sorted(wanted):
        items = _query(f"serviceName eq 'Virtual Machines' and armRegionName eq '{region}' "
                       f"and armSkuName eq '{size}' and priceType eq 'Consumption'", currency, opener)
        rate = pick_vm_rate(items, os_)
        if rate is not None:
            book.vm[(region, size, os_)] = rate
            base = BASELINE_VM_HOURLY.get(size, {}).get(os_)
            if base and usd_ref is None:
                usd_ref = rate / base
    if currency != "USD" and usd_ref:
        book.fx = usd_ref   # scale the non-VM baseline items roughly into the chosen currency
    return book
