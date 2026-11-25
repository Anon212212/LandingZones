"""A fictional tenant for demos, screenshots and UI tests (LZDESIGNER_DEMO=1).

Mimics the ArmClient methods used by the pre-flight with plausible data:
an existing VNet that overlaps the default production spoke, no Network
Watcher in West Europe, and EncryptionAtHost not registered.
"""

CONN = "00000000-0000-0000-0000-000000000000"
IDENT = "11111111-1111-1111-1111-111111111111"
OWNER = "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"


class DemoTenant:
    def principal(self):
        return {"object_id": "demo-user", "tenant_id": "contoso.onmicrosoft.com", "name": "platform.admin@contoso.com"}

    def subscriptions(self):
        return [
            {"subscriptionId": CONN, "displayName": "sub-connectivity-prod", "state": "Enabled"},
            {"subscriptionId": IDENT, "displayName": "sub-identity-prod", "state": "Enabled"},
            {"subscriptionId": "22222222-2222-2222-2222-222222222222", "displayName": "sub-sandbox", "state": "Enabled"},
        ]

    def role_assignments(self, sub, principal_id):
        return [{"properties": {"scope": f"/subscriptions/{sub}", "roleDefinitionId": f"/subscriptions/{sub}{OWNER}"}}]

    def vnets(self, sub):
        if sub == CONN:
            return [{"name": "vnet-legacy-apps", "properties": {"addressSpace": {"addressPrefixes": ["10.145.2.0/24"]}}}]
        return []

    def network_watchers(self, sub):
        return [{"name": "NetworkWatcher_northeurope", "location": "northeurope",
                 "id": f"/subscriptions/{sub}/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_northeurope"}]

    def feature_state(self, sub, namespace, feature):
        return "NotRegistered"

    def vm_skus(self, sub, location):
        def sku(name, vcpus):
            return {"resourceType": "virtualMachines", "name": name, "family": "standardDSv5Family",
                    "locationInfo": [{"zones": ["1", "2", "3"]}], "restrictions": [],
                    "capabilities": [{"name": "vCPUs", "value": str(vcpus)}]}
        return [sku("Standard_D2s_v5", 2), sku("Standard_D4s_v5", 4), sku("Standard_D8s_v5", 8)]

    def usages(self, sub, location):
        return [{"name": {"value": "standardDSv5Family"}, "currentValue": 4, "limit": 50},
                {"name": {"value": "cores"}, "currentValue": 10, "limit": 100}]
