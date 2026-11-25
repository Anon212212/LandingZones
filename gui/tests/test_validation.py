from lzdesigner.validation import validate


def fields(issues):
    return {i.field for i in issues}


def test_complete_config_is_valid(cfg):
    assert validate(cfg) == []


def test_required_inputs(cfg):
    cfg.owner = ""
    cfg.subscription_id = "not-a-guid"
    cfg.nva_admin_ssh_public_key = "hello"
    assert {"owner", "subscription_id", "nva_admin_ssh_public_key"} <= fields(validate(cfg))


def test_identity_must_use_its_own_subscription(cfg):
    cfg.identity_subscription_id = cfg.subscription_id
    assert "identity_subscription_id" in fields(validate(cfg))


def test_overlapping_address_spaces(cfg):
    cfg.auto_addressing = False
    cfg.spokes[1].address_space = "10.145.1.128/25"
    assert any("overlaps" in i.message for i in validate(cfg))


def test_ssh_never_open_to_internet(cfg):
    cfg.nva_mgmt_source_cidrs = ["0.0.0.0/0"]
    assert "nva_mgmt_source_cidrs" in fields(validate(cfg))


def test_identity_regions_distinct_and_zonal(cfg):
    cfg.identity_regions[1].location = cfg.identity_regions[0].location
    cfg.identity_regions[0].dc_zones = ["1"]
    msgs = " ".join(i.message for i in validate(cfg))
    assert "different Azure region" in msgs and "two DCs" in msgs


def test_budget_needs_recipient(cfg):
    cfg.monthly_budget_amount = 500
    assert "monthly_budget_amount" in fields(validate(cfg))


def test_ssh_key_blob_must_decode(cfg):
    cfg.nva_admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVsZXN0aW5nb25seQ test"
    assert "nva_admin_ssh_public_key" in fields(validate(cfg))


def test_spoke_rules_validated(cfg):
    from lzdesigner.model import NsgRule
    cfg.spokes[0].nsg_rules = [
        NsgRule("Allow-Web", 300, ["0.0.0.0/0"], ["443"]),
        NsgRule("Dup", 300, ["10.0.0.0/8"], ["80"]),
        NsgRule("Low", 100, ["10.0.0.0/8"], ["abc"]),
    ]
    msgs = " ".join(i.message for i in validate(cfg))
    assert "Internet" in msgs and "duplicate priority" in msgs and "300–3900" in msgs and "'abc'" in msgs


def test_spoke_names(cfg):
    cfg.spokes[0].key = "Prod-1"
    cfg.spokes[1].key = "avd"
    assert "spokes" in fields(validate(cfg))


def test_landing_zone_subscriptions_required_and_distinct(cfg):
    cfg.production_subscription_id = ""
    assert "production_subscription_id" in fields(validate(cfg))
    cfg.production_subscription_id = cfg.subscription_id
    assert any("must be different" in i.message for i in validate(cfg))
    cfg.production_subscription_id = cfg.shared_services_subscription_id
    assert any("must be different" in i.message for i in validate(cfg))


def test_unused_landing_zone_subscription_is_optional(cfg):
    for sp in cfg.spokes:
        sp.subscription = "connectivity"
    cfg.shared_services_subscription_id = cfg.production_subscription_id = ""
    assert validate(cfg) == []
