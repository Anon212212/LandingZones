"""Landing Zone Designer – a simple front end for the Terraform landing zone.

Run:  python gui/app.py            (opens http://localhost:8080)
      python gui/app.py --native   (desktop window, needs `pip install pywebview`)

Users pick options from dropdowns, switches and presets; the app keeps a live
architecture diagram, validates inputs, enforces the WAF / NIS2 / DORA
baseline, and writes terraform.tfvars for the Terraform in the repo root.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from nicegui import events, run, ui

sys.path.insert(0, str(Path(__file__).parent))

from lzdesigner import azure, compliance, diagram, pricing, tfvars  # noqa: E402
from lzdesigner.catalog import (BACKUP_MODES, BASTION_SKUS, DC_IMAGES, ENVIRONMENTS,  # noqa: E402
                                NVA_HA_MODES, NVA_VENDOR_SIZES, NVA_VENDORS, REGIONS, RESILIENCE_PRESETS,
                                VM_SIZES)
from lzdesigner.model import SPOKE_SUBSCRIPTIONS, LandingZoneConfig  # noqa: E402
from lzdesigner.validation import validate  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
ALL_NVA_SIZES = {**{v: k for k, v in VM_SIZES.items()}, **{v: k for k, v in NVA_VENDOR_SIZES.items()}}
SUBSCRIPTION_FIELDS = [
    ("subscription_id", "Connectivity subscription"),
    ("identity_subscription_id", "Identity (tier-0) subscription"),
    ("shared_services_subscription_id", "Shared services subscription"),
    ("production_subscription_id", "Production subscription"),
    ("avd_subscription_id", "Azure Virtual Desktop subscription"),
]
ZONES = ["1", "2", "3"]
REGION_OPTIONS = {k: f"{r.display}  ·  {k}" for k, r in REGIONS.items()}
STATUS_ICON = {
    compliance.PASS: ("check_circle", "positive"),
    compliance.BUILTIN: ("verified", "positive"),
    compliance.WARN: ("error_outline", "warning"),
    compliance.FAIL: ("cancel", "negative"),
}

CSS = """
body { background: #F5F6F8; }
.lz-card { border-radius: 14px; box-shadow: 0 1px 2px rgba(0,0,0,.06), 0 2px 8px rgba(0,0,0,.04); }
.lz-diagram svg { width: 100%; height: auto; display: block; }
.lz-section { font-size: 12px; letter-spacing: .06em; text-transform: uppercase; color: #605E5C; font-weight: 600; margin-top: 8px; }
.lz-hint { font-size: 12px; color: #605E5C; }
.lz-lock { font-size: 12px; color: #8764B8; }
.q-tab__label { font-weight: 600; font-size: 11.5px; }
.lz-tabs .q-tab { padding: 0 5px; min-width: 0; }
"""


def parse_list(text: str) -> list[str]:
    return [x.strip() for x in (text or "").replace("\n", ",").split(",") if x.strip()]


def join_list(values: list[str]) -> str:
    return ", ".join(values or [])


class Designer:
    def __init__(self) -> None:
        self.cfg = LandingZoneConfig()
        self.cfg.derive_addresses()
        self.locks: dict[str, ui.label] = {}
        self.lockable: dict[str, ui.element] = {}
        # Azure (optional)
        self.arm = None  # azure.ArmClient (or the demo tenant)
        self.account: dict | None = None
        self.subscriptions: list[dict] = []
        self.preflight: list[azure.Check] | None = None
        self.preflight_stale = False
        self.preflight_running = False
        self.device_message = ""
        # Pricing
        self.price_book = pricing.PriceBook()

    # ------------------------------------------------------------------ helpers
    def changed(self, *_):
        """Re-derive, enforce the compliance baseline, refresh the views."""
        cfg = self.cfg
        if cfg.auto_addressing:
            cfg.derive_addresses()
        compliance.enforce(cfg)
        preset = cfg.matching_preset()
        if preset != cfg.resilience:
            cfg.resilience = preset
            self.resilience_cards.refresh()
        locks = compliance.locked_fields(cfg)
        for fld, el in self.lockable.items():
            reason = locks.get(fld)
            el.set_enabled(reason is None)
            lbl = self.locks.get(fld)
            if lbl:
                lbl.set_text(f"🔒 {reason}" if reason else "")
                lbl.set_visibility(reason is not None)
        self.address_table.refresh()
        self.cost_view.refresh()
        if self.preflight is not None and not self.preflight_stale:
            self.preflight_stale = True
            self.azure_view.refresh()
        self.diagram_view.refresh()
        self.status_view.refresh()
        self.export_view.refresh()
        self.compliance_view.refresh()

    def lock(self, fld: str, element: ui.element) -> ui.element:
        self.lockable[fld] = element
        self.locks[fld] = ui.label("").classes("lz-lock").style("margin-top:-6px")
        self.locks[fld].set_visibility(False)
        return element

    @staticmethod
    def section(title: str) -> None:
        ui.label(title).classes("lz-section")

    # ------------------------------------------------------------------ layout
    def build(self) -> None:
        ui.add_css(CSS)
        ui.colors(primary="#0F6CBD", secondary="#5C2D91", accent="#038387", positive="#107C10",
                  negative="#C50F1F", warning="#BC4B09")

        with ui.header().classes("items-center bg-white text-black q-px-lg").style("border-bottom:1px solid #E1DFDD"):
            ui.icon("hub", size="28px").classes("text-primary")
            with ui.column().classes("gap-0"):
                ui.label("Landing Zone Designer").classes("text-lg font-semibold")
                ui.label("Azure hub & spoke · firewall NVAs · tier-0 identity — governed by WAF, NIS2 & DORA guardrails"
                         ).classes("text-xs text-grey-7")
            ui.space()
            self.account_view()
            ui.button("Load project", icon="upload_file", on_click=self.open_upload).props("flat no-caps")
            ui.button("Export", icon="download", on_click=lambda: self.tabs.set_value("Export")).props("unelevated no-caps")

        with ui.row().classes("w-full no-wrap q-pa-md gap-4 items-start"):
            with ui.card().classes("lz-card").style("width: 560px; min-width: 520px"):
                self.build_tabs()
            with ui.column().classes("grow gap-4").style("min-width: 0"):
                with ui.card().classes("lz-card w-full"):
                    self.status_view()
                with ui.row().classes("w-full no-wrap gap-4 items-stretch"):
                    with ui.card().classes("lz-card").style("flex: 1 1 0; min-width: 0"):
                        self.cost_view()
                    with ui.card().classes("lz-card").style("flex: 1 1 0; min-width: 0"):
                        self.azure_view()
                with ui.card().classes("lz-card w-full q-pa-sm"):
                    self.diagram_view()

        self.changed()

    def build_tabs(self) -> None:
        names = [("Basics", "badge"), ("Network", "lan"), ("Firewall", "local_fire_department"), ("Resilience", "shield"),
                 ("Identity", "admin_panel_settings"),
                 ("Security", "lock"), ("Operations", "monitor_heart"), ("Compliance", "gavel"), ("Export", "ios_share")]
        with ui.tabs().props("dense no-caps").classes("w-full lz-tabs") as self.tabs:
            for n, icon in names:
                ui.tab(n, icon=icon)
        with ui.tab_panels(self.tabs, value="Basics").classes("w-full").style("max-height: calc(100vh - 150px); overflow:auto"):
            with ui.tab_panel("Basics"):
                self.tab_basics()
            with ui.tab_panel("Network"):
                self.tab_network()
            with ui.tab_panel("Firewall"):
                self.firewall_view()
            with ui.tab_panel("Resilience"):
                self.tab_resilience()
            with ui.tab_panel("Identity"):
                self.tab_identity()
            with ui.tab_panel("Security"):
                self.tab_security()
            with ui.tab_panel("Operations"):
                self.tab_operations()
            with ui.tab_panel("Compliance"):
                self.compliance_view()
            with ui.tab_panel("Export"):
                self.export_view()

    # ------------------------------------------------------------------ tabs
    def tab_basics(self) -> None:
        c = self.cfg
        self.section("Organisation")
        with ui.row().classes("w-full no-wrap"):
            ui.input("Org prefix", placeholder="contoso").bind_value(c, "org_prefix").on_value_change(self.changed) \
                .props("outlined dense hint='2–15 lowercase chars'").classes("grow")
            ui.select(ENVIRONMENTS, label="Environment").bind_value(c, "environment").on_value_change(self.changed) \
                .props("outlined dense").classes("w-40")
        with ui.row().classes("w-full no-wrap"):
            ui.input("Owner (team or email)").bind_value(c, "owner").on_value_change(self.changed).props("outlined dense").classes("grow")
            ui.input("Cost centre").bind_value(c, "cost_center").on_value_change(self.changed).props("outlined dense").classes("w-40")
        self.section("Region")
        ui.select(REGION_OPTIONS, label="Primary region", value=c.location,
                  on_change=lambda e: (c.set_primary_location(e.value), self.identity_regions_view.refresh(), self.changed())) \
            .props("outlined dense").classes("w-full")
        ui.label("Only regions with Availability Zones are offered.").classes("lz-hint")
        self.section("Subscriptions")
        self.subscription_fields()
        self.section("Extra tags")
        ui.input("key=value, key=value", value=", ".join(f"{k}={v}" for k, v in c.tags.items()),
                 on_change=lambda e: (setattr(c, "tags", {p.split("=", 1)[0].strip(): p.split("=", 1)[1].strip()
                                                           for p in parse_list(e.value) if "=" in p}), self.changed())) \
            .props("outlined dense").classes("w-full")
        ui.label("environment, owner, cost-center, workload and managed-by are always added.").classes("lz-hint")

    def tab_network(self) -> None:
        c = self.cfg
        self.section("Address plan")
        ui.switch("Plan addresses automatically from one /16").bind_value(c, "auto_addressing").on_value_change(
            lambda: (self.manual_addresses.refresh(), self.spokes_view.refresh(), self.changed()))
        ui.input("Base network (/16)", placeholder="10.145.0.0/16").bind_value(c, "network_base") \
            .bind_enabled_from(c, "auto_addressing").on_value_change(self.changed).props("outlined dense").classes("w-full")
        self.manual_addresses()
        self.section("Workload spokes")
        ui.label("Each spoke gets its own VNet, NSG (baseline + your rules), route to the NVAs and hub peering.") \
            .classes("lz-hint")
        self.spokes_view()
        self.address_table()
        self.section("Egress")
        self.lock("enable_nat_gateway", ui.switch("NAT Gateway for Internet egress").bind_value(c, "enable_nat_gateway")
                  .on_value_change(self.changed))
        ui.label("Gives the NVAs a fixed public egress IP. Azure default outbound access is retired.").classes("lz-hint")

    @ui.refreshable
    def manual_addresses(self) -> None:
        c = self.cfg
        if c.auto_addressing:
            return
        ui.input("Hub (/24 or larger)").bind_value(c, "hub_address_space").on_value_change(self.changed) \
            .props("outlined dense").classes("w-full")
        ui.label("Spoke address spaces are set on each spoke below; identity ones per region on the Identity tab.") \
            .classes("lz-hint")

    @ui.refreshable
    def spokes_view(self) -> None:
        c = self.cfg
        for sp in c.spokes:
            with ui.card().tight().classes("w-full q-pa-sm").style("border:1px solid #E1DFDD; border-radius:10px"):
                with ui.row().classes("w-full no-wrap items-center"):
                    ui.input("Name").bind_value(sp, "key", forward=lambda v: (v or "").strip().lower()) \
                        .on_value_change(self.changed).props("outlined dense").classes("w-32")
                    ui.input("Label (diagram)").bind_value(sp, "description").on_value_change(self.changed) \
                        .props("outlined dense").classes("grow")
                    ui.button(icon="delete", on_click=lambda s_=sp: (c.remove_spoke(s_.key), self.spokes_view.refresh(),
                                                                        self.changed())).props("flat dense round") \
                        .tooltip("Remove spoke")
                ui.select(SPOKE_SUBSCRIPTIONS, label="Subscription").bind_value(sp, "subscription") \
                    .on_value_change(lambda: (self.subscription_fields.refresh(), self.changed())) \
                    .props("outlined dense").classes("w-full")
                with ui.row().classes("w-full no-wrap items-center"):
                    if c.auto_addressing:
                        ui.label().bind_text_from(sp, "key", backward=lambda _, s_=sp: f"{s_.address_space} · {s_.effective_subnet_name}") \
                            .classes("lz-hint grow")
                    else:
                        ui.input("Address space").bind_value(sp, "address_space").on_value_change(self.changed) \
                            .props("outlined dense").classes("grow")
                    n = len(sp.nsg_rules)
                    ui.button(f"NSG rules ({n})", icon="rule", on_click=lambda s_=sp: self.edit_rules(s_)) \
                        .props("flat dense no-caps")
        ui.button("Add spoke", icon="add", on_click=lambda: (c.add_spoke(), self.spokes_view.refresh(), self.changed())) \
            .props("flat no-caps")

    def edit_rules(self, spoke) -> None:
        from lzdesigner.model import NsgRule

        @ui.refreshable
        def rows():
            if not spoke.nsg_rules:
                ui.label("No custom rules – the baseline allows Bastion (SSH/RDP) and VNet traffic in, "
                         "and denies everything else.").classes("lz-hint")
            for r in spoke.nsg_rules:
                with ui.row().classes("w-full no-wrap items-center gap-2"):
                    ui.input("Name").bind_value(r, "name").on_value_change(self.changed).props("outlined dense").classes("w-40")
                    ui.number("Priority", min=300, max=3900, step=10).bind_value(r, "priority", forward=lambda v: int(v or 300)) \
                        .on_value_change(self.changed).props("outlined dense").classes("w-24")
                    ui.select(["Inbound", "Outbound"], label="Direction").bind_value(r, "direction") \
                        .on_value_change(self.changed).props("outlined dense").classes("w-28")
                    ui.select(["Allow", "Deny"], label="Access").bind_value(r, "access") \
                        .on_value_change(self.changed).props("outlined dense").classes("w-24")
                    ui.select(["Tcp", "Udp", "Icmp", "*"], label="Protocol").bind_value(r, "protocol") \
                        .on_value_change(self.changed).props("outlined dense").classes("w-24")
                    ui.input("Sources (CIDR / tag)").bind_value(r, "source_address_prefixes", forward=parse_list,
                                                               backward=join_list) \
                        .on_value_change(self.changed).props("outlined dense").classes("grow")
                    ui.input("Ports").bind_value(r, "destination_port_ranges", forward=parse_list, backward=join_list) \
                        .on_value_change(self.changed).props("outlined dense").classes("w-28")
                    ui.button(icon="delete", on_click=lambda r_=r: (spoke.nsg_rules.remove(r_), rows.refresh(),
                                                                    self.changed())).props("flat dense round")

        def add_rule():
            used = {r.priority for r in spoke.nsg_rules}
            prio = next(p for p in range(300, 3901, 10) if p not in used)
            spoke.nsg_rules.append(NsgRule(f"Allow-{prio}", prio, [self.cfg.hub_address_space], ["443"]))
            rows.refresh()
            self.changed()

        with ui.dialog() as dlg, ui.card().style("min-width: 1000px"):
            ui.label(f"NSG rules – spoke '{spoke.key}'").classes("text-lg font-semibold")
            ui.label("Priorities 300–3900 sit between the baseline allows (100, 200) and the deny-all (4096). "
                     "Inbound rules from the Internet are rejected.").classes("lz-hint")
            rows()
            with ui.row():
                ui.button("Add rule", icon="add", on_click=add_rule).props("flat no-caps")
                ui.space()
                ui.button("Done", on_click=lambda: (dlg.close(), self.spokes_view.refresh())).props("unelevated")
        dlg.open()

    @ui.refreshable
    def address_table(self) -> None:
        c = self.cfg
        rows = [{"name": k, "cidr": v} for k, v in c.all_address_spaces().items()]
        hs = c.hub_subnets()
        rows += [{"name": f"hub · {k}", "cidr": v} for k, v in hs.items()]
        rows.append({"name": "ILB frontend (next hop)", "cidr": c.ilb_ip() or "?"})
        ui.table(columns=[{"name": "name", "label": "Network", "field": "name", "align": "left"},
                          {"name": "cidr", "label": "Address", "field": "cidr", "align": "left"}],
                 rows=rows, row_key="name").props("dense flat bordered").classes("w-full q-mt-sm")

    def tab_resilience(self) -> None:
        c = self.cfg
        self.section("Resilience level")
        with ui.column().classes("w-full gap-2"):
            self.resilience_cards()
        self.section("Fine-tune")
        ui.select(ZONES, multiple=True, label="NVA zones (one NVA per zone)").bind_value(c, "nva_zones") \
            .on_value_change(self.changed) \
            .props("outlined dense use-chips").classes("w-full")
        ui.select(ZONES, multiple=True, label="Zones for ILB, Bastion and public IPs").bind_value(c, "zones") \
            .on_value_change(self.changed).props("outlined dense use-chips").classes("w-full")
        ui.select(ALL_NVA_SIZES, label="Firewall / NVA size").bind_value(c, "nva_size") \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")
        self.lock("enable_resource_locks", ui.switch("Delete locks on critical resources")
                  .bind_value(c, "enable_resource_locks").on_value_change(self.changed))

    @ui.refreshable
    def firewall_view(self) -> None:
        c = self.cfg
        v = c.vendor
        ui.label("Choose the firewall that inspects all spoke, east-west and Internet traffic in the hub. "
                 "The rest of the landing zone (subnets, routing, NSGs, NAT Gateway) adapts automatically.") \
            .classes("lz-hint")
        self.section("Appliance")
        ui.select({k: x.label for k, x in NVA_VENDORS.items()}, label="Firewall vendor", value=c.nva_vendor,
                  on_change=lambda e: (c.set_nva_vendor(e.value), self.firewall_view.refresh(), self.changed())) \
            .props("outlined dense").classes("w-full")
        ui.select({m: NVA_HA_MODES[m] for m in v.ha_modes}, label="High availability", value=c.nva_ha_mode,
                  on_change=lambda e: (setattr(c, "nva_ha_mode", e.value), self.firewall_view.refresh(), self.changed())) \
            .props("outlined dense").classes("w-full").set_enabled(len(v.ha_modes) > 1)
        if v.licenses:
            lic_opts = {"": f"Vendor default ({v.licenses[v.default_license]})", **v.licenses}
            ui.select(lic_opts, label="Licence", value=c.nva_license_type,
                      on_change=lambda e: (setattr(c, "nva_license_type", e.value or ""), self.firewall_view.refresh(),
                                           self.changed())).props("outlined dense").classes("w-full")
            sizes = {val: lbl for lbl, val in NVA_VENDOR_SIZES.items()}
            if c.nva_size not in sizes:
                sizes[c.nva_size] = c.nva_size
            ui.select(sizes, label="VM size (>= 4 vCPUs for accelerated networking)", value=c.nva_size,
                      on_change=lambda e: (setattr(c, "nva_size", e.value), self.changed())) \
                .props("outlined dense").classes("w-full")
            ui.switch("Accept Marketplace terms in the connectivity subscription",
                      value=c.nva_accept_marketplace_terms,
                      on_change=lambda e: (setattr(c, "nva_accept_marketplace_terms", e.value), self.changed()))
        self.section("What you get")
        mode_text = {
            "active-active": f"{c.nva_count()} firewalls (one per NVA zone) behind the internal load balancer. "
                             f"Spokes route 0.0.0.0/0 to the ILB frontend {c.ilb_ip()}.",
            "active-standby": "2 firewalls across zones, no load balancer. Spokes route to the floating trust VIP "
                              f"{c.nva_next_hop()}; on failover the firewalls move it via the Azure API "
                              "(managed identity with a least-privilege role). Adds an HA sync subnet.",
            "single": f"1 firewall, no high availability. Spokes route to its trust IP {c.nva_next_hop()}.",
        }[c.nva_ha_mode]
        nic = v.nic_layout.get(c.nva_ha_mode, v.nic_layout.get("*", ""))
        with ui.card().tight().classes("w-full q-pa-md").style("border:1px solid #E1DFDD; border-radius:10px"):
            for icon, title, text in [
                ("dns", "Appliance", f"{v.product}" + (f" · {v.publisher}/{v.offer}" if v.publisher else "")),
                ("alt_route", "Routing", mode_text),
                ("settings_ethernet", "NICs", nic),
                ("admin_panel_settings", "Management", f"{v.management} · LB probe port {v.probe_port}"),
                ("key", "Admin password",
                 "SSH key (Security tab)" if c.nva_vendor == "linux" else
                 "Generated and stored in the connectivity Key Vault – no pipeline secret needed"),
                ("receipt_long", "Licence",
                 "–" if not v.licenses else v.licenses[c.effective_license]),
                ("info", "Notes", v.notes),
            ]:
                with ui.row().classes("w-full no-wrap items-start gap-3 q-py-xs"):
                    ui.icon(icon, color="primary", size="20px")
                    with ui.column().classes("gap-0"):
                        ui.label(title).classes("text-sm font-semibold")
                        ui.label(text).classes("lz-hint")

    @ui.refreshable
    def resilience_cards(self) -> None:
        c = self.cfg
        for key, p in RESILIENCE_PRESETS.items():
            selected = c.resilience == key
            with ui.card().tight().classes("w-full cursor-pointer q-pa-md").style(
                    f"border: 2px solid {'#0F6CBD' if selected else '#E1DFDD'}; border-radius: 12px;"
                    f"background: {'#F2F8FD' if selected else 'white'}") \
                    .on("click", lambda k=key: (c.apply_resilience(k), self.resilience_cards.refresh(),
                                                 self.identity_regions_view.refresh(), self.changed())):
                with ui.row().classes("items-center no-wrap"):
                    ui.icon("radio_button_checked" if selected else "radio_button_unchecked", color="primary")
                    with ui.column().classes("gap-0"):
                        ui.label(p.label).classes("font-semibold")
                        ui.label(p.description).classes("lz-hint")
        if c.resilience == "custom":
            ui.label("Custom – you've adjusted individual settings.").classes("lz-hint")

    def tab_identity(self) -> None:
        c = self.cfg
        ui.label("Domain controllers are tier-0 and live in their own subscription. Each region gets its own VNet, "
                 "one DC per zone and its own Recovery Services vault.").classes("lz-hint")
        self.section("Regions")
        self.identity_regions_view()
        self.section("Domain controllers")
        with ui.row().classes("w-full no-wrap"):
            ui.select({v: k for k, v in VM_SIZES.items()}, label="DC size").bind_value(c, "dc_size") \
                .on_value_change(self.changed).props("outlined dense").classes("grow")
            ui.number("NTDS disk (GB)", min=32, max=1024, step=32).bind_value(c, "dc_data_disk_size_gb",
                                                                              forward=lambda v: int(v or 64)) \
                .on_value_change(self.changed).props("outlined dense").classes("w-36")
        ui.select({v: k for k, v in DC_IMAGES.items()}, label="Windows Server image").bind_value(c, "dc_image_sku") \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")
        ui.switch("Azure Hybrid Benefit (I own Windows Server licences)").bind_value(c, "dc_hybrid_benefit") \
            .on_value_change(self.changed)
        self.section("Backup")
        self.lock("identity_backup_storage_mode",
                  ui.select({v: k for k, v in BACKUP_MODES.items()}, label="Vault redundancy")
                  .bind_value(c, "identity_backup_storage_mode")
                  .on_value_change(self.changed)
                  .props("outlined dense").classes("w-full"))
        self.section("Tier-0 access")
        ui.switch("Allow RDP to DCs via the shared hub Bastion").bind_value(c, "identity_allow_hub_bastion") \
            .on_value_change(self.changed)
        ui.input("Extra admin networks (PAW CIDRs)").bind_value(c, "identity_admin_source_cidrs", forward=parse_list,
                                                               backward=join_list) \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")
        ui.input("Key Vault allowed IPs (deployment agent)").bind_value(c, "identity_key_vault_allowed_ips",
                                                                       forward=parse_list, backward=join_list) \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")
        self.section("DNS (after promotion)")
        with ui.row().classes("w-full no-wrap items-center"):
            ui.input("Identity VNet DNS servers").bind_value(c, "identity_dns_servers", forward=parse_list,
                                                             backward=join_list) \
                .on_value_change(self.changed).props("outlined dense").classes("grow")
            ui.button("Use DC IPs", on_click=lambda: (setattr(c, "identity_dns_servers",
                                                               [ip for r in c.identity_regions for ip in c.dc_ips(r)]),
                                                       self.changed())).props("flat no-caps")
        ui.label("Leave empty for the build, then switch to the DC IPs once the forest is promoted.").classes("lz-hint")

    @ui.refreshable
    def identity_regions_view(self) -> None:
        c = self.cfg
        for i, r in enumerate(c.identity_regions):
            role = "Primary" if i == 0 else ("Secondary" if i == 1 else "Additional")
            with ui.card().tight().classes("w-full q-pa-sm").style("border:1px solid #E1DFDD; border-radius:10px"):
                with ui.row().classes("w-full items-center no-wrap"):
                    ui.badge(role, color="secondary" if i else "primary")
                    ui.label(r.key).classes("text-grey-7 text-xs")
                    ui.space()
                    if i >= 2:
                        ui.button(icon="delete", on_click=lambda k=r.key: (c.remove_identity_region(k),
                                                                           self.identity_regions_view.refresh(),
                                                                           self.changed())).props("flat dense round")
                with ui.row().classes("w-full no-wrap"):
                    sel = ui.select(REGION_OPTIONS, label="Region").bind_value(r, "location") \
                        .on_value_change(self.changed).props("outlined dense").classes("grow")
                    if i == 0:
                        sel.disable()
                        sel.tooltip("Follows the primary region (Basics)")
                    ui.select(ZONES, multiple=True, label="DC zones").bind_value(r, "dc_zones") \
                        .on_value_change(self.changed).props("outlined dense use-chips").classes("w-40")
                if not c.auto_addressing:
                    ui.input("Address space").bind_value(r, "address_space").on_value_change(self.changed) \
                        .props("outlined dense").classes("w-full")
                else:
                    ui.label(f"Address space {r.address_space} · DCs {', '.join(c.dc_ips(r))}").classes("lz-hint")
        ui.button("Add region", icon="add", on_click=lambda: (c.add_identity_region(), self.identity_regions_view.refresh(),
                                                              self.changed())).props("flat no-caps")

    def tab_security(self) -> None:
        c = self.cfg
        self.section("NVA access")
        ui.input("NVA admin username").bind_value(c, "nva_admin_username").on_value_change(self.changed) \
            .props("outlined dense").classes("w-full")
        ui.textarea("NVA SSH public key", placeholder="ssh-ed25519 AAAA… you@example").bind_value(
            c, "nva_admin_ssh_public_key").on_value_change(self.changed).props("outlined dense autogrow").classes("w-full")
        ui.input("Extra SSH source CIDRs (Bastion + mgmt always allowed)").bind_value(
            c, "nva_mgmt_source_cidrs", forward=parse_list, backward=join_list).on_value_change(self.changed) \
            .props("outlined dense").classes("w-full")
        self.section("Bastion")
        ui.select({v: k for k, v in BASTION_SKUS.items()}, label="Bastion SKU").bind_value(c, "bastion_sku") \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")
        self.section("Protection")
        self.eah_switch = ui.switch("Encryption at host (NVAs and DCs)").bind_value(c, "nva_encryption_at_host") \
            .on_value_change(self.changed)
        ui.label("Register the Microsoft.Compute/EncryptionAtHost feature on both subscriptions first.").classes("lz-hint")
        ui.input("DDoS Network Protection plan ID (optional)").bind_value(c, "ddos_protection_plan_id") \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")

    def tab_operations(self) -> None:
        c = self.cfg
        self.section("Alerting")
        ui.input("Alert & budget recipients (comma separated)").bind_value(
            c, "alert_email_addresses", forward=parse_list, backward=join_list).on_value_change(self.changed) \
            .props("outlined dense").classes("w-full")
        self.section("Logging")
        ui.label().bind_text_from(c, "log_retention_days", lambda v: f"Log retention: {v} days").classes("text-sm")
        self.lock("log_retention_days", ui.slider(min=30, max=730, step=1).bind_value(c, "log_retention_days")
                  .on_value_change(self.changed))
        self.lock("enable_flow_logs", ui.switch("VNet flow logs + Traffic Analytics").bind_value(c, "enable_flow_logs")
                  .on_value_change(self.changed))
        with ui.row().classes("w-full no-wrap"):
            ui.number("Flow-log retention (days)", min=1, max=365).bind_value(c, "flow_log_retention_days",
                                                                              forward=lambda v: int(v or 30)) \
                .on_value_change(self.changed).props("outlined dense").classes("grow")
            ui.number("Daily ingestion cap (GB, -1 = none)", min=-1).bind_value(c, "log_daily_quota_gb",
                                                                               forward=lambda v: v if v is not None else -1) \
                .on_value_change(self.changed).props("outlined dense").classes("grow")
        self.section("Cost")
        ui.number("Monthly budget in € (0 = none)", min=0, step=100).bind_value(c, "monthly_budget_amount",
                                                                           forward=lambda v: v or 0) \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")
        self.section("Scaling signal")
        ui.label().bind_text_from(c, "nva_cpu_alert_threshold", lambda v: f"Alert when NVA CPU > {v} %").classes("text-sm")
        self.lock("nva_cpu_alert_threshold", ui.slider(min=50, max=95).bind_value(c, "nva_cpu_alert_threshold")
                  .on_value_change(self.changed))

    # ------------------------------------------------------------------ Azure
    @ui.refreshable
    def subscription_fields(self) -> None:
        c = self.cfg
        if self.subscriptions:
            opts = {s["subscriptionId"]: f"{s['displayName']}  ·  {s['subscriptionId']}" for s in self.subscriptions
                    if s.get("state") == "Enabled"}
            for fld, label in SUBSCRIPTION_FIELDS:
                value = getattr(c, fld) if getattr(c, fld) in opts else None
                ui.select(opts, label=label, value=value, with_input=True,
                          on_change=lambda e, f=fld: (setattr(c, f, e.value or ""), self.changed())) \
                    .props("outlined dense").classes("w-full")
            ui.label(f"{len(opts)} subscriptions in tenant {self.account.get('tenant_id', '')}.").classes("lz-hint")
        else:
            for fld, label in SUBSCRIPTION_FIELDS:
                ui.input(f"{label} ID", placeholder="00000000-0000-0000-0000-000000000000") \
                    .bind_value(c, fld).on_value_change(self.changed).props("outlined dense").classes("w-full")
            ui.label("Sign in to Azure (top right) to pick subscriptions from your tenant.").classes("lz-hint")
        used = {t: ", ".join(sp.key for sp in c.spokes if sp.subscription == t) for t in ("shared", "prod", "avd")}
        ui.label("Landing-zone subscriptions host workload spokes: "
                 f"shared services → {used['shared'] or 'no spokes yet'}; production → {used['prod'] or 'no spokes yet'}; "
                 f"AVD → {used['avd'] or 'no spokes yet'}. Choose each spoke's subscription on the Network tab.") \
            .classes("lz-hint")

    @ui.refreshable
    def account_view(self) -> None:
        if self.account:
            with ui.button(icon="account_circle").props("flat no-caps").classes("text-primary"):
                ui.label(self.account.get("name") or "Signed in").classes("q-ml-xs")
                with ui.menu():
                    ui.menu_item(f"Tenant {self.account.get('tenant_id', '')}").props("disable")
                    ui.menu_item("Sign out", on_click=self.sign_out)
        else:
            ui.button("Sign in to Azure", icon="login", on_click=self.open_sign_in).props("flat no-caps")

    def open_sign_in(self) -> None:
        method = {"value": "cli"}
        tenant = {"value": ""}

        async def go():
            btn.disable()
            status.set_text("Signing in…")
            self.device_message = ""
            try:
                if method["value"] == "demo":
                    from lzdesigner.demo import DemoTenant
                    client = DemoTenant()
                else:
                    cred = await run.io_bound(azure.sign_in, method["value"], tenant["value"] or None,
                                              lambda m: setattr(self, "device_message", m))
                    client = azure.ArmClient(cred)
                self.account = await run.io_bound(client.principal)
                self.subscriptions = await run.io_bound(client.subscriptions)
                self.arm = client
            except Exception as e:  # noqa: BLE001 – show sign-in problems to the user
                status.set_text(f"Sign-in failed: {e}")
                btn.enable()
                return
            dlg.close()
            ui.notify(f"Signed in as {self.account.get('name')} – {len(self.subscriptions)} subscriptions", type="positive")
            self.account_view.refresh()
            self.subscription_fields.refresh()
            self.azure_view.refresh()

        with ui.dialog() as dlg, ui.card().style("min-width: 520px"):
            ui.label("Sign in to Azure").classes("text-lg font-semibold")
            ui.label("Read-only: lists subscriptions and runs pre-flight checks. The designer stores no tokens.") \
                .classes("lz-hint")
            options = {"cli": "Use my Azure CLI session (az login)",
                       "browser": "Sign in with a browser",
                       "device": "Device code (no browser on this machine)"}
            if os.environ.get("LZDESIGNER_DEMO"):
                options["demo"] = "Demo tenant (no Azure access – for demos and screenshots)"
            ui.radio(options, value="cli", on_change=lambda e: method.update(value=e.value))
            ui.input("Tenant ID or domain (optional)", on_change=lambda e: tenant.update(value=e.value)) \
                .props("outlined dense").classes("w-full")
            status = ui.label("").classes("text-sm")
            code = ui.label("").classes("text-sm font-semibold text-primary")
            ui.timer(0.5, lambda: code.set_text(self.device_message))
            with ui.row():
                ui.button("Cancel", on_click=dlg.close).props("flat")
                btn = ui.button("Sign in", on_click=go).props("unelevated")
        dlg.open()

    def sign_out(self) -> None:
        self.arm, self.account, self.subscriptions, self.preflight = None, None, [], None
        self.account_view.refresh()
        self.subscription_fields.refresh()
        self.azure_view.refresh()
        ui.notify("Signed out – the designer kept no tokens.")

    async def run_preflight(self) -> None:
        if not self.arm:
            return
        self.preflight_running = True
        self.azure_view.refresh()
        try:
            self.preflight = await run.io_bound(azure.run_preflight, self.cfg, self.arm)
        except Exception as e:  # noqa: BLE001
            ui.notify(f"Pre-flight failed: {e}", type="negative")
        self.preflight_running = False
        self.preflight_stale = False
        eah = next((c for c in self.preflight or [] if c.id == "EAH"), None)
        if eah and "NotRegistered" in eah.detail and not self.cfg.nva_encryption_at_host:
            self.eah_switch.disable()
            # props, not ui.tooltip(): the button that started this was inside a refreshed view
            self.eah_switch.props('title="EncryptionAtHost is not registered on the subscriptions – see pre-flight."')
        self.azure_view.refresh()

    @ui.refreshable
    def azure_view(self) -> None:
        with ui.row().classes("w-full items-center"):
            ui.label("Pre-flight checks").classes("lz-section").style("margin:0")
            ui.space()
            if self.arm:
                ui.button("Run checks", icon="play_arrow", on_click=self.run_preflight) \
                    .props("flat dense no-caps").set_enabled(not self.preflight_running)
        if not self.arm:
            ui.label("Sign in to check this design against your tenant: existing VNet overlap, Network Watchers, "
                     "EncryptionAtHost, VM size/zone availability, vCPU quota and your deploy permissions.") \
                .classes("lz-hint")
            ui.button("Sign in to Azure", icon="login", on_click=self.open_sign_in).props("outline no-caps dense")
            return
        if self.preflight_running:
            with ui.row().classes("items-center"):
                ui.spinner(size="sm")
                ui.label("Checking your tenant…").classes("text-sm")
            return
        if self.preflight is None:
            ui.label("Signed in. Run the checks once the subscriptions are selected.").classes("lz-hint")
            return
        sm = azure.summary(self.preflight)
        with ui.row().classes("items-center gap-2"):
            for st, color in ((azure.FAIL, "negative"), (azure.WARN, "warning"), (azure.PASS, "positive")):
                if sm[st]:
                    ui.badge(f"{sm[st]} {st}", color=color)
            if self.preflight_stale:
                ui.label("design changed – re-run").classes("lz-hint")
        order = {azure.FAIL: 0, azure.WARN: 1, azure.INFO: 2, azure.PASS: 3}
        icons = {azure.FAIL: ("cancel", "negative"), azure.WARN: ("error_outline", "warning"),
                 azure.INFO: ("info", "grey"), azure.PASS: ("check_circle", "positive")}
        with ui.column().classes("w-full gap-1").style("max-height: 260px; overflow:auto"):
            for chk in sorted(self.preflight, key=lambda c: order[c.status]):
                icon, color = icons[chk.status]
                with ui.row().classes("w-full no-wrap items-start gap-2 cursor-pointer") \
                        .on("click", lambda s_=chk.section: self.tabs.set_value(s_)):
                    ui.icon(icon, color=color, size="18px")
                    with ui.column().classes("gap-0"):
                        ui.label(chk.title).classes("text-sm font-medium")
                        ui.label(chk.detail).classes("lz-hint")

    # ------------------------------------------------------------------ cost
    @ui.refreshable
    def cost_view(self) -> None:
        est = pricing.estimate(self.cfg, self.price_book)
        sym = {"USD": "$", "EUR": "€", "GBP": "£"}.get(est.currency, est.currency + " ")
        with ui.row().classes("w-full items-center"):
            ui.label("Estimated monthly cost").classes("lz-section").style("margin:0")
            ui.space()
            ui.select(["EUR", "USD", "GBP"], value=self.price_book.currency,
                      on_change=lambda e: self.refresh_prices(e.value)).props("dense borderless").classes("w-20")
            ui.button(icon="sync", on_click=lambda: self.refresh_prices(self.price_book.currency)) \
                .props("flat dense round").tooltip("Refresh live prices from the Azure Retail Prices API")
        with ui.row().classes("items-baseline gap-2"):
            ui.label(f"≈ {sym}{est.total:,.0f}").classes("text-2xl font-semibold")
            ui.label(f"/ month · {sym}{est.fixed:,.0f} fixed + {sym}{est.total - est.fixed:,.0f} usage-based").classes("lz-hint")
        cats = est.by_category()
        top = max(cats.values()) if cats else 1
        for cat, amount in cats.items():
            with ui.row().classes("w-full no-wrap items-center gap-2"):
                ui.label(cat).classes("text-xs").style("width: 90px")
                ui.linear_progress(amount / top, show_value=False, size="8px").classes("grow")
                ui.label(f"{sym}{amount:,.0f}").classes("text-xs text-right").style("width: 70px")
        with ui.expansion("Line items & assumptions").classes("w-full").props("dense"):
            for line in est.lines:
                with ui.row().classes("w-full no-wrap"):
                    ui.label(line.item + (" *" if line.usage_based else "")).classes("text-xs grow")
                    ui.label(line.qty).classes("text-xs text-grey-7").style("width: 120px")
                    ui.label(f"{sym}{line.monthly:,.2f}").classes("text-xs text-right").style("width: 80px")
            ui.label("* usage-based, from default assumptions (2 GB/day platform logs, 1 GB/day tier-0 logs, "
                     "1 GB/day flow logs, 100 GB/month NAT egress, 60 GB backup per DC).").classes("lz-hint")
            for note in est.notes:
                ui.label(note).classes("lz-hint")

    async def refresh_prices(self, currency: str) -> None:
        ui.notify("Fetching live prices…")
        try:
            self.price_book = await run.io_bound(pricing.refresh_live_prices, self.cfg, currency)
            ui.notify(f"Live {currency} prices loaded", type="positive")
        except Exception as e:  # noqa: BLE001 – offline or blocked: keep the baseline
            self.price_book = pricing.PriceBook()
            ui.notify(f"Couldn't reach prices.azure.com ({e.__class__.__name__}) – showing the bundled EUR baseline.",
                      type="warning")
        self.cost_view.refresh()

    # ------------------------------------------------------------------ live views
    @ui.refreshable
    def diagram_view(self) -> None:
        with ui.row().classes("w-full items-center q-px-sm"):
            ui.label("Live architecture").classes("lz-section").style("margin:0")
            ui.space()
            ui.button("Full size", icon="open_in_full", on_click=self.open_full_diagram).props("flat dense no-caps")
        with ui.element("div").classes("lz-diagram w-full"):
            ui.html(diagram.render_svg(self.cfg), sanitize=False)

    def open_full_diagram(self) -> None:
        with ui.dialog().props("maximized") as dlg, ui.card().classes("w-full"):
            with ui.row().classes("w-full items-center"):
                ui.label("Live architecture").classes("text-lg font-semibold")
                ui.space()
                ui.button("Download draw.io", icon="schema",
                          on_click=lambda: ui.download.content(diagram.render_drawio_svg(self.cfg), "architecture.drawio.svg")) \
                    .props("flat no-caps")
                ui.button(icon="close", on_click=dlg.close).props("flat round")
            with ui.element("div").classes("lz-diagram w-full").style("overflow:auto"):
                ui.html(diagram.render_svg(self.cfg), sanitize=False)
        dlg.open()

    @ui.refreshable
    def status_view(self) -> None:
        c = self.cfg
        issues = validate(c)
        results = compliance.evaluate(c)
        sc = compliance.scores(results, c.frameworks)
        fails = sum(r.status == compliance.FAIL for r in results)
        with ui.row().classes("w-full items-center gap-6"):
            for fw, s in sc.items():
                color = "positive" if s["fail"] == 0 else "negative"
                with ui.row().classes("items-center gap-2 no-wrap"):
                    ui.circular_progress(s["percent"], max=100, show_value=True, size="44px", color=color).props("thickness=0.18")
                    with ui.column().classes("gap-0"):
                        ui.label(fw).classes("font-semibold")
                        ui.label(f"{s['ok']}/{s['total']} met · {s['warn']} advisory").classes("lz-hint")
            ui.space()
            if not issues and not fails:
                ui.chip("Ready to export", icon="task_alt", color="positive").props("text-color=white")
            else:
                ui.chip(f"{len(issues)} input issue{'s' if len(issues) != 1 else ''} · {fails} required control{'s' if fails != 1 else ''}",
                        icon="report", color="negative").props("text-color=white")
        if issues or fails:
            with ui.expansion("What needs attention", icon="checklist").classes("w-full").props("dense"):
                for i in issues:
                    with ui.row().classes("items-center no-wrap gap-2 cursor-pointer") \
                            .on("click", lambda s=i.section: self.tabs.set_value(s)):
                        ui.icon("edit", color="negative", size="18px")
                        ui.label(f"{i.section}: {i.message}").classes("text-sm")
                for r in results:
                    if r.status == compliance.FAIL:  # required by at least one enabled framework
                        with ui.row().classes("items-center no-wrap gap-2"):
                            ui.icon("gavel", color="negative", size="18px")
                            ui.label(f"{r.control.id} {r.control.title} – {r.control.hint}").classes("text-sm")

    @ui.refreshable
    def compliance_view(self) -> None:
        c = self.cfg
        ui.label(compliance.DISCLAIMER).classes("lz-hint")
        self.section("Frameworks")
        for fw, desc in compliance.FRAMEWORK_INFO.items():
            sw = ui.switch(f"{fw} – {desc.split('–')[0].strip()}", value=fw in c.frameworks,
                           on_change=lambda e, f=fw: self.toggle_framework(f, e.value))
            if fw == "WAF":
                sw.disable()
        ui.label("Switching on NIS2 or DORA applies and locks the settings they require (marked 🔒 on each tab).") \
            .classes("lz-hint")
        self.section("Controls")
        results = compliance.evaluate(c)
        for pillar in ["Security", "Reliability", "Operational Excellence", "Cost Optimization", "Performance Efficiency"]:
            rows = [r for r in results if r.control.pillar == pillar]
            if not rows:
                continue
            with ui.expansion(f"{pillar} ({sum(r.status in ('pass', 'built-in') for r in rows)}/{len(rows)})",
                              value=any(r.status in ("fail", "warn") for r in rows)).classes("w-full").props("dense"):
                for r in rows:
                    icon, color = STATUS_ICON[r.status]
                    with ui.row().classes("w-full no-wrap items-start gap-2 q-py-xs"):
                        ui.icon(icon, color=color, size="20px")
                        with ui.column().classes("gap-0 grow"):
                            ui.label(f"{r.control.title}").classes("text-sm font-medium")
                            refs = " · ".join(f"{f} {r.control.refs[f]}" for f in r.frameworks)
                            extra = r.control.evidence if r.control.builtin else (r.control.hint if r.status != "pass" else "")
                            ui.label(f"{r.control.id} · {refs}{(' · ' + extra) if extra else ''}").classes("lz-hint")

    def toggle_framework(self, fw: str, on: bool) -> None:
        fws = set(self.cfg.frameworks)
        fws.add(fw) if on else fws.discard(fw)
        self.cfg.frameworks = [f for f in compliance.FRAMEWORK_INFO if f in fws]
        self.changed()
        self.resilience_cards.refresh()
        if on:
            ui.notify(f"{fw} baseline applied", type="positive")

    @ui.refreshable
    def export_view(self) -> None:
        c = self.cfg
        issues = validate(c)
        text = tfvars.render(c)
        if issues:
            ui.label(f"Fix {len(issues)} input issue(s) before writing terraform.tfvars – see the panel on the right.") \
                .classes("text-negative text-sm")
        with ui.row().classes("gap-2"):
            ui.button("Write terraform.tfvars to repo", icon="save", on_click=self.write_tfvars) \
                .props("unelevated no-caps").set_enabled(not issues)
            ui.button("tfvars", icon="download", on_click=lambda: ui.download.content(text, "terraform.tfvars")) \
                .props("outline no-caps")
            ui.button("Diagram (draw.io)", icon="schema",
                      on_click=lambda: ui.download.content(diagram.render_drawio_svg(c), "architecture.drawio.svg")) \
                .props("outline no-caps")
            ui.button("Compliance report", icon="description",
                      on_click=lambda: ui.download.content(compliance.report_markdown(c), "compliance-report.md")) \
                .props("outline no-caps")
            ui.button("Project file", icon="data_object",
                      on_click=lambda: ui.download.content(c.to_json(), "landingzone.json")).props("outline no-caps")
        ui.label(f"Writes {REPO_ROOT / 'terraform.tfvars'} (git-ignored). Then run terraform init / plan.").classes("lz-hint")

        self.section("Deployment pipeline")
        ui.label("Plan on pull requests with a read-only identity, apply on main after an approval – passwordless "
                 "(OIDC) GitHub Actions. See .github/workflows/deploy.yml.").classes("lz-hint")
        rg, sa = c.state_names()
        with ui.row().classes("w-full no-wrap"):
            ui.input("GitHub repository (OWNER/REPO)").bind_value(c, "github_repo") \
                .on("blur", self.export_view.refresh).props("outlined dense").classes("grow")
            ui.input("GitHub environment").bind_value(c, "github_environment") \
                .on("blur", self.export_view.refresh).props("outlined dense").classes("w-40")
        with ui.row().classes("w-full no-wrap"):
            ui.input("State resource group", placeholder=rg).bind_value(c, "state_resource_group") \
                .on("blur", self.export_view.refresh).props("outlined dense").classes("grow")
            ui.input("State storage account", placeholder=sa).bind_value(c, "state_storage_account") \
                .on("blur", self.export_view.refresh).props("outlined dense").classes("grow")
        env_file = f"environments/{c.github_environment or 'production'}.tfvars"
        ui.button(f"Write {env_file}", icon="save", on_click=lambda: self.write_env_tfvars(env_file)) \
            .props("unelevated no-caps").set_enabled(not issues)
        ui.label("1 · Run once (az login as an admin) to create the state storage and the two pipeline identities:") \
            .classes("text-sm q-mt-sm")
        ui.code(c.bootstrap_command(), language="bash").classes("w-full text-xs")
        ui.label("2 · Set the repository variables it prints, and add required reviewers to the "
                 f"'{c.github_environment}' environment.  3 · Commit {env_file} in a pull request: the plan runs, "
                 "and the apply waits for approval after merge.").classes("text-sm")

        self.section("terraform.tfvars preview")
        ui.code(text, language="terraform").classes("w-full text-xs")

    # ------------------------------------------------------------------ actions
    def write_tfvars(self) -> None:
        target = REPO_ROOT / "terraform.tfvars"

        def do_write():
            target.write_text(tfvars.render(self.cfg))
            (REPO_ROOT / "landingzone.json").write_text(self.cfg.to_json())
            dialog.close()
            ui.notify(f"Wrote {target.name} and landingzone.json", type="positive")

        with ui.dialog() as dialog, ui.card():
            ui.label(f"{'Overwrite' if target.exists() else 'Create'} {target}?").classes("font-semibold")
            ui.label("The project file landingzone.json is saved alongside so you can reopen this design.").classes("lz-hint")
            with ui.row():
                ui.button("Cancel", on_click=dialog.close).props("flat")
                ui.button("Write", on_click=do_write).props("unelevated")
        dialog.open()

    def write_env_tfvars(self, rel: str) -> None:
        target = REPO_ROOT / rel
        target.parent.mkdir(exist_ok=True)
        target.write_text(tfvars.render(self.cfg))
        ui.notify(f"Wrote {rel} – commit it in a pull request to run the plan.", type="positive")

    def open_upload(self) -> None:
        async def handle(e: events.UploadEventArguments):
            try:
                self.cfg.__dict__.update(LandingZoneConfig.from_json(await e.file.text()).__dict__)
            except Exception as ex:  # noqa: BLE001 – show any parse error to the user
                ui.notify(f"Could not load project: {ex}", type="negative")
                return
            dialog.close()
            self.identity_regions_view.refresh()
            self.resilience_cards.refresh()
            self.manual_addresses.refresh()
            self.changed()
            ui.notify("Project loaded", type="positive")

        with ui.dialog() as dialog, ui.card():
            ui.label("Load a landingzone.json project file").classes("font-semibold")
            ui.upload(on_upload=handle, auto_upload=True).props("accept=.json flat bordered")
        dialog.open()


@ui.page("/")
def index() -> None:
    Designer().build()


def main() -> None:
    parser = argparse.ArgumentParser(description="Landing Zone Designer")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--native", action="store_true", help="open in a desktop window (requires pywebview)")
    args = parser.parse_args()
    ui.run(title="Landing Zone Designer", host=args.host, port=args.port, native=args.native,
           reload=False, show=not args.native, favicon="🛡️", window_size=(1600, 1000) if args.native else None)


if __name__ in {"__main__", "__mp_main__"}:
    main()
