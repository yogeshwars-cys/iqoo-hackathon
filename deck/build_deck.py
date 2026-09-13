"""
Vault (PocketRAG) - compact submission deck.

Eleven slides in the section order the UHI, Drift-Sense, Ground-Zero Mesh and
Aerothon decks share: title with problem statement and headline numbers,
then problem, existing approaches, solution, architecture, end-to-end flow,
security, stack, outcomes, limitations, summary. One sentence headline and
one diagram or table per slide.

Drawing kit (tokens, chrome, node/arrow/table helpers): deck_kit.py.

    python build_deck.py      # -> Vault_PocketRAG_Deck.pptx
"""

import os

from pptx import Presentation
from pptx.util import Inches
from pptx.enum.text import PP_ALIGN
from pptx.enum.dml import MSO_LINE_DASH_STYLE

from deck_kit import (
    ACCENT, AMBER, BG, BODY, CW, DANGER, DIM, DISPLAY, FOOT_Y, INK, M, MONO,
    MUTED, PAGE_Y, PANEL, PANEL2, ROADMAP, RULE, RULE_SOFT, VOID,
    arr, chip, chip_w, chrome, hair, line, mix, new_slide, node, oval, paras,
    pill, rect, rrect, section_label, starfield, scrim, table, txt,
)

TEAL = "3DD6C0"
LAPTOP = "8F9BFF"


def callout(sl, x, y, w, h, label, body, color=ACCENT, size=10.5):
    """GZM / UHI 'the gap, stated precisely' box: tinted panel, left rule."""
    rrect(sl, x, y, w, h, fill=mix(BG, color, 0.07), line=mix(BG, color, 0.30),
          lw=0.7, radius=0.05)
    rect(sl, x, y, 0.045, h, fill=color)
    txt(sl, x + 0.24, y + 0.14, w - 0.4, 0.2, label, 7.5, color, True, spc=1.2,
        caps=True)
    txt(sl, x + 0.24, y + 0.40, w - 0.42, h - 0.5, body, size, INK, lh=1.22)


def lead_rows(sl, x, y, w, rows, gap=0.78, hsize=11, bsize=9.6):
    """UHI slide-2 rhythm: bold lead sentence, one plain sentence under it."""
    for i, (head, body) in enumerate(rows):
        yy = y + i * gap
        txt(sl, x, yy, w, 0.26, head, hsize, INK, True)
        txt(sl, x, yy + 0.28, w, gap - 0.3, body, bsize, BODY, lh=1.2)


def big_stats(sl, x, y, w, stats, vsize=30):
    n = len(stats)
    cw = w / n
    for i, (value, label, color) in enumerate(stats):
        cx = x + i * cw
        txt(sl, cx, y, cw - 0.2, 0.52, value, vsize, color, False, DISPLAY)
        txt(sl, cx, y + 0.56, cw - 0.3, 0.36, label, 7.5, MUTED, True, spc=0.9,
            caps=True, lh=1.1)


def chain(sl, x, y, w, stops, color=ACCENT):
    """GZM hero hop-chain: glowing dots joined by a line, labels underneath."""
    n = len(stops)
    step = w / (n - 1)
    line(sl, x, y, x + w, y, mix(BG, color, 0.5), 1.4)
    for i, (name, sub, c) in enumerate(stops):
        cx = x + i * step
        oval(sl, cx, y, 0.16, fill=mix(BG, c, 0.16))
        oval(sl, cx, y, 0.09, fill=mix(BG, c, 0.35))
        oval(sl, cx, y, 0.05, fill=c)
        txt(sl, cx - 0.9, y + 0.26, 1.8, 0.2, name, 8.5, INK, True,
            align=PP_ALIGN.CENTER, spc=1.0, caps=True)
        txt(sl, cx - 0.9, y + 0.48, 1.8, 0.2, sub, 7.8, MUTED,
            align=PP_ALIGN.CENTER)


# ================================================================== slides ==

def s_title(prs):
    sl = new_slide(prs)
    rect(sl, 0, 0, 13.333, 0.06, fill=ACCENT)
    starfield(sl, 7.3, 0.4, 5.8, 3.2, n=60, seed=3)
    txt(sl, M, 0.50, 7, 0.24, "On-device private RAG  /  Android · iQOO 15", 8.5,
        MUTED, True, spc=1.5, caps=True)
    txt(sl, M, 0.86, 7.5, 0.9, "VAULT", 48, INK, True, DISPLAY)
    txt(sl, M, 1.78, 7.5, 0.3, "Your documents stay on the phone. Your laptop "
        "gets a signed answer.", 14, ACCENT, True)

    callout(sl, M, 2.38, 6.55, 1.30, "Problem statement",
            "Answer questions about confidential documents from a laptop, "
            "without the documents, their index or the model ever leaving the "
            "phone, and prove which device produced each answer.", ACCENT, 11)

    # hero: the round trip
    rrect(sl, 7.55, 2.38, 5.13, 1.30, fill=PANEL, line=RULE_SOFT, lw=0.7,
          radius=0.05)
    txt(sl, 7.78, 2.50, 4.8, 0.2, "One round trip", 7.5, MUTED, True, spc=1.2,
        caps=True)
    chain(sl, 8.25, 2.95, 3.75, [("Laptop", "asks · verifies", LAPTOP),
                                 ("Clipboard", "sealed frames", AMBER),
                                 ("Phone", "retrieves · signs", ACCENT)])

    big_stats(sl, M, 4.20, CW, [
        ("0", "network permissions\nin the air-gap build", ACCENT),
        ("5", "chunks decrypted\nper question", INK),
        ("≈10.5", "tok/s on-device LLM\nSmolLM2-1.7B · GPU", INK),
        ("20 s", "capsule lifetime\non the clipboard", INK),
    ])

    hair(sl, M, 5.42, CW, RULE)
    cols = [
        ("Stack", ["Flutter app · Kotlin + C++ native channels",
                   "LiteRT + Qualcomm QNN HTP (MiniLM)",
                   "llama.cpp OpenCL · MediaPipe (one reasoner)",
                   "AndroidKeyStore / StrongBox · Python laptop tools"]),
        ("What runs where", ["NPU  ·  sentence embeddings",
                             "GPU  ·  the reasoning model",
                             "CPU  ·  tokenizer and vector ranking",
                             "StrongBox  ·  keys, decryption, signing"]),
        ("Project", ["vault_rag_test/  ·  phone app",
                     "bridge/  ·  vaultlink.py, verifier, eval set",
                     "SECURITY.md  ·  threat model",
                     "NPU_QNN.md  ·  NPU bring-up"]),
    ]
    for i, (head, rows) in enumerate(cols):
        x = M + i * 4.1
        section_label(sl, x, 5.60, head)
        paras(sl, x, 5.92, 3.9, 1.2, rows, 9.8, BODY, lh=1.3)
    return sl


def s_problem(prs):
    sl = new_slide(prs)
    chrome(sl, "01 — Problem understanding & motivation",
           "Private documents, public models, and nothing in between",
           "Every current way to ask questions of a confidential corpus puts "
           "the corpus somewhere it should not be.", "01")
    lead_rows(sl, M, 2.40, 6.2, [
        ("Cloud RAG uploads the corpus.",
         "The documents and their embeddings leave the device to answer a "
         "single question."),
        ("Laptop-local RAG trusts the busiest machine.",
         "The index sits next to browsers, plugins and IDE agents with broad "
         "file access."),
        ("The phone's silicon sits idle.",
         "A flagship SoC with an NPU, a GPU and a hardware keystore does "
         "nothing while the laptop works."),
        ("Answers cannot be attributed.",
         "Nothing tells the reader which machine produced an answer, or "
         "whether its quotes were edited."),
    ], gap=0.98)
    callout(sl, 7.25, 2.40, 5.43, 1.55, "The gap, stated precisely",
            "A laptop cannot use a private corpus it is not allowed to hold, "
            "and cannot verify where an answer came from.", DANGER, 11.5)
    section_label(sl, 7.25, 4.25, "What a solution has to guarantee")
    for i, g in enumerate(["The corpus, index and model never leave the phone",
                           "The heavy work runs on the phone's own silicon",
                           "Every answer is signed by the device that made it",
                           "No new network path is opened to do any of this"]):
        yy = 4.60 + i * 0.46
        oval(sl, 7.36, yy + 0.10, 0.055, fill=ACCENT)
        txt(sl, 7.56, yy, 5.1, 0.3, g, 10.5, INK)
    return sl


def s_existing(prs):
    sl = new_slide(prs)
    chrome(sl, "02 — Existing approaches & why they fail",
           "Every option assumes the data can sit somewhere else",
           "Each works for public data. For a confidential corpus, each breaks "
           "at exactly the assumption it makes.", "02")
    table(sl, M, 2.35, CW, [("Approach", 0.22), ("Assumes", 0.33),
                            ("Why it fails for private documents", 0.45)], [
        ("Cloud RAG / hosted assistants", "the provider may process the corpus",
         "confidential text leaves the device on every query"),
        ("Laptop-local RAG", "the laptop is a safe place for secrets",
         "index and model share a machine with browsers, plugins and agents"),
        ("Encrypted cloud vector store", "ciphertext at rest is enough",
         "queries and retrieved chunks are still decrypted server-side"),
        ("Phone-only assistant apps", "the phone is where the work happens",
         "no path to the laptop, and no way to verify an answer there"),
    ], row_h=0.56, cell_size=10, header_size=8)
    callout(sl, M, 5.05, 5.9, 1.45, "The solution gap",
            "Keep storage and inference where the data is safest. Move only a "
            "verifiable answer to where the work is.", ACCENT, 11.5)
    callout(sl, 6.78, 5.05, 5.9, 1.45, "Why a phone",
            "It already has an NPU, a GPU, a hardware keystore and a user who "
            "carries it. It only lacks the software.", TEAL, 11.5)
    return sl


def s_solution(prs):
    sl = new_slide(prs)
    chrome(sl, "03 — Proposed solution",
           "The phone becomes a private co-processor for the laptop",
           "Three responsibilities, each enforced by hardware or by the build, "
           "not by a promise.", "03")
    pillars = [
        ("Store", "measured",
         "Documents are chunked, embedded and encrypted on the phone. The key "
         "is generated in StrongBox and never exported.",
         "AES-256-GCM · AndroidKeyStore"),
        ("Answer", "measured",
         "A question is embedded, ranked in RAM, and only the top five chunks "
         "are decrypted for the one loaded reasoning model.",
         "MiniLM · SmolLM2 on GPU"),
        ("Prove", "measured",
         "The answer leaves as a signed JSON capsule over an encrypted "
         "clipboard link. The laptop checks the signature against a pinned key.",
         "ECDSA P-256 · VAULTLINK/2"),
    ]
    for i, (name, status, body, tech) in enumerate(pillars):
        x = M + i * 4.08
        rrect(sl, x, 2.30, 3.86, 2.55, fill=PANEL, line=mix(BG, ACCENT, 0.35),
              lw=0.8, radius=0.05)
        rect(sl, x, 2.30, 0.045, 2.55, fill=ACCENT)
        txt(sl, x + 0.28, 2.46, 3.3, 0.36, name.upper(), 15, INK, True, spc=1.5)
        chip(sl, x + 0.28, 2.92, status)
        txt(sl, x + 0.28, 3.28, 3.35, 1.1, body, 10.2, BODY, lh=1.25)
        txt(sl, x + 0.28, 4.42, 3.35, 0.24, tech, 9, ACCENT, True, spc=0.4)

    hair(sl, M, 5.15, CW, RULE)
    section_label(sl, M, 5.30, "Distinguishing choices")
    for i, (h, b) in enumerate([
            ("One reasoner at a time", "Loading one model unloads the other, "
             "so the model you loaded is the one that answers."),
            ("Plaintext for five chunks only", "Ranking runs on vectors; the "
             "text stays ciphertext unless a question needs it."),
            ("A clipboard, not a socket", "The air-gap APK has no network "
             "permission; Office Kit carries sealed frames.")]):
        x = M + i * 4.08
        txt(sl, x, 5.62, 3.86, 0.26, h, 10.5, INK, True)
        txt(sl, x, 5.90, 3.86, 0.7, b, 9.4, BODY, lh=1.22)
    return sl


def s_architecture(prs):
    sl = new_slide(prs)
    chrome(sl, "04 — Solution architecture",
           "Four layers, and the one capsule that crosses them",
           "Each layer can be replaced without the others noticing. The capsule "
           "is the only thing the laptop ever receives.", "04")
    layers = [
        ("L3", "LAPTOP TOOLS", "built", LAPTOP,
         "vaultlink.py pairs, asks and checks every capsule against the "
         "pinned phone key; scrubs the clipboard in 20 s."),
        ("L2", "VAULTLINK TRANSPORT", "verified", AMBER,
         "Sealed request and reply frames over Office Kit's clipboard mirror. "
         "Pairing code → keys, replay and clock checks."),
        ("L1", "VAULT ENGINE", "measured", ACCENT,
         "Chunk, embed, encrypted store, RAM ranking, decrypt top-5, one "
         "reasoner, capsule and signature."),
        ("L0", "SILICON & KEYS", "gap", TEAL,
         "NPU for MiniLM (QNN HTP, not yet confirmed), GPU for the LLM, CPU "
         "for ranking, StrongBox for keys."),
    ]
    for i, (ln, name, status, c, blurb) in enumerate(layers):
        yy = 2.32 + i * 1.02
        rrect(sl, M, yy, 7.15, 0.90, fill=PANEL, line=RULE_SOFT, lw=0.7,
              radius=0.05)
        rect(sl, M, yy, 0.05, 0.90, fill=c)
        txt(sl, M + 0.24, yy + 0.18, 0.6, 0.4, ln, 17, c, False, DISPLAY)
        txt(sl, M + 0.95, yy + 0.14, 3.0, 0.24, name, 10, INK, True, spc=1.0)
        chip(sl, M + 7.15 - chip_w(status) - 0.18, yy + 0.15, status)
        txt(sl, M + 0.95, yy + 0.42, 6.0, 0.46, blurb, 9.2, BODY, lh=1.18)

    x0 = 8.10
    rrect(sl, x0, 2.32, 4.58, 3.96, fill=PANEL, line=RULE_SOFT, lw=0.7,
          radius=0.05)  # same height as the four layers
    txt(sl, x0 + 0.26, 2.47, 4.1, 0.2, "The capsule · all the laptop receives",
        7.5, ACCENT, True, spc=1.1, caps=True)
    rrect(sl, x0 + 0.24, 2.80, 4.10, 2.02, fill=VOID, line=RULE_SOFT, lw=0.6,
          radius=0.04)
    paras(sl, x0 + 0.40, 2.93, 3.9, 2.35, [
        '{ "answer": "Base salary is USD 98,500",',
        '  "confidence": "high",',
        '  "key_facts": [{ "fact": …,',
        '     "verbatim": …, "verified": true }],',
        '  "context": [ 5 retrieved chunks ],',
        '  "generation": { "model": "smollm2-1.7b",',
        '     "backend": "llama.cpp/GPU" },',
        '  "provenance": { "enclave": "StrongBox",',
        '     "signature": "ECDSA-P256 …" } }',
    ], 8.6, BODY, MONO, lh=1.12)
    for i, (h, b) in enumerate([
            ("Checked before signing", "quoted facts must appear word for word in the chunks"),
            ("Checked on arrival", "signature must match the phone key pinned at enrollment")]):
        yy = 5.00 + i * 0.60
        rect(sl, x0 + 0.26, yy + 0.03, 0.04, 0.44, fill=ACCENT)
        txt(sl, x0 + 0.42, yy, 3.9, 0.24, h, 9.6, INK, True)
        txt(sl, x0 + 0.42, yy + 0.24, 3.9, 0.3, b, 8.8, BODY)
    return sl


def s_flow(prs):
    sl = new_slide(prs)
    chrome(sl, "05 — Architecture, end to end",
           "One question, seven stages, and the artefact each hands on",
           None, "05")
    steps = [
        ("1", "ASK", "laptop", "vaultlink.py seals the question with the pairing key",
         "sealed request", LAPTOP),
        ("2", "CARRY", "clipboard", "AES-256-GCM frame, replay + clock checks, no socket",
         "frame on the phone", AMBER),
        ("3", "EMBED", "NPU → CPU", "MiniLM turns the question into a vector",
         "384-dim vector", mix(ACCENT, TEAL, 0.0)),
        ("4", "RETRIEVE", "CPU + StrongBox", "cosine top-5 in RAM, decrypt only those five",
         "5 plaintext chunks", mix(ACCENT, TEAL, 0.33)),
        ("5", "REASON", "GPU", "one loaded model writes the answer (or the best chunk is quoted)",
         "JSON answer", mix(ACCENT, TEAL, 0.66)),
        ("6", "SIGN", "StrongBox", "facts checked verbatim, ECDSA P-256 over the capsule",
         "signed capsule", TEAL),
        ("7", "VERIFY", "laptop", "sealed reply back; wrong key → rejected; scrub in 20 s",
         "trusted answer", LAPTOP),
    ]
    X, W, H, G = M, 8.35, 0.54, 0.13
    y = 1.72
    for i, (n, title, where, detail, art, c) in enumerate(steps):
        rrect(sl, X, y, W, H, fill=mix(BG, c, 0.085), line=mix(BG, c, 0.42),
              lw=0.8, radius=0.05)
        txt(sl, X + 0.20, y + 0.09, 0.4, 0.34, n, 15, c, False, DISPLAY)
        txt(sl, X + 0.62, y + 0.07, 3.2, 0.22, title, 9.6, INK, True, spc=0.9)
        txt(sl, X + 1.72, y + 0.085, 2.2, 0.2, where.upper(), 7, MUTED, True,
            spc=0.9)
        txt(sl, X + 0.62, y + 0.29, 5.6, 0.22, detail, 8.8, BODY)
        txt(sl, X + W - 2.25, y + 0.17, 2.05, 0.22, art, 9, c, True,
            align=PP_ALIGN.RIGHT)
        if i < len(steps) - 1:
            arr(sl, X + W / 2, y + H + 0.005, X + W / 2, y + H + G - 0.005,
                DIM, 0.9)
        y += H + G

    # ingest side panel feeding stage 4
    x0 = 9.30
    rrect(sl, x0, 1.72, 3.38, 3.38, fill=PANEL, line=RULE_SOFT, lw=0.7,
          radius=0.05)
    txt(sl, x0 + 0.24, 1.86, 3.0, 0.2, "Ingest · once per file", 7.5, TEAL,
        True, spc=1.1, caps=True)
    ing = [("Pick", ".txt / .md on the phone"), ("Chunk", "split + tokenize"),
           ("Embed", "same MiniLM path"), ("Encrypt", "AES-GCM, key in Keystore"),
           ("Store", "SQLite + RAM index")]
    for i, (h, b) in enumerate(ing):
        yy = 2.24 + i * 0.54
        oval(sl, x0 + 0.34, yy + 0.12, 0.06, fill=TEAL if i < 4 else ACCENT)
        if i < len(ing) - 1:
            line(sl, x0 + 0.34, yy + 0.20, x0 + 0.34, yy + 0.58,
                 mix(BG, TEAL, 0.4), 0.9)
        txt(sl, x0 + 0.58, yy, 2.6, 0.22, h.upper(), 9, INK, True, spc=0.8)
        txt(sl, x0 + 0.58, yy + 0.22, 2.7, 0.22, b, 8.6, BODY)
    y4 = 1.72 + 3 * (H + G) + H / 2
    arr(sl, x0, y4, X + W + 0.04, y4, TEAL, 1.0, "index", TEAL, lw_box=0.9,
        loff=-0.22)

    rrect(sl, x0, 5.28, 3.38, 1.22, fill=PANEL, line=RULE_SOFT, lw=0.7,
          radius=0.05)
    txt(sl, x0 + 0.24, 5.40, 3.0, 0.2, "Trust zones", 7.5, MUTED, True, spc=1.1,
        caps=True)
    for i, (label, c) in enumerate([("Laptop · untrusted", LAPTOP),
                                    ("Clipboard · ciphertext only", AMBER),
                                    ("Phone · trusted core", ACCENT)]):
        yy = 5.70 + i * 0.25
        rect(sl, x0 + 0.26, yy + 0.04, 0.22, 0.13, fill=mix(BG, c, 0.3),
             line=c, lw=0.7)
        txt(sl, x0 + 0.60, yy, 2.6, 0.2, label, 8.8, BODY)
    return sl


def s_security(prs):
    sl = new_slide(prs)
    chrome(sl, "06 — Security by design",
           "Five layers, each one checkable",
           "Stated as what is enforced by hardware, by the protocol or by the "
           "build, with the limit of each.", "06")
    rows = [
        ("At rest", "AES-256-GCM per chunk; key generated in StrongBox, never exported",
         "a copied database or a stolen phone", "measured"),
        ("Attribution", "ECDSA P-256 over a canonical payload; laptop pins the device key",
         "forged or edited capsules", "measured"),
        ("In transit", "VAULTLINK/2: pairing code → HMAC keys, AES-GCM frames, replay window",
         "other apps reading or injecting queries", "verified"),
        ("Residue", "20 s compare-and-clear on the clipboard, phone and laptop",
         "answers lingering on the clipboard", "built"),
        ("Network", "air-gap flavor ships with no INTERNET permission (aapt2)",
         "the app itself sending data anywhere", "verified"),
    ]
    top = 2.35
    xs = [M, M + 1.55, M + 7.0, M + 10.25]
    for label, x in zip(["Layer", "Mechanism", "Stops", "Status"], xs):
        txt(sl, x, top, 2.5, 0.22, label, 8, MUTED, True, spc=1.0, caps=True)
    hair(sl, M, top + 0.30, CW, RULE)
    for i, (layer, mech, stops, status) in enumerate(rows):
        yy = top + 0.42 + i * 0.60
        rect(sl, M, yy + 0.02, 0.045, 0.42, fill=ACCENT if status != "built" else AMBER)
        txt(sl, M + 0.18, yy + 0.08, 1.3, 0.26, layer, 11, INK, True)
        txt(sl, xs[1], yy + 0.02, 5.25, 0.5, mech, 9.8, BODY, lh=1.18)
        txt(sl, xs[2], yy + 0.02, 3.1, 0.5, stops, 9.8, INK, lh=1.18)
        chip(sl, xs[3], yy + 0.10, status)
        if i < len(rows) - 1:
            hair(sl, M, yy + 0.56, CW, RULE_SOFT)
    callout(sl, M, 5.92, CW, 0.82, "Not stopped, stated plainly",
            "A rooted phone, a laptop compromised after verification, or the "
            "legacy VAULTLINK/1 mode when a user switches it on.", DANGER, 10.5)
    return sl


def s_stack(prs):
    sl = new_slide(prs)
    chrome(sl, "07 — Solution stack & feasibility",
           "Built, tested, and running on the target phone",
           "Every part below exists in the repository; the chip says how far "
           "each has been proven.", "07")
    stats = [("236", "Flutter tests passing", ACCENT),
             ("66", "Python tests passing", ACCENT),
             ("305", "nodes in the NPU-shaped MiniLM", INK),
             ("1.000", "cosine vs the original model", INK)]
    for i, (v, l, c) in enumerate(stats):
        x = M + i * 3.05
        txt(sl, x, 2.25, 2.9, 0.52, v, 30, c, False, DISPLAY)
        txt(sl, x, 2.82, 2.9, 0.22, l, 7.5, MUTED, True, spc=0.9, caps=True)
    cards = [
        ("Phone app", "measured", "Flutter + Dart UI, Kotlin channels, C++ JNI. "
         "Air-gap and LAN build flavors."),
        ("Encoder", "gap", "all-MiniLM-L6-v2 on LiteRT. QNN HTP → XNNPACK → CPU, "
         "accepted only after validation."),
        ("Reasoner", "measured", "SmolLM2-1.7B Q4_K_M on llama.cpp OpenCL, or "
         "Gemma on MediaPipe. One at a time."),
        ("Keys & crypto", "measured", "AndroidKeyStore with StrongBox: AES-256-GCM "
         "store, ECDSA P-256 signatures."),
        ("Link", "verified", "VAULTLINK/2 over the Office Kit clipboard. "
         "Cross-language test vectors."),
        ("Laptop", "built", "Python vaultlink.py and capsule verifier, DPAPI key "
         "storage, optional MCP bridge."),
    ]
    for i, (t, status, b) in enumerate(cards):
        x = M + (i % 3) * 4.08
        y = 3.35 + (i // 3) * 1.62
        rrect(sl, x, y, 3.86, 1.45, fill=PANEL, line=RULE_SOFT, lw=0.7,
              radius=0.05)
        txt(sl, x + 0.22, y + 0.16, 2.2, 0.26, t.upper(), 10, INK, True, spc=1.0)
        chip(sl, x + 3.86 - chip_w(status) - 0.18, y + 0.18, status)
        txt(sl, x + 0.22, y + 0.54, 3.45, 0.85, b, 9.6, BODY, lh=1.22)
    return sl


def s_outcomes(prs):
    sl = new_slide(prs)
    chrome(sl, "08 — Expected outcomes & evaluation",
           "What the phone measured, and what it taught us",
           "Numbers from VaultLink sessions on the iQOO 15 and from host "
           "tooling, labelled by source.", "08")
    table(sl, M, 2.30, 6.2, [("Metric", 0.36), ("Result", 0.44), ("Source", 0.20)], [
        ("Key location", "StrongBox for AES and ECDSA keys", "DEVICE"),
        ("Capsule signature", "valid ECDSA P-256, verified on laptop", "DEVICE"),
        ("Reasoning speed", "≈10.5 tok/s end to end, GPU", "DEVICE"),
        ("Retrieval latency", "≈2.0 s, dominated by StrongBox", "DEVICE"),
        ("Encoder latency", "113–137 ms per query, XNNPACK", "DEVICE"),
        ("NPU (QNN HTP)", "re-exported model, awaiting phone", "OPEN"),
        ("Network permissions", "none in the air-gap APK", "HOST"),
    ], row_h=0.46, cell_size=9.6, header_size=8,
        colors=[ACCENT, ACCENT, ACCENT, ACCENT, ACCENT, DANGER, TEAL])

    x0 = 7.25
    section_label(sl, x0, 2.30, "What the device taught us")
    txt(sl, x0, 2.60, 5.4, 0.5, "Failed answers were a retrieval problem, not "
        "a model problem.", 11.5, INK, True, lh=1.18)
    W = 5.43
    rect(sl, x0, 3.30, W * 0.63, 0.42, fill=mix(BG, ACCENT, 0.32))
    rect(sl, x0 + W * 0.63, 3.30, W * 0.37, 0.42, fill=mix(BG, DANGER, 0.38))
    txt(sl, x0, 3.40, W * 0.63, 0.22, "embedded · 254 tokens", 8.6, INK, True,
        align=PP_ALIGN.CENTER)
    txt(sl, x0 + W * 0.63, 3.40, W * 0.37, 0.22, "never seen · 35–38 %", 8.6,
        INK, True, align=PP_ALIGN.CENTER)
    txt(sl, x0, 3.82, W, 0.5, "Chunks were longer than the encoder's window, so "
        "facts in the last third could not be found.", 9.4, BODY, lh=1.2)
    section_label(sl, x0, 4.55, "Fixes, in order of impact")
    for i, (h, b, c) in enumerate([
            ("Token-aware chunks", "≤ 200 tokens with overlap, then re-index", ACCENT),
            ("Chunk key in TEE", "cut the StrongBox round trips from retrieval", ACCENT),
            ("Similarity gate removed", "a loaded model now answers every query", TEAL)]):
        yy = 4.88 + i * 0.52
        rect(sl, x0, yy + 0.02, 0.045, 0.40, fill=c)
        txt(sl, x0 + 0.18, yy, 2.2, 0.24, h, 10, INK, True)
        txt(sl, x0 + 2.35, yy + 0.02, 3.1, 0.4, b, 9.2, BODY, lh=1.15)
    return sl


def s_limits(prs):
    sl = new_slide(prs)
    chrome(sl, "09 — Limitations & future work",
           "Known limits, and the work that would resolve them",
           "Stated plainly, because a privacy tool that oversells itself is "
           "worse than none.", "09")
    lim = [
        ("NPU not yet confirmed.", "MiniLM runs on XNNPACK until the phone reports "
         "\"QNN HTP verified\"."),
        ("Retrieval misses long chunks.", "35–38 % of a chunk falls outside the "
         "encoder window."),
        ("Retrieval is slow.", "≈2 s per question, mostly StrongBox decryption."),
        ("Vectors are not encrypted.", "Embeddings sit in plaintext so ranking can "
         "run in RAM."),
        ("Legacy mode exists.", "VAULTLINK/1 is unauthenticated; off by default, "
         "one switch away."),
    ]
    fut = [
        ("Token-aware chunking", "re-index with ≤ 200-token chunks and measure recall"),
        ("Confirm the NPU", "QNN HTP verdict and pipeline benchmark on the phone"),
        ("Faster retrieval", "chunk key in TEE; signing key stays in StrongBox"),
        ("Encrypt embeddings", "decrypt into RAM on open, wipe on background"),
        ("Stronger pairing", "PAKE with a 6-digit compare; retire VAULTLINK/1"),
    ]
    for ci, (label, color, rows) in enumerate([("Current limitations", DANGER, lim),
                                               ("Future work · in priority order", ACCENT, fut)]):
        x = M + ci * 6.18
        rrect(sl, x, 2.30, 5.85, 4.30, fill=PANEL, line=RULE_SOFT, lw=0.7,
              radius=0.05)
        rect(sl, x, 2.30, 0.045, 4.30, fill=color)
        txt(sl, x + 0.28, 2.44, 5.3, 0.22, label, 8, color, True, spc=1.2,
            caps=True)
        for i, (h, b) in enumerate(rows):
            yy = 2.82 + i * 0.74
            if ci == 1:
                txt(sl, x + 0.28, yy, 0.5, 0.3, f"0{i + 1}", 12, ACCENT, False,
                    DISPLAY)
                tx = x + 0.80
            else:
                tx = x + 0.28
            txt(sl, tx, yy, 5.0, 0.26, h, 10.5, INK, True)
            txt(sl, tx, yy + 0.28, 5.0, 0.42, b, 9.3, BODY, lh=1.15)
    return sl


def s_summary(prs):
    sl = new_slide(prs)
    chrome(sl, "10 — One-shot summary", "Your documents stay on the phone.",
           None, "10", head_size=30)
    txt(sl, M, 1.30, CW, 0.6, "Your laptop gets a signed answer.", 30, ACCENT,
        False, DISPLAY)
    callout(sl, M, 2.35, 5.9, 1.25, "The gap",
            "Private corpora end up in the cloud or on the busiest laptop, and "
            "nobody can tell where an answer came from.", DANGER, 10.5)
    callout(sl, 6.78, 2.35, 5.9, 1.25, "The move",
            "Store, search and reason on the phone. Send only a signed capsule, "
            "over a sealed clipboard link.", ACCENT, 10.5)
    chain(sl, 1.4, 4.20, 10.5, [
        ("Ask", "laptop", LAPTOP), ("Sealed", "clipboard", AMBER),
        ("Retrieve", "NPU · CPU", ACCENT), ("Reason", "GPU", ACCENT),
        ("Sign", "StrongBox", TEAL), ("Verify", "laptop", LAPTOP)])
    hair(sl, M, 5.05, CW, RULE)
    section_label(sl, M, 5.20, "Proven on the phone", color=ACCENT)
    txt(sl, M, 5.50, 5.9, 1.1, "StrongBox keys, signed capsules verified on the "
        "laptop, SmolLM2 on the GPU at ≈10.5 tok/s, sealed round trips over the "
        "clipboard, an APK with no network permission.", 10, BODY, lh=1.25)
    section_label(sl, 6.78, 5.20, "Not yet proven", color=AMBER)
    txt(sl, 6.78, 5.50, 5.9, 1.1, "MiniLM on the Hexagon NPU, retrieval recall "
        "after token-aware chunking, and VAULTLINK/2 enrollment on the phone.",
        10, BODY, lh=1.25)
    return sl


SLIDES = (s_title, s_problem, s_existing, s_solution, s_architecture, s_flow,
          s_security, s_stack, s_outcomes, s_limits, s_summary)


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
