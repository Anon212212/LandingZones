"""Compliance control catalogue: Azure Well-Architected Framework, NIS2 and DORA.

Every control maps a *technical* measure in this landing zone to the
framework requirement it supports. Controls are either:

* built-in   – always enforced by the Terraform code (evidence only), or
* setting    – depends on a choice in the designer; evaluated per config.

When a framework is switched on, settings it *requires* are enforced
(auto-applied and locked in the GUI); settings it *recommends* raise a
warning. Controls that need a value only the user can supply (e.g. alert
recipients) fail until it is provided.

Scope note: NIS2 and DORA also demand organisational measures
(governance, incident reporting, supplier management, testing
programmes, training). Those are outside infrastructure code; this
catalogue covers only the technical controls the landing zone provides.
NIS2 references are to Directive (EU) 2022/2555 Art. 21(2) unless stated;
DORA references are to Regulation (EU) 2022/2554.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

from .model import LandingZoneConfig

DISCLAIMER = (
    "Maps technical controls in this landing zone to framework requirements. It is not legal advice. "
    "NIS2 and DORA compliance also needs organisational measures (governance, incident reporting, "
    "third-party risk, resilience testing, training) that sit outside infrastructure code."
)

FRAMEWORK_INFO = {
    "WAF": "Azure Well-Architected Framework – always applied",
    "NIS2": "EU NIS2 Directive (2022/2555) – Art. 21 cybersecurity risk-management measures",
    "DORA": "EU Digital Operational Resilience Act (2022/2554) – ICT risk management & resilience",
}

PASS, WARN, FAIL, BUILTIN = "pass", "warn", "fail", "built-in"


@dataclass(frozen=True)
class Control:
    id: str
    title: str
    pillar: str                        # WAF pillar, for grouping
    refs: dict[str, str]               # framework -> reference text
    builtin: bool = False
    evidence: str = ""                 # where the code enforces it
    check: Callable[[LandingZoneConfig], bool] | None = None
    required_by: tuple[str, ...] = ()  # frameworks for which a failing setting is a FAIL
    fix: dict = field(default_factory=dict)   # auto-applied when required (empty = needs user input)
    hint: str = ""


def _builtin(id, title, pillar, refs, evidence):
    return Control(id, title, pillar, refs, builtin=True, evidence=evidence)


CONTROLS: list[Control] = [
    # ---------------------------------------------------------------- built-in
    _builtin("NET-01", "NSG on every subnet with explicit deny-all", "Security",
             {"WAF": "SE:06", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 9(2)"}, "security.tf, modules/identity-region"),
    _builtin("NET-02", "Private subnets – no default outbound access", "Security",
             {"WAF": "SE:06", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 9(2)"}, "network.tf"),
    _builtin("NET-03", "All spoke traffic forced through the NVAs (UDR, BGP propagation off)", "Security",
             {"WAF": "SE:04", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 9(4)(a)"}, "network.tf"),
    _builtin("NET-04", "No public IPs on VMs; admin access only via Bastion", "Security",
             {"WAF": "SE:06", "NIS2": "Art. 21(2)(i)", "DORA": "Art. 9(4)(c)"}, "bastion.tf, security.tf"),
    _builtin("IDN-01", "Tier-0 identity isolated in a dedicated subscription", "Security",
             {"WAF": "SE:04", "NIS2": "Art. 21(2)(i)", "DORA": "Art. 9(4)(c)"}, "providers.tf, identity.tf"),
    _builtin("IDN-02", "DC admin passwords generated and held only in a tier-0 Key Vault", "Security",
             {"WAF": "SE:09", "NIS2": "Art. 21(2)(i)", "DORA": "Art. 9(4)(d)"}, "modules/identity-region"),
    _builtin("IDN-03", "Entra ID-only access to Log Analytics (local auth disabled)", "Security",
             {"WAF": "SE:05", "NIS2": "Art. 21(2)(j)", "DORA": "Art. 9(4)(c)"}, "main.tf, identity.tf"),
    _builtin("HRD-01", "Trusted Launch (Secure Boot + vTPM) on NVAs and DCs", "Security",
             {"WAF": "SE:08", "NIS2": "Art. 21(2)(e)", "DORA": "Art. 9(2)"}, "nva.tf, modules/identity-region"),
    _builtin("HRD-02", "Platform-orchestrated patching (never both NVAs/DCs together)", "Security",
             {"WAF": "SE:08", "NIS2": "Art. 21(2)(e)", "DORA": "Art. 9(4)(f)"}, "nva.tf, modules/identity-region"),
    _builtin("CRY-01", "TLS 1.2+, HTTPS-only, no public blobs on storage", "Security",
             {"WAF": "SE:07", "NIS2": "Art. 21(2)(h)", "DORA": "Art. 9(4)(d)"}, "monitoring.tf"),
    _builtin("CRY-02", "Key Vault: RBAC, purge protection, premium (HSM-backed keys)", "Security",
             {"WAF": "SE:09", "NIS2": "Art. 21(2)(h)", "DORA": "Art. 9(4)(d)"}, "identity.tf"),
    _builtin("REL-01", "Zone-redundant ILB, Bastion and NVAs spread across zones", "Reliability",
             {"WAF": "RE:05", "NIS2": "Art. 21(2)(c)", "DORA": "Art. 7"}, "nva.tf, bastion.tf"),
    _builtin("REL-02", "Domain controllers in ≥ 2 regions × ≥ 2 zones", "Reliability",
             {"WAF": "RE:05", "NIS2": "Art. 21(2)(c)", "DORA": "Art. 11(1)"}, "identity.tf (validated)"),
    _builtin("REL-03", "Immutable, soft-deleted backups; retention within AD tombstone", "Reliability",
             {"WAF": "RE:09", "NIS2": "Art. 21(2)(c)", "DORA": "Art. 12(1)"}, "modules/identity-region"),
    _builtin("REL-04", "Documented restore and forest-recovery procedure", "Reliability",
             {"WAF": "RE:09", "NIS2": "Art. 21(2)(c)", "DORA": "Art. 11(2)"}, "docs/identity.md"),
    _builtin("OPS-01", "Diagnostics from every network resource to Log Analytics", "Operational Excellence",
             {"WAF": "OE:07", "NIS2": "Art. 21(2)(b)", "DORA": "Art. 10(1)"}, "monitoring.tf"),
    _builtin("OPS-02", "Health, Service Health and Resource Health alerts", "Reliability",
             {"WAF": "RE:10", "NIS2": "Art. 21(2)(b)", "DORA": "Art. 10(1)"}, "monitoring.tf, identity.tf"),
    _builtin("OPS-03", "Separate tier-0 Log Analytics (≥ 365 days) incl. activity log", "Security",
             {"WAF": "SE:10", "NIS2": "Art. 21(2)(b)", "DORA": "Art. 10(1)"}, "identity.tf"),
    _builtin("OPS-04", "Infrastructure as code with CI guardrail tests", "Operational Excellence",
             {"WAF": "OE:05", "NIS2": "Art. 21(2)(f)", "DORA": "Art. 9(4)(e)"}, ".github/workflows, tests/"),
    _builtin("GOV-01", "Mandatory owner / cost-center / environment tags (asset inventory)", "Cost Optimization",
             {"WAF": "CO:01", "NIS2": "Art. 21(2)(i)", "DORA": "Art. 8(1)"}, "locals.tf"),

    # ---------------------------------------------------------------- settings
    Control("OPS-10", "Alert recipients configured (incident detection & early warning)", "Operational Excellence",
            {"WAF": "OE:08", "NIS2": "Art. 21(2)(b), Art. 23", "DORA": "Art. 10, Art. 17"},
            check=lambda c: len(c.alert_email_addresses) > 0, required_by=("NIS2", "DORA"),
            hint="Add at least one on-call email under Operations."),
    Control("OPS-11", "Log retention ≥ 365 days", "Operational Excellence",
            {"WAF": "OE:07", "NIS2": "Art. 21(2)(b)", "DORA": "Art. 10, Art. 13"},
            check=lambda c: c.log_retention_days >= 365, required_by=("NIS2", "DORA"),
            fix={"log_retention_days": 365}, hint="One year supports investigation and post-incident review."),
    Control("OPS-12", "VNet flow logs + Traffic Analytics enabled", "Security",
            {"WAF": "SE:10", "NIS2": "Art. 21(2)(b)", "DORA": "Art. 10(1)"},
            check=lambda c: c.enable_flow_logs, required_by=("WAF", "NIS2", "DORA"),
            fix={"enable_flow_logs": True}),
    Control("REL-10", "Delete locks on critical resources", "Reliability",
            {"WAF": "RE:07", "NIS2": "Art. 21(2)(c)", "DORA": "Art. 9(3)"},
            check=lambda c: c.enable_resource_locks, required_by=("WAF", "NIS2", "DORA"),
            fix={"enable_resource_locks": True}),
    Control("REL-11", "Geographically separated backups with Cross Region Restore", "Reliability",
            {"WAF": "RE:09", "NIS2": "Art. 21(2)(c)", "DORA": "Art. 12(3)"},
            check=lambda c: c.identity_backup_storage_mode == "GeoRedundant", required_by=("DORA",),
            fix={"identity_backup_storage_mode": "GeoRedundant"},
            hint="DORA expects backups restorable from a physically separate location."),
    Control("SEC-10", "Tier-0 admin access from dedicated PAWs, not the shared Bastion", "Security",
            {"WAF": "SE:05", "NIS2": "Art. 21(2)(i)", "DORA": "Art. 9(4)(c)"},
            check=lambda c: not c.identity_allow_hub_bastion,
            hint="Disable 'RDP via hub Bastion' once a PAW network exists."),
    Control("SEC-11", "Tier-0 Key Vault firewall restricted to known IPs", "Security",
            {"WAF": "SE:06", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 9(2)"},
            check=lambda c: len(c.identity_key_vault_allowed_ips) > 0,
            hint="Add the deployment agent's egress IPs."),
    Control("SEC-12", "Encryption at host on NVAs and DCs", "Security",
            {"WAF": "SE:07", "NIS2": "Art. 21(2)(h)", "DORA": "Art. 9(4)(d)"},
            check=lambda c: c.nva_encryption_at_host,
            hint="Requires the EncryptionAtHost feature registered on both subscriptions."),
    Control("SEC-13", "DDoS Network Protection on public endpoints", "Security",
            {"WAF": "SE:06", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 7"},
            check=lambda c: bool(c.ddos_protection_plan_id),
            hint="Attach a shared DDoS plan (cost trade-off)."),
    Control("SEC-14", "Deterministic, controlled Internet egress (NAT Gateway)", "Security",
            {"WAF": "SE:06", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 9(2)"},
            check=lambda c: c.enable_nat_gateway, required_by=("NIS2", "DORA"),
            fix={"enable_nat_gateway": True}),
    Control("SEC-15", "NVA SSH never open to the Internet", "Security",
            {"WAF": "SE:06", "NIS2": "Art. 21(2)(i)", "DORA": "Art. 9(4)(c)"},
            check=lambda c: all(not x.endswith("/0") for x in c.nva_mgmt_source_cidrs),
            required_by=("WAF", "NIS2", "DORA"), hint="Remove 0.0.0.0/0 from extra SSH sources."),
    Control("SEC-16", "Spoke NSG rules follow least privilege (no allow-all ports)", "Security",
            {"WAF": "SE:06", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 9(4)(c)"},
            check=lambda c: not any(r.access == "Allow" and "*" in r.destination_port_ranges
                                    for sp in c.spokes for r in sp.nsg_rules),
            hint="Replace '*' ports in spoke rules with the specific ports the workload needs."),
    Control("SEC-17", "Workload spokes in dedicated landing-zone subscriptions", "Security",
            {"WAF": "SE:04", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 9(4)(c)"},
            check=lambda c: all(sp.subscription != "connectivity" for sp in c.spokes),
            hint="Move workload spokes out of the connectivity subscription (Network tab → spoke → Subscription)."),
    Control("SEC-18", "Inspecting next-generation firewall in the hub (IDPS, TLS/app inspection)", "Security",
            {"WAF": "SE:06", "NIS2": "Art. 21(2)(a)", "DORA": "Art. 9(2)"},
            check=lambda c: c.nva_vendor != "linux",
            hint="The built-in Linux NVA only routes and SNATs. Choose FortiGate, Palo Alto, SonicWall or pfSense on the Firewall tab."),
    Control("REL-13", "Firewall without a single point of failure (active/active or active/standby)", "Reliability",
            {"WAF": "RE:05", "NIS2": "Art. 21(2)(c)", "DORA": "Art. 11(1)"},
            check=lambda c: c.nva_ha_mode != "single",
            hint="Single-firewall mode loses all spoke and Internet traffic if the VM or its zone fails."),
    Control("REL-12", "Three-zone redundancy for NVAs and DCs", "Reliability",
            {"WAF": "RE:05", "NIS2": "Art. 21(2)(c)", "DORA": "Art. 11(1)"},
            check=lambda c: len(c.nva_zones) >= 3 and all(len(r.dc_zones) >= 3 for r in c.identity_regions),
            hint="Choose the High or Maximum resilience preset."),
    Control("COS-10", "Monthly budget with alerts", "Cost Optimization",
            {"WAF": "CO:04"},
            check=lambda c: c.monthly_budget_amount > 0 and len(c.alert_email_addresses) > 0,
            hint="Set a budget under Operations & cost."),
    Control("PER-10", "CPU scaling signal on the NVAs (≤ 80 %)", "Performance Efficiency",
            {"WAF": "PE:05"},
            check=lambda c: c.nva_cpu_alert_threshold <= 80, required_by=("WAF",),
            fix={"nva_cpu_alert_threshold": 75}),
]


@dataclass
class Result:
    control: Control
    status: str
    frameworks: list[str]


def applicable(control: Control, frameworks: list[str]) -> list[str]:
    return [f for f in frameworks if f in control.refs]


def evaluate(cfg: LandingZoneConfig) -> list[Result]:
    results = []
    for c in CONTROLS:
        fws = applicable(c, cfg.frameworks)
        if not fws:
            continue
        if c.builtin:
            status = BUILTIN
        elif c.check(cfg):
            status = PASS
        elif any(f in c.required_by for f in fws):
            status = FAIL
        else:
            status = WARN
        results.append(Result(c, status, fws))
    return results


def status_for(result: Result, framework: str) -> str:
    """A setting only *fails* under a framework that requires it; elsewhere it's advisory."""
    if result.status == FAIL and framework not in result.control.required_by:
        return WARN
    return result.status


def scores(results: list[Result], frameworks: list[str]) -> dict[str, dict]:
    out = {}
    for f in frameworks:
        st = [status_for(r, f) for r in results if f in r.frameworks]
        ok = sum(s in (PASS, BUILTIN) for s in st)
        out[f] = {
            "total": len(st), "ok": ok,
            "warn": sum(s == WARN for s in st),
            "fail": sum(s == FAIL for s in st),
            "percent": round(100 * ok / len(st)) if st else 100,
        }
    return out


def locked_fields(cfg: LandingZoneConfig) -> dict[str, str]:
    """Fields forced by an enabled framework → reason shown in the GUI."""
    locks: dict[str, str] = {}
    for c in CONTROLS:
        if c.builtin or not c.fix:
            continue
        req = [f for f in cfg.frameworks if f in c.required_by]
        if req:
            for fld in c.fix:
                locks[fld] = f"Required by {' & '.join(req)} ({'; '.join(c.refs[f] for f in req)}) – {c.title}"
    return locks


def enforce(cfg: LandingZoneConfig) -> list[str]:
    """Apply required settings for the enabled frameworks. Returns what changed."""
    changed = []
    for c in CONTROLS:
        if c.builtin or not c.fix or c.check(cfg):
            continue
        if any(f in c.required_by for f in cfg.frameworks):
            for fld, value in c.fix.items():
                setattr(cfg, fld, value)
                changed.append(f"{fld} → {value} ({c.id})")
    if changed:
        cfg.resilience = cfg.matching_preset()
    return changed


def report_markdown(cfg: LandingZoneConfig) -> str:
    results = evaluate(cfg)
    sc = scores(results, cfg.frameworks)
    icon = {PASS: "✅ pass", BUILTIN: "✅ built-in", WARN: "⚠️ recommended", FAIL: "❌ required"}
    lines = [
        f"# Compliance report – {cfg.org_prefix} ({cfg.environment})",
        "",
        f"> {DISCLAIMER}",
        "",
        "| Framework | Controls | Met | Recommended | Required, not met |",
        "|---|---|---|---|---|",
    ]
    for f, s in sc.items():
        lines.append(f"| {f} | {s['total']} | {s['ok']} ({s['percent']} %) | {s['warn']} | {s['fail']} |")
    for pillar in ["Reliability", "Security", "Cost Optimization", "Operational Excellence", "Performance Efficiency"]:
        rows = [r for r in results if r.control.pillar == pillar]
        if not rows:
            continue
        lines += ["", f"## {pillar}", "", "| ID | Control | Status | " + " | ".join(cfg.frameworks) + " | Evidence / action |",
                  "|---|---|---|" + "---|" * len(cfg.frameworks) + "---|"]
        for r in rows:
            c = r.control
            refs = " | ".join(c.refs.get(f, "–") for f in cfg.frameworks)
            note = c.evidence if c.builtin else (c.hint if r.status != PASS else "configured")
            lines.append(f"| {c.id} | {c.title} | {icon[r.status]} | {refs} | {note} |")
    return "\n".join(lines) + "\n"
