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

    return issues
