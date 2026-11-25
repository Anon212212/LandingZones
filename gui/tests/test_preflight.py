from lzdesigner import azure

CONN = "00000000-0000-0000-0000-000000000000"
IDENT = "11111111-1111-1111-1111-111111111111"
SHARED = "44444444-4444-4444-4444-444444444444"
PROD = "55555555-5555-5555-5555-555555555555"
AVD = "66666666-6666-6666-6666-666666666666"
OWNER = "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
CONTRIB = "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"


def sku(name, family, vcpus, zones, restricted_zones=()):
    s = {"resourceType": "virtualMachines", "name": name, "family": family,
         "locationInfo": [{"zones": list(zones)}], "capabilities": [{"name": "vCPUs", "value": str(vcpus)}],
         "restrictions": []}
    if restricted_zones:
        s["restrictions"].append({"type": "Zone", "reasonCode": "NotAvailableForSubscription",
                                  "restrictionInfo": {"zones": list(restricted_zones)}})
    return s


class FakeTenant:
    def __init__(self, **kw):
        self.vnet_map = kw.get("vnets", {})
        self.roles = kw.get("roles", {CONN: [OWNER], IDENT: [OWNER], SHARED: [OWNER], PROD: [OWNER], AVD: [OWNER]})
        self.features = kw.get("features", "Registered")
        self.restricted = kw.get("restricted", {})
        self.quota_free = kw.get("quota_free", 100)
        self.watchers = kw.get("watchers", True)

    def principal(self):
        return {"object_id": "me", "tenant_id": "t", "name": "admin@contoso.com"}

    def subscriptions(self):
        return [{"subscriptionId": CONN, "displayName": "Connectivity", "state": "Enabled"},
                {"subscriptionId": IDENT, "displayName": "Identity", "state": "Enabled"},
                {"subscriptionId": SHARED, "displayName": "Shared services", "state": "Enabled"},
                {"subscriptionId": PROD, "displayName": "Production", "state": "Enabled"},
                {"subscriptionId": AVD, "displayName": "AVD", "state": "Enabled"}]

    def role_assignments(self, sub, principal_id):
        return [{"properties": {"scope": f"/subscriptions/{sub}", "roleDefinitionId": f"/subscriptions/{sub}{r}"}}
                for r in self.roles.get(sub, [])]

    def vnets(self, sub):
        return [{"name": n, "properties": {"addressSpace": {"addressPrefixes": [p]}}} for n, p in self.vnet_map.get(sub, [])]

    def network_watchers(self, sub):
        if not self.watchers:
            return []
        return [{"name": f"NetworkWatcher_{loc}", "location": loc,
                 "id": f"/subscriptions/{sub}/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_{loc}"}
                for loc in ("northeurope", "westeurope")]

    def feature_state(self, sub, ns, name):
        return self.features

    def vm_skus(self, sub, location):
        return [sku("Standard_D2s_v5", "standardDSv5Family", 2, ["1", "2", "3"], self.restricted.get(location, ()))]

    def usages(self, sub, location):
        return [{"name": {"value": "standardDSv5Family"}, "currentValue": 0, "limit": self.quota_free},
                {"name": {"value": "cores"}, "currentValue": 0, "limit": self.quota_free}]


def status(checks):
    return {c.id.split("-")[0] if c.id.startswith(("SKU", "QUOTA", "NW")) else c.id: c.status for c in checks}


def failing(checks):
    return [c for c in checks if c.status == azure.FAIL]


def test_clean_tenant_passes(cfg):
    checks = azure.run_preflight(cfg, FakeTenant())
    assert failing(checks) == []
    assert {"SUB-Connectivity", "SUB-Identity", "RBAC-connectivity", "RBAC-identity", "NET-OVERLAP", "EAH", "ZONES"} \
        <= {c.id for c in checks}


def test_detects_overlap_but_ignores_our_own_vnets(cfg):
    tenant = FakeTenant(vnets={CONN: [("vnet-contoso-hub-prod-neu", "10.145.0.0/24"),   # ours (re-run)
                                      ("vnet-legacy", "10.145.2.0/23")]})
    bad = failing(azure.run_preflight(cfg, tenant))
    assert [c.id for c in bad] == ["NET-OVERLAP"]
    assert "vnet-legacy" in bad[0].detail and "prod" in bad[0].detail and "hub" not in bad[0].detail.split("↔")[0]


def test_contributor_alone_cannot_deploy(cfg):
    bad = failing(azure.run_preflight(cfg, FakeTenant(roles={CONN: [OWNER], IDENT: [CONTRIB], SHARED: [OWNER], PROD: [OWNER], AVD: [OWNER]})))
    assert [c.id for c in bad] == ["RBAC-identity"]


def test_encryption_at_host_needs_feature(cfg):
    cfg.nva_encryption_at_host = True
    bad = failing(azure.run_preflight(cfg, FakeTenant(features="NotRegistered")))
    assert [c.id for c in bad] == ["EAH"] and "az feature register" in bad[0].detail


def test_zone_restriction_and_quota(cfg):
    cfg.apply_resilience("high")
    bad = failing(azure.run_preflight(cfg, FakeTenant(restricted={"westeurope": ["3"]}, quota_free=4)))
    ids = [c.id for c in bad]
    assert any(i.startswith("SKU-DCs (secondary)") for i in ids)
    assert any(i.startswith("QUOTA") for i in ids)


def test_missing_watchers_warn(cfg):
    checks = azure.run_preflight(cfg, FakeTenant(watchers=False))
    assert any(c.id.startswith("NW-") and c.status == azure.WARN for c in checks)


def test_api_errors_become_warnings(cfg):
    class Broken(FakeTenant):
        def vnets(self, sub):
            raise PermissionError("403 AuthorizationFailed")
    checks = azure.run_preflight(cfg, Broken())
    c = next(c for c in checks if c.id == "NET-OVERLAP")
    assert c.status == azure.WARN and "403" in c.detail


def test_unknown_subscription_fails(cfg):
    cfg.identity_subscription_id = "22222222-2222-2222-2222-222222222222"
    bad = failing(azure.run_preflight(cfg, FakeTenant()))
    assert [c.id for c in bad] == ["SUB-Identity"]


def test_token_claims_decoding():
    import base64
    import json
    payload = base64.urlsafe_b64encode(json.dumps({"oid": "abc", "tid": "t1", "upn": "a@b.c"}).encode()).decode().rstrip("=")

    class Cred:
        def get_token(self, scope):
            class T:
                token = f"x.{payload}.y"
                expires_on = 9999999999
            return T()
    assert azure.ArmClient(Cred()).principal() == {"object_id": "abc", "tenant_id": "t1", "name": "a@b.c"}


def test_landing_zone_subscriptions_are_checked(cfg):
    tenant = FakeTenant(vnets={PROD: [("vnet-old-prod", "10.145.2.0/24")]},
                        roles={CONN: [OWNER], IDENT: [OWNER], SHARED: [OWNER], PROD: [], AVD: [OWNER]})
    checks = azure.run_preflight(cfg, tenant)
    ids = {c.id for c in checks}
    assert {"SUB-Shared services", "SUB-Production", "SUB-AVD", "RBAC-shared services", "RBAC-production", "RBAC-avd"} <= ids
    assert next(c for c in checks if c.id == "NET-OVERLAP").status == azure.FAIL
    assert next(c for c in checks if c.id == "RBAC-production").status == azure.WARN
