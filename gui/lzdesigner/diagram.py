"""Architecture diagram generated from a LandingZoneConfig.

`render_svg(cfg)` returns an SVG for live display. `render_drawio_svg(cfg)`
returns the same SVG with the draw.io model embedded (`content` attribute),
so the export opens and edits in diagrams.net / the VS Code extension.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from xml.sax.saxutils import escape, quoteattr

from .catalog import REGIONS
from .model import LandingZoneConfig

W = 1660
FONT = "Segoe UI, Helvetica, Arial, sans-serif"

C = {
    "blue": "#0078D4", "blue_bg": "#F2F8FD",
    "red": "#A4262C", "red_bg": "#FDF5F5",
    "green": "#107C10",
    "purple": "#5C2D91",
    "grey": "#8A8886", "grey_bg": "#FAFAFA",
    "text": "#201F1E", "muted": "#605E5C", "orange": "#CA5010",
    "off": "#C8C6C4",
}

EDGE_STYLE = {
    "traffic": dict(color=C["blue"], dash=None, start=False, width=1.8),
    "peering": dict(color=C["green"], dash="7 4", start=True, width=1.8),
    "replication": dict(color=C["purple"], dash="4 3", start=True, width=2.4),
    "backup": dict(color=C["red"], dash="2 3", start=False, width=1.8),
}

FW_COLOR = {"WAF": C["blue"], "NIS2": "#038387", "DORA": "#8764B8"}


@dataclass
class Node:
    id: str
    x: float
    y: float
    w: float
    h: float
    kind: str
    lines: list[str]
    parent: str | None = None
    stroke: str | None = None
    fill: str | None = None
    dashed: bool = False
    sw: float = 1.5


@dataclass
class Edge:
    id: str
    src: str
    dst: str
    pts: list[tuple[float, float]]
    label: str
    kind: str


@dataclass
class Model:
    height: float
    nodes: list[Node] = field(default_factory=list)
    edges: list[Edge] = field(default_factory=list)
    badges: list[str] = field(default_factory=list)

    def node(self, *a, **k) -> Node:
        n = Node(*a, **k)
        self.nodes.append(n)
        return n

    def edge(self, *a) -> None:
        self.edges.append(Edge(*a))

    @property
    def byid(self) -> dict[str, Node]:
        return {n.id: n for n in self.nodes}


def _region_name(loc: str) -> str:
    r = REGIONS.get(loc)
    return r.display if r else loc


def _region_short(loc: str) -> str:
    r = REGIONS.get(loc)
    return r.short if r else loc


def _size_short(size: str) -> str:
    return size.replace("Standard_", "")


def build(cfg: LandingZoneConfig) -> Model:
    k = len(cfg.identity_regions)
    region_h = [144 + 88 * max(len(r.dc_zones), 1) for r in cfg.identity_regions]
    id_bottom = 355 + sum(region_h) + 30 * max(k - 1, 0) + 15
    per_row = 4 if len(cfg.spokes) > 3 else 3
    spoke_rows = max(1, math.ceil(len(cfg.spokes) / per_row))
    mgmt_y = 610 + spoke_rows * 210
    dy = mgmt_y - 820                       # shift of everything below the spokes
    conn_bottom = 1040 + dy
    body_bottom = max(conn_bottom, id_bottom)
    m = Model(height=body_bottom + 70)
    m.badges = list(cfg.frameworks)

    m.node("title", 20, 14, 1100, 30, "title",
           [f"{cfg.org_prefix} · {cfg.environment} — hub & spoke with HA NVAs and tier-0 identity"])
    m.node("internet", 420, 58, 200, 56, "cloud", ["Internet"], stroke=C["grey"], fill="#FFFFFF")

    # ---------------------------------------------------------- connectivity
    m.node("sub_conn", 20, 150, 1000, conn_bottom - 150, "container",
           ["Connectivity subscription", f"{_region_name(cfg.location)} · rg-{cfg.org_prefix}-connectivity-{cfg.environment}-{_region_short(cfg.location)}"],
           stroke=C["blue"], fill=C["blue_bg"], sw=2)
    hs = cfg.hub_subnets()
    m.node("hub", 40, 200, 960, 345, "container", ["Hub VNet", f"vnet-{cfg.org_prefix}-hub · {cfg.hub_address_space}"],
           parent="sub_conn", stroke=C["green"], fill="#FFFFFF")
    m.node("sn_ext", 60, 248, 610, 110, "subnet", [f"snet-nva-external · {hs.get('nva_external', '?')}"], parent="hub")
    m.node("sn_int", 60, 372, 610, 115, "subnet", [f"snet-nva-internal · {hs.get('nva_internal', '?')}"], parent="hub")
    if cfg.enable_nat_gateway:
        m.node("nat", 80, 280, 205, 62, "res", ["NAT Gateway", "+ Standard public IP (egress)"],
               parent="sn_ext", stroke=C["blue"])
    else:
        m.node("nat", 80, 280, 205, 62, "res", ["No NAT Gateway", "egress needs another path"],
               parent="sn_ext", stroke=C["off"])
    m.node("ilb", 80, 408, 205, 66, "res",
           ["Internal Load Balancer", f"{cfg.ilb_ip() or '?'} · zone-redundant", "HA Ports → NVA pool"],
           parent="sn_int", stroke=C["blue"])

    n = max(len(cfg.nva_zones), 1)
    area_x, area_w, gap = 320, 340, 12
    bw = (area_w - gap * (n - 1)) / n
    ips = cfg.nva_ips()
    for i, z in enumerate(cfg.nva_zones):
        ext, inn = ips[i] if i < len(ips) else ("?", "?")
        if n <= 2:
            lines = [f"NVA-{i+1} · Zone {z}", f"Ubuntu 24.04 · {_size_short(cfg.nva_size)}", "",
                     f"eth0  {ext}", "", "IP forwarding · SNAT", "", f"eth1  {inn}"]
        else:
            lines = [f"NVA-{i+1}", f"Zone {z}", "", "eth0", ext, "", "eth1", inn]
        m.node(f"nva{i+1}", area_x + i * (bw + gap), 276, bw, 200, "res", lines, parent="hub", stroke=C["orange"])

    m.node("sn_mgmt", 690, 248, 290, 110, "subnet", [f"snet-mgmt · {hs.get('mgmt', '?')}"], parent="hub")
    m.node("mgmt", 710, 282, 250, 58, "res", ["Management VMs", "SSH/RDP from Bastion only"], parent="sn_mgmt", stroke=C["blue"])
    m.node("sn_bas", 690, 372, 290, 115, "subnet", [f"AzureBastionSubnet · {hs.get('bastion', '?')}"], parent="hub")
    m.node("bastion", 710, 408, 250, 66, "res", [f"Azure Bastion · {cfg.bastion_sku}", "zone-redundant", "only admin entry point"],
           parent="sn_bas", stroke=C["blue"])
    notes = ["NSG on every subnet", "private subnets"]
    if cfg.enable_flow_logs:
        notes.append("VNet flow logs")
    if cfg.ddos_protection_plan_id:
        notes.append("DDoS Network Protection")
    if cfg.nva_encryption_at_host:
        notes.append("encryption at host")
    if cfg.enable_resource_locks:
        notes.append("delete locks")
    m.node("hub_note", 60, 498, 920, 34, "note", [" · ".join(notes)], parent="hub")

    ilb = cfg.ilb_ip() or "ILB"
    spoke_boxes = []
    for idx, sp in enumerate(cfg.spokes):
        row, col = divmod(idx, per_row)
        in_row = min(per_row, len(cfg.spokes) - row * per_row)
        w = (960 - 15 * (per_row - 1)) / per_row
        x = 40 + col * (w + 15)
        y = 610 + row * 210
        name = sp.description or sp.key.capitalize()
        rules = len(sp.nsg_rules)
        m.node(f"vnet_{sp.key}", x, y, w, 175, "container", [name, f"vnet-{cfg.org_prefix}-{sp.key} · {sp.address_space}"],
               parent="sub_conn", stroke=C["green"], fill="#FFFFFF")
        m.node(f"sn_{sp.key}", x + 15, y + 50, w - 30, 70, "res",
               [sp.effective_subnet_name, f"{sp.address_space} · NSG baseline" + (f" + {rules} rule{'s' if rules != 1 else ''}" if rules else "")],
               parent=f"vnet_{sp.key}", stroke=C["grey"])
        m.node(f"udr_{sp.key}", x + 15, y + 132, w - 30, 30, "note",
               [f"UDR 0.0.0.0/0 → {ilb}" if row == 0 else f"UDR 0.0.0.0/0 → {ilb} · peered to hub"], parent=f"vnet_{sp.key}")
        spoke_boxes.append((sp.key, x, w, row))
    if not cfg.spokes:
        m.node("no_spokes", 40, 640, 960, 40, "note", ["No workload spokes – add them on the Network tab"], parent="sub_conn")

    m.node("mgmt_rg", 40, 820 + dy, 960, 200, "container", ["Platform management", f"rg-{cfg.org_prefix}-management-{cfg.environment}"],
           parent="sub_conn", stroke=C["grey"], fill="#FFFFFF")
    m.node("law", 60, 872 + dy, 215, 78, "res", ["Log Analytics", f"{cfg.log_retention_days}-day retention · Entra-only",
                                             "diagnostics from all resources"], parent="mgmt_rg", stroke=C["blue"])
    if cfg.enable_flow_logs:
        m.node("flow", 295, 872 + dy, 215, 78, "res", ["VNet flow logs", "Traffic Analytics",
                                                   f"{cfg.flow_log_retention_days}-day raw retention"], parent="mgmt_rg", stroke=C["blue"])
    else:
        m.node("flow", 295, 872 + dy, 215, 78, "res", ["VNet flow logs", "disabled", ""], parent="mgmt_rg", stroke=C["off"])
    recips = len(cfg.alert_email_addresses)
    m.node("alerts", 530, 872 + dy, 215, 78, "res",
           ["Alerts → action group", f"{recips} recipient{'s' if recips != 1 else ''}" if recips else "portal only (no recipients)",
            "ILB · NVA · NAT · Service Health"], parent="mgmt_rg", stroke=C["blue"] if recips else C["off"])
    m.node("budget", 765, 872 + dy, 215, 78, "res",
           ["Budget + mandatory tags",
            f"{cfg.monthly_budget_amount:,.0f} / month" if cfg.monthly_budget_amount > 0 else "no budget set",
            f"owner: {cfg.owner or '—'}"], parent="mgmt_rg", stroke=C["blue"])
    m.node("mgmt_note", 60, 965 + dy, 920, 34, "note",
           ["Azure Monitor Agent + DCR on NVAs · CI: fmt / validate / test / tflint / checkov"], parent="mgmt_rg")

    # ---------------------------------------------------------- identity
    m.node("sub_id", 1060, 150, 580, id_bottom - 150, "container",
           ["Identity subscription · Tier-0", "dedicated, isolated from connectivity"], stroke=C["red"], fill=C["red_bg"], sw=2)
    m.node("t0", 1080, 200, 540, 135, "container", ["Tier-0 shared services", f"rg-{cfg.org_prefix}-identity-mgmt"],
           parent="sub_id", stroke=C["red"], fill="#FFFFFF", sw=1.2, dashed=True)
    m.node("t0_law", 1095, 248, 165, 74, "res", ["Log Analytics", f"{max(cfg.log_retention_days, 365)} days · Entra-only",
                                                 "activity log + KV audit"], parent="t0", stroke=C["red"])
    kv_net = "firewalled" if cfg.identity_key_vault_allowed_ips else "public network (RBAC)"
    m.node("t0_kv", 1268, 248, 165, 74, "res", ["Key Vault (premium)", "RBAC · purge protection",
                                                "DC passwords", kv_net], parent="t0", stroke=C["red"])
    m.node("t0_dcr", 1441, 248, 165, 74, "res", ["Data collection rule", "AD DS · DNS · DFSR", "events + perf"],
           parent="t0", stroke=C["red"])

    image = "Windows Server 2025" if "2025" in cfg.dc_image_sku else "Windows Server 2022"
    backup = "GRS + CRR · immutable" if cfg.identity_backup_storage_mode == "GeoRedundant" else "ZRS · immutable"
    y0 = 355
    vnet_boxes = []
    for i, r in enumerate(cfg.identity_regions):
        dz = max(len(r.dc_zones), 1)
        rh = region_h[i]
        short = _region_short(r.location)
        role = "primary" if i == 0 else ("secondary" if i == 1 else "additional")
        net = r.address_space
        m.node(f"reg_{i}", 1080, y0, 540, rh, "container", [f"{_region_name(r.location)} ({role})",
                                                             f"rg-{cfg.org_prefix}-identity-{cfg.environment}-{short}"],
               parent="sub_id", stroke=C["purple"], fill="#FFFFFF", dashed=True)
        vh = 87 + 88 * dz
        m.node(f"idvnet_{i}", 1095, y0 + 42, 340, vh, "container", [f"vnet-{cfg.org_prefix}-identity-{short}", net],
               parent=f"reg_{i}", stroke=C["green"], fill="#FFFFFF")
        vnet_boxes.append((y0 + 42, y0 + 42 + vh))
        m.node(f"sn_dc_{i}", 1110, y0 + 88, 310, 29 + 88 * dz, "subnet",
               [f"snet-dc · {cfg.dc_subnet(net) or '?'} · NSG: AD DS from LZ CIDRs"], parent=f"idvnet_{i}")
        dc_ips = cfg.dc_ips(r)
        for j, z in enumerate(r.dc_zones):
            ip = dc_ips[j] if j < len(dc_ips) else "?"
            m.node(f"dc{j}_{i}", 1125, y0 + 118 + j * 88, 280, 74, "res",
                   [f"DC{j+1:02d} · Zone {z} · {ip}", f"{image} · {_size_short(cfg.dc_size)}", "NTDS/SYSVOL on F: (cache off)"],
                   parent=f"sn_dc_{i}", stroke=C["red"])
            yy = y0 + 155 + j * 88
            m.edge(f"e_bkp{j}_{i}", f"dc{j}_{i}", f"rsv_{i}", [(1405, yy), (1450, yy)], "", "backup")
        m.node(f"rsv_{i}", 1450, y0 + 42, 155, vh, "res",
               ["Recovery Services", "vault", "", backup, "soft delete", "", "Enhanced (V2) policy", "daily 22:00 UTC",
                "30d · 12w · 5m", "(< 180-day tombstone)"], parent=f"reg_{i}", stroke=C["purple"])

        lane = 1048 - 12 * i
        sy = 280 + 45 * i
        ty = y0 + 42 + min(175, vh - 30)
        label = "peering" if r.location == cfg.location else "global peering"
        m.edge(f"e_hub_id{i}", "hub", f"idvnet_{i}", [(1000, sy), (lane, sy), (lane, ty), (1095, ty)], label, "peering")
        y0 += rh + 30

    for i in range(len(vnet_boxes) - 1):
        m.edge(f"e_mesh{i}", f"idvnet_{i}", f"idvnet_{i+1}", [(1265, vnet_boxes[i][1]), (1265, vnet_boxes[i + 1][0])],
               "mesh peering · AD replication", "replication")

    # ---------------------------------------------------------- connectivity edges
    if cfg.enable_nat_gateway:
        m.edge("e_inet_nat", "internet", "nat", [(470, 114), (470, 132), (255, 132), (255, 280)], "egress (SNAT)", "traffic")
    m.edge("e_inet_bas", "internet", "bastion", [(620, 86), (990, 86), (990, 441), (960, 441)], "HTTPS 443 · admins", "traffic")
    m.edge("e_ilb_nva", "ilb", "nva1", [(285, 441), (320, 441)], "", "traffic")
    for key, x, w, row in spoke_boxes:
        if row == 0:  # later rows are labelled "peered to hub" to keep the drawing clean
            cx = round(x + w / 2)
            m.edge(f"e_peer_{key}", "hub", f"vnet_{key}", [(cx, 545), (cx, 610)], "peering", "peering")

    m.node("legend", 20, body_bottom + 18, 1620, 40, "legend", [])
    return m


# ====================================================================== SVG
def _fit(text: str, width: float, size: float = 11, bold: bool = False) -> str:
    """Trim text with an ellipsis so it fits roughly within `width` pixels."""
    per_char = size * (0.62 if bold else 0.56)
    max_chars = max(4, int(width / per_char))
    return text if len(text) <= max_chars else text[: max_chars - 1].rstrip() + "…"


def _t(x, y, s, size=11, weight="normal", color=C["muted"], anchor="middle", italic=False):
    st = ' font-style="italic"' if italic else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
            f'fill="{color}" text-anchor="{anchor}"{st}>{escape(s)}</text>')


def _svg_node(n: Node) -> str:
    x, y, w, h, k = n.x, n.y, n.w, n.h, n.kind
    out = []
    if k == "title":
        out.append(_t(x, y + 20, n.lines[0], 20, "600", C["text"], "start"))
    elif k == "cloud":
        out.append(f'<ellipse cx="{x+w/2}" cy="{y+h/2}" rx="{w/2}" ry="{h/2}" fill="#FFFFFF" stroke="{n.stroke}" stroke-width="1.5"/>')
        out.append(_t(x + w / 2, y + h / 2 + 5, n.lines[0], 14, "600", C["text"]))
    elif k == "container":
        dash = ' stroke-dasharray="6 4"' if n.dashed else ""
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{n.fill}" stroke="{n.stroke}" stroke-width="{n.sw}"{dash}/>')
        out.append(_t(x + 12, y + 20, _fit(n.lines[0], w - 24, 13, True), 13, "600", n.stroke, "start"))
        if len(n.lines) > 1:
            out.append(_t(x + 12, y + 35, _fit(n.lines[1], w - 24), 11, "normal", C["muted"], "start"))
    elif k == "subnet":
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="5" fill="{C["grey_bg"]}" stroke="{C["grey"]}" stroke-width="1" stroke-dasharray="4 3"/>')
        out.append(_t(x + 10, y + 17, n.lines[0], 11, "600", C["muted"], "start"))
    elif k == "res":
        off = n.stroke == C["off"]
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{"#FAFAFA" if off else "#FFFFFF"}" stroke="{n.stroke}" stroke-width="1.5"{" stroke-dasharray=\"5 3\"" if off else ""}/>')
        out.append(f'<rect x="{x+1.5}" y="{y+4}" width="4" height="{h-8}" rx="2" fill="{n.stroke}"/>')
        lh = 15
        top = y + h / 2 - (len(n.lines) - 1) * lh / 2 + 4
        for i, line in enumerate(n.lines):
            if line:
                line = _fit(line, w - 14, 12 if i == 0 else 11, i == 0)
                out.append(_t(x + w / 2 + 2, top + i * lh, line, 12 if i == 0 else 11, "600" if i == 0 else "normal",
                              (C["muted"] if off else C["text"]) if i == 0 else C["muted"]))
    elif k == "note":
        out.append(_t(x + w / 2, y + h / 2 + 4, n.lines[0], 11, "normal", C["muted"], italic=True))
    elif k == "legend":
        cx = x + 10
        out.append(_t(cx, y + 24, "Legend", 12, "600", C["text"], "start"))
        cx += 70
        for label, kind in [("traffic", "traffic"), ("VNet peering", "peering"), ("DC replication", "replication"), ("backup", "backup")]:
            s = EDGE_STYLE[kind]
            dash = f' stroke-dasharray="{s["dash"]}"' if s["dash"] else ""
            out.append(f'<line x1="{cx}" y1="{y+20}" x2="{cx+44}" y2="{y+20}" stroke="{s["color"]}" stroke-width="{s["width"]}"{dash} marker-end="url(#arr-{kind})"/>')
            out.append(_t(cx + 54, y + 24, label, 11, "normal", C["text"], "start"))
            cx += 74 + len(label) * 6.5
        for label, col in [("connectivity", C["blue"]), ("tier-0 identity", C["red"]), ("VNet", C["green"]),
                           ("region", C["purple"]), ("NVA", C["orange"]), ("disabled", C["off"])]:
            out.append(f'<rect x="{cx}" y="{y+12}" width="16" height="16" rx="3" fill="#FFFFFF" stroke="{col}" stroke-width="2"/>')
            out.append(_t(cx + 24, y + 24, label, 11, "normal", C["text"], "start"))
            cx += 40 + len(label) * 6.5
    return "\n".join(out)


def _path_mid(pts):
    segs = list(zip(pts, pts[1:]))
    lens = [math.dist(a, b) for a, b in segs]
    half = sum(lens) / 2
    for (a, b), ln in zip(segs, lens):
        if half <= ln:
            f = half / ln if ln else 0
            return a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f
        half -= ln
    return pts[-1]


def _svg_edge(e: Edge) -> str:
    s = EDGE_STYLE[e.kind]
    d = "M " + " L ".join(f"{x} {y}" for x, y in e.pts)
    dash = f' stroke-dasharray="{s["dash"]}"' if s["dash"] else ""
    start = f' marker-start="url(#arr-{e.kind})"' if s["start"] else ""
    out = [f'<path d="{d}" fill="none" stroke="{s["color"]}" stroke-width="{s["width"]}"{dash}{start} marker-end="url(#arr-{e.kind})"/>']
    if e.label:
        mx, my = _path_mid(e.pts)
        tw = len(e.label) * 6.2 + 10
        out.append(f'<rect x="{mx-tw/2:.1f}" y="{my-9:.1f}" width="{tw:.1f}" height="17" rx="3" fill="#FFFFFF" stroke="{s["color"]}" stroke-width="0.8"/>')
        out.append(_t(mx, my + 4, e.label, 11, "600", s["color"]))
    return "\n".join(out)


def _badges(m: Model) -> str:
    out, x = [], W - 20
    for fw in reversed(m.badges):
        w = len(fw) * 9 + 46
        x -= w
        col = FW_COLOR.get(fw, C["blue"])
        out.append(f'<rect x="{x}" y="18" width="{w}" height="26" rx="13" fill="{col}"/>')
        out.append(_t(x + w / 2, 35.5, f"✓ {fw}", 12, "600", "#FFFFFF"))
        x -= 8
    if m.badges:
        out.append(_t(x - 4, 35.5, "Aligned to", 12, "normal", C["muted"], "end"))
    return "\n".join(out)


def _markers() -> str:
    return "<defs>" + "".join(
        f'<marker id="arr-{k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{s["color"]}"/></marker>' for k, s in EDGE_STYLE.items()) + "</defs>"


def _depth(n: Node, byid) -> int:
    d, p = 0, n.parent
    while p:
        d, p = d + 1, byid[p].parent
    return d


def render_svg(cfg: LandingZoneConfig, content: str | None = None) -> str:
    m = build(cfg)
    byid = m.byid
    order = {"container": 0, "subnet": 1}
    nodes = sorted(m.nodes, key=lambda n: (order.get(n.kind, 2), _depth(n, byid)))
    front = ("res", "note", "cloud", "legend", "title")
    body = [_svg_node(n) for n in nodes if n.kind not in front]
    body += [_svg_edge(e) for e in m.edges]
    body += [_svg_node(n) for n in nodes if n.kind in front]
    body.append(_badges(m))
    content_attr = f" content={quoteattr(content)}" if content else ""
    H = int(m.height)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="{W}" height="{H}" viewBox="0 0 {W} {H}"{content_attr}>\n'
            f'{_markers()}\n<rect width="{W}" height="{H}" fill="#FFFFFF"/>\n' + "\n".join(body) + "\n</svg>\n")


# ====================================================================== draw.io
def _html(n: Node) -> str:
    if n.kind in ("container", "res"):
        v = f"<b>{escape(n.lines[0])}</b>"
        for ln in n.lines[1:]:
            v += f'<br><font style="font-size:11px" color="{C["muted"]}">{escape(ln) if ln else "&nbsp;"}</font>'
        return v
    return escape(n.lines[0]) if n.lines else ""


def _style(n: Node) -> str:
    k = n.kind
    if k == "title":
        return "text;html=1;align=left;verticalAlign=middle;fontSize=20;fontStyle=1;fontColor=#201F1E;"
    if k == "cloud":
        return f"ellipse;whiteSpace=wrap;html=1;fillColor=#FFFFFF;strokeColor={n.stroke};strokeWidth=1.5;fontSize=14;fontStyle=1;"
    if k == "container":
        return (f"rounded=1;arcSize=8;absoluteArcSize=1;whiteSpace=wrap;html=1;container=1;collapsible=0;recursiveResize=0;"
                f"verticalAlign=top;align=left;spacingLeft=10;spacingTop=2;fontSize=13;fontColor={n.stroke};"
                f"fillColor={n.fill};strokeColor={n.stroke};strokeWidth={n.sw};dashed={int(n.dashed)};")
    if k == "subnet":
        return (f"rounded=1;arcSize=5;absoluteArcSize=1;whiteSpace=wrap;html=1;container=1;collapsible=0;recursiveResize=0;"
                f"verticalAlign=top;align=left;spacingLeft=8;fontSize=11;fontStyle=1;fontColor={C['muted']};"
                f"fillColor={C['grey_bg']};strokeColor={C['grey']};dashed=1;")
    if k == "res":
        return (f"rounded=1;arcSize=6;absoluteArcSize=1;whiteSpace=wrap;html=1;fillColor=#FFFFFF;strokeColor={n.stroke};"
                f"strokeWidth=1.5;fontSize=12;fontColor={C['text']};dashed={int(n.stroke == C['off'])};")
    return f"text;html=1;align=center;verticalAlign=middle;fontSize=11;fontStyle=2;fontColor={C['muted']};"


def drawio_xml(cfg: LandingZoneConfig) -> str:
    m = build(cfg)
    byid = m.byid
    cells = ['<mxCell id="0"/>', '<mxCell id="1" parent="0"/>']
    for n in m.nodes:
        if n.kind == "legend":
            continue
        px, py = (byid[n.parent].x, byid[n.parent].y) if n.parent else (0, 0)
        cells.append(f'<mxCell id={quoteattr(n.id)} value={quoteattr(_html(n))} style={quoteattr(_style(n))} vertex="1" '
                     f'parent={quoteattr(n.parent or "1")}><mxGeometry x="{n.x-px:.1f}" y="{n.y-py:.1f}" '
                     f'width="{n.w:.1f}" height="{n.h:.1f}" as="geometry"/></mxCell>')
    for e in m.edges:
        s = EDGE_STYLE[e.kind]
        a, b = byid[e.src], byid[e.dst]
        (x0, y0), (x1, y1) = e.pts[0], e.pts[-1]
        style = (f"edgeStyle=none;rounded=0;html=1;strokeColor={s['color']};strokeWidth={s['width']};endArrow=block;endFill=1;"
                 f"startArrow={'block' if s['start'] else 'none'};startFill=1;dashed={int(bool(s['dash']))};"
                 f"{('dashPattern=' + s['dash'] + ';') if s['dash'] else ''}fontSize=11;fontStyle=1;fontColor={s['color']};"
                 f"labelBackgroundColor=#FFFFFF;labelBorderColor={s['color']};"
                 f"exitX={(x0-a.x)/a.w:.4f};exitY={(y0-a.y)/a.h:.4f};exitDx=0;exitDy=0;"
                 f"entryX={(x1-b.x)/b.w:.4f};entryY={(y1-b.y)/b.h:.4f};entryDx=0;entryDy=0;")
        pts = "".join(f'<mxPoint x="{x}" y="{y}"/>' for x, y in e.pts[1:-1])
        cells.append(f'<mxCell id={quoteattr(e.id)} value={quoteattr(escape(e.label))} style={quoteattr(style)} edge="1" parent="1" '
                     f'source={quoteattr(e.src)} target={quoteattr(e.dst)}><mxGeometry relative="1" as="geometry">'
                     f'<Array as="points">{pts}</Array></mxGeometry></mxCell>')
    H = int(m.height)
    return (f'<mxfile host="app.diagrams.net" type="device"><diagram id="landing-zone" name="Landing zone">'
            f'<mxGraphModel dx="{W}" dy="{H}" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" '
            f'page="1" pageScale="1" pageWidth="{W}" pageHeight="{H}" background="#FFFFFF" math="0" shadow="0">'
            f'<root>{"".join(cells)}</root></mxGraphModel></diagram></mxfile>')


def render_drawio_svg(cfg: LandingZoneConfig) -> str:
    return render_svg(cfg, content=drawio_xml(cfg))
