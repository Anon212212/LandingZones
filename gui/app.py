"""Landing Zone Designer – a simple front end for the Terraform landing zone.

Run:  python gui/app.py            (opens http://localhost:8080)
      python gui/app.py --native   (desktop window, needs `pip install pywebview`)

Users pick options from dropdowns, switches and presets; the app keeps a live
architecture diagram, validates inputs, enforces the WAF / NIS2 / DORA
baseline, and writes terraform.tfvars for the Terraform in the repo root.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from nicegui import app as ng_app
from nicegui import events, ui

sys.path.insert(0, str(Path(__file__).parent))

from lzdesigner import compliance, diagram, tfvars  # noqa: E402
from lzdesigner.catalog import (BACKUP_MODES, BASTION_SKUS, DC_IMAGES, ENVIRONMENTS,  # noqa: E402
                                REGIONS, RESILIENCE_PRESETS, VM_SIZES)
from lzdesigner.model import LandingZoneConfig  # noqa: E402
from lzdesigner.validation import validate  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
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
.q-tab__label { font-weight: 600; font-size: 12px; }
.lz-tabs .q-tab { padding: 0 6px; min-width: 0; }
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
                ui.label("Azure hub & spoke · HA NVAs · tier-0 identity — governed by WAF, NIS2 & DORA guardrails"
                         ).classes("text-xs text-grey-7")
            ui.space()
            ui.button("Load project", icon="upload_file", on_click=self.open_upload).props("flat no-caps")
            ui.button("Export", icon="download", on_click=lambda: self.tabs.set_value("Export")).props("unelevated no-caps")

        with ui.row().classes("w-full no-wrap q-pa-md gap-4 items-start"):
            with ui.card().classes("lz-card").style("width: 560px; min-width: 520px"):
                self.build_tabs()
            with ui.column().classes("grow gap-4").style("min-width: 0"):
                with ui.card().classes("lz-card w-full"):
                    self.status_view()
                with ui.card().classes("lz-card w-full q-pa-sm"):
                    self.diagram_view()

        self.changed()

    def build_tabs(self) -> None:
        names = [("Basics", "badge"), ("Network", "lan"), ("Resilience", "shield"), ("Identity", "admin_panel_settings"),
                 ("Security", "lock"), ("Operations", "monitor_heart"), ("Compliance", "gavel"), ("Export", "ios_share")]
        with ui.tabs().props("dense no-caps").classes("w-full lz-tabs") as self.tabs:
            for n, icon in names:
                ui.tab(n, icon=icon)
        with ui.tab_panels(self.tabs, value="Basics").classes("w-full").style("max-height: calc(100vh - 150px); overflow:auto"):
            with ui.tab_panel("Basics"):
                self.tab_basics()
            with ui.tab_panel("Network"):
                self.tab_network()
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
        ui.input("Connectivity subscription ID", placeholder="00000000-0000-0000-0000-000000000000") \
            .bind_value(c, "subscription_id").on_value_change(self.changed).props("outlined dense").classes("w-full")
        ui.input("Identity (tier-0) subscription ID", placeholder="must differ from connectivity") \
            .bind_value(c, "identity_subscription_id").on_value_change(self.changed).props("outlined dense").classes("w-full")
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
            lambda: (self.manual_addresses.refresh(), self.changed()))
        ui.input("Base network (/16)", placeholder="10.145.0.0/16").bind_value(c, "network_base") \
            .bind_enabled_from(c, "auto_addressing").on_value_change(self.changed).props("outlined dense").classes("w-full")
        self.manual_addresses()
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
        for fld, label in [("hub_address_space", "Hub (/24 or larger)"), ("spoke_address_space", "Shared services spoke"),
                           ("prod_address_space", "Production spoke"), ("avd_address_space", "AVD spoke")]:
            ui.input(label).bind_value(c, fld).on_value_change(self.changed).props("outlined dense").classes("w-full")
        ui.label("Identity address spaces are set per region on the Identity tab.").classes("lz-hint")

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
        ui.select({v: k for k, v in VM_SIZES.items()}, label="NVA size").bind_value(c, "nva_size") \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")
        self.lock("enable_resource_locks", ui.switch("Delete locks on critical resources")
                  .bind_value(c, "enable_resource_locks").on_value_change(self.changed))

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
        ui.switch("Encryption at host (NVAs and DCs)").bind_value(c, "nva_encryption_at_host").on_value_change(self.changed)
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
        ui.number("Monthly budget (0 = none)", min=0, step=100).bind_value(c, "monthly_budget_amount",
                                                                           forward=lambda v: v or 0) \
            .on_value_change(self.changed).props("outlined dense").classes("w-full")
        self.section("Scaling signal")
        ui.label().bind_text_from(c, "nva_cpu_alert_threshold", lambda v: f"Alert when NVA CPU > {v} %").classes("text-sm")
        self.lock("nva_cpu_alert_threshold", ui.slider(min=50, max=95).bind_value(c, "nva_cpu_alert_threshold")
                  .on_value_change(self.changed))

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
