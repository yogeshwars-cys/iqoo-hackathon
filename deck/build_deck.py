"""
Vault (PocketRAG) - deck generator.

Describes the system that exists in this repository, as built and measured:
the Flutter vault app (vault_rag_test/), the desktop tooling (bridge/), the
model-prep pipeline (modelprep/) and the explainer (vault_video/).

Every number on a slide carries a status chip saying where it came from:
MEASURED ON DEVICE (iQOO 15 runs), VERIFIED (host tests / tooling), BUILT -
NOT HARDENED, TARGET / DESIGNED (not built), OPEN GAP. Nothing is upgraded.

Editorial grid: eyebrow -> headline -> standfirst -> content -> hairline +
folio. Palette: green = on-device / verified, red = left the device or
failed, amber = built but unproven, violet = roadmap.

    python build_deck.py
"""

import os

from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE, MSO_CONNECTOR
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.dml import MSO_LINE_DASH_STYLE
from pptx.oxml.ns import qn
from pptx.oxml import parse_xml

# ----------------------------------------------------------------- tokens ---

VOID      = "0B1120"   # deepest ground
BG        = "0F172A"   # page
PANEL     = "10192E"   # sunken card
PANEL2    = "16213B"   # raised card
RULE      = "2A3854"   # visible hairline
RULE_SOFT = "1B2740"   # barely-there hairline
INK       = "FFFFFF"   # primary text
BODY      = "94A3B8"   # running text  (4.6:1 on BG)
MUTED     = "64748B"   # labels, captions
DIM       = "44546F"   # furniture

ACCENT    = "22C55E"   # on-device, private, verifiable
DANGER    = "DC2626"   # it left the device
AMBER     = "F0B429"   # built, not hardened
ROADMAP   = "7C8CF8"   # designed, not built

DISPLAY = "Aptos Display"
TEXT    = "Aptos"
MONO    = "Consolas"

M      = 0.65          # page margin
CW     = 12.03         # content width
FOOT_Y = 6.88          # hairline
PAGE_Y = 7.02          # folio

STATUS = {
    "measured": (ACCENT,  "MEASURED ON DEVICE"),
    "verified": (ACCENT,  "VERIFIED"),
    "built":    (AMBER,   "BUILT - NOT HARDENED"),
    "target":   (ROADMAP, "TARGET BUILD"),
    "roadmap":  (ROADMAP, "DESIGNED - NOT BUILT"),
    "gap":      (DANGER,  "OPEN GAP"),
}


def mix(a, b, t):
    """Blend two hex colours; t=0 -> a, t=1 -> b."""
    av = [int(a[i:i + 2], 16) for i in (0, 2, 4)]
    bv = [int(b[i:i + 2], 16) for i in (0, 2, 4)]
    return "".join(f"{int(av[i] + (bv[i] - av[i]) * t):02X}" for i in range(3))


# ---------------------------------------------------------------- helpers ---

def rect(sl, x, y, w, h, fill=None, line=None, lw=0.75,
         shape=MSO_SHAPE.RECTANGLE, dash=None, alpha=None):
    s = sl.shapes.add_shape(shape, Inches(x), Inches(y), Inches(w), Inches(h))
    s.shadow.inherit = False
    if fill:
        s.fill.solid()
        s.fill.fore_color.rgb = RGBColor.from_string(fill)
        if alpha is not None:
            clr = s._element.spPr.find(qn("a:solidFill")).find(qn("a:srgbClr"))
            clr.append(parse_xml(
                '<a:alpha xmlns:a="http://schemas.openxmlformats.org/'
                f'drawingml/2006/main" val="{int(alpha * 100000)}"/>'))
    else:
        s.fill.background()
    if line:
        s.line.color.rgb = RGBColor.from_string(line)
        s.line.width = Pt(lw)
        if dash:
            s.line.dash_style = dash
    else:
        s.line.fill.background()
    if s.has_text_frame:
        s.text_frame.word_wrap = True
        s.text_frame.text = ""
    return s


def rrect(sl, x, y, w, h, fill=None, line=None, lw=0.75, radius=0.06,
          alpha=None, dash=None):
    s = rect(sl, x, y, w, h, fill, line, lw, MSO_SHAPE.ROUNDED_RECTANGLE,
             dash=dash, alpha=alpha)
    try:
        s.adjustments[0] = radius / min(w, h) if min(w, h) else 0.05
    except Exception:
        pass
    return s


def oval(sl, cx, cy, r, fill=None, line=None, lw=0.75):
    return rect(sl, cx - r, cy - r, r * 2, r * 2, fill, line, lw, MSO_SHAPE.OVAL)


def hair(sl, x, y, w, color=RULE, thick=0.011):
    return rect(sl, x, y, w, thick, fill=color)


def line(sl, x1, y1, x2, y2, color=RULE, lw=0.75, dash=None):
    c = sl.shapes.add_connector(MSO_CONNECTOR.STRAIGHT,
                                Inches(x1), Inches(y1), Inches(x2), Inches(y2))
    c.line.color.rgb = RGBColor.from_string(color)
    c.line.width = Pt(lw)
    if dash:
        c.line.dash_style = dash
    c.shadow.inherit = False
    return c


def txt(sl, x, y, w, h, s, size=10, color=BODY, bold=False, font=TEXT,
        align=PP_ALIGN.LEFT, spc=0.0, lh=None, anchor=MSO_ANCHOR.TOP,
        italic=False, caps=False):
    """One paragraph of text. spc is letter-spacing in points."""
    tb = sl.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    tf.vertical_anchor = anchor
    p = tf.paragraphs[0]
    p.alignment = align
    if lh:
        p.line_spacing = lh
    r = p.add_run()
    r.text = s.upper() if caps else s
    f = r.font
    f.name = font
    f.size = Pt(size)
    f.bold = bold
    f.italic = italic
    f.color.rgb = RGBColor.from_string(color)
    if spc:
        r.font._element.set("spc", str(int(spc * 100)))
    return tb


def rich(sl, x, y, w, h, parts, size=10, color=BODY, font=TEXT, lh=1.25,
         align=PP_ALIGN.LEFT):
    """parts = [(text, {size, color, bold, font, spc, italic}), ...]"""
    tb = sl.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    p = tf.paragraphs[0]
    p.alignment = align
    p.line_spacing = lh
    for text, ov in parts:
        r = p.add_run()
        r.text = text
        f = r.font
        f.name = ov.get("font", font)
        f.size = Pt(ov.get("size", size))
        f.bold = ov.get("bold", False)
        f.italic = ov.get("italic", False)
        f.color.rgb = RGBColor.from_string(ov.get("color", color))
        if ov.get("spc"):
            r.font._element.set("spc", str(int(ov["spc"] * 100)))
    return tb


def freeform(sl, pts, color=ACCENT, lw=1.0, dash=None):
    e = lambda v: Emu(int(v * 914400))
    b = sl.shapes.build_freeform(e(pts[0][0]), e(pts[0][1]))
    b.add_line_segments([(e(px), e(py)) for px, py in pts[1:]], close=False)
    s = b.convert_to_shape()
    s.fill.background()
    s.line.color.rgb = RGBColor.from_string(color)
    s.line.width = Pt(lw)
    if dash:
        s.line.dash_style = dash
    s.shadow.inherit = False
    return s


def scrim(sl, x, y, w, h, stops, angle=0, base=BG):
    """Gradient wash, used to sink decorative fields behind type."""
    s = rect(sl, x, y, w, h)
    gs = "".join(
        f'<a:gs pos="{int(pos * 100000)}">'
        f'<a:srgbClr val="{base}"><a:alpha val="{int(a * 100000)}"/></a:srgbClr>'
        f"</a:gs>"
        for pos, a in stops
    )
    xml = (
        '<a:gradFill xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
        ' rotWithShape="1">'
        f"<a:gsLst>{gs}</a:gsLst>"
        f'<a:lin ang="{int(angle * 60000)}" scaled="0"/>'
        "</a:gradFill>"
    )
    spPr = s._element.spPr
    for tag in ("a:solidFill", "a:noFill", "a:gradFill"):
        el = spPr.find(qn(tag))
        if el is not None:
            spPr.remove(el)
    ln = spPr.find(qn("a:ln"))
    (spPr.insert(list(spPr).index(ln), parse_xml(xml)) if ln is not None
     else spPr.append(parse_xml(xml)))
    return s


def chip_w(kind):
    return 0.062 * len(STATUS[kind][1]) + 0.26


def chip(sl, x, y, kind, w=None):
    color, label = STATUS[kind]
    w = w or chip_w(kind)
    s = rrect(sl, x, y, w, 0.185, fill=mix(BG, color, 0.14),
              line=mix(BG, color, 0.42), lw=0.6, radius=0.03)
    txt(sl, x, y + 0.028, w, 0.16, label, 6.5, color, True,
        align=PP_ALIGN.CENTER, spc=0.55)
    return s


# ----------------------------------------------------------- slide chrome ---

def new_slide(prs):
    sl = prs.slides.add_slide(prs.slide_layouts[6])
    rect(sl, 0, 0, 13.333, 7.5, fill=BG)
    return sl


def chrome(sl, eyebrow, headline, standfirst=None, folio=None, link=None,
           head_size=27):
    txt(sl, M, 0.38, 9.6, 0.24, eyebrow, 8.5, MUTED, True, spc=1.5, caps=True)
    txt(sl, M, 0.80, CW, 0.80, headline, head_size, INK, False, DISPLAY, lh=1.02)
    if standfirst:
        txt(sl, M, 1.62, 11.3, 0.50, standfirst, 11.5, BODY, lh=1.25)
    hair(sl, M, FOOT_Y, CW, RULE_SOFT)
    if link:
        txt(sl, M, PAGE_Y, 9.6, 0.22, link, 8, DIM, spc=0.3)
    if folio:
        txt(sl, 11.90, PAGE_Y, 0.78, 0.22, folio, 8.5, MUTED, True,
            align=PP_ALIGN.RIGHT, spc=0.8)


def section_label(sl, x, y, s, w=5.6, color=MUTED):
    txt(sl, x, y, w, 0.22, s, 8, color, True, spc=1.4, caps=True)


def stat(sl, x, y, w, value, label, vcolor=INK, vsize=27, lsize=7.5):
    txt(sl, x, y, w, 0.46, value, vsize, vcolor, False, DISPLAY)
    txt(sl, x, y + 0.46, w, 0.36, label, lsize, MUTED, True, spc=0.9, caps=True)


def bullet_rows(sl, x, y, w, rows, gap=0.66, tsize=9.5, bsize=8.8,
                tcolor=INK, bcolor=BODY, lh=1.22):
    for i, (head, body) in enumerate(rows):
        yy = y + gap * i
        txt(sl, x, yy, w, 0.22, head, tsize, tcolor, True)
        txt(sl, x, yy + 0.235, w, gap - 0.24, body, bsize, bcolor, lh=lh)


def table(sl, x, y, w, cols, rows, header_size=7.5, cell_size=8.6,
          row_h=0.335, head_h=0.30, first_bold=True, colors=None):
    """cols = [(label, width_fraction), ...]; colors tints the last column."""
    xs, acc = [], 0.0
    for _, fr in cols:
        xs.append(x + acc * w)
        acc += fr
    for (label, fr), cx in zip(cols, xs):
        txt(sl, cx, y, fr * w - 0.08, 0.22, label, header_size, MUTED, True,
            spc=1.0, caps=True)
    hair(sl, x, y + head_h, w, RULE)
    for r, row in enumerate(rows):
        yy = y + head_h + 0.10 + r * row_h
        for ci, ((_, fr), cx, val) in enumerate(zip(cols, xs, row)):
            bold = first_bold and ci == 0
            color = INK if bold else BODY
            if colors and colors[r] and ci == len(cols) - 1:
                color = colors[r]
                bold = True
            txt(sl, cx, yy, fr * w - 0.10, row_h - 0.04, val, cell_size, color,
                bold, lh=1.14)
        if r < len(rows) - 1:
            hair(sl, x, yy + row_h - 0.075, w, RULE_SOFT)
    return y + head_h + 0.10 + len(rows) * row_h


# ------------------------------------------------------------- visual kit ---

def starfield(sl, x, y, w, h, n=90, seed=11, color=ACCENT):
    """Faint idle-silicon field. Decoration that stays out of the way."""
    rnd = seed
    for _ in range(n):
        rnd = (rnd * 1103515245 + 12345) % 2147483648
        px = x + (rnd / 2147483648) * w
        rnd = (rnd * 1103515245 + 12345) % 2147483648
        py = y + (rnd / 2147483648) * h
        rnd = (rnd * 1103515245 + 12345) % 2147483648
        t = 0.72 + (rnd / 2147483648) * 0.24
        oval(sl, px, py, 0.017, fill=mix(color, BG, t))


def device(sl, x, y, w, h, label, sub, accent=None, rows=None, notch=False,
           footer=None):
    """A phone or laptop outline with its contents stacked inside."""
    edge = mix(BG, accent, 0.44) if accent else RULE
    rrect(sl, x, y, w, h, fill=PANEL, line=edge, lw=1.0,
          radius=0.14 if notch else 0.10)
    if notch:
        rect(sl, x + w / 2 - 0.24, y + 0.085, 0.48, 0.045,
             fill=mix(BG, accent, 0.30))
    else:
        hair(sl, x + 0.16, y + h - 0.20, w - 0.32, RULE_SOFT)
    txt(sl, x, y + 0.24, w, 0.20, label, 8.5, INK, True,
        align=PP_ALIGN.CENTER, spc=1.1)
    txt(sl, x, y + 0.44, w, 0.18, sub, 7, accent or MUTED, True,
        align=PP_ALIGN.CENTER, spc=1.2)
    ry = y + 0.76
    for name, meta in rows or []:
        rrect(sl, x + 0.16, ry, w - 0.32, 0.40, fill=PANEL2,
              line=RULE_SOFT, lw=0.6, radius=0.04)
        txt(sl, x + 0.30, ry + 0.055, w - 0.60, 0.18, name, 8, INK, True)
        txt(sl, x + 0.30, ry + 0.215, w - 0.60, 0.16, meta, 6.8, MUTED)
        ry += 0.48
    if footer:
        hair(sl, x + 0.16, ry + 0.10, w - 0.32, RULE_SOFT)
        txt(sl, x + 0.16, ry + 0.26, w - 0.32, 0.40, footer, 7.6,
            accent or MUTED, lh=1.26, align=PP_ALIGN.CENTER)


def arrow(sl, x1, y, x2, label, sub=None, color=ACCENT, above=True, lw=1.2):
    """Horizontal labelled arrow between the two devices."""
    line(sl, x1, y, x2, y, color, lw)
    d = 0.09 if x2 > x1 else -0.09
    freeform(sl, [(x2 - d, y - 0.062), (x2, y), (x2 - d, y + 0.062)], color, lw)
    mid = (x1 + x2) / 2
    ty = y - 0.40 if above else y + 0.12
    txt(sl, mid - 1.35, ty, 2.70, 0.20, label, 8, color, True,
        align=PP_ALIGN.CENTER, spc=0.8, caps=True)
    if sub:
        txt(sl, mid - 1.35, ty + 0.19, 2.70, 0.18, sub, 7.2, MUTED,
            align=PP_ALIGN.CENTER)


def boundary(sl, x, y, h, label="TRUST BOUNDARY"):
    for i in range(int(h / 0.14)):
        rect(sl, x, y + i * 0.14, 0.014, 0.075, fill=mix(BG, INK, 0.24))
    if label:
        txt(sl, x - 0.95, y - 0.30, 1.90, 0.20, label, 7, MUTED, True,
            align=PP_ALIGN.CENTER, spc=1.3)


def barrier(sl, x, y, w, h, label):
    """A red 'this never happens' plate - the cloud path, crossed out."""
    rrect(sl, x, y, w, h, fill=mix(BG, DANGER, 0.10),
          line=mix(BG, DANGER, 0.38), lw=0.8, radius=0.05,
          dash=MSO_LINE_DASH_STYLE.DASH)
    txt(sl, x, y + h / 2 - 0.11, w, 0.22, label, 8, DANGER, True,
        align=PP_ALIGN.CENTER, spc=0.9, caps=True)


def stage_chain(sl, x, y, w, stages, color=ACCENT, box_h=0.86):
    """Pipeline stages left to right, each with a caption underneath."""
    n = len(stages)
    gap = 0.16
    bw = (w - gap * (n - 1)) / n
    for i, (title, meta, note) in enumerate(stages):
        bx = x + i * (bw + gap)
        rrect(sl, bx, y, bw, box_h, fill=PANEL, line=RULE_SOFT, lw=0.7,
              radius=0.05)
        rect(sl, bx, y, bw, 0.032, fill=mix(BG, color, 0.55 - i * 0.06))
        txt(sl, bx + 0.14, y + 0.16, bw - 0.28, 0.20, title, 8.5, INK, True,
            spc=0.4)
        txt(sl, bx + 0.14, y + 0.38, bw - 0.28, box_h - 0.46, meta, 7.4, BODY,
            lh=1.2)
        txt(sl, bx + 0.14, y + box_h + 0.10, bw - 0.20, 0.20, note, 7, color,
            True, spc=0.6, caps=True)
        if i < n - 1:
            txt(sl, bx + bw, y + box_h / 2 - 0.10, gap, 0.20, ">", 11, DIM,
                align=PP_ALIGN.CENTER)


def meter(sl, x, y, w, frac, color=ACCENT, h=0.10, track=None):
    rrect(sl, x, y, w, h, fill=track or mix(BG, INK, 0.09), radius=h / 2)
    if frac > 0:
        rrect(sl, x, y, max(w * frac, h), h, fill=color, radius=h / 2)


# ============================================================ diagram kit ===

import math


def node(sl, x, y, w, h, title, meta=None, color=None, fill=PANEL,
         tsize=8.6, msize=7.2, center=False, bar=True):
    """Rounded box: optional coloured top bar, bold title, wrapped meta."""
    edge = mix(BG, color, 0.45) if color else RULE_SOFT
    rrect(sl, x, y, w, h, fill=fill, line=edge, lw=0.8, radius=0.05)
    if color and bar:
        rect(sl, x, y, w, 0.03, fill=mix(BG, color, 0.62))
    al = PP_ALIGN.CENTER if center else PP_ALIGN.LEFT
    txt(sl, x + 0.11, y + 0.09, w - 0.22, 0.20, title, tsize, INK, True, align=al)
    if meta:
        txt(sl, x + 0.11, y + 0.30, w - 0.22, h - 0.34, meta, msize, BODY,
            lh=1.17, align=al)


def arr(sl, x1, y1, x2, y2, color=ACCENT, lw=1.1, label=None, lcolor=None,
        dash=None, lw_box=1.9, loff=-0.21, lsize=7):
    """Straight arrow with a head at (x2, y2) and an optional mid label."""
    line(sl, x1, y1, x2, y2, color, lw, dash)
    ang = math.atan2(y2 - y1, x2 - x1)
    L, W = 0.085, 0.055
    bx, by = x2 - L * math.cos(ang), y2 - L * math.sin(ang)
    p1 = (bx + W * math.sin(ang), by - W * math.cos(ang))
    p2 = (bx - W * math.sin(ang), by + W * math.cos(ang))
    freeform(sl, [p1, (x2, y2), p2], color, lw)
    if label:
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        txt(sl, mx - lw_box / 2, my + loff, lw_box, 0.19, label, lsize,
            lcolor or color, True, align=PP_ALIGN.CENTER, spc=0.4)


def lifeline(sl, x, y, h, title, sub, color=None, w=2.0):
    """Sequence-diagram actor header plus dashed lifeline."""
    node(sl, x - w / 2, y, w, 0.52, title, sub, color, tsize=8.2, msize=6.8,
         center=True)
    line(sl, x, y + 0.52, x, y + h, mix(BG, INK, 0.22), 0.8,
         MSO_LINE_DASH_STYLE.DASH)


def paras(sl, x, y, w, h, rows, size=8, color=BODY, font=TEXT, lh=1.15):
    """Several paragraphs; row = str or (text, color, bold)."""
    tb = sl.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    for i, row in enumerate(rows):
        text, c, b = (row, color, False) if isinstance(row, str) else row
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.line_spacing = lh
        r = p.add_run()
        r.text = text
        r.font.name = font
        r.font.size = Pt(size)
        r.font.bold = b
        r.font.color.rgb = RGBColor.from_string(c)
    return tb


def code(sl, x, y, w, h, rows, size=7.4, title=None):
    rrect(sl, x, y, w, h, fill=VOID, line=RULE_SOFT, lw=0.7, radius=0.04)
    top = y + 0.12
    if title:
        txt(sl, x + 0.14, y + 0.10, w - 0.28, 0.18, title, 6.8, MUTED, True,
            spc=1.1, caps=True)
        top = y + 0.34
    paras(sl, x + 0.14, top, w - 0.28, h - (top - y) - 0.08, rows, size,
          BODY, MONO, lh=1.12)


def status_line(sl, kind, text, y=6.56):
    chip(sl, M, y, kind)
    txt(sl, M + chip_w(kind) + 0.16, y + 0.02, CW - chip_w(kind) - 0.2, 0.20,
        text, 7.8, DIM)


def pill(sl, x, y, text, color, w=None):
    w = w or (0.058 * len(text) + 0.30)
    rrect(sl, x, y, w, 0.24, fill=mix(BG, color, 0.16),
          line=mix(BG, color, 0.5), lw=0.6, radius=0.05)
    txt(sl, x, y + 0.045, w, 0.18, text, 7, color, True, align=PP_ALIGN.CENTER,
        spc=0.5)
    return w


# =========================================================== slide builders ==

def s_hero(prs):
    sl = new_slide(prs)
    starfield(sl, 6.9, 0.3, 6.2, 6.9, n=110)
    scrim(sl, 5.6, 0, 7.8, 7.5, [(0, 1.0), (0.45, 0.55), (1, 0.0)], angle=0)
    txt(sl, M, 0.60, 6, 0.24, "iQOO hackathon 2026 · vault / pocketrag", 9,
        MUTED, True, spc=1.6, caps=True)
    txt(sl, M, 1.45, 7.6, 1.4, "Your documents stay on the phone.\n"
        "Your laptop gets a signed answer.", 30, INK, False, DISPLAY, lh=1.05)
    txt(sl, M, 3.05, 6.9, 1.4,
        "Vault is an on-device RAG system for the iQOO 15. The phone holds the "
        "corpus, the encrypted index, the encoder and the reasoner. A laptop "
        "asks over an encrypted clipboard link and receives a context capsule "
        "that is signed by a key living in StrongBox.", 13, BODY, lh=1.32)
    rows = [("NPU", "MiniLM embeddings via Qualcomm QNN HTP", ACCENT),
            ("GPU", "one reasoner: llama.cpp OpenCL or MediaPipe", ACCENT),
            ("TEE", "AES-256-GCM at rest · ECDSA-P256 capsules", ACCENT),
            ("LINK", "VAULTLINK/2 over Office Kit clipboard", ACCENT)]
    for i, (k, v, c) in enumerate(rows):
        yy = 5.02 + i * 0.36
        pill(sl, M, yy, k, c, 0.62)
        txt(sl, M + 0.78, yy + 0.035, 5.6, 0.22, v, 10, INK)
    node(sl, 8.2, 1.95, 4.45, 3.55, "What is in this repository", None, ACCENT,
         tsize=10)
    paras(sl, 8.34, 2.40, 4.2, 3.0, [
        ("vault_rag_test/", INK, True), "Flutter + Kotlin + C++ phone app",
        ("bridge/", INK, True), "desktop VaultLink client, verifier, LAN "
        "bridge server, MCP tools, eval corpus",
        ("modelprep/", INK, True), "MiniLM ONNX → TFLite export + verification",
        ("vault_video/ · deck/", INK, True), "Remotion explainer · this deck",
        ("SECURITY.md · NPU_QNN.md", INK, True), "threat model · NPU bring-up",
    ], 9.6, BODY, lh=1.22)
    hair(sl, M, FOOT_Y, CW, RULE_SOFT)
    txt(sl, M, PAGE_Y, 9, 0.22, "branch vault/coprocessor-gemma-capsule",
        8, DIM)
    return sl


def s_problem(prs):
    sl = new_slide(prs)
    chrome(sl, "01 · the problem",
           "Private documents, public models, and nothing in between.",
           "Cloud RAG uploads the corpus to answer one question. Keeping it "
           "local on a laptop puts the most sensitive data on the least "
           "controlled machine.", "01")
    cards = [
        ("Cloud RAG", "The whole corpus and its embeddings leave the device "
         "to answer a single question. Compliance ends at upload.", DANGER),
        ("Laptop-local RAG", "The index sits on the machine that runs "
         "browsers, plugins and IDE agents with broad file access.", AMBER),
        ("Phones are idle compute", "A flagship SoC carries an NPU, a GPU and "
         "a hardware keystore, yet sits unused next to the laptop.", ACCENT),
    ]
    for i, (t, b, c) in enumerate(cards):
        x = M + i * 4.08
        node(sl, x, 2.45, 3.86, 1.7, t, b, c, tsize=11, msize=9.2)
    section_label(sl, M, 4.52, "What Vault needs to prove")
    bullet_rows(sl, M, 4.84, 5.8, [
        ("The corpus never leaves the phone",
         "Documents, chunks and the index stay on device; only the answer "
         "for one question crosses."),
        ("The answer is attributable",
         "A consumer can verify which device produced it and that nobody "
         "edited the quoted evidence on the way."),
    ], gap=0.78)
    bullet_rows(sl, 6.95, 4.84, 5.7, [
        ("The phone does real work",
         "Embeddings on the NPU and generation on the GPU, attributed from "
         "what the runtimes report, not from the SoC name."),
        ("No new attack surface",
         "An air-gapped build with zero network permissions; the link runs "
         "over an authenticated, encrypted clipboard protocol."),
    ], gap=0.78)
    return sl


def s_overall(prs):
    sl = new_slide(prs)
    chrome(sl, "02 · overall", "The whole system in one picture.",
           "The laptop never holds the corpus. It sends a sealed question and "
           "gets back a sealed, signed capsule.", "02")
    # laptop
    device(sl, M, 2.28, 3.1, 4.05, "LAPTOP", "UNTRUSTED EDGE", None, rows=[
        ("vaultlink.py", "pair · enroll · ask · verify"),
        ("capsule_verify.py", "digest · ECDSA · pinned key"),
        ("DPAPI pairing key", "Windows user scope"),
        ("Clipboard scrub", "20 s countdown, compare-and-clear"),
        ("IDE / MCP client", "optional, via LAN bridge (lan flavor)")])
    # link column
    boundary(sl, 4.05, 2.28, 4.05)
    node(sl, 4.35, 2.55, 3.0, 1.05, "Office Kit clipboard mirror",
         "Carries opaque VAULTLINK/2 frames both ways. It sees ciphertext "
         "only.", AMBER, msize=7.4)
    arr(sl, 4.42, 3.95, 7.28, 3.95, BODY, 1.1, "SEALED REQUEST", BODY)
    arr(sl, 7.28, 4.50, 4.42, 4.50, ACCENT, 1.1, "SEALED + SIGNED CAPSULE",
        ACCENT, loff=0.08)
    node(sl, 4.35, 4.95, 3.0, 0.78, "LAN bridge (lan flavor only)",
         "bridge_server.py WebSocket · off in the air-gapped APK", ROADMAP,
         msize=7.2)
    barrier(sl, 4.35, 5.88, 3.0, 0.42, "no internet path in airgap build")
    boundary(sl, 7.62, 2.28, 4.05, "")
    # phone
    x0 = 7.95
    rrect(sl, x0, 2.28, 4.73, 4.05, fill=PANEL, line=mix(BG, ACCENT, 0.44),
          lw=1.0, radius=0.12)
    txt(sl, x0, 2.40, 4.73, 0.2, "iQOO 15 · VAULT APP", 8.5, INK, True,
        align=PP_ALIGN.CENTER, spc=1.1)
    txt(sl, x0, 2.60, 4.73, 0.18, "TRUSTED CORE · SM8850", 7, ACCENT, True,
        align=PP_ALIGN.CENTER, spc=1.2)
    cells = [
        ("VaultLink service", "open frame · replay check", CPU := "7C8CF8"),
        ("MiniLM encoder", "QNN HTP → XNNPACK → CPU", ACCENT),
        ("Vector index", "Float32 RAM matrix · top-K", BODY),
        ("Encrypted store", "SQLite · AES-GCM chunks", ACCENT),
        ("Reasoner (one)", "llama.cpp GPU · MediaPipe", AMBER),
        ("Capsule signer", "ECDSA-P256 · StrongBox", ACCENT),
    ]
    for i, (t, m, c) in enumerate(cells):
        cx = x0 + 0.18 + (i % 2) * 2.2
        cy = 2.95 + (i // 2) * 1.08
        node(sl, cx, cy, 2.12, 0.92, t, m, c, tsize=9, msize=8.2)
    status_line(sl, "measured", "Verified on the iQOO 15: sealed/signed capsules "
                "returned over the clipboard, StrongBox keys, llama.cpp on GPU. "
                "QNN NPU path: re-exported model pending on-device check.")
    return sl


def s_repo(prs):
    sl = new_slide(prs)
    chrome(sl, "03 · the repository", "Five parts, one protocol.",
           "Everything below ships from one branch and is exercised by 236 "
           "Flutter tests and 66 Python tests.", "03")
    cols = [
        ("vault_rag_test/", "Phone app", ACCENT, [
            "lib/core — engine, chunker, tokenizer, vector store, gating path",
            "lib/core/security — keystore, signing, clipboard TTL",
            "lib/core/llm — capsule, prompts, llama/MediaPipe, coordinator",
            "lib/core/qnn — HTP delegate, acceptance gates",
            "lib/link — VaultLink v1/v2 service",
            "lib/telemetry — probes, leases, 3 benchmark runners",
            "android/ — Keystore, QNN, Clipboard, llama JNI channels",
            "flavors: airgap (default) · lan"]),
        ("bridge/", "Desktop", AMBER, [
            "testdata/vaultlink.py — pair, enroll, ask, all, verify",
            "vault_cli/capsule_verify.py — verifier + trust store",
            "vault_cli/vaultlink_protocol.py — v2 frames, DPAPI",
            "bridge_server.py — FastAPI + WebSocket (lan flavor)",
            "iqoo_mcp_server.py — 5 MCP tools",
            "vault-embed / vault-query CLI",
            "corpus/ + run_eval.py — labelled eval",
            "testdata/gen_sensitive_doc.py — synthetic secrets doc"]),
        ("modelprep/", "Models", ROADMAP, [
            "fix_onnx.py — int32 inputs, static 1×256",
            "convert.py — onnx2tf baseline export",
            "export_htp.py — NPU-shaped re-export",
            "verify.py — tokenizer, numerics, retrieval",
            "dart_tokenizer_port.py — golden tokenizer"]),
        ("vault_video/ · deck/", "Story", BODY, [
            "Remotion 5-minute explainer",
            "this deck, generated by build_deck.py",
            "SECURITY.md — threat model and limits",
            "NPU_QNN.md — NPU bring-up checklist",
            "BUILD_NOTES.md — traps and measurements"]),
    ]
    widths = [3.45, 3.45, 2.45, 2.36]
    x = M
    for (t, sub, c, items), w in zip(cols, widths):
        node(sl, x, 2.30, w, 4.1, t, None, c, tsize=10)
        txt(sl, x + 0.11, 2.55, w - 0.2, 0.2, sub, 7.4, c, True, spc=1.0,
            caps=True)
        paras(sl, x + 0.11, 2.86, w - 0.22, 3.45,
              [f"· {i}" for i in items], 9.2, BODY, lh=1.42)
        x += w + 0.11
    return sl


def s_app(prs):
    sl = new_slide(prs)
    chrome(sl, "04 · vault app anatomy", "Five tabs over one engine.",
           "Screens are clients of long-lived services; nothing that must "
           "outlive a screen is owned by a widget.", "04")
    tabs = [("Vault", "ingest · ask · copy capsule"),
            ("Model", "load one reasoner · QNN verdict"),
            ("Bridge / Air-gap", "LAN bridge (lan) or notice"),
            ("Link", "VaultLink session · pairing"),
            ("Stats", "telemetry · 3 benchmarks")]
    for i, (t, m) in enumerate(tabs):
        node(sl, M + i * 2.42, 2.30, 2.30, 0.74, t, m, BODY, tsize=9.6,
             msize=8.4)
    layers = [
        ("SERVICES", ACCENT, [("VaultEngine", "serialised encoder + store"),
                              ("ReasonerCoordinator", "exactly one LLM loaded"),
                              ("VaultLinkService", "clipboard protocol"),
                              ("ComputeTelemetry", "probes + leases")]),
        ("CORE", AMBER, [("Chunker + Tokenizer", "256-word windows · WordPiece"),
                         ("MiniLM service", "QNN → XNNPACK → CPU"),
                         ("VectorStore", "AES-GCM SQLite + RAM matrix"),
                         ("Capsule + Signer", "schema · canonical · ECDSA")]),
        ("NATIVE", ROADMAP, [("KeystoreChannel.kt", "AES + ECDSA in StrongBox/TEE"),
                             ("QnnChannel + qnn shim", "Hexagon HTP delegate"),
                             ("llama JNI (C++)", "GGUF · OpenCL Adreno"),
                             ("LlmChannel.kt", "MediaPipe Gemma")]),
    ]
    for li, (name, c, items) in enumerate(layers):
        y = 3.32 + li * 1.12
        txt(sl, M, y + 0.30, 1.0, 0.2, name, 7.5, c, True, spc=1.2)
        for i, (t, m) in enumerate(items):
            node(sl, M + 1.05 + i * 2.75, y, 2.62, 0.86, t, m, c, tsize=9.4,
                 msize=8.4)
    status_line(sl, "verified", "flutter analyze clean · 236 Flutter tests · "
                "airgap and lan release APKs build (153 MB, arm64-v8a).")
    return sl


def s_ingest(prs):
    sl = new_slide(prs)
    chrome(sl, "05 · vault · ingest", "From a file to an encrypted, searchable chunk.",
           "Text is encrypted before it reaches SQLite, and only indexed after "
           "the write succeeds, so RAM and disk never disagree.", "05")
    stage_chain(sl, M, 2.35, CW, [
        ("Pick", "System document picker, per-file grant, no storage "
                 "permission. Text formats only.", "on phone"),
        ("Chunk", "256-word windows, 32-word overlap, ids in document "
                  "order.", "on phone"),
        ("Tokenize", "WordPiece port verified against HuggingFace; int32 "
                     "ids padded to 256.", "on phone"),
        ("Embed", "MiniLM-L6-v2, 384-d, mean-pooled and L2-normalised.",
         "npu · qnn htp / cpu"),
        ("Encrypt", "AES-256-GCM in AndroidKeyStore, fresh 12-byte IV per "
                    "chunk.", "strongbox / tee"),
        ("Store + index", "SQLite row (content_cipher, embedding), then the "
                          "RAM matrix.", "on phone"),
    ], box_h=1.25)
    hair(sl, M, 4.28, CW, RULE_SOFT)
    code(sl, M, 4.50, 5.9, 1.85, [
        "CREATE TABLE chunks (",
        "  id             TEXT PRIMARY KEY,",
        "  file_name      TEXT NOT NULL,",
        "  content_cipher BLOB NOT NULL,  -- IV(12) || ct || tag(16)",
        "  embedding      BLOB NOT NULL   -- 384 × float32 LE",
        ");   PRAGMA user_version = 2; secure_delete = ON",
    ], 8.6, "schema v2")
    bullet_rows(sl, 6.85, 4.50, 5.85, [
        ("Migration never loses data",
         "Legacy plaintext rows are encrypted first; the table swap commits "
         "only if every row made it, then VACUUM drops old pages."),
        ("Fail closed",
         "A keystore refusal aborts the insert: no row, no index entry."),
        ("Checked on the raw file",
         "A plaintext marker is absent from the SQLite file bytes after a "
         "migration — tested on host."),
    ], gap=0.62, bsize=8.3)
    return sl


def s_query(prs):
    sl = new_slide(prs)
    chrome(sl, "06 · vault · query", "From a question to a signed capsule.",
           "Ranking touches only RAM. Only the winning chunks are read from "
           "disk and decrypted, in one keystore batch.", "06")
    steps = [
        ("Embed query", "MiniLM on the verified backend", "113–137 ms", ACCENT),
        ("Rank in RAM", "contiguous Float32List, cached norms, top-K heap",
         "host 0.6–0.8 ms / 1k", BODY),
        ("Fetch + decrypt", "SELECT … WHERE id IN (winners) · batch GCM",
         "≈1.8 s on StrongBox", AMBER),
        ("Extract", "best matching line, kept as the floor", "ms", BODY),
        ("Reason", "the one loaded reasoner writes the capsule JSON",
         "15.7–18.2 s", ACCENT),
        ("Sign", "canonical payload → ECDSA-P256 in keystore", "1 op", ACCENT),
    ]
    w = 1.92
    for i, (t, m, n, c) in enumerate(steps):
        x = M + i * (w + 0.1)
        node(sl, x, 2.35, w, 1.3, t, m, c, tsize=9.6, msize=8.4)
        txt(sl, x + 0.11, 3.34, w - 0.2, 0.2, n, 8.6, c, True)
        if i < len(steps) - 1:
            arr(sl, x + w + 0.005, 3.0, x + w + 0.095, 3.0, DIM, 1.0)
    hair(sl, M, 3.95, CW, RULE_SOFT)
    section_label(sl, M, 4.12, "who writes the answer")
    node(sl, M, 4.45, 3.85, 1.55, "Reasoner loaded + generation on",
         "The model answers every query that retrieved context, whatever "
         "the similarity score. gating_path = llm_synthesized.", ACCENT,
         msize=9.2)
    node(sl, M + 4.0, 4.45, 3.85, 1.55, "No model · generation off · "
         "nothing retrieved · generation failed",
         "The extractive line is returned instead and labelled "
         "extractive_fallback. Retrieval is never lost.", AMBER, msize=9.2)
    node(sl, M + 8.0, 4.45, 4.03, 1.55, "Why no similarity gate",
         "A 0.82 / 0.50 gate was tried and removed: on the phone it refused "
         "3 of 5 answerable questions (scores 0.30–0.45) and bypassed the "
         "reasoner the app exists to run.", DANGER, msize=9.2)
    status_line(sl, "measured", "Timings from iQOO 15 capsules (MiniLM on "
                "XNNPACK, SmolLM2-1.7B Q4_K_M on llama.cpp GPU). Host ranking "
                "figure is not a device number.")
    return sl


def s_capsule(prs):
    sl = new_slide(prs)
    chrome(sl, "07 · vault · the context capsule",
           "An answer a program can check, not a paragraph.",
           "Fixed schema. The model fills it; the parser repairs syntax but "
           "never invents content; retrieval is always inside.", "07")
    code(sl, M, 2.30, 5.6, 4.1, [
        '{ "capsule_version": "1.1",',
        '  "query": "...",  "answer": "...",',
        '  "confidence": "high|medium|low|none",',
        '  "key_facts": [{ "fact", "source", "verbatim", "verified" }],',
        '  "caveats": [...],  "sources": [{ "file", "similarity" }],',
        '  "context": [{ "id", "file", "similarity", "content" }],',
        '  "extracted_answer": "...",  "extracted_from": "file:line",',
        '  "generation": { "ran", "model", "backend", "tokens", "elapsed_ms" },',
        '  "retrieval": { "encoder_backend", "encoder_hardware",',
        '                 "latency_ms", "embed_ms", "chunks_scanned" },',
        '  "gating": { "path", "top_score" },',
        '  "provenance": { "device", "enclave", "key_security_level",',
        '     "gating_path", "timestamp", "canonical_digest",',
        '     "signature", "public_key" } }',
    ], 8.5, "capsule.json")
    bullet_rows(sl, 6.55, 2.30, 6.1, [
        ("key_facts[].verified",
         "True only if the quoted span really occurs in the retrieved text "
         "(whitespace-normalised substring) — an invented quote is flagged."),
        ("A forgiving parser",
         "Fences, chatty preambles, trailing commas, smart quotes, "
         "truncation: repaired syntactically outside string literals."),
        ("The extractive floor",
         "extracted_answer is present even when the model fails, so a "
         "consumer that distrusts prose has something quoted."),
        ("Runtime-sourced labels",
         "encoder_backend and generation.backend come from what the runtimes "
         "reported, never from device branding."),
        ("Signed",
         "query, answer, facts, context text, gating path, device, key level "
         "and key hash are all under the ECDSA signature (slide 12)."),
    ], gap=0.80, bsize=8.4)
    return sl


def s_compute(prs):
    sl = new_slide(prs)
    chrome(sl, "08 · compute placement", "Right work, right silicon, one reasoner.",
           "NPU for embeddings, GPU for the model, CPU for ranking, secure "
           "hardware for keys. Attribution comes from the runtime.", "08")
    units = [
        ("HEXAGON NPU · V81", ACCENT, "MiniLM encoder", "QNN HTP delegate, FP16, "
         "burst mode. Accepted only after coverage, equivalence and latency "
         "gates; else XNNPACK."),
        ("ADRENO GPU", ACCENT, "The reasoner", "llama.cpp GGUF on OpenCL "
         "(Qwen / SmolLM / Llama) or MediaPipe Gemma. GGML_HEXAGON stays off."),
        ("ORYON CPU", BODY, "Ranking + fallbacks", "Top-K over the RAM matrix, "
         "XNNPACK encoder fallback, capsule parsing and JSON."),
        ("STRONGBOX / TEE", AMBER, "Keys", "AES-256-GCM chunk key and ECDSA "
         "signing key; KeyInfo reported StrongBox on the iQOO 15."),
    ]
    for i, (hw, c, t, m) in enumerate(units):
        x = M + i * 3.04
        rrect(sl, x, 2.30, 2.92, 2.25, fill=PANEL, line=mix(BG, c, 0.5),
              lw=1.0, radius=0.06)
        txt(sl, x + 0.14, 2.42, 2.7, 0.2, hw, 7.6, c, True, spc=1.1)
        txt(sl, x + 0.14, 2.68, 2.7, 0.26, t, 12, INK, False, DISPLAY)
        txt(sl, x + 0.14, 3.05, 2.64, 1.45, m, 9.4, BODY, lh=1.25)
    hair(sl, M, 4.78, CW, RULE_SOFT)
    section_label(sl, M, 4.92, "one reasoner — a hard invariant")
    boxes = [("Load GGUF", "llama.cpp"), ("success?", ""),
             ("unload MediaPipe", "after idle"), ("persist activeReasoner", "")]
    xs = [M, M + 2.45, M + 4.3, M + 6.75]
    ws = [2.1, 1.5, 2.1, 2.4]
    for (t, m), x, w in zip(boxes, xs, ws):
        node(sl, x, 5.25, w, 0.62, t, m or None, ACCENT, tsize=8.4, msize=7,
             center=True)
    for a, b in zip(range(3), range(1, 4)):
        arr(sl, xs[a] + ws[a], 5.56, xs[b], 5.56, ACCENT, 1.0)
    txt(sl, M + 2.45, 5.95, 1.6, 0.2, "no → nothing changes", 7.2, DANGER, True)
    paras(sl, 10.05, 5.18, 2.63, 1.2, [
        "Same rule in reverse for MediaPipe.",
        "ask() routes to the saved selection only — never 'whichever is ready'.",
        "Startup auto-loads only the selected runtime."], 7.8, BODY, lh=1.2)
    status_line(sl, "measured", "GPU generation confirmed on device (GPU 99 % "
                "busy during decode). NPU: first export failed to build an "
                "interpreter; NPU-shaped model shipped, device check pending.")
    return sl


def s_npu(prs):
    sl = new_slide(prs)
    chrome(sl, "09 · npu bring-up", "What the Hexagon NPU needs, and how we prove it ran.",
           "Qualcomm's QNN runtime and LiteRT delegate from Maven Central; a "
           "C shim over the external-delegate ABI; strict acceptance.", "09")
    req = [("1 · Libraries", "libQnnHtp, HtpPrepare, System, TFLiteDelegate, "
            "V81 + V79 skel/stub"),
           ("2 · Extracted", "useLegacyPackaging — DSP loads the skel by path"),
           ("3 · FastRPC", "uses-native-library libcdsprpc.so"),
           ("4 · Skel path", "ADSP_LIBRARY_PATH + skel_library_dir"),
           ("5 · Unsigned PD", "htp_pd_session 0 — no Qualcomm signing"),
           ("6 · FP16, burst", "htp_precision 1 · performance mode 2"),
           ("7 · NPU-shaped graph", "static, no SHAPE / int64, FP16-safe mask")]
    section_label(sl, M, 2.28, "bring-up checklist (iQOO 15 · SM8850 · V81)")
    for i, (t, m) in enumerate(req):
        y = 2.58 + i * 0.50
        rrect(sl, M, y, 4.55, 0.42, fill=PANEL, line=RULE_SOFT, lw=0.6,
              radius=0.04)
        txt(sl, M + 0.12, y + 0.06, 1.55, 0.2, t, 8, INK, True)
        txt(sl, M + 1.68, y + 0.07, 2.8, 0.3, m, 7.4, BODY, lh=1.1)
    # model re-export
    node(sl, 5.45, 2.28, 3.35, 2.0, "Model re-export (export_htp.py)", None,
         AMBER)
    stat(sl, 5.62, 2.65, 1.5, "664", "nodes before", DANGER, 22)
    txt(sl, 7.0, 2.72, 0.3, 0.3, "→", 16, DIM)
    stat(sl, 7.3, 2.65, 1.5, "305", "nodes after", ACCENT, 22)
    paras(sl, 5.62, 3.52, 3.05, 0.75, [
        "82 SHAPE, int64 tensors, −3.4e38 mask removed.",
        "Cosine 1.000000 vs ONNX and previous model."], 7.6, BODY)
    # delegate path
    node(sl, 5.45, 4.42, 3.35, 1.95, "Delegate path", None, ROADMAP)
    paras(sl, 5.6, 4.78, 3.1, 1.5, [
        ("Dart QnnHtpDelegate", INK, True), "  ↓ FFI",
        ("libvault_qnn_delegate.so", INK, True), "  ↓ dlopen",
        ("libQnnTFLiteDelegate.so", INK, True),
        "tflite_plugin_create_delegate(k, v, n)"], 7.6, BODY, MONO, lh=1.12)
    # acceptance gates
    node(sl, 8.95, 2.28, 3.73, 4.09, "Acceptance gates", None, ACCENT)
    gates = [("Smoke", "finite, unit-length output"),
             ("Coverage", "delegate's own log: ≥ 75 % of nodes delegated; "
              "no report = rejected"),
             ("Equivalence", "12 passages + 4 queries vs XNNPACK: min cosine "
              "≥ 0.995, same top-1, top-3 ≥ 0.9"),
             ("Latency", "QNN median ≤ 1.10 × XNNPACK")]
    for i, (t, m) in enumerate(gates):
        y = 2.66 + i * 0.66
        txt(sl, 9.1, y, 3.4, 0.2, t, 8.6, INK, True)
        txt(sl, 9.1, y + 0.21, 3.45, 0.42, m, 7.5, BODY, lh=1.15)
    hair(sl, 9.1, 5.35, 3.45, RULE_SOFT)
    for i, (lbl, c) in enumerate([("QNN HTP verified", ACCENT),
                                  ("QNN unavailable", AMBER),
                                  ("XNNPACK fallback", AMBER)]):
        pill(sl, 9.1, 5.48 + i * 0.29, lbl, c, 1.7)
    txt(sl, 10.9, 5.52, 1.7, 0.8, "the only three verdicts the UI and "
        "capsules may show", 7.2, MUTED, lh=1.2)
    status_line(sl, "gap", "First device attempt: delegate created, interpreter "
                "build failed. Cause traced to the export; fix built, "
                "not yet confirmed on the iQOO 15.")
    return sl


def s_security_overview(prs):
    sl = new_slide(prs)
    chrome(sl, "10 · security · overview", "Five layers, each checkable.",
           "Security is stated as what is enforced by hardware, by protocol or "
           "by build configuration — with its limits.", "10")
    layers = [
        ("At rest", ACCENT, "AES-256-GCM per chunk, key in AndroidKeyStore "
         "(StrongBox → TEE). Tamper → fail closed.", "KeystoreChannel.kt · vector_store.dart"),
        ("Attribution", ACCENT, "Every capsule ECDSA-P256 signed over a "
         "length-prefixed canonical payload; laptop verifies against a pinned key.",
         "capsule_signing.dart · capsule_verify.py"),
        ("In transit", ACCENT, "VAULTLINK/2: pairing code → HMAC key schedule → "
         "AES-GCM frames, direction keys, replay window.", "vaultlink_secure.dart · vaultlink_protocol.py"),
        ("Residue", AMBER, "Capsules auto-scrub from the clipboard after 20 s on "
         "both devices, only if unchanged.", "ephemeral_clipboard.dart · vaultlink.py"),
        ("Network", ACCENT, "airgap flavor requests zero network permissions; "
         "only the lan flavor can open the bridge socket.", "build.gradle.kts · AndroidManifest"),
    ]
    for i, (t, c, m, f) in enumerate(layers):
        y = 2.28 + i * 0.84
        rect(sl, M, y, 0.06, 0.70, fill=c)
        txt(sl, M + 0.22, y + 0.04, 1.8, 0.26, t, 13, INK, False, DISPLAY)
        txt(sl, M + 2.15, y + 0.03, 6.4, 0.5, m, 9, BODY, lh=1.22)
        txt(sl, M + 8.7, y + 0.10, 3.3, 0.4, f, 7.4, MUTED, lh=1.2, font=MONO)
        if i < len(layers) - 1:
            hair(sl, M + 0.22, y + 0.78, CW - 0.22, RULE_SOFT)
    status_line(sl, "verified", "StrongBox level and signature validity seen on "
                "device; aapt2: airgap = no network permission, lan = INTERNET.",
                y=6.56)
    return sl


def s_at_rest(prs):
    sl = new_slide(prs)
    chrome(sl, "11 · security · encryption at rest",
           "A stolen phone yields ciphertext.",
           "The chunk key is generated inside AndroidKeyStore and never "
           "exported. Dart sends bytes in and gets bytes out.", "11")
    # key generation flow
    node(sl, M, 2.30, 2.6, 0.85, "generate key", "AES-256 · GCM · no padding · "
         "randomized IV", ACCENT, msize=7.4)
    node(sl, M + 3.0, 2.30, 2.4, 0.85, "StrongBox?", "setIsStrongBoxBacked(true)",
         ACCENT, msize=7.4)
    node(sl, M + 5.8, 2.10, 2.5, 0.72, "StrongBox key", "reported on iQOO 15",
         ACCENT, msize=7.2)
    node(sl, M + 5.8, 3.00, 2.5, 0.72, "TEE KeyStore key", "fallback, still "
         "hardware", AMBER, msize=7.2)
    arr(sl, M + 2.6, 2.72, M + 3.0, 2.72, ACCENT, 1.0)
    arr(sl, M + 5.4, 2.60, M + 5.8, 2.46, ACCENT, 1.0, "yes", ACCENT, lw_box=0.5)
    arr(sl, M + 5.4, 2.84, M + 5.8, 3.36, AMBER, 1.0, "no", AMBER, lw_box=0.5,
        loff=0.02)
    barrier(sl, M + 8.7, 2.40, 3.33, 0.62, "never an app-held software key")
    # payload format
    section_label(sl, M, 4.0, "payload format stored in content_cipher")
    segs = [("IV", 12, ACCENT, "12 bytes, keystore-generated"),
            ("ciphertext", 46, BODY, "same length as the plaintext"),
            ("tag", 16, AMBER, "16-byte GCM tag")]
    x = M
    total = sum(s[1] for s in segs)
    for name, n, c, m in segs:
        w = 7.2 * n / total
        rect(sl, x, 4.32, w - 0.04, 0.5, fill=mix(BG, c, 0.25),
             line=mix(BG, c, 0.6), lw=0.7)
        txt(sl, x, 4.44, w - 0.04, 0.24, name, 9, INK, True,
            align=PP_ALIGN.CENTER)
        txt(sl, x, 4.90, w - 0.04, 0.3, m, 7.2, MUTED, align=PP_ALIGN.CENTER)
        x += w
    bullet_rows(sl, 8.15, 3.98, 4.5, [
        ("Lazy decryption", "Only the top-K winners are decrypted, in one "
         "channel call. Ranking decrypts nothing (tested)."),
        ("Fail closed", "A flipped bit anywhere → AUTH_FAILED → "
         "ChunkIntegrityException. No partial plaintext."),
        ("Latency cost", "StrongBox is a separate secure element: ≈1.8 s to "
         "decrypt 3 chunks on the phone. TEE for the chunk key is the fix."),
    ], gap=0.78, bsize=8.2)
    status_line(sl, "verified", "Host: GCM format, IV uniqueness, tamper and "
                "truncation rejection, raw DB file free of plaintext. JDK JCA "
                "↔ Python interop verified.")
    return sl


def s_signing(prs):
    sl = new_slide(prs)
    chrome(sl, "12 · security · signed capsules",
           "Who produced this answer, and did anyone edit it?",
           "The phone signs a canonical encoding of the capsule. The laptop "
           "rebuilds it byte-for-byte and trusts only a pinned key.", "12")
    code(sl, M, 2.30, 5.9, 2.25, [
        "payload = LP(\"vault-capsule-sig/v1\") LP(query) LP(answer)",
        "          LP(timestamp) LP(gating_path) LPL(chunk_ids)",
        "          LP(confidence) LPL(key_fact_texts)",
        "          LPL(sha256(context_content)) LP(device)",
        "          LP(key_security_level) LP(sha256(public_key))",
        "LP(s) = \"<utf8 byte length>:\" s",
        "canonical_digest = SHA-256(payload)",
        "signature = ECDSA-P256-SHA256(payload)   # in keystore",
    ], 8.4, "canonical payload")
    node(sl, M, 4.72, 5.9, 1.55, "Why length-prefixed, not query|answer|…",
         "A pipe-joined string is not injective: query \"a|b\" + answer \"c\" "
         "signs identically to \"a\" + \"b|c\". It also left the quoted context "
         "and key facts unsigned, so a relay could rewrite the evidence under "
         "a valid signature.", DANGER, msize=8.2)
    # verify chain
    section_label(sl, 6.85, 2.28, "laptop verification — every step fails closed")
    steps = [("provenance present", "else MISSING_PROVENANCE"),
             ("rebuild payload from JSON", "else MALFORMED"),
             ("SHA-256 == canonical_digest", "else DIGEST_MISMATCH"),
             ("real DER signature", "MOCK_SIG / null → UNSIGNED"),
             ("public key is P-256", "else BAD_PUBLIC_KEY"),
             ("ECDSA verifies", "else INVALID_SIGNATURE"),
             ("key == pinned device key", "NOT_ENROLLED / KEY_MISMATCH")]
    for i, (t, m) in enumerate(steps):
        y = 2.58 + i * 0.52
        c = ACCENT if i == len(steps) - 1 else BODY
        node(sl, 6.85, y, 3.3, 0.42, t, None, c, tsize=8.2, bar=False)
        txt(sl, 10.3, y + 0.12, 2.4, 0.2, m, 7.2, MUTED, font=MONO)
        if i < len(steps) - 1:
            arr(sl, 8.5, y + 0.42, 8.5, y + 0.52, DIM, 0.8)
    status_line(sl, "verified", "Python verifier rejects every tamper case "
                "(answer, query, timestamp, path, ids, context, facts, level, "
                "digest, signature, attacker key). Same vector asserted by Dart.")
    return sl


def s_trust(prs):
    sl = new_slide(prs)
    chrome(sl, "13 · security · trust & attestation",
           "A key in the message is not a reason to trust the message.",
           "Anyone can sign their own capsule. Trust comes from pinning the "
           "device key once, over the already-authenticated link.", "13")
    lifeline(sl, 2.2, 2.3, 2.45, "Phone", "keystore signing key", ACCENT)
    lifeline(sl, 6.65, 2.3, 2.45, "Office Kit", "clipboard mirror", AMBER)
    lifeline(sl, 11.1, 2.3, 2.45, "Laptop", "vaultlink.py", None)
    arr(sl, 11.1, 3.25, 2.2, 3.25, BODY, 1.0, "pair: type code shown on phone "
        "(never pasted)", BODY, lw_box=5)
    arr(sl, 11.1, 3.85, 2.2, 3.85, BODY, 1.0, "sealed enroll request", BODY,
        lw_box=4)
    arr(sl, 2.2, 4.45, 11.1, 4.45, ACCENT, 1.1, "sealed reply: public key + "
        "attestation chain + KeyInfo level", ACCENT, lw_box=6)
    node(sl, 8.5, 4.85, 4.18, 1.3, "Laptop pins the key",
         "trusted_devices.json. A different key never silently replaces it "
         "(TRUSTED_KEY_MISMATCH). Re-enrol = explicit unenroll + enroll.",
         ACCENT, msize=7.8)
    node(sl, M, 4.85, 4.3, 1.3, "Attestation chain, honestly scoped",
         "Chain linkage, leaf = signing key and the KeyDescription security "
         "level are checked. Hardware is PROVEN only with a trusted Google "
         "root supplied (--attestation-root).", AMBER, msize=7.8)
    node(sl, 5.1, 4.85, 3.25, 1.3, "Security line printed",
         "Built from signed fields: \"Qualcomm TEE (Qualcomm SM8850)\" only if "
         "the signed device string says so.", BODY, msize=7.8)
    status_line(sl, "built", "Enrollment path built and unit-tested with a "
                "synthetic chain; on-device enroll not yet run (phone "
                "used legacy v1 in the last session).")
    return sl


def s_vlp_loop(prs):
    sl = new_slide(prs)
    chrome(sl, "14 · vaultlink protocol (vlp)",
           "A request/response loop carried by the clipboard.",
           "No socket, no IP address, no Android permission. The phone polls "
           "its own clipboard while the Link tab is in the foreground.", "14")
    lifeline(sl, 2.0, 2.28, 3.2, "vaultlink.py", "laptop", None)
    lifeline(sl, 6.65, 2.28, 3.2, "Office Kit", "mirrors clipboard", AMBER)
    lifeline(sl, 11.3, 2.28, 3.2, "VaultLinkService", "phone, 700 ms poll",
             ACCENT)
    msgs = [(2.0, 6.65, 3.15, "VAULTLINK/2 req frame → clipboard", BODY),
            (6.65, 11.3, 3.55, "mirrored to phone clipboard", BODY),
            (11.3, 6.65, 4.05, "{status: processing} (sealed)", AMBER),
            (6.65, 2.0, 4.35, "mirrored back", AMBER),
            (11.3, 6.65, 5.05, "sealed capsule (TTL 20 s)", ACCENT),
            (6.65, 2.0, 5.40, "mirrored back", ACCENT)]
    for x1, x2, y, lbl, c in msgs:
        arr(sl, x1, y, x2, y, c, 1.0, lbl, c, lw_box=4.2, loff=-0.21)
    node(sl, 11.42, 4.30, 1.26, 0.62, "open · verify", "then ask()", ACCENT,
         tsize=7.6, msize=7, bar=False)
    node(sl, M, 5.62, 2.9, 0.62, "verify · print · scrub", "digest, ECDSA, "
         "pinned key; 20→1 countdown", BODY, tsize=8, msize=7)
    code(sl, 4.0, 5.70, 5.0, 0.62, [
        'VAULTLINK/2\\n{"kid":"8b1e…","dir":"req","ct":"<base64 IV‖ct‖tag>"}'],
        7.3)
    paras(sl, 9.2, 5.58, 3.5, 0.9, [
        "Ops: ping · query · enroll (v2 only).",
        "Only frames with the prefix are touched; anything else a user copies "
        "is left alone."], 7.8, BODY, lh=1.2)
    status_line(sl, "measured", "Clipboard loop exercised end-to-end with the "
                "iQOO 15 over Office Kit (legacy v1 for the latest run; v2 "
                "built and host-tested).")
    return sl


def s_vlp_crypto(prs):
    sl = new_slide(prs)
    chrome(sl, "15 · vlp v2 · cryptography",
           "One typed code becomes four purpose-bound values.",
           "The code never crosses the clipboard it protects. Everything after "
           "it is standard primitives: HMAC-SHA256 and AES-256-GCM.", "15")
    node(sl, M, 2.35, 2.8, 1.0, "Pairing code", "20 Crockford base32 chars · "
         "100 bits · shown on phone, typed on laptop", ACCENT, msize=7.4)
    node(sl, M + 3.35, 2.35, 3.0, 1.0, "root", "HMAC(\"vaultlink/2 pairing\", "
         "code) · laptop stores under DPAPI", AMBER, msize=7.4)
    arr(sl, M + 2.8, 2.85, M + 3.35, 2.85, ACCENT, 1.0)
    outs = [("K_req", "HMAC(root, \"…req\")", "laptop → phone"),
            ("K_rep", "HMAC(root, \"…rep\")", "phone → laptop"),
            ("kid", "hex(HMAC(root, \"…kid\"))[0:16]", "which pairing")]
    for i, (t, m, n) in enumerate(outs):
        y = 2.05 + i * 0.62
        node(sl, M + 6.9, y, 3.1, 0.52, t, m, ACCENT, tsize=8.4, msize=7)
        txt(sl, M + 10.15, y + 0.16, 1.9, 0.2, n, 7.6, MUTED, True)
        arr(sl, M + 6.35, 2.85, M + 6.9, y + 0.26, DIM, 0.9)
    hair(sl, M, 4.08, CW, RULE_SOFT)
    code(sl, M, 4.25, 6.0, 2.05, [
        "frame = \"VAULTLINK/2\\n\" + {kid, dir, ct}",
        "ct    = IV(12) ‖ AES-256-GCM(json) ‖ tag(16)",
        "AAD   = \"VAULTLINK/2|\" + dir + \"|\" + kid",
        "request json: {id, op, ts, q, k, generate}",
        "reply   json: {id, status, ...capsule, compute}",
    ], 8.6, "frame format")
    bullet_rows(sl, 6.9, 4.25, 5.8, [
        ("Direction binding", "Separate keys and AAD per direction: a reply "
         "cannot be replayed to the phone as a request."),
        ("Freshness", "Phone rejects ts outside ±5 min and any id seen in the "
         "last 10 min."),
        ("Confidentiality", "Office Kit, clipboard history and other apps see "
         "base64 ciphertext only."),
    ], gap=0.66, bsize=8.3)
    status_line(sl, "verified", "Key schedule vector shared by Dart and Python; "
                "tamper, wrong key, reflection, replay and stale ts all rejected "
                "in tests.")
    return sl


def s_vlp_threats(prs):
    sl = new_slide(prs)
    chrome(sl, "16 · vlp · threat model", "What v2 stops, and what it does not.",
           "v1 was plaintext and unauthenticated. It remains only behind an "
           "explicit, labelled legacy switch.", "16")
    table(sl, M, 2.30, 7.55, [("Threat", 0.40), ("v1", 0.18), ("v2", 0.42)], [
        ("Another app queries the vault", "open", "needs the pairing key"),
        ("Clipboard sync reads Q&A", "plaintext", "ciphertext only"),
        ("Forged / edited reply", "undetected", "GCM tag + ECDSA capsule"),
        ("Reply reflected as request", "possible", "direction keys + AAD"),
        ("Replay of a captured request", "possible", "±5 min, id cache"),
        ("Capsule left on clipboard", "indefinite", "20 s compare-and-clear"),
        ("Attacker's own signing key", "accepted", "pinned key mismatch"),
    ], row_h=0.44, cell_size=8.6,
        colors=[ACCENT] * 7)
    node(sl, 8.45, 2.30, 4.23, 3.55, "Not stopped — stated plainly", None,
         DANGER)
    paras(sl, 8.6, 2.68, 3.95, 3.1, [
        ("Malware as the same Windows user", INK, True),
        "DPAPI protects the root from other accounts, not your own processes.",
        ("Shoulder-surfing the code", INK, True),
        "Hidden until tapped; it is still a screen.",
        ("Replay across an app restart", INK, True),
        "Replay cache is in memory; ops are read-only and replies sealed.",
        ("Traffic analysis", INK, True),
        "Frame size and timing are visible.",
    ], 8, BODY, lh=1.22)
    status_line(sl, "built", "Legacy v1 is off by default on the phone; the "
                "laptop needs --insecure-v1 and prints a warning.")
    return sl


def s_residue(prs):
    sl = new_slide(prs)
    chrome(sl, "17 · clipboard residue & air gap",
           "Leave nothing behind, and nowhere to send it.",
           "Both ends scrub the capsule after 20 seconds, but only if the "
           "clipboard still holds exactly what Vault put there.", "17")
    flow = [("copy capsule", "sensitive clip flag (Android 13+)", ACCENT),
            ("20 s countdown", "banner + progress; Win: 20→1", BODY),
            ("read clipboard", "still byte-identical?", AMBER)]
    for i, (t, m, c) in enumerate(flow):
        x = M + i * 2.55
        node(sl, x, 2.35, 2.3, 0.85, t, m, c, tsize=9, msize=7.4)
        if i < 2:
            arr(sl, x + 2.3, 2.78, x + 2.55, 2.78, DIM, 1.0)
    node(sl, M + 7.65, 2.05, 2.45, 0.7, "yes → clear", "clearPrimaryClip / "
         "EmptyClipboard", ACCENT, msize=7.2)
    node(sl, M + 7.65, 2.95, 2.45, 0.7, "no → leave it", "user copied "
         "something else", BODY, msize=7.2)
    arr(sl, M + 7.4, 2.78, M + 7.65, 2.40, ACCENT, 1.0)
    arr(sl, M + 7.4, 2.78, M + 7.65, 3.30, BODY, 1.0)
    txt(sl, M + 10.25, 2.20, 1.8, 1.5, "Background on Android? Unreadable → "
        "retried on resume, never cleared blind.", 7.6, MUTED, lh=1.2)
    hair(sl, M, 3.95, CW, RULE_SOFT)
    section_label(sl, M, 4.10, "network isolation is a build property")
    for i, (flavor, perm, note, c) in enumerate([
            ("airgap (default)", "no network permission",
             "src/airgapRelease strips INTERNET, ACCESS_NETWORK_STATE, "
             "WIFI/CHANGE_NETWORK_STATE even if a library merges them in. "
             "Bridge tab replaced by an air-gap notice.", ACCENT),
            ("lan", "android.permission.INTERNET",
             "Opt-in WebSocket co-processor bridge to bridge_server.py; "
             "phone dials out, no listening port on the device.", AMBER)]):
        x = M + i * 6.1
        node(sl, x, 4.42, 5.9, 1.9, flavor, None, c, tsize=11)
        txt(sl, x + 0.12, 4.78, 5.6, 0.22, perm, 9, c, True, font=MONO)
        txt(sl, x + 0.12, 5.10, 5.6, 1.15, note, 8.4, BODY, lh=1.25)
    status_line(sl, "verified", "aapt2 dump permissions on both release APKs; "
                "Win32 scrub tested on a real clipboard (cleared vs replaced).")
    return sl


def s_desktop(prs):
    sl = new_slide(prs)
    chrome(sl, "18 · desktop tooling", "The laptop side: small, scriptable, verifying.",
           "Two transports to the same engine — the clipboard loop for the "
           "air-gapped build, a LAN bridge for IDE and MCP clients.", "18")
    node(sl, M, 2.30, 5.95, 2.5, "vaultlink.py  (clipboard, any build)", None,
         ACCENT)
    code(sl, M + 0.12, 2.66, 5.7, 2.0, [
        "python vaultlink.py pair XXXXX-XXXXX-XXXXX-XXXXX",
        "python vaultlink.py enroll [--attestation-root root.pem]",
        "python vaultlink.py ping",
        "python vaultlink.py ask \"question\" [-k 5] [--no-generate]",
        "python vaultlink.py all          # 14 ground-truth questions",
        "python vaultlink.py verify out/capsule_s01.json",
    ], 8.4)
    node(sl, 6.73, 2.30, 5.95, 2.5, "bridge_server.py  (lan flavor)", None, AMBER)
    paras(sl, 6.86, 2.66, 5.7, 2.1, [
        ("IDE / MCP / query.py  → HTTP 127.0.0.1:8000", INK, True),
        "            ↓",
        ("bridge_server.py  ← WebSocket /ws/phone ← phone dials out", INK, True),
        "",
        "/api/status · /api/telemetry · /api/query · /api/llm · /api/ask · "
        "/api/index",
        "MCP: iqoo_get_status · iqoo_get_telemetry · iqoo_query_agent · "
        "iqoo_ask_capsule · iqoo_index_code",
    ], 7.8, BODY, lh=1.2)
    section_label(sl, M, 5.02, "evaluation and test data")
    for i, (t, m) in enumerate([
            ("gen_sensitive_doc.py", "synthetic HR/finance secrets doc + 14 "
             "labelled questions, invalid-by-construction values"),
            ("corpus/ + run_eval.py", "4 policy documents with ground truth "
             "for retrieval scoring"),
            ("vault-embed · vault-query", "CLI to push documents and query "
             "over the bridge")]):
        node(sl, M + i * 4.08, 5.32, 3.9, 0.95, t, m, BODY, tsize=8.6, msize=7.6)
    return sl


def s_telemetry(prs):
    sl = new_slide(prs)
    chrome(sl, "19 · telemetry & benchmarks",
           "Measure what the hardware did, not what the brochure says.",
           "Device counters where Android exposes them, and per-hardware "
           "leases from the code that dispatched the work.", "19")
    # lease timeline
    section_label(sl, M, 2.28, "runtime leases — independent per hardware")
    lanes = [("NPU · minilm", ACCENT, [(0.5, 0.95), (1.55, 2.0), (2.6, 3.05),
                                      (3.65, 4.1), (4.7, 5.15)]),
             ("GPU · llama.cpp", AMBER, [(0.2, 5.5)]),
             ("CPU · ranking", BODY, [(1.0, 1.1), (2.3, 2.4), (3.5, 3.6),
                                     (4.7, 4.8)])]
    x0, w0 = M + 1.6, 5.6
    for i, (name, c, spans) in enumerate(lanes):
        y = 2.62 + i * 0.46
        txt(sl, M, y + 0.06, 1.55, 0.2, name, 7.8, INK, True)
        rect(sl, x0, y + 0.12, w0, 0.012, fill=RULE_SOFT)
        for a, b in spans:
            rrect(sl, x0 + a / 6 * w0, y, (b - a) / 6 * w0, 0.26,
                  fill=mix(BG, c, 0.55), radius=0.03)
    rect(sl, x0 + 0.2 / 6 * w0, 2.52, (5.5 - 0.2) / 6 * w0, 1.46,
         fill=None, line=mix(BG, ACCENT, 0.5), lw=0.7,
         dash=MSO_LINE_DASH_STYLE.DASH)
    txt(sl, x0, 4.02, w0, 0.2, "npu_gpu_overlap_ms = wall time both had work "
        "in flight", 7.6, ACCENT, True)
    paras(sl, 7.95, 2.28, 4.7, 1.9, [
        ("Device-wide probes", INK, True),
        "CPU /proc/stat · GPU KGSL busy · NPU devfreq (not exposed on "
        "production Android — shown unavailable, never faked) · thermal via "
        "PowerManager",
        ("Attribution rules", INK, True),
        "NPU only after QNN HTP verified; GPU only when ggml reports the "
        "model on a GPU device; MediaPipe by its load backend.",
    ], 8, BODY, lh=1.22)
    hair(sl, M, 4.40, CW, RULE_SOFT)
    section_label(sl, M, 4.52, "benchmarks on the stats tab")
    for i, (t, m) in enumerate([
            ("Embedding", "warm-up discarded; P50/P90/P95; per-backend sweep "
             "incl. QNN HTP"),
            ("Reasoning", "timed generations on the loaded runtime with "
             "utilisation averaged over the run"),
            ("Two-model pipeline", "MiniLM · CPU ranking · retrieval-only · "
             "prefill/decode/tok/s · indexing during generation · RSS · "
             "thermal · QNN + llama status"),
            ("Rank micro-bench", "bench_rank_main.dart: 1,000 and 5,000 × 384 "
             "in release AOT on device")]):
        node(sl, M + i * 3.04, 4.84, 2.92, 1.45, t, m, ACCENT if i == 2 else
             BODY, tsize=9, msize=7.8)
    status_line(sl, "built", "Pipeline benchmark built; device run pending "
                "once QNN is confirmed. Host rank bench: 0.6–0.8 ms "
                "(not a device figure).")
    return sl


def s_evidence(prs):
    sl = new_slide(prs)
    chrome(sl, "20 · evidence", "What is measured, what is verified, what is open.",
           "Numbers from the iQOO 15 VaultLink sessions and from host "
           "tooling, each labelled by where it came from.", "20")
    table(sl, M, 2.30, CW, [("Claim", 0.34), ("Result", 0.44),
                            ("Status", 0.22)], [
        ("SoC reported by Build", "SM8850 · Hexagon V81 skel packaged", "MEASURED"),
        ("Key location (KeyInfo)", "StrongBox for AES + ECDSA keys", "MEASURED"),
        ("Capsule signature", "valid ECDSA-P256 from device key", "MEASURED"),
        ("MiniLM encoder", "XNNPACK: 58 ms load bench · 113–137 ms in query", "MEASURED"),
        ("Retrieval end-to-end", "≈2.0 s (StrongBox decrypt of 3 chunks)", "MEASURED"),
        ("Reasoner", "SmolLM2-1.7B Q4_K_M · llama.cpp GPU · ≈10.5 tok/s e2e", "MEASURED"),
        ("QNN HTP embeddings", "first export failed; re-export pending", "OPEN GAP"),
        ("Network permissions", "airgap: none · lan: INTERNET (aapt2)", "VERIFIED"),
        ("Crypto + protocol", "236 Flutter · 66 Python tests; JCA interop", "VERIFIED"),
        ("NPU-shaped model", "305 nodes · cosine 1.000000 vs ONNX", "VERIFIED"),
    ], row_h=0.395, cell_size=8.4,
        colors=[ACCENT, ACCENT, ACCENT, ACCENT, ACCENT, ACCENT, DANGER, ACCENT,
                ACCENT, ACCENT])
    return sl


def s_learned(prs):
    sl = new_slide(prs)
    chrome(sl, "21 · what the device taught us",
           "When answers fail, look at retrieval before the model.",
           "Five sensitive-doc questions on the phone: every question that "
           "reached the model was answered correctly.", "21")
    # chunk truncation diagram
    section_label(sl, M, 2.28, "256-word chunk vs MiniLM's 254-token window")
    rect(sl, M, 2.62, 6.0, 0.46, fill=mix(BG, ACCENT, 0.3), line=None)
    rect(sl, M + 6.0 * 0.63, 2.62, 6.0 * 0.37, 0.46, fill=mix(BG, DANGER, 0.35))
    txt(sl, M, 2.74, 6.0 * 0.63, 0.22, "embedded · 254 tokens", 8, INK, True,
        align=PP_ALIGN.CENTER)
    txt(sl, M + 6.0 * 0.63, 2.74, 6.0 * 0.37, 0.22, "never seen · 35–38 %", 8,
        INK, True, align=PP_ALIGN.CENTER)
    for q, off, ok in [("s01 salary · token 148", 148, True),
                       ("s03 bonus 272 · s11 card 280", 276, False)]:
        px = M + 6.0 * off / 405
        line(sl, px, 3.12, px, 3.34, ACCENT if ok else DANGER, 1.2)
        txt(sl, px - 1.1, 3.36, 2.2, 0.2, q, 7.4, ACCENT if ok else DANGER,
            True, align=PP_ALIGN.CENTER)
    paras(sl, M, 3.75, 6.0, 1.0, [
        "A ~400-token chunk is cut at 254 tokens, so facts in the back third "
        "are unretrievable, and one vector averaged over many facts dilutes "
        "single-fact questions (scores 0.30–0.45)."], 8.4, BODY, lh=1.25)
    table(sl, 7.0, 2.30, 5.68, [("Symptom", 0.42), ("Cause", 0.58)], [
        ("3/5 refused", "similarity gate — removed"),
        ("facts not found", "chunks overflow the encoder window"),
        ("≈2 s retrieval", "chunk key in StrongBox"),
        ("≈10.5 tok/s e2e", "long prompt + verbose JSON"),
        ("no NPU", "export with shape ops + int64"),
    ], row_h=0.40, cell_size=8.3)
    hair(sl, M, 4.95, CW, RULE_SOFT)
    section_label(sl, M, 5.08, "fixes, in order of impact")
    for i, (t, m, c) in enumerate([
            ("Token-aware chunks", "≤ ~200 tokens, ~40 overlap; re-index", ACCENT),
            ("Chunk key in TEE", "keep signing key in StrongBox", ACCENT),
            ("Confirm QNN on device", "NPU-shaped model shipped", AMBER),
            ("Record prefill/decode", "cap tokens for short answers", BODY)]):
        node(sl, M + i * 3.04, 5.40, 2.92, 0.9, t, m, c, tsize=9, msize=7.8)
    status_line(sl, "measured", "Token offsets computed with the verified "
                "tokenizer port on the exact chunks the phone returned.")
    return sl


def s_roadmap(prs):
    sl = new_slide(prs)
    chrome(sl, "22 · roadmap & limits", "What comes next, and what is not claimed.",
           "Ordered by what moves answer quality and demo credibility first.",
           "22")
    now = [("Retrieval quality", "token-aware chunking, re-index, eval with "
            "run_eval.py on the sensitive doc"),
           ("NPU confirmed", "QNN HTP verified on iQOO 15, pipeline benchmark "
            "with NPU∩GPU overlap"),
           ("Latency", "TEE chunk key; shorter capsule prompt; prefill/decode "
            "split in capsules")]
    nxt = [("Embeddings encrypted", "decrypt once into RAM at open, zeroise "
            "on background"),
           ("Unlocked-device keys", "setUnlockedDeviceRequired after device "
            "testing"),
           ("Fresh attestation", "laptop-supplied challenge at enrollment")]
    later = [("TLS / Noise for lan bridge", "same pairing as VaultLink"),
             ("Persisted replay cache", "reject replays across restarts"),
             ("PAKE pairing", "SPAKE2 + 6-digit compare; retire legacy v1")]
    for ci, (title, c, items) in enumerate([("NOW", ACCENT, now),
                                             ("NEXT", AMBER, nxt),
                                             ("LATER", ROADMAP, later)]):
        x = M + ci * 4.08
        txt(sl, x, 2.30, 3.8, 0.24, title, 9, c, True, spc=1.4)
        rect(sl, x, 2.58, 3.86, 0.03, fill=mix(BG, c, 0.6))
        for i, (t, m) in enumerate(items):
            node(sl, x, 2.78 + i * 0.86, 3.86, 0.76, t, m, None, tsize=9,
                 msize=7.8)
    node(sl, M, 5.45, CW, 0.9, "Not claimed", "NPU acceleration is not claimed "
         "until QNN HTP is verified on the device. Embeddings are plaintext "
         "vectors. Hardware level is device-reported unless the attestation "
         "root is supplied. The QNN AARs carry the Qualcomm AI Hub Model License.",
         DANGER, msize=8.4)
    return sl


def s_summary(prs):
    sl = new_slide(prs)
    starfield(sl, 8.4, 0.3, 4.7, 6.9, n=70, seed=5)
    chrome(sl, "23 · in one page", "Vault, in one page.", None, "23")
    rows = [
        ("Overall", "Phone holds corpus, index, encoder and one reasoner; the "
         "laptop gets a sealed, signed capsule over the clipboard."),
        ("Vault", "Chunk → MiniLM → AES-GCM SQLite + RAM matrix; rank in RAM, "
         "decrypt only winners; the loaded LLM writes every answer."),
        ("Compute", "NPU for embeddings (QNN HTP, strictly gated), GPU for "
         "the reasoner, CPU for ranking, StrongBox/TEE for keys."),
        ("Security", "Keys never leave the keystore; capsules signed over a "
         "canonical payload; laptop trusts only a pinned key."),
        ("VLP", "VAULTLINK/2: typed pairing code, HMAC key schedule, "
         "AES-GCM frames, direction keys, replay window, 20 s scrub."),
        ("Evidence", "Measured on the iQOO 15 where possible; verified on "
         "host otherwise; open gaps named, not hidden."),
    ]
    for i, (k, v) in enumerate(rows):
        y = 1.75 + i * 0.78
        pill(sl, M, y, k.upper(), ACCENT, 1.2)
        txt(sl, M + 1.4, y - 0.02, 6.6, 0.7, v, 11, INK, lh=1.22)
    return sl


SLIDES = (s_hero, s_problem, s_overall, s_repo, s_app, s_ingest, s_query,
          s_capsule, s_compute, s_npu, s_security_overview, s_at_rest,
          s_signing, s_trust, s_vlp_loop, s_vlp_crypto, s_vlp_threats,
          s_residue, s_desktop, s_telemetry, s_evidence, s_learned, s_roadmap,
          s_summary)


# -------------------------------------------------------------------- main --

def build(path=None):
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "Vault_PocketRAG_Deck.pptx")
    prs = Presentation()
    prs.slide_width = Inches(13.333)
    prs.slide_height = Inches(7.5)
    for fn in SLIDES:
        fn(prs)
    prs.save(path)
    print(f"wrote {path} - {len(prs.slides._sldIdLst)} slides")


if __name__ == "__main__":
    build()
