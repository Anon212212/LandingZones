import xml.dom.minidom as minidom

from lzdesigner import diagram


def test_svg_and_drawio_are_well_formed(cfg):
    doc = minidom.parseString(diagram.render_drawio_svg(cfg))
    model = minidom.parseString(doc.documentElement.getAttribute("content"))
    cells = model.getElementsByTagName("mxCell")
    ids = {x.getAttribute("id") for x in cells}
    for x in cells:
        if x.getAttribute("parent"):
            assert x.getAttribute("parent") in ids
        if x.getAttribute("edge") == "1":
            assert x.getAttribute("source") in ids and x.getAttribute("target") in ids


def test_diagram_follows_the_configuration(cfg):
    cfg.apply_resilience("high")
    cfg.add_identity_region()
    cfg.enable_nat_gateway = False
    m = diagram.build(cfg)
    ids = {n.id for n in m.nodes}
    assert {"nva1", "nva2", "nva3"} <= ids
    assert sum(1 for n in m.nodes if n.id.startswith("reg_")) == 3
    assert sum(1 for n in m.nodes if n.id.startswith("dc")) == 9
    assert not any(e.id == "e_inet_nat" for e in m.edges)
    assert sum(1 for e in m.edges if e.kind == "replication") == 2


def test_badges_show_frameworks(cfg):
    cfg.frameworks = ["WAF", "DORA"]
    svg = diagram.render_svg(cfg)
    assert "✓ DORA" in svg and "✓ NIS2" not in svg


def test_diagram_grows_with_spokes(cfg):
    base = diagram.build(cfg).height
    for i in range(3):
        cfg.add_spoke(f"app{i}")
    m = diagram.build(cfg)
    assert sum(1 for n in m.nodes if n.id.startswith("vnet_")) == 6
    assert sum(1 for e in m.edges if e.id.startswith("e_peer_")) == 4      # first row of four
    assert m.height >= base


def test_landing_zone_frames(cfg):
    m = diagram.build(cfg)
    frames = {n.id: n for n in m.nodes if n.kind == "frame"}
    assert set(frames) == {"lz_shared_0", "lz_prod_0"}
    assert m.byid["vnet_shared"].parent == "lz_shared_0" and m.byid["vnet_avd"].parent == "sub_conn"
    assert frames["lz_prod_0"].lines[0].startswith("Production subscription · 55555555")
    assert "(cont.)" not in frames["lz_shared_0"].lines[0]
