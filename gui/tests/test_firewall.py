import re
from pathlib import Path

from lzdesigner import compliance, diagram, pricing
from lzdesigner.catalog import NVA_VENDORS
from lzdesigner.validation import validate

ROOT = Path(__file__).resolve().parents[2]


def test_catalog_matches_terraform_vendor_defaults():
    for key, v in NVA_VENDORS.items():
        if key == "linux":
            continue
        tf = (ROOT / "modules" / "vendors" / key / "main.tf").read_text()
        assert f'default_publisher = "{v.publisher}"' in tf, key
        assert re.search(rf'default_offer\s*=\s*"{re.escape(v.offer)}"', tf), key
        for lic, sku in v.skus.items():
            assert re.search(rf'{lic}\s*=\s*"{re.escape(sku)}"', tf), (key, lic)


def test_vendor_switch_coerces_mode_licence_and_size(cfg):
    cfg.set_nva_vendor("fortigate")
    cfg.nva_ha_mode = "active-standby"
    cfg.nva_license_type = "payg"
    cfg.set_nva_vendor("pfsense")             # no active-standby, no 'payg'→ kept? pfSense has payg
    assert cfg.nva_ha_mode == "active-active" and cfg.nva_license_type == "payg"
    cfg.nva_license_type = "bundle2"
    cfg.set_nva_vendor("sonicwall")
    assert cfg.nva_license_type == ""
    assert cfg.nva_size == "Standard_D4s_v5"


def test_validation_blocks_invalid_combinations(cfg):
    cfg.nva_ha_mode = "active-standby"          # linux only supports active-active
    assert any(i.field == "nva_ha_mode" for i in validate(cfg))
    cfg.set_nva_vendor("paloalto")
    cfg.nva_size = "Standard_D2s_v5"
    msgs = {i.field for i in validate(cfg)}
    assert "nva_size" in msgs and "nva_ha_mode" not in msgs


def test_next_hop_follows_mode(cfg):
    assert cfg.nva_next_hop() == "10.145.0.36"
    cfg.set_nva_vendor("sonicwall")
    cfg.nva_ha_mode = "single"
    assert cfg.nva_next_hop() == "10.145.0.37" and cfg.nva_count() == 1
    cfg.nva_ha_mode = "active-standby"
    assert cfg.nva_next_hop() == "10.145.0.36" and cfg.nva_count() == 2


def test_diagram_shows_vendor_and_mode(cfg):
    cfg.set_nva_vendor("fortigate")
    cfg.nva_ha_mode = "active-standby"
    m = diagram.build(cfg)
    assert m.byid["ilb"].lines[0] == "Floating trust VIP"
    assert "FortiGate-VM" in m.byid["nva1"].lines[1] and m.byid["nva1"].lines[5].startswith("active · BYOL")
    assert m.byid["nva2"].lines[5].startswith("standby")
    cfg.nva_ha_mode = "single"
    m = diagram.build(cfg)
    assert "nva2" not in m.byid and not any(e.id == "e_ilb_nva" for e in m.edges)


def test_firewall_controls(cfg):
    ids = {r.control.id: r.status for r in compliance.evaluate(cfg)}
    assert ids["SEC-18"] == compliance.WARN and ids["REL-13"] == compliance.PASS
    cfg.set_nva_vendor("paloalto")
    cfg.nva_ha_mode = "single"
    ids = {r.control.id: r.status for r in compliance.evaluate(cfg)}
    assert ids["SEC-18"] == compliance.PASS and ids["REL-13"] == compliance.WARN


def test_pricing_notes_vendor_licence(cfg):
    cfg.set_nva_vendor("fortigate")
    est = pricing.estimate(cfg)
    assert any("FortiGate" in line.item for line in est.lines)
    assert any("BYOL" in n for n in est.notes)
    cfg.nva_ha_mode = "active-standby"
    assert not any("Load Balancer" in line.item for line in pricing.estimate(cfg).lines)
