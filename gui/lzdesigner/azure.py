"""Optional Azure sign-in and read-only pre-flight checks.

Sign-in methods (all via azure-identity, nothing persisted by the designer):
  cli      reuse the Azure CLI session (`az login`); tokens stay in the CLI cache
  browser  interactive browser sign-in; tokens kept in memory for this session
  device   device-code flow for machines without a browser

Only Reader-level ARM calls are made. `run_preflight()` takes any object with
the `ArmClient` methods, so tests use a fake tenant.
"""

from __future__ import annotations

import base64
import ipaddress
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Callable

from .catalog import REGIONS
from .model import LandingZoneConfig

ARM = "https://management.azure.com"
SCOPE = "https://management.azure.com/.default"

ROLE_IDS = {
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635": "Owner",
    "b24988ac-6180-42a0-ab88-20f7382dd24c": "Contributor",
    "18d7d88d-d35e-4fb5-a5c3-7773c4a72b9d": "User Access Administrator",
    "f58310d9-a9f6-439a-9e8d-f62e7b41a168": "Role Based Access Control Administrator",
    "acdd72a7-3385-48ef-bd42-f606fba81ae7": "Reader",
}


# ---------------------------------------------------------------- sign-in
def sign_in(method: str, tenant_id: str | None = None,
            device_code_message: Callable[[str], None] | None = None):
    """Return an azure-identity credential and verify it can get an ARM token."""
    from azure.identity import AzureCliCredential, DeviceCodeCredential, InteractiveBrowserCredential

    tenant_id = tenant_id or None
    if method == "cli":
        cred = AzureCliCredential(tenant_id=tenant_id)
    elif method == "browser":
        cred = InteractiveBrowserCredential(tenant_id=tenant_id)
    elif method == "device":
        def prompt(verification_uri, user_code, expires_on):
            msg = f"Open {verification_uri} and enter the code {user_code}"
            (device_code_message or print)(msg)
        cred = DeviceCodeCredential(tenant_id=tenant_id, prompt_callback=prompt)
    else:
        raise ValueError(f"unknown sign-in method {method!r}")
    cred.get_token(SCOPE)
    return cred


def _claims(token: str) -> dict:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


class ArmClient:
    """Minimal read-only Azure Resource Manager client."""

    def __init__(self, credential, opener=urllib.request.urlopen):
        self.credential = credential
        self.opener = opener
        self._token = None

    def _bearer(self) -> str:
        if self._token is None or self._token.expires_on - 300 < time.time():
            self._token = self.credential.get_token(SCOPE)
        return self._token.token

    def principal(self) -> dict:
        c = _claims(self._bearer())
        return {"object_id": c.get("oid"), "tenant_id": c.get("tid"),
                "name": c.get("upn") or c.get("unique_name") or c.get("preferred_username") or c.get("appid", "")}

    def get(self, path: str, api_version: str, params: dict | None = None) -> list | dict:
        q = {"api-version": api_version, **(params or {})}
        url = f"{ARM}{path}?{urllib.parse.urlencode(q, quote_via=urllib.parse.quote)}"
        values, single = [], None
        while url:
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self._bearer()}"})
            with self.opener(req, timeout=30) as resp:
                data = json.loads(resp.read())
            if "value" not in data:
                single = data
                break
            values += data["value"]
            url = data.get("nextLink")
        return single if single is not None else values

    # --- the calls the pre-flight uses ---------------------------------------
    def subscriptions(self) -> list[dict]:
        return self.get("/subscriptions", "2022-12-01")

    def vnets(self, sub: str) -> list[dict]:
        return self.get(f"/subscriptions/{sub}/providers/Microsoft.Network/virtualNetworks", "2023-09-01")

    def network_watchers(self, sub: str) -> list[dict]:
        return self.get(f"/subscriptions/{sub}/providers/Microsoft.Network/networkWatchers", "2023-09-01")

    def feature_state(self, sub: str, namespace: str, feature: str) -> str:
        try:
            data = self.get(f"/subscriptions/{sub}/providers/Microsoft.Features/providers/{namespace}/features/{feature}",
                            "2021-07-01")
            return data.get("properties", {}).get("state", "NotRegistered")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return "NotRegistered"
            raise

    def vm_skus(self, sub: str, location: str) -> list[dict]:
        skus = self.get(f"/subscriptions/{sub}/providers/Microsoft.Compute/skus", "2021-07-01",
                        {"$filter": f"location eq '{location}'"})
        return [s for s in skus if s.get("resourceType") == "virtualMachines"]

    def usages(self, sub: str, location: str) -> list[dict]:
        return self.get(f"/subscriptions/{sub}/providers/Microsoft.Compute/locations/{location}/usages", "2023-09-01")

    def role_assignments(self, sub: str, principal_id: str) -> list[dict]:
        return self.get(f"/subscriptions/{sub}/providers/Microsoft.Authorization/roleAssignments", "2022-04-01",
                        {"$filter": f"assignedTo('{principal_id}')"})


# ---------------------------------------------------------------- pre-flight
PASS, WARN, FAIL, INFO = "pass", "warn", "fail", "info"


@dataclass
class Check:
    id: str
    title: str
    status: str
    detail: str
    section: str


def planned_vnet_names(cfg: LandingZoneConfig) -> set[str]:
    short = REGIONS[cfg.location].short if cfg.location in REGIONS else cfg.location
    names = {f"vnet-{cfg.org_prefix}-hub-{cfg.environment}-{short}"}
    names |= {f"vnet-{cfg.org_prefix}-{sp.key}-{cfg.environment}-{short}" for sp in cfg.spokes}
    for r in cfg.identity_regions:
        rs = REGIONS[r.location].short if r.location in REGIONS else r.location
        names.add(f"vnet-{cfg.org_prefix}-identity-{cfg.environment}-{rs}")
    return names


def _roles_at_subscription(assignments: list[dict], sub: str) -> set[str]:
    roles = set()
    sub_scope = f"/subscriptions/{sub}".lower()
    for a in assignments:
        props = a.get("properties", a)
        scope = (props.get("scope") or "").lower().rstrip("/")
        applies = scope in ("", sub_scope) or scope.startswith("/providers/microsoft.management/managementgroups/")
        if applies:
            rid = (props.get("roleDefinitionId") or "").rsplit("/", 1)[-1].lower()
            roles.add(ROLE_IDS.get(rid, rid))
    return roles


def _sku_info(skus: list[dict], size: str) -> dict | None:
    for s in skus:
        if s.get("name", "").lower() == size.lower():
            loc = (s.get("locationInfo") or [{}])[0]
            zones = set(loc.get("zones") or [])
            blocked_location = False
            for r in s.get("restrictions") or []:
                if r.get("reasonCode") != "NotAvailableForSubscription":
                    continue
                if r.get("type") == "Location":
                    blocked_location = True
                if r.get("type") == "Zone":
                    zones -= set((r.get("restrictionInfo") or {}).get("zones") or [])
            caps = {c["name"]: c["value"] for c in s.get("capabilities") or []}
            return {"zones": set() if blocked_location else zones, "family": s.get("family"),
                    "vcpus": int(caps.get("vCPUs", 0) or 0), "blocked": blocked_location}
    return None


def run_preflight(cfg: LandingZoneConfig, client) -> list[Check]:
    checks: list[Check] = []

    def add(id_, title, status, detail, section):
        checks.append(Check(id_, title, status, detail, section))

    def guarded(id_, title, section, fn):
        try:
            fn()
        except Exception as e:  # noqa: BLE001 – report any API problem as a warning, keep going
            add(id_, title, WARN, f"Could not check: {e}", section)

    conn, ident = cfg.subscription_id.lower(), cfg.identity_subscription_id.lower()
    subs = {s["subscriptionId"].lower(): s for s in client.subscriptions()}

    # 1. Subscriptions -----------------------------------------------------------
    for label, sid, section in (("Connectivity", conn, "Basics"), ("Identity", ident, "Basics")):
        s = subs.get(sid)
        if not s:
            add(f"SUB-{label}", f"{label} subscription accessible", FAIL,
                f"{sid or '(not set)'} isn't visible to the signed-in account.", section)
        elif s.get("state") != "Enabled":
            add(f"SUB-{label}", f"{label} subscription accessible", FAIL, f"{s['displayName']} is {s.get('state')}.", section)
        else:
            add(f"SUB-{label}", f"{label} subscription accessible", PASS, f"{s['displayName']} ({sid})", section)
    targets = [(sid, label) for sid, label in ((conn, "connectivity"), (ident, "identity")) if sid in subs]

    # 2. Permissions -------------------------------------------------------------
    def roles():
        principal = client.principal()
        for sid, label in targets:
            have = _roles_at_subscription(client.role_assignments(sid, principal["object_id"]), sid)
            can_assign = {"User Access Administrator", "Role Based Access Control Administrator"} & have
            if "Owner" in have or ("Contributor" in have and can_assign):
                add(f"RBAC-{label}", f"Deploy permissions on {label}", PASS, ", ".join(sorted(have)), "Basics")
            elif "Contributor" in have:
                add(f"RBAC-{label}", f"Deploy permissions on {label}", FAIL,
                    "Contributor only – also needs User Access Administrator (role assignments for Key Vault, backups).",
                    "Basics")
            else:
                add(f"RBAC-{label}", f"Deploy permissions on {label}", WARN,
                    f"{', '.join(sorted(have)) or 'No active role'} – enough to run these checks, not to deploy. "
                    "PIM-eligible roles must be activated.", "Basics")
    guarded("RBAC", "Deploy permissions", "Basics", roles)

    # 3. Address overlap with existing VNets --------------------------------------
    def overlap():
        planned = {k: ipaddress.IPv4Network(v, strict=False) for k, v in cfg.all_address_spaces().items()}
        ours = {n.lower() for n in planned_vnet_names(cfg)}
        clashes = []
        seen = 0
        for sid, label in targets:
            for vnet in client.vnets(sid):
                if vnet["name"].lower() in ours:
                    continue
                seen += 1
                for prefix in vnet.get("properties", {}).get("addressSpace", {}).get("addressPrefixes", []):
                    try:
                        existing = ipaddress.ip_network(prefix, strict=False)
                    except ValueError:
                        continue
                    for name, net in planned.items():
                        if existing.version == 4 and existing.overlaps(net):
                            clashes.append(f"{name} {net} ↔ {vnet['name']} {prefix} ({label})")
        if clashes:
            add("NET-OVERLAP", "No overlap with existing VNets", FAIL, "; ".join(clashes), "Network")
        else:
            add("NET-OVERLAP", "No overlap with existing VNets", PASS,
                f"Compared with {seen} existing VNet{'s' if seen != 1 else ''}.", "Network")
    guarded("NET-OVERLAP", "No overlap with existing VNets", "Network", overlap)

    # 4. Network Watchers ---------------------------------------------------------
    def watchers():
        if not cfg.enable_flow_logs:
            add("NW", "Network Watchers for flow logs", INFO, "Flow logs are off.", "Operations")
            return
        need = {(conn, cfg.location)} | {(ident, r.location) for r in cfg.identity_regions}
        cache: dict[str, list[dict]] = {}
        for sid, loc in sorted(need):
            if sid not in subs:
                continue
            nws = cache.setdefault(sid, client.network_watchers(sid))
            here = [w for w in nws if w.get("location", "").lower() == loc]
            expected = [w for w in here if w["name"] == f"NetworkWatcher_{loc}" and "/resourcegroups/networkwatcherrg/" in w["id"].lower()]
            where = f"{subs[sid]['displayName']} / {loc}"
            if expected:
                add(f"NW-{sid[:8]}-{loc}", f"Network Watcher in {loc}", PASS, where, "Operations")
            elif here:
                add(f"NW-{sid[:8]}-{loc}", f"Network Watcher in {loc}", WARN,
                    f"{where}: found {here[0]['name']} – Terraform expects NetworkWatcher_{loc} in NetworkWatcherRG "
                    "(set network_watcher_name / network_watcher_resource_group).", "Operations")
            else:
                add(f"NW-{sid[:8]}-{loc}", f"Network Watcher in {loc}", WARN,
                    f"{where}: none yet. Azure normally creates one with the first VNet; if a policy disables that, "
                    "create it first or flow logs will fail.", "Operations")
    guarded("NW", "Network Watchers for flow logs", "Operations", watchers)

    # 5. Encryption at host --------------------------------------------------------
    def eah():
        states = {label: client.feature_state(sid, "Microsoft.Compute", "EncryptionAtHost") for sid, label in targets}
        ok = all(s == "Registered" for s in states.values())
        detail = ", ".join(f"{k}: {v}" for k, v in states.items())
        if cfg.nva_encryption_at_host and not ok:
            add("EAH", "EncryptionAtHost feature registered", FAIL,
                f"{detail}. Run `az feature register --namespace Microsoft.Compute --name EncryptionAtHost` "
                "on each subscription, or switch encryption at host off.", "Security")
        else:
            add("EAH", "EncryptionAtHost feature registered", PASS if ok else INFO, detail, "Security")
    guarded("EAH", "EncryptionAtHost feature registered", "Security", eah)

    # 6 + 7. VM sizes, zones and quota ---------------------------------------------
    def capacity():
        demand = [(conn, cfg.location, cfg.nva_size, list(cfg.nva_zones), "NVAs", "Resilience")]
        demand += [(ident, r.location, cfg.dc_size, list(r.dc_zones), f"DCs ({r.key})", "Identity")
                   for r in cfg.identity_regions]
        sku_cache: dict[tuple[str, str], list[dict]] = {}
        need_quota: dict[tuple[str, str, str], dict] = {}
        for sid, loc, size, zones, what, section in demand:
            if sid not in subs:
                continue
            skus = sku_cache.setdefault((sid, loc), client.vm_skus(sid, loc))
            info = _sku_info(skus, size)
            cid = f"SKU-{what}-{loc}"
            if not info or info["blocked"]:
                add(cid, f"{size} available for {what} in {loc}", FAIL,
                    f"{size} isn't offered to this subscription in {loc}. Pick another size or region.", section)
                continue
            missing = sorted(set(zones) - info["zones"])
            if missing:
                add(cid, f"{size} available for {what} in {loc}", FAIL,
                    f"Not available in zone(s) {', '.join(missing)} (available: {', '.join(sorted(info['zones'])) or 'none'}).",
                    section)
            else:
                add(cid, f"{size} available for {what} in {loc}", PASS, f"zones {', '.join(zones)}", section)
            key = (sid, loc, info["family"])
            entry = need_quota.setdefault(key, {"vcpus": 0, "what": [], "section": section})
            entry["vcpus"] += info["vcpus"] * len(zones)
            entry["what"].append(what)
        for (sid, loc, family), entry in need_quota.items():
            usages = {u["name"]["value"]: u for u in client.usages(sid, loc)}
            for quota_name, label in ((family, f"{family} vCPUs"), ("cores", "Total regional vCPUs")):
                u = usages.get(quota_name)
                if not u:
                    continue
                free = u["limit"] - u["currentValue"]
                cid = f"QUOTA-{sid[:8]}-{loc}-{quota_name}"
                title = f"{label} quota in {loc}"
                detail = f"need {entry['vcpus']}, free {free} of {u['limit']} ({', '.join(entry['what'])})"
                add(cid, title, PASS if free >= entry["vcpus"] else FAIL,
                    detail if free >= entry["vcpus"] else f"{detail} – request a quota increase.", entry["section"])
    guarded("CAP", "VM sizes, zones and quota", "Resilience", capacity)

    # 8. Zones for zone-redundant resources (ILB, Bastion, public IPs) ---------------
    def region_zones():
        skus = client.vm_skus(conn, cfg.location) if conn in subs else []
        zones = set().union(*[set((s.get("locationInfo") or [{}])[0].get("zones") or []) for s in skus]) if skus else set()
        missing = sorted(set(cfg.zones) - zones)
        add("ZONES", f"Availability Zones in {cfg.location}", FAIL if missing and skus else PASS,
            f"missing zone(s) {', '.join(missing)}" if missing and skus else f"zones {', '.join(sorted(zones)) or '?'}",
            "Resilience")
    guarded("ZONES", "Availability Zones", "Resilience", region_zones)

    return checks


def summary(checks: list[Check]) -> dict[str, int]:
    return {s: sum(c.status == s for c in checks) for s in (PASS, WARN, FAIL, INFO)}
