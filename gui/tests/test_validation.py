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
    cfg.prod_address_space = "10.145.1.128/25"
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
