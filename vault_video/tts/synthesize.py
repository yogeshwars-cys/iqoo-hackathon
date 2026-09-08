"""
Generate the voiceover with Piper, one WAV per narration line.

Why per line rather than one long file: the caption timings in src/script.ts
are authoritative, and Remotion places each clip at its own frame offset. That
makes drift structurally impossible — there is no long take that can slowly
slide out of sync with the captions.

It also lets us AUTO-FIT. Each line has a duration budget `d`. If Piper's
natural read overruns it, the line is re-synthesised slightly faster so it
still lands inside its caption window. Underruns are left alone: a pause
before the next line is fine, a caption disappearing mid-sentence is not.

Engine:  piper-tts (OHF-Voice/piper1-gpl), CPU, no network at synthesis time.
Voice:   en_US-ryan-high — warm, measured, documentary register.

    python tts/synthesize.py
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT_TS = ROOT / "src" / "script.ts"
OUT_DIR = ROOT / "public" / "vo"
PY = sys.executable

MODEL = Path("D:/modelprep/voices/en_US-ryan-high.onnx")

SCENE_SECONDS = 60.0
# Piper's length_scale: >1 slower, <1 faster. 1.06 reads a touch under the
# default pace, which suits the documentary direction in script/narration.md.
BASE_LENGTH_SCALE = 1.06
MIN_LENGTH_SCALE = 0.80

SCENE_RE = re.compile(
    r"id: '([^']+)',\s*\n\s*chapter: '([^']+)',\s*\n\s*title: '([^']+)',\s*\n\s*lines: \[([\s\S]*?)\n\s*\],"
)
LINE_RE = re.compile(
    r"""\{t: ([\d.]+), d: ([\d.]+), text: (?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")\}"""
)


def parse_script() -> list[dict]:
    src = SCRIPT_TS.read_text(encoding="utf-8")
    scenes = []
    for sid, chapter, title, body in SCENE_RE.findall(src):
        lines = []
        for t, d, a, b in LINE_RE.findall(body):
            text = (a or b).replace("\\'", "'").replace('\\"', '"')
            # Em dashes read as an audible stumble; a comma gives the same beat.
            spoken = text.replace("—", ",").replace("’", "'")
            lines.append({"t": float(t), "d": float(d), "text": text, "spoken": spoken})
        scenes.append({"id": sid, "chapter": chapter, "title": title, "lines": lines})
    return scenes


def synth(text: str, out: Path, length_scale: float) -> float:
    """Render one line, return its duration in seconds."""
    cmd = [
        PY, "-m", "piper",
        "--model", str(MODEL),
        "--output-file", str(out),
        "--length-scale", f"{length_scale:.4f}",
    ]
    proc = subprocess.run(
        cmd, input=text.encode("utf-8"), capture_output=True, check=False
    )
    if proc.returncode != 0 or not out.exists():
        raise RuntimeError(
            f"piper failed ({proc.returncode}): {proc.stderr.decode(errors='replace')[-600:]}"
        )
    with wave.open(str(out), "rb") as w:
        return w.getnframes() / float(w.getframerate())


def main() -> int:
    if not MODEL.exists():
        print(f"Voice model missing: {MODEL}", file=sys.stderr)
        return 1

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    scenes = parse_script()
    manifest: list[dict] = []
    refitted = 0
    overruns: list[str] = []

    for si, scene in enumerate(scenes):
        print(f"\n=== Scene {si + 1}: {scene['title']} ===")
        for li, line in enumerate(scene["lines"]):
            name = f"{si + 1:02d}-{scene['id']}-{li:02d}.wav"
            path = OUT_DIR / name

            scale = BASE_LENGTH_SCALE
            dur = synth(line["spoken"], path, scale)

            # Auto-fit: one corrective pass, never below MIN_LENGTH_SCALE.
            if dur > line["d"]:
                target = scale * (line["d"] / dur) * 0.97
                scale = max(target, MIN_LENGTH_SCALE)
                dur = synth(line["spoken"], path, scale)
                refitted += 1

            fits = dur <= line["d"] + 0.05
            if not fits:
                overruns.append(
                    f"  scene {si + 1} line {li}: {dur:.2f}s vs {line['d']:.2f}s budget "
                    f"— \"{line['text'][:56]}...\""
                )

            manifest.append({
                "scene": si,
                "index": li,
                "file": name,
                "t": line["t"],
                "budget": line["d"],
                "duration": round(dur, 3),
                "lengthScale": round(scale, 4),
            })
            flag = "  " if fits else "!!"
            print(f"{flag} [{li:02d}] {dur:5.2f}s / {line['d']:4.1f}s  x{scale:.2f}  {name}")

    # Written into src/ (not public/) so Remotion can import it at build time
    # and place every clip without a runtime fetch.
    (ROOT / "src" / "voManifest.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )

    total = max(
        m["scene"] * SCENE_SECONDS + m["t"] + m["duration"] for m in manifest
    )
    print(f"\n{len(manifest)} clips → {OUT_DIR}")
    print(f"speech ends at {total:.1f}s of {len(scenes) * SCENE_SECONDS:.0f}s")
    print(f"auto-refitted to budget: {refitted}")
    if overruns:
        print(f"\nSTILL OVER BUDGET ({len(overruns)}) — widen `d` in src/script.ts:")
        print("\n".join(overruns))
    else:
        print("every line fits inside its caption window")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
