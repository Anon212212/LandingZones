"""Input validation – mirrors the Terraform variable validations and adds
cross-field checks (address overlap, region rules) that Terraform can't
express cleanly. Fixing everything here means `terraform plan` won't fail
on inputs."""

from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass
from itertools import combinations

from .catalog import ENVIRONMENTS, REGIONS
from .model import LandingZoneConfig

GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PREFIX = re.compile(r"^[a-z][a-z0-9-]{1,14}$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
SSH_KEY = re.compile(r"^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( .*)?$")
PORTS = re.compile(r"^(\*|\d{1,5}(-\d{1,5})?)$")
SERVICE_TAGS = {"VirtualNetwork", "AzureLoadBalancer", "Internet", "*", "Any"}
RESERVED_USERS = {"administrator", "admin", "user", "guest", "root"}


@dataclass(frozen=True)
class Issue:
    field: str
    message: str
    section: str


def valid_ssh_public_key(text: str) -> bool:
    """OpenSSH public key whose base64 blob decodes and declares the same key type
    (the same check azurerm performs)."""
    import base64
    import struct
    text = (text or "").strip()
    if not SSH_KEY.match(text):
        return False
    kind, blob = text.split()[:2]
    try:
        raw = base64.b64decode(blob, validate=True)
        (n,) = struct.unpack(">I", raw[:4])
        return raw[4:4 + n].decode() == kind and len(raw) > 4 + n
    except (ValueError, struct.error, UnicodeDecodeError):
        return False


def _cidr(value: str) -> ipaddress.IPv4Network | None:
    try:
        return ipaddress.IPv4Network(value, strict=False)
    except (ValueError, TypeError):
        return None


def validate(cfg: LandingZoneConfig) -> list[Issue]:
    issues: list[Issue] = []

    def add(fld: str, msg: str, section: str) -> None:
        issues.append(Issue(fld, msg, section))

    # Organisation
    if not PREFIX.match(cfg.org_prefix or ""):
        add("org_prefix", "2–15 lowercase letters, digits or hyphens, starting with a letter.", "Basics")
    if cfg.environment not in ENVIRONMENTS:
        add("environment", "Choose an environment from the list.", "Basics")
    if not cfg.owner.strip():
        add("owner", "Owner is a mandatory tag (team or email).", "Basics")
    if not cfg.cost_center.strip():
        add("cost_center", "Cost centre is a mandatory tag.", "Basics")
    if cfg.location not in REGIONS:
        add("location", "Choose a region that supports Availability Zones.", "Basics")

    # Subscriptions / access
    if not GUID.match(cfg.subscription_id or ""):
        add("subscription_id", "Connectivity subscription ID must be a GUID.", "Basics")
    if not GUID.match(cfg.identity_subscription_id or ""):
        add("identity_subscription_id", "Identity subscription ID must be a GUID.", "Identity")
    elif cfg.subscription_id and cfg.subscription_id.lower() == cfg.identity_subscription_id.lower():
        add("identity_subscription_id", "Tier-0 identity must use its own subscription.", "Identity")
    if not valid_ssh_public_key(cfg.nva_admin_ssh_public_key):
        add("nva_admin_ssh_public_key", "Paste an OpenSSH public key (ssh-ed25519 / ssh-rsa …).", "Security")

    # Network
    named = cfg.all_address_spaces()
    nets: dict[str, ipaddress.IPv4Network] = {}
    for name, value in named.items():
        n = _cidr(value)
        if n is None:
            add(f"cidr:{name}", f"{name}: '{value}' is not a valid CIDR.", "Network")
        else:
            nets[name] = n
    hub = nets.get("hub")
    if hub is not None and hub.prefixlen > 24:
        add("hub_address_space", "Hub must be /24 or larger.", "Network")
    for (a, na), (b, nb) in combinations(nets.items(), 2):
        if na.overlaps(nb):
            add(f"cidr:{b}", f"{a} ({na}) overlaps {b} ({nb}).", "Network")
    for c in cfg.nva_mgmt_source_cidrs:
        if _cidr(c) is None:
            add("nva_mgmt_source_cidrs", f"'{c}' is not a valid CIDR.", "Security")
        elif _cidr(c).prefixlen == 0:
            add("nva_mgmt_source_cidrs", "SSH must never be open to 0.0.0.0/0.", "Security")

    # Spokes
    keys = [sp.key for sp in cfg.spokes]
    if len(set(keys)) != len(keys):
        add("spokes", "Spoke names must be unique.", "Network")
    for sp in cfg.spokes:
        if not re.match(r"^[a-z][a-z0-9]{1,15}$", sp.key or ""):
            add("spokes", f"Spoke '{sp.key}': 2–16 lowercase letters/digits, starting with a letter.", "Network")
        seen = set()
        for r in sp.nsg_rules:
            where = f"Spoke '{sp.key}' rule '{r.name}'"
            if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$", r.name or ""):
                add("spokes", f"{where}: name must be letters, digits, '-', '_' or '.'.", "Network")
            if not 300 <= int(r.priority or 0) <= 3900:
                add("spokes", f"{where}: priority must be 300–3900 (baseline rules use the rest).", "Network")
            if (r.direction, r.priority) in seen:
                add("spokes", f"{where}: duplicate priority {r.priority}.", "Network")
            seen.add((r.direction, r.priority))
            if r.direction not in ("Inbound", "Outbound") or r.access not in ("Allow", "Deny") \
                    or r.protocol not in ("Tcp", "Udp", "Icmp", "*"):
                add("spokes", f"{where}: invalid direction, access or protocol.", "Network")
            if not r.source_address_prefixes or not r.destination_port_ranges:
                add("spokes", f"{where}: needs at least one source and one port.", "Network")
            for src in r.source_address_prefixes:
                if src not in SERVICE_TAGS and _cidr(src) is None:
                    add("spokes", f"{where}: '{src}' is not a CIDR or allowed service tag.", "Network")
            for port in r.destination_port_ranges:
                if not PORTS.match(port):
                    add("spokes", f"{where}: '{port}' is not a port, range or '*'.", "Network")
            if r.direction == "Inbound" and r.access == "Allow" and any(
                    x in ("*", "0.0.0.0/0", "Internet", "Any") for x in r.source_address_prefixes):
                add("spokes", f"{where}: inbound from the Internet is not allowed.", "Network")

    # Resilience
    if len(set(cfg.nva_zones)) < 2:
        add("nva_zones", "At least two NVAs in distinct zones are required.", "Resilience")

    # Identity
    if len(cfg.identity_regions) < 2:
        add("identity_regions", "Identity needs at least two regions.", "Identity")
    locations = [r.location for r in cfg.identity_regions]
    if len(set(locations)) != len(locations):
        add("identity_regions", "Each identity region must be a different Azure region.", "Identity")
    keys = [r.key for r in cfg.identity_regions]
    if len(set(keys)) != len(keys):
        add("identity_regions", "Identity region names must be unique.", "Identity")
    for r in cfg.identity_regions:
        if r.location not in REGIONS:
            add("identity_regions", f"{r.key}: choose a zone-capable region.", "Identity")
        if len(set(r.dc_zones)) < 2:
            add("identity_regions", f"{r.key}: at least two DCs in distinct zones.", "Identity")
        if not re.match(r"^[a-z][a-z0-9]{1,15}$", r.key):
            add("identity_regions", f"'{r.key}': region names are lowercase letters/digits.", "Identity")
    if (cfg.dc_admin_username or "").lower() in RESERVED_USERS or not cfg.dc_admin_username:
        add("dc_admin_username", "Choose a non-reserved admin username.", "Identity")
    for c in cfg.identity_admin_source_cidrs + cfg.identity_key_vault_allowed_ips + cfg.identity_dns_servers:
        if _cidr(c) is None:
            add("identity", f"'{c}' is not a valid IP/CIDR.", "Identity")

    # Operations
    if not 30 <= cfg.log_retention_days <= 730:
        add("log_retention_days", "Log retention must be 30–730 days.", "Operations")
    if cfg.flow_log_retention_days < 1:
        add("flow_log_retention_days", "Flow-log retention must be at least 1 day.", "Operations")
    for e in cfg.alert_email_addresses:
        if not EMAIL.match(e):
            add("alert_email_addresses", f"'{e}' is not a valid email address.", "Operations")
    if cfg.monthly_budget_amount < 0:
        add("monthly_budget_amount", "Budget cannot be negative.", "Operations")
    if cfg.monthly_budget_amount > 0 and not cfg.alert_email_addresses:
        add("monthly_budget_amount", "A budget needs at least one alert email.", "Operations")
    if not 1 <= cfg.nva_cpu_alert_threshold <= 100:
        add("nva_cpu_alert_threshold", "CPU threshold must be 1–100 %.", "Operations")

    # Pipeline (optional – only validated when filled in)
    if cfg.github_repo and not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", cfg.github_repo):
        add("github_repo", "GitHub repository must be OWNER/REPO.", "Export")
    if not re.match(r"^[A-Za-z0-9_.-]{1,64}$", cfg.github_environment or ""):
        add("github_environment", "GitHub environment: letters, digits, '-', '_' or '.'.", "Export")
    if cfg.state_storage_account and not re.match(r"^[a-z0-9]{3,24}$", cfg.state_storage_account):
        add("state_storage_account", "State storage account: 3–24 lowercase letters and digits.", "Export")

    return issues
