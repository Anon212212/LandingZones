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
