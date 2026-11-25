from lzdesigner.model import LandingZoneConfig


def test_defaults_match_terraform_defaults(cfg):
    assert cfg.hub_address_space == "10.145.0.0/24"
    assert [r.address_space for r in cfg.identity_regions] == ["10.145.4.0/24", "10.146.4.0/24"]
    assert cfg.ilb_ip() == "10.145.0.36"
    assert cfg.nva_ips() == [("10.145.0.4", "10.145.0.37"), ("10.145.0.5", "10.145.0.38")]
    assert cfg.dc_ips(cfg.identity_regions[1]) == ["10.146.4.4", "10.146.4.5"]


def test_derive_addresses_from_new_base(cfg):
    cfg.network_base = "172.20.0.0/16"
    cfg.add_identity_region()
    cfg.derive_addresses()
    assert cfg.hub_address_space == "172.20.0.0/24"
    assert [sp.address_space for sp in cfg.spokes] == ["172.20.1.0/24", "172.20.2.0/24", "172.20.3.0/24"]
    assert [r.address_space for r in cfg.identity_regions] == ["172.20.4.0/24", "172.21.4.0/24", "172.22.4.0/24"]


def test_presets_and_matching(cfg):
    assert cfg.matching_preset() == "standard"
    cfg.apply_resilience("maximum")
    assert cfg.nva_zones == ["1", "2", "3"]
    assert cfg.identity_backup_storage_mode == "GeoRedundant"
    assert cfg.matching_preset() == "maximum"
    cfg.nva_zones = ["1", "2"]
    assert cfg.matching_preset() == "custom"


def test_primary_location_keeps_regions_distinct(cfg):
    cfg.set_primary_location("westeurope")
    assert cfg.identity_regions[0].location == "westeurope"
    assert cfg.identity_regions[1].location == "northeurope"


def test_cannot_drop_below_two_regions(cfg):
    cfg.remove_identity_region("secondary")
    assert len(cfg.identity_regions) == 2


def test_json_round_trip(cfg):
    cfg.frameworks = ["WAF", "DORA"]
    cfg.add_identity_region()
    again = LandingZoneConfig.from_json(cfg.to_json())
    assert again == cfg


def test_extra_spokes_skip_the_identity_slot(cfg):
    cfg.add_spoke("web")
    cfg.add_spoke("data")
    assert [sp.address_space for sp in cfg.spokes][-2:] == ["10.145.5.0/24", "10.145.6.0/24"]
    assert cfg.identity_regions[0].address_space == "10.145.4.0/24"
    cfg.remove_spoke("prod")
    assert [sp.key for sp in cfg.spokes] == ["shared", "avd", "web", "data"]
    assert cfg.spokes[1].address_space == "10.145.2.0/24"
