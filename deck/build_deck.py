"""
Vault (PocketRAG) — pitch deck generator.

Describes the system as it will actually be built and deployed, not the
plumbing prototype in ../vault_rag_test. The prototype appears once, on the
evidence slide, as the measured floor under the claims.

Editorial grid borrowed from the Ground Zero Mesh deck (eyebrow -> headline ->
standfirst -> content -> hairline + folio). Palette from vault_video/theme.ts:
green means on-device, red means it left the device, nothing else saturates.

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


# =========================================================== slide builders ==

def slide_hero(prs):
    sl = new_slide(prs)
    rect(sl, 0, 0, 13.333, 7.5, fill=VOID)
    starfield(sl, 6.6, 0.4, 6.5, 6.7, n=110, seed=23)
    scrim(sl, 0, 0, 13.333, 7.5, [(0, 0.98), (0.55, 0.86), (1, 0.55)], angle=0,
          base=VOID)

    for i in range(6):
        rect(sl, 2.222 * i, 0, 2.222, 0.115, fill=mix(ACCENT, VOID, i / 5 * 0.86))

    txt(sl, M, 0.60, 9.0, 0.24,
        "POCKETRAG  /  ON-DEVICE RETRIEVAL VAULT  /  ANDROID + DESKTOP",
        8.5, MUTED, True, spc=1.6)
    txt(sl, M, 0.98, 9.0, 0.95, "VAULT", 58, INK, False, DISPLAY, lh=0.96)
    txt(sl, M, 1.92, 7.4, 0.34,
        "Your documents never leave your phone. Only the evidence for the "
        "answer does.", 13, ACCENT, lh=1.15)

    rrect(sl, M, 2.44, 6.30, 1.52, fill=PANEL, line=RULE_SOFT, lw=0.7,
          alpha=0.88)
    txt(sl, M + 0.26, 2.62, 5.80, 0.20, "THE PROBLEM", 7.5, MUTED, True, spc=1.3)
    txt(sl, M + 0.26, 2.86, 5.80, 1.00,
        "To use AI on your own documents you are asked to upload them - "
        "contracts, medical records, source code, unpublished research. "
        "Encryption in transit does not help: the server must read the "
        "plaintext to embed it.", 9.8, INK, lh=1.30)

    rrect(sl, M, 4.10, 6.30, 1.40, fill=PANEL,
          line=mix(BG, ACCENT, 0.32), lw=0.8, alpha=0.90)
    txt(sl, M + 0.26, 4.28, 5.80, 0.20, "THE MOVE", 7.5, ACCENT, True, spc=1.3)
    txt(sl, M + 0.26, 4.52, 5.80, 0.90,
        "Invert the topology. The phone becomes the trusted core holding the "
        "corpus, the index and the encoder. The workstation becomes the edge, "
        "and only ever sees retrieved passages.", 9.8, INK, lh=1.30)

    stats = [("1 GB", "CORPUS THAT STAYS PUT", INK),
             ("~800", "TOKENS THAT MOVE", ACCENT),
             ("0", "NETWORK PERMISSIONS", ACCENT),
             ("0", "PER-TOKEN COST", INK)]
    for i, (v, l, c) in enumerate(stats):
        stat(sl, M + i * 1.62, 5.72, 1.55, v, l, c, 25, 7)

    # --- the ratio, drawn: what stays against what moves --------------------
    RX, RW = 7.40, 5.28
    section_label(sl, RX, 2.62, "WHAT STAYS ON THE PHONE", RW, ACCENT)
    rrect(sl, RX, 2.92, RW, 1.34, fill=mix(VOID, ACCENT, 0.10),
          line=mix(VOID, ACCENT, 0.38), lw=0.9)
    txt(sl, RX + 0.30, 3.14, 3.0, 0.52, "1,000 MB", 30, INK, False, DISPLAY)
    txt(sl, RX + 0.30, 3.74, RW - 0.60, 0.36,
        "the corpus, the index, every embedding, and the encoder itself",
        8.6, BODY, lh=1.24)

    section_label(sl, RX, 4.56, "WHAT CROSSES THE BRIDGE", RW, MUTED)
    rrect(sl, RX, 4.86, 0.34, 0.42, fill=mix(VOID, ACCENT, 0.22),
          line=mix(VOID, ACCENT, 0.46), lw=0.9, radius=0.04)
    txt(sl, RX + 0.52, 4.88, 4.70, 0.24, "approx. 4 KB", 14, ACCENT, False,
        DISPLAY)
    txt(sl, RX + 0.52, 5.14, 4.70, 0.22,
        "your question, and the passages that answer it", 8.6, BODY)

    hair(sl, RX, 5.56, RW, RULE_SOFT)
    txt(sl, RX, 5.72, RW, 0.46,
        "One part in 250,000 of what the vault holds ever becomes visible to "
        "anything else. Blocks not to scale - the real sliver would be "
        "invisible.", 8.4, MUTED, lh=1.26)

    hair(sl, M, FOOT_Y, CW, RULE_SOFT)
    txt(sl, M, PAGE_Y, 10.5, 0.22,
        "TEAM jSONs  ·  iQOO HACKATHON 2026  ·  TARGET ARCHITECTURE, NOT THE "
        "BENCH PROTOTYPE", 8, DIM, spc=0.6)
    return sl


def slide_problem(prs):
    sl = new_slide(prs)
    chrome(sl, "01 · the problem",
           "Two problems with the same shape.",
           "The data is in the wrong place, and the work is on the wrong "
           "processor. Every current answer fixes one by making the other "
           "worse.", "01")

    rrect(sl, M, 2.34, 5.85, 3.74, fill=PANEL, line=mix(BG, DANGER, 0.26),
          lw=0.8)
    txt(sl, M + 0.28, 2.54, 5.30, 0.22, "PROBLEM ONE - THE DATA LEAVES", 8,
        DANGER, True, spc=1.2)
    txt(sl, M + 0.28, 2.82, 5.30, 0.46,
        "The moment a document leaves your machine, you lose control of the "
        "copy.", 11, INK, lh=1.24)

    fates = [("RETAINED", "held on infrastructure you do not operate"),
             ("INDEXED", "searchable by systems you cannot audit"),
             ("SUBPOENAED", "discoverable through a third party"),
             ("TRAINED ON", "absorbed into weights, unremovable")]
    for i, (a, b) in enumerate(fates):
        yy = 3.44 + i * 0.42
        rect(sl, M + 0.28, yy, 0.038, 0.30, fill=DANGER)
        txt(sl, M + 0.46, yy + 0.025, 1.62, 0.22, a, 8.6, INK, True, spc=0.5)
        txt(sl, M + 2.10, yy + 0.035, 3.50, 0.22, b, 8.2, BODY)

    txt(sl, M + 0.28, 5.34, 5.30, 0.42,
        "Transport encryption is not a fix. The embedding server has to see "
        "the plaintext to turn it into a vector.", 8.4, MUTED, lh=1.24,
        italic=True)

    rrect(sl, 6.98, 2.34, 5.70, 3.74, fill=PANEL, line=RULE, lw=0.8)
    txt(sl, 7.26, 2.54, 5.10, 0.22, "PROBLEM TWO - THE WRONG PROCESSOR", 8,
        AMBER, True, spc=1.2)
    txt(sl, 7.26, 2.82, 5.10, 0.46,
        "So you run it locally - and a transformer starts competing with your "
        "compiler for the same cores.", 11, INK, lh=1.24)

    section_label(sl, 7.26, 3.50, "UTILISATION WHILE YOU WORK", 5.0)
    bars = [("Laptop CPU / GPU", 0.94, DANGER, "saturated - fans, throttling"),
            ("Phone NPU", 0.04, ACCENT, "tens of TOPS, sitting near idle")]
    for i, (name, frac, col, note) in enumerate(bars):
        yy = 3.82 + i * 0.86
        txt(sl, 7.26, yy, 3.2, 0.20, name, 9, INK, True)
        txt(sl, 10.60, yy, 1.76, 0.20, f"{int(frac * 100)}%", 9, col, True,
            align=PP_ALIGN.RIGHT)
        meter(sl, 7.26, yy + 0.26, 5.10, frac, col)
        txt(sl, 7.26, yy + 0.44, 5.10, 0.20, note, 7.8, MUTED)

    txt(sl, 7.26, 5.44, 5.10, 0.62,
        "Every flagship phone ships a neural accelerator rated in tens of "
        "trillions of operations per second. It sits near zero utilisation in "
        "your pocket all day.", 8.6, BODY, lh=1.26)

    txt(sl, M, 6.34, CW, 0.24,
        "THE MOST CAPABLE IDLE PROCESSOR YOU OWN IS ALREADY HOLDING YOUR DATA",
        8.5, ACCENT, True, spc=1.1)
    return sl


def slide_existing(prs):
    sl = new_slide(prs)
    chrome(sl, "02 · why the existing answers fail",
           "Four ways people solve this today. None of them close.",
           "Each option trades away either privacy, capability, or the "
           "hardware you already own.", "02")

    cards = [
        ("CLOUD RAG", DANGER, "ChatGPT · Claude Projects · NotebookLM",
         "Upload the corpus. Fast, capable, and the plaintext is on someone "
         "else's disk before the first vector exists.",
         "Privacy is a promise in a policy document."),
        ("LAPTOP-LOCAL LLM", AMBER, "Ollama · LM Studio · llama.cpp",
         "Nothing leaves, but the machine you are working on is the machine "
         "doing the inference. Thermals and battery both lose.",
         "Right threat model, wrong processor."),
        ("ENTERPRISE ON-PREM", MUTED, "Private VPC · self-hosted vector DB",
         "Works, at the cost of a cluster, a security review and a budget. "
         "Nothing an individual can deploy.",
         "Right answer for a company, not a person."),
        ("BROWSER / WASM RAG", MUTED, "WebLLM · transformers.js",
         "Data stays in the tab, but so does the ceiling - small models, cold "
         "caches, and no access to the NPU.",
         "Private, but not capable enough to use."),
    ]
    cw = 2.86
    for i, (title, col, sub, body, verdict) in enumerate(cards):
        x = M + i * (cw + 0.19)
        rrect(sl, x, 2.36, cw, 3.20, fill=PANEL, line=RULE_SOFT, lw=0.7)
        rect(sl, x, 2.36, cw, 0.036, fill=col)
        txt(sl, x + 0.22, 2.58, cw - 0.44, 0.22, title, 9.5, INK, True, spc=0.6)
        txt(sl, x + 0.22, 2.84, cw - 0.44, 0.34, sub, 7.4, col, True, lh=1.2)
        hair(sl, x + 0.22, 3.26, cw - 0.44, RULE_SOFT)
        txt(sl, x + 0.22, 3.42, cw - 0.44, 1.20, body, 8.8, BODY, lh=1.30)
        hair(sl, x + 0.22, 4.62, cw - 0.44, RULE_SOFT)
        txt(sl, x + 0.22, 4.78, cw - 0.44, 0.62, verdict, 8.4, INK, lh=1.26,
            italic=True)

    rrect(sl, M, 5.86, CW, 0.60, fill=mix(BG, ACCENT, 0.09),
          line=mix(BG, ACCENT, 0.30), lw=0.7)
    rich(sl, M + 0.26, 6.02, CW - 0.52, 0.30,
         [("The gap: ", {"bold": True, "color": ACCENT, "size": 9.5}),
          ("nobody treats the phone as the trusted core. It is always the thin "
           "client asking a bigger machine for help - even though it holds the "
           "documents, the camera that captured them, and an idle NPU.",
           {"size": 9.5, "color": INK})])
    return sl


def slide_inversion(prs):
    sl = new_slide(prs)
    chrome(sl, "03 · the solution",
           "Invert the topology.",
           "Stop treating the phone as a thin client for the cloud. Treat it "
           "as a private inference appliance that happens to fit in your "
           "pocket.", "03")

    section_label(sl, M, 2.36, "CONVENTIONAL - THE CORPUS TRAVELS", 5.6, DANGER)
    rrect(sl, M, 2.66, 5.85, 1.86, fill=PANEL, line=mix(BG, DANGER, 0.24),
          lw=0.8)
    rrect(sl, M + 0.30, 2.94, 1.42, 0.74, fill=PANEL2, line=RULE_SOFT, lw=0.6)
    txt(sl, M + 0.30, 3.18, 1.42, 0.22, "YOUR DEVICE", 7.6, INK, True,
        align=PP_ALIGN.CENTER, spc=0.6)
    rrect(sl, M + 4.06, 2.94, 1.42, 0.74, fill=mix(BG, DANGER, 0.12),
          line=mix(BG, DANGER, 0.36), lw=0.7)
    txt(sl, M + 4.06, 3.18, 1.42, 0.22, "THE SERVER", 7.6, DANGER, True,
        align=PP_ALIGN.CENTER, spc=0.6)
    arrow(sl, M + 1.82, 3.31, M + 3.96, "ENTIRE CORPUS", "gigabytes, plaintext",
          DANGER, above=True)
    txt(sl, M + 0.30, 3.86, 5.25, 0.48,
        "Everything you own is copied to infrastructure you do not control, "
        "and has to be readable once it arrives.", 8.8, BODY, lh=1.26)

    section_label(sl, 6.98, 2.36, "VAULT - ONLY THE QUESTION TRAVELS", 5.7,
                  ACCENT)
    rrect(sl, 6.98, 2.66, 5.70, 1.86, fill=PANEL, line=mix(BG, ACCENT, 0.30),
          lw=0.8)
    rrect(sl, 7.26, 2.94, 1.42, 0.74, fill=mix(BG, ACCENT, 0.12),
          line=mix(BG, ACCENT, 0.40), lw=0.7)
    txt(sl, 7.26, 3.10, 1.42, 0.20, "PHONE", 7.6, ACCENT, True,
        align=PP_ALIGN.CENTER, spc=0.6)
    txt(sl, 7.26, 3.30, 1.42, 0.18, "trusted core", 6.6, MUTED,
        align=PP_ALIGN.CENTER)
    rrect(sl, 10.94, 2.94, 1.42, 0.74, fill=PANEL2, line=RULE_SOFT, lw=0.6)
    txt(sl, 10.94, 3.10, 1.42, 0.20, "LAPTOP", 7.6, INK, True,
        align=PP_ALIGN.CENTER, spc=0.6)
    txt(sl, 10.94, 3.30, 1.42, 0.18, "the edge", 6.6, MUTED,
        align=PP_ALIGN.CENTER)
    arrow(sl, 10.86, 3.14, 8.78, "QUESTION", "~40 tokens", BODY, above=True)
    arrow(sl, 8.78, 3.52, 10.86, "TOP PASSAGES", "~800 tokens", ACCENT,
          above=False)
    txt(sl, 7.26, 4.06, 5.14, 0.36,
        "A gigabyte of private material stays put. A few hundred tokens of "
        "relevant context is all that moves.", 8.8, BODY, lh=1.26)

    hair(sl, M, 4.82, CW, RULE_SOFT)
    section_label(sl, M, 5.00, "WHAT THAT SEPARATION BUYS", 6.0)
    cols = [
        ("Retrieval is private",
         "The corpus, the index and the encoder never exist anywhere but the "
         "phone. Search happens entirely inside the vault."),
        ("Generation is yours to choose",
         "The passages can go to a local model, a self-hosted one, or a "
         "frontier API. That is a policy setting, not an architecture "
         "change."),
        ("It crosses a wire, not the internet",
         "The bridge is a direct device-to-device link, so there is nothing "
         "in the middle that has to be trusted."),
    ]
    cwid = 3.90
    for i, (h, b) in enumerate(cols):
        x = M + i * (cwid + 0.17)
        rect(sl, x, 5.32, 0.036, 1.06, fill=ACCENT if i == 0 else RULE)
        txt(sl, x + 0.18, 5.32, cwid - 0.24, 0.24, h, 9.6, INK, True)
        txt(sl, x + 0.18, 5.60, cwid - 0.24, 0.80, b, 8.6, BODY, lh=1.28)
    return sl


def slide_architecture(prs):
    sl = new_slide(prs)
    chrome(sl, "04 · architecture",
           "The vault, the bridge, and the edge.",
           "Three components, one trust boundary. Everything to the left of "
           "the dashed line is under the user's physical control.", "04")

    device(sl, M, 2.30, 3.05, 4.10, "YOUR PHONE", "THE VAULT · TRUSTED CORE",
           ACCENT, notch=True, rows=[
               ("Corpus", "documents, code, captured images"),
               ("Chunker", "256-token windows, 32 overlap"),
               ("Encoder", "MiniLM-L6 · 384-d · NPU delegate"),
               ("Index", "SQLite + sqlite-vec, ANN search"),
               ("Keystore", "SQLCipher key, hardware-backed")],
           footer="Nothing in this column has a network path.")

    boundary(sl, 4.16, 2.30, 4.10)

    rrect(sl, 4.52, 2.66, 3.90, 2.14, fill=PANEL, line=RULE, lw=0.8)
    txt(sl, 4.52, 2.84, 3.90, 0.20, "THE BRIDGE", 8.5, INK, True,
        align=PP_ALIGN.CENTER, spc=1.1)
    txt(sl, 4.52, 3.04, 3.90, 0.18, "DIRECT DEVICE-TO-DEVICE", 7, MUTED, True,
        align=PP_ALIGN.CENTER, spc=1.2)
    arrow(sl, 7.90, 3.78, 5.04, "QUESTION IN", "~40 tokens", BODY, above=True)
    arrow(sl, 5.04, 4.18, 7.90, "PASSAGES OUT", "~800 tokens · cited", ACCENT,
          above=False)
    txt(sl, 4.72, 4.92, 3.50, 0.40,
        "Office Kit transport at the venue; USB or a local socket as the "
        "fallback. Never an internet hop.", 8, MUTED, lh=1.24,
        align=PP_ALIGN.CENTER)

    boundary(sl, 8.62, 2.30, 4.10, "")

    device(sl, 9.00, 2.30, 3.68, 4.10, "YOUR LAPTOP", "THE EDGE · UNTRUSTED",
           None, rows=[
               ("Editor extension", "VS Code or browser side panel"),
               ("Prompt assembler", "passages + question, nothing else"),
               ("Model of your choice", "local, self-hosted, or API"),
               ("Answer + citations", "every claim points back to a chunk"),
               ("Nothing else", "no corpus, no index, no embeddings")],
           footer="Compromising it exposes only what you asked for.")

    barrier(sl, 4.52, 5.48, 3.90, 0.50, "NO PATH TO ANY SERVER")
    txt(sl, 4.52, 6.08, 3.90, 0.40,
        "The app requests no network permission, so this arrow cannot be "
        "drawn even by a compromised build.", 7.8, MUTED, lh=1.26,
        align=PP_ALIGN.CENTER)

    chip(sl, M, 6.56, "target")
    txt(sl, M + chip_w("target") + 0.16, 6.58, 7.6, 0.20,
        "sqlite-vec, SQLCipher, the NPU delegate and Office Kit are the target "
        "build - slide 09 states what is measured today.", 7.8, DIM)
    return sl


def slide_pipeline(prs):
    sl = new_slide(prs)
    chrome(sl, "05 · the pipeline",
           "From a document to a cited answer.",
           "Six stages. The first five never leave the phone; only the sixth "
           "crosses the boundary.", "05")

    stage_chain(sl, M, 2.42, CW, [
        ("Ingest", "Text, code and camera captures are normalised to plain "
                   "text on-device. OCR runs locally.", "on phone"),
        ("Chunk", "256-token windows with 32 tokens of overlap, so an idea "
                  "spanning a boundary is never cut in half.", "on phone"),
        ("Encode", "MiniLM-L6-v2, 384 dimensions, quantised and compiled for "
                   "the phone's neural engine.", "on phone · npu"),
        ("Store", "Vectors land in SQLite with a vector index, encrypted at "
                  "rest under a hardware-held key.", "on phone · encrypted"),
        ("Retrieve", "The same encoder embeds the question; cosine similarity "
                     "ranks the index and the top passages are serialised.",
         "on phone"),
        ("Generate", "The bridge hands those passages to an editor extension, "
                     "which prompts whichever model you trust.",
         "your choice"),
    ], box_h=1.30)

    hair(sl, M, 4.42, CW, RULE_SOFT)

    section_label(sl, M, 4.62, "WHY EACH CHOICE IS THE ONE IT IS", 6.0)
    left = [
        ("256 tokens with 32 overlap",
         "Matches MiniLM's context without truncation, and the overlap keeps "
         "a definition that straddles two windows retrievable from either."),
        ("MiniLM-L6-v2 at 384 dimensions",
         "Small enough to quantise onto a phone NPU, strong enough for passage "
         "retrieval. A 1 GB corpus indexes to roughly 200 MB."),
    ]
    right = [
        ("SQLite rather than a vector service",
         "One file, no daemon, no port, no network - and the only storage "
         "engine on Android that SQLCipher already understands."),
        ("Encryption at rest, key in hardware",
         "A stolen phone yields a ciphertext blob. The key never leaves the "
         "secure element, so the index is unreadable off-device."),
    ]
    bullet_rows(sl, M, 4.94, 5.75, left, gap=0.86)
    bullet_rows(sl, 6.98, 4.94, 5.70, right, gap=0.86)
    return sl


def slide_disclosure(prs):
    sl = new_slide(prs)
    chrome(sl, "06 · the trust boundary",
           "Minimal disclosure, measured in bytes.",
           "Even the side you trust only ever sees the passages it needs - "
           "never the corpus, never the index, never the embeddings.", "06")

    section_label(sl, M, 2.34, "WHAT A SINGLE QUESTION ACTUALLY MOVES", 6.0)

    rows = [
        ("Your corpus", "1,000 MB", 1.00, DANGER, "never crosses"),
        ("The vector index", "approx. 200 MB", 0.20, DANGER, "never crosses"),
        ("Chunk embeddings", "1.5 KB each", 0.015, DANGER, "never crosses"),
        ("Your question", "approx. 40 tokens", 0.006, BODY, "crosses"),
        ("Top-k passages", "approx. 800 tokens", 0.012, ACCENT,
         "crosses, cited"),
    ]
    for i, (name, size, frac, col, verdict) in enumerate(rows):
        yy = 2.70 + i * 0.62
        crossing = "never" not in verdict
        txt(sl, M, yy, 2.55, 0.22, name, 9.6, INK if crossing else BODY, True)
        txt(sl, M + 2.60, yy, 1.65, 0.22, size, 9, col, True)
        meter(sl, M + 4.40, yy + 0.045, 4.20, frac,
              col if crossing else mix(BG, DANGER, 0.42))
        txt(sl, M + 8.80, yy, 3.10, 0.22, verdict.upper(), 7.6,
            ACCENT if crossing else DIM, True, spc=1.0)
        if i < len(rows) - 1:
            hair(sl, M, yy + 0.44, CW, RULE_SOFT)

    hair(sl, M, 5.88, CW, RULE)

    rich(sl, M, 6.08, 7.6, 0.60,
         [("The ratio is the argument. ", {"bold": True, "color": INK,
                                           "size": 10.5}),
          ("Roughly one part in 250,000 of what the vault holds ever becomes "
           "visible to anything else - and that part is chosen by a similarity "
           "search you ran yourself.",
           {"size": 10.5, "color": BODY})], lh=1.28)

    rrect(sl, 8.62, 6.00, 4.06, 0.68, fill=mix(BG, ACCENT, 0.09),
          line=mix(BG, ACCENT, 0.28), lw=0.7)
    txt(sl, 8.84, 6.14, 3.66, 0.20, "AND IT IS REVOCABLE", 7.5, ACCENT, True,
        spc=1.2)
    txt(sl, 8.84, 6.36, 3.66, 0.26,
        "Delete the passages and the disclosure ends. A copy cannot be "
        "recalled.", 8.2, BODY, lh=1.2)
    return sl


def slide_enforcement(prs):
    sl = new_slide(prs)
    chrome(sl, "07 · what is new",
           "Privacy that is enforced, not promised.",
           "The strongest claim in this project is also the cheapest to "
           "check: the application asks the operating system for no network "
           "access, so it has none.", "07")

    chip(sl, M, 2.16, "verified")

    rrect(sl, M, 2.44, 6.05, 2.62, fill=VOID, line=RULE, lw=0.8)
    txt(sl, M + 0.26, 2.62, 5.50, 0.20,
        "aapt2 dump permissions app-release.apk", 8, MUTED, False, MONO)
    hair(sl, M + 0.26, 2.90, 5.53, RULE_SOFT)
    perms = [("android.permission.INTERNET", "not requested"),
             ("ACCESS_NETWORK_STATE", "not requested"),
             ("READ_EXTERNAL_STORAGE", "not requested"),
             ("ACCESS_FINE_LOCATION", "not requested")]
    for i, (p, v) in enumerate(perms):
        yy = 3.06 + i * 0.36
        txt(sl, M + 0.26, yy, 3.60, 0.22, p, 8.4, BODY, False, MONO)
        txt(sl, M + 4.00, yy, 1.80, 0.22, v, 8.4, ACCENT, True, font=MONO)
    hair(sl, M + 0.26, 4.54, 5.53, RULE_SOFT)
    txt(sl, M + 0.26, 4.68, 5.53, 0.24,
        "0 permissions requested in the release build", 9.5, ACCENT, True,
        font=MONO)

    section_label(sl, 6.98, 2.44, "WHY THIS IS A DIFFERENT KIND OF CLAIM", 5.7,
                  ACCENT)
    bullet_rows(sl, 6.98, 2.76, 5.70, [
        ("An auditor verifies it in seconds",
         "One command against the shipped APK. No code review, no trust in our "
         "build process, no reading of a privacy policy."),
        ("It survives a compromised build",
         "If the app were backdoored tomorrow, the exfiltration path still "
         "would not exist - the OS never granted the capability."),
        ("It is a property, not a policy",
         "Policies change with a version bump and an email. A missing manifest "
         "entry changes only by shipping a visibly different app."),
    ], gap=0.86, tsize=10, bsize=8.8)

    hair(sl, M, 5.42, CW, RULE_SOFT)
    section_label(sl, M, 5.62, "THE OTHER THREE NOVELTIES", 6.0)
    novel = [
        ("Direction of trust",
         "The personal device is the trusted core and the workstation is the "
         "edge. Normally the small device asks the big one for help."),
        ("Minimal disclosure",
         "Even the trusted side sees only the passages it needs, never the "
         "corpus and never the index."),
        ("Silicon you already own",
         "No new hardware, no per-token cost, no rate limit - and because "
         "capture is local, a whiteboard photo becomes searchable without "
         "touching a server."),
    ]
    cwid = 3.90
    for i, (h, b) in enumerate(novel):
        x = M + i * (cwid + 0.17)
        rect(sl, x, 5.92, 0.036, 0.82, fill=ACCENT)
        txt(sl, x + 0.18, 5.92, cwid - 0.24, 0.22, h, 9.4, INK, True)
        txt(sl, x + 0.18, 6.18, cwid - 0.24, 0.60, b, 8.4, BODY, lh=1.26)
    return sl


def slide_usecases(prs):
    sl = new_slide(prs)
    chrome(sl, "08 · the real-world case",
           "Who cannot upload, and therefore cannot use AI today.",
           "These are not privacy-preference users. In each case the upload "
           "itself is what is prohibited - by law, by contract, or by "
           "physics.", "08")

    cases = [
        ("LEGAL", "Contracts, discovery, privileged files",
         "Privilege does not survive disclosure to a third-party processor, "
         "and client agreements routinely forbid it outright.",
         "Uploading is a professional-conduct problem, not a preference."),
        ("CLINICAL", "Patient notes, imaging reports, histories",
         "DPDP and HIPAA make a cloud embedding call a regulated disclosure "
         "with a named accountable party.",
         "The consent form does not cover an AI vendor."),
        ("ENGINEERING", "Proprietary source, pre-release designs",
         "Source under NDA, unreleased hardware documents, and security "
         "findings that must not be indexed anywhere.",
         "Most employers already block the upload at the proxy."),
        ("RESEARCH", "Unpublished data, embargoed manuscripts",
         "Priority is lost the moment an unpublished result is retained by a "
         "system that may train on it.",
         "Embargo and third-party retention are incompatible."),
        ("FIELD", "Survey, audit and inspection work offline",
         "Mines, ships, rural clinics and secure facilities - sites with no "
         "connectivity, where the phone is the only computer allowed in.",
         "There is no server to upload to in the first place."),
    ]
    cwid = 2.25
    for i, (tag, sub, body, kicker) in enumerate(cases):
        x = M + i * (cwid + 0.18)
        rrect(sl, x, 2.36, cwid, 3.36, fill=PANEL, line=RULE_SOFT, lw=0.7)
        rect(sl, x, 2.36, cwid, 0.036, fill=ACCENT)
        txt(sl, x + 0.20, 2.56, cwid - 0.40, 0.20, tag, 9, ACCENT, True, spc=1.2)
        txt(sl, x + 0.20, 2.80, cwid - 0.40, 0.44, sub, 8.6, INK, True, lh=1.22)
        hair(sl, x + 0.20, 3.34, cwid - 0.40, RULE_SOFT)
        txt(sl, x + 0.20, 3.50, cwid - 0.40, 1.36, body, 8.2, BODY, lh=1.30)
        hair(sl, x + 0.20, 4.88, cwid - 0.40, RULE_SOFT)
        txt(sl, x + 0.20, 5.02, cwid - 0.40, 0.62, kicker, 8, MUTED, lh=1.26,
            italic=True)

    rrect(sl, M, 5.92, CW, 0.66, fill=mix(BG, ACCENT, 0.09),
          line=mix(BG, ACCENT, 0.30), lw=0.7)
    rich(sl, M + 0.26, 6.08, CW - 0.52, 0.36,
         [("The shape they share: ", {"bold": True, "color": ACCENT,
                                      "size": 9.6}),
          ("the corpus is small, personal, and legally attached to one "
           "individual - exactly the workload a phone can hold entirely, and "
           "exactly the workload a shared server should never hold at all.",
           {"size": 9.6, "color": INK})])
    return sl


def slide_evidence(prs):
    sl = new_slide(prs)
    chrome(sl, "09 · evidence",
           "What is measured today, and what is still a target.",
           "A bench prototype already runs the retrieval half of this on a "
           "mid-range handset. These are its numbers, not projections.", "09")

    LW = 5.90                                   # left column, clear of table
    section_label(sl, M, 2.34, "MEASURED ON A REAL HANDSET", 4.2, ACCENT)
    chip(sl, M + 3.10, 2.30, "measured")
    txt(sl, M, 2.60, LW, 0.20,
        "realme RMX3660 · Snapdragon 695 · Android 14 · release build", 8,
        MUTED)

    facts = [("233 ms", "QUERY EMBEDDING · 256 TOKENS", ACCENT),
             ("567 ms", "MODEL LOAD, ONCE PER SESSION", INK),
             ("12x", "XNNPACK OVER CPU KERNELS", ACCENT),
             ("0", "PERMISSIONS IN THE APK", ACCENT)]
    for i, (v, l, c) in enumerate(facts):
        stat(sl, M + (i % 2) * 3.05, 2.94 + (i // 2) * 0.94, 2.90, v, l, c,
             25, 7)

    txt(sl, M, 4.86, LW, 0.50,
        "2,782 ms fell to 224 ms once XNNPACK was enabled. Retrieval quality "
        "was checked by hand against known-answer queries, and 13 of 13 unit "
        "tests pass on chunking and tokenisation.", 8.6, BODY, lh=1.28)

    rrect(sl, M, 5.52, LW, 1.16, fill=PANEL, line=mix(BG, AMBER, 0.26), lw=0.8)
    txt(sl, M + 0.24, 5.70, LW - 0.48, 0.20,
        "THE HONEST GAP - WHAT WE WILL NOT CLAIM ON STAGE", 7.5, AMBER, True,
        spc=1.2)
    txt(sl, M + 0.24, 5.94, LW - 0.48, 0.62,
        "That the NPU path is proven. On a Snapdragon 695 it never "
        "materialised, so the hackathon hardware has to be measured rather "
        "than assumed. The security story is scoped, not yet shipped.",
        8.4, BODY, lh=1.28)

    table(sl, 7.05, 2.34, 5.63,
          [("CAPABILITY", 0.32), ("TARGET BUILD", 0.38), ("TODAY", 0.30)],
          [("Embedding", "NPU vendor delegate", "XNNPACK CPU"),
           ("Vector index", "sqlite-vec ANN", "brute-force cosine"),
           ("At rest", "SQLCipher + Keystore", "not yet"),
           ("Bridge", "Office Kit transport", "USB / clipboard"),
           ("Generation", "on-device SLM", "laptop model"),
           ("Network perms", "none", "none")],
          colors=[AMBER, AMBER, DANGER, AMBER, AMBER, ACCENT],
          row_h=0.44, cell_size=8.6)

    txt(sl, 7.05, 5.52, 5.63, 0.80,
        "Only the last row is already where it needs to be - and it is the row "
        "the whole argument rests on. Everything above it is engineering with "
        "known answers, not research.", 8.8, BODY, lh=1.30)
    return sl


def slide_roadmap(prs):
    sl = new_slide(prs)
    chrome(sl, "10 · where it goes",
           "Close the loop, then federate, then make it ambient.",
           "Each step removes one more reason to send anything anywhere.",
           "10")

    phases = [
        ("NEAR", "Generation moves on-device",
         "A small language model reads the retrieved passages on the phone "
         "itself. The loop closes entirely inside the vault, and the bridge "
         "becomes optional rather than load-bearing.",
         "The laptop stops being part of the threat model.", ACCENT, 0.34),
        ("NEXT", "Vaults federate, peer to peer",
         "Phone, laptop and workstation hold one personal index, synchronised "
         "directly between devices you own, with no server in the middle "
         "holding a key or a copy.",
         "One corpus, many devices, still no third party.", ROADMAP, 0.62),
        ("LATER", "Ingestion becomes ambient",
         "Meetings, screenshots and notes are indexed continuously and "
         "locally. Capture stops being a deliberate act and the vault fills "
         "itself as you work.",
         "Personal memory that was never uploadable to begin with.",
         ROADMAP, 0.86),
    ]
    cwid = 3.90
    for i, (tag, title, body, kicker, col, frac) in enumerate(phases):
        x = M + i * (cwid + 0.17)
        rrect(sl, x, 2.36, cwid, 2.72, fill=PANEL, line=RULE_SOFT, lw=0.7)
        rect(sl, x, 2.36, cwid, 0.036, fill=col)
        txt(sl, x + 0.24, 2.58, 1.4, 0.20, tag, 7.5, col, True, spc=1.4)
        txt(sl, x + 0.24, 2.84, cwid - 0.48, 0.44, title, 12.5, INK, False,
            DISPLAY, lh=1.12)
        txt(sl, x + 0.24, 3.40, cwid - 0.48, 1.00, body, 8.8, BODY, lh=1.30)
        hair(sl, x + 0.24, 4.44, cwid - 0.48, RULE_SOFT)
        txt(sl, x + 0.24, 4.60, cwid - 0.48, 0.40, kicker, 8.4, col, lh=1.24)
        meter(sl, x + 0.24, 4.86, cwid - 0.48, frac, col, h=0.055)

    hair(sl, M, 5.42, CW, RULE)
    section_label(sl, M, 5.62, "THE LONGER ARC", 6.0)
    txt(sl, M, 5.92, 8.6, 0.70,
        "Every year more neural silicon ships inside devices people already "
        "carry. The data is already there. The compute is already there. The "
        "only thing still missing is the assumption that it has to leave.",
        11.5, INK, lh=1.30)
    txt(sl, 9.40, 5.96, 3.28, 0.28, "BUILD THE VAULT.", 12, ACCENT, True,
        DISPLAY, align=PP_ALIGN.RIGHT)
    txt(sl, 9.40, 6.28, 3.28, 0.28, "KEEP THE CORPUS.", 12, ACCENT, True,
        DISPLAY, align=PP_ALIGN.RIGHT)
    return sl


def slide_risks(prs):
    sl = new_slide(prs)
    chrome(sl, "11 · limits and risks",
           "Where this is hard, and what we do about it.",
           "Stated plainly, because every one of these is a question a "
           "reviewer will ask.", "11")

    txt(sl, M + 3.75, 2.16, 4.15, 0.20, "THE RISK", 7.5, MUTED, True, spc=1.3)
    txt(sl, M + 8.20, 2.16, 4.48, 0.20, "THE MITIGATION", 7.5, ACCENT, True,
        spc=1.3)

    risks = [
        ("The NPU may not be reachable", AMBER,
         "Vendor delegates vary by chipset and OS build. On our test handset "
         "NNAPI never materialised at all.",
         "XNNPACK on CPU is already fast enough at 233 ms. The NPU is upside, "
         "not a dependency."),
        ("Retrieval quality is the real ceiling", AMBER,
         "A 384-dimension model on a small corpus will miss paraphrase and "
         "cross-document reasoning a large model would catch.",
         "Hybrid BM25 plus vector ranking, and a reranker small enough to run "
         "on the same NPU."),
        ("Corpus size has a hard limit", MUTED,
         "Brute-force cosine stops being acceptable somewhere in the tens of "
         "thousands of chunks.",
         "sqlite-vec gives approximate search in the same file, with no daemon "
         "and no new trust boundary."),
        ("The bridge is a new attack surface", DANGER,
         "Anything that carries passages off the phone is, by definition, the "
         "one place data can leak.",
         "Pairing is explicit and per-session, the payload is passages only, "
         "and it is a direct link with no server to intercept."),
        ("On-device generation is not free", MUTED,
         "A model small enough for phone memory is meaningfully weaker than "
         "the frontier model a user would otherwise pick.",
         "Generation stays pluggable. Privacy is guaranteed at the retrieval "
         "layer, so the model is the user's trade to make."),
    ]
    y = 2.44
    for i, (title, col, risk, fix) in enumerate(risks):
        rect(sl, M, y + 0.02, 0.036, 0.62, fill=col)
        txt(sl, M + 0.20, y, 3.35, 0.48, title, 9.6, INK, True, lh=1.18)
        txt(sl, M + 3.75, y + 0.02, 4.15, 0.66, risk, 8.5, BODY, lh=1.26)
        txt(sl, M + 8.20, y + 0.02, 4.48, 0.66, fix, 8.5, ACCENT, lh=1.26)
        if i < len(risks) - 1:
            hair(sl, M, y + 0.74, CW, RULE_SOFT)
        y += 0.86
    return sl


def slide_summary(prs):
    sl = new_slide(prs)
    rect(sl, 0, 0, 13.333, 7.5, fill=VOID)
    starfield(sl, 0.2, 0.3, 12.9, 6.9, n=70, seed=41)
    scrim(sl, 0, 0, 13.333, 7.5, [(0, 0.90), (0.5, 0.96), (1, 0.90)], angle=90,
          base=VOID)
    for i in range(6):
        rect(sl, 2.222 * i, 0, 2.222, 0.115,
             fill=mix(ACCENT, VOID, i / 5 * 0.86))

    txt(sl, M, 0.62, 9.0, 0.24, "12 · IN ONE PAGE", 8.5, MUTED, True, spc=1.6)
    txt(sl, M, 1.02, 11.4, 0.66,
        "The data is already on the phone. So is the compute.", 30, INK, False,
        DISPLAY, lh=1.04)
    txt(sl, M, 1.84, 10.6, 0.34,
        "Vault makes retrieval a local operation, and disclosure an explicit, "
        "revocable, byte-countable act.", 12, ACCENT, lh=1.2)

    points = [
        ("THE PROBLEM",
         "Using AI on your own documents currently means uploading them, and "
         "the plaintext has to be readable on the far side to be embedded."),
        ("THE INVERSION",
         "The phone becomes the trusted core holding corpus, index and "
         "encoder. The laptop becomes the edge, and sees only passages."),
        ("THE PROOF",
         "233 ms per query embedding on a mid-range handset, and a release "
         "build that requests zero permissions - verifiable in one command."),
        ("THE MARKET",
         "Legal, clinical, engineering, research and field work: corpora that "
         "are small, personal, and prohibited from being uploaded at all."),
    ]
    for i, (h, b) in enumerate(points):
        x = M + (i % 2) * 6.20
        y = 2.66 + (i // 2) * 1.28
        rect(sl, x, y, 0.036, 0.98, fill=ACCENT)
        txt(sl, x + 0.20, y, 5.60, 0.20, h, 8, ACCENT, True, spc=1.3)
        txt(sl, x + 0.20, y + 0.26, 5.70, 0.74, b, 9.8, INK, lh=1.30)

    hair(sl, M, 5.42, CW, RULE)
    stats = [("1 GB", "STAYS ON THE PHONE", INK),
             ("~800", "TOKENS EVER LEAVE", ACCENT),
             ("233 ms", "MEASURED QUERY EMBED", ACCENT),
             ("0", "NETWORK PERMISSIONS", ACCENT),
             ("0", "PER-TOKEN COST", INK)]
    for i, (v, l, c) in enumerate(stats):
        stat(sl, M + i * 2.45, 5.66, 2.35, v, l, c, 26, 7)

    hair(sl, M, FOOT_Y, CW, RULE_SOFT)
    txt(sl, M, PAGE_Y, 10.5, 0.22,
        "VAULT / POCKETRAG  ·  TEAM jSONs  ·  BUILD THE VAULT. KEEP THE "
        "CORPUS.", 8, DIM, spc=0.6)
    txt(sl, 11.90, PAGE_Y, 0.78, 0.22, "12", 8.5, MUTED, True,
        align=PP_ALIGN.RIGHT, spc=0.8)
    return sl


# -------------------------------------------------------------------- main --

def build(path=None):
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "Vault_PocketRAG_Deck.pptx")
    prs = Presentation()
    prs.slide_width = Inches(13.333)
    prs.slide_height = Inches(7.5)

    for fn in (slide_hero, slide_problem, slide_existing, slide_inversion,
               slide_architecture, slide_pipeline, slide_disclosure,
               slide_enforcement, slide_usecases, slide_evidence,
               slide_roadmap, slide_risks, slide_summary):
        fn(prs)

    prs.save(path)
    print(f"wrote {path} - {len(prs.slides._sldIdLst)} slides")


if __name__ == "__main__":
    build()
