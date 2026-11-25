import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lzdesigner.model import LandingZoneConfig  # noqa: E402

VALID_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f test-only"  # structurally valid, test-only


@pytest.fixture
def cfg() -> LandingZoneConfig:
    c = LandingZoneConfig(
        owner="platform-team@contoso.com",
        cost_center="CC-1234",
        subscription_id="00000000-0000-0000-0000-000000000000",
        identity_subscription_id="11111111-1111-1111-1111-111111111111",
        nva_admin_ssh_public_key=VALID_KEY,
    )
    c.derive_addresses()
    return c
