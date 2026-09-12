"""
iQOO Phone MCP Server.

Exposes the phone's on-device vector index to an MCP client (Claude Code,
Claude Desktop, an IDE agent) through the local bridge.

The useful property: proprietary source never leaves the laptop-plus-phone
pair. `iqoo_index_code` pushes a file to the device, it is embedded there,
and the vectors stay there. A later `iqoo_query_agent` returns only the
chunks that matched.

Register with Claude Code:

    claude mcp add iqoo-phone -- python /absolute/path/to/iqoo_mcp_server.py

Requires bridge_server.py to be running and a phone linked to it.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Dict

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("iqoo-phone")

BRIDGE_URL = "http://127.0.0.1:8000"


def _get(path: str, timeout: float = 5.0) -> Dict[str, Any]:
    request = urllib.request.Request(f"{BRIDGE_URL}{path}")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def _post(path: str, payload: Dict[str, Any], timeout: float) -> Dict[str, Any]:
    request = urllib.request.Request(
        f"{BRIDGE_URL}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def _bridge_down(exc: Exception) -> str:
    return (
        f"Cannot reach the bridge at {BRIDGE_URL} ({exc}).\n"
        "Start it with: python bridge_server.py"
    )


@mcp.tool()
def iqoo_get_status() -> str:
    """Check whether the iQOO phone is linked to the local AI bridge."""
    try:
        data = _get("/api/status")
    except Exception as exc:  # noqa: BLE001
        return _bridge_down(exc)

    connected = data.get("phone_connected", False)
    info = data.get("phone_device_info", {}) or {}
    device = (info.get("compute", {}) or {}).get("device", {}) or {}

    lines = [
        "=== iQOO Neural Co-Processor ===",
        f"Bridge:  ONLINE ({BRIDGE_URL})",
        f"Phone:   {'LINKED' if connected else 'not connected'}",
    ]
    if not connected:
        lines.append("")
        lines.append("Open the Vault Co-Processor app on the phone, go to the")
        lines.append("Bridge tab, and connect to one of these addresses:")
        for address in data.get("bridge_addresses", []):
            lines.append(f"    {address}:8000")
        return "\n".join(lines)

    model = " ".join(
        str(v) for v in (device.get("manufacturer"), device.get("model")) if v
    )
    soc = device.get("soc_model")
    llm = info.get("llm", {}) or {}
    reasoner = (
        f"{llm.get('model')} on {str(llm.get('backend', '?')).upper()}"
        if llm.get("state") == "ready"
        else f"not loaded ({llm.get('state', 'unknown')}) - capsules will be "
             f"retrieval-only"
    )
    lines += [
        f"Device:  {model or 'unknown'}" + (f" ({soc})" if soc else ""),
        f"Encoder: MiniLM-L6-v2, {info.get('backend', 'unknown')} delegate, "
        f"{info.get('embedding_dim', '?')}-dim",
        f"Reason:  {reasoner}",
        f"Corpus:  {info.get('total_indexed', 0)} chunks indexed on-device",
        f"Served:  {info.get('served_queries', 0)} queries, "
        f"{info.get('served_indexes', 0)} documents",
    ]
    return "\n".join(lines)


@mcp.tool()
def iqoo_get_telemetry() -> str:
    """Read live CPU / GPU / NPU utilisation from the linked iQOO phone.

    Each reading is tagged with how it was obtained. "measured" is a real
    kernel busy counter; "proxy" is derived from clock frequency and is a
    hint rather than a utilisation figure; "unavailable" means the device
    exposes no counter for that engine — which is the normal answer for the
    NPU on production Android, since the fastrpc statistics require root.
    """
    try:
        data = _get("/api/telemetry")
    except Exception as exc:  # noqa: BLE001
        return _bridge_down(exc)

    if "error" in data:
        return data["error"]

    compute = data.get("compute", {}) or {}

    def lane(label: str, value_key: str, kind_key: str) -> str:
        value = compute.get(value_key)
        kind = compute.get(kind_key, "unknown")
        if value is None:
            return f"  {label:<10} unavailable ({kind})"
        return f"  {label:<10} {value:5.1f} %   [{kind}]"

    thermal = compute.get("thermal") or {}
    lines = [
        "=== On-device compute ===",
        lane("CPU", "cpu_percent", "cpu_kind"),
        lane("GPU", "gpu_percent", "gpu_kind"),
        lane("NPU", "npu_percent", "npu_kind"),
        f"  {'Inference':<10} "
        f"{compute.get('inference_duty_percent') or 0:5.1f} %   [derived]",
        "",
        f"  CPU clock: {compute.get('cpu_clock_mhz') or '—'} MHz",
        f"  GPU clock: {compute.get('gpu_clock_mhz') or '—'} MHz",
        f"  RSS:       {compute.get('rss_mb') or '—'} MB",
    ]
    if thermal:
        state = thermal.get("label", "unknown")
        note = " — clocks are being limited, benchmarks will read low" \
            if thermal.get("throttling") else ""
        lines.append(f"  Thermal:   {state}{note}")
    lines.append(f"\n  Corpus: {data.get('total_indexed', 0)} chunks")
    return "\n".join(lines)


@mcp.tool()
def iqoo_query_agent(prompt: str, top_k: int = 3) -> str:
    """Search the phone's private on-device vector index.

    The phone embeds the query locally and returns only the matching chunks.
    `direct_answer`, when present, is a line quoted verbatim from the indexed
    source — the device holds an encoder, not a language model, so nothing
    in the reply is generated text.
    """
    try:
        data = _post("/api/query", {"query": prompt, "top_k": top_k},
                     timeout=30.0)
    except urllib.error.HTTPError as exc:
        return f"Query failed ({exc.code}): {exc.read().decode('utf-8')}"
    except Exception as exc:  # noqa: BLE001
        return _bridge_down(exc)

    if "error" in data:
        return data["error"]

    results = data.get("results", [])
    output = [
        "--- iQOO on-device retrieval ---",
        f"On-device: {data.get('latency_ms', '?')} ms "
        f"(encoder {data.get('embed_ms', '?')} ms) | "
        f"roundtrip: {data.get('roundtrip_latency_ms', '?')} ms",
        f"Searched {data.get('total_indexed', '?')} private chunks",
    ]

    answer = data.get("direct_answer")
    if answer:
        meta = data.get("direct_answer_meta", {}) or {}
        output += [
            "",
            "EXTRACTED ANSWER (quoted verbatim, not generated):",
            f"  {answer}",
            f"  — {meta.get('file', '?')}, chunk line "
            f"{meta.get('line_in_chunk', '?')}",
        ]

    output.append("")
    for index, result in enumerate(results, 1):
        output.append(
            f"[{index}] {result.get('file')} "
            f"(cosine {result.get('similarity')})"
        )
        output.append(f"{result.get('content')}\n")
    return "\n".join(output)


@mcp.tool()
def iqoo_ask_capsule(question: str, top_k: int = 5,
                     generate: bool = True) -> str:
    """Ask the phone a question and get a structured context capsule.

    Two models run on the device: MiniLM finds the relevant chunks, then
    Gemma 2B reads only those chunks and writes them up as fixed-schema
    JSON. Nothing outside the retrieved context reaches the reasoning model.

    Every entry in key_facts carries the exact span it came from, checked
    against the retrieved text — `verified: false` means the model produced
    a quote that does not occur in the source, which is the signal to
    distrust that fact specifically.

    If no reasoning model is loaded the capsule still comes back, with the
    answer quoted verbatim from the corpus instead of written. Set
    generate=False to skip generation deliberately and get the fast path.
    """
    try:
        data = _post(
            "/api/ask",
            {"query": question, "top_k": top_k, "generate": generate},
            timeout=310.0,
        )
    except urllib.error.HTTPError as exc:
        return f"Ask failed ({exc.code}): {exc.read().decode('utf-8')}"
    except Exception as exc:  # noqa: BLE001
        return _bridge_down(exc)

    if "error" in data:
        return data["error"]

    # Returned as JSON rather than prose: the caller is a model that will
    # reason over it, and a capsule's whole value is being addressable.
    # Context is stripped - it is already in `sources` by filename, and a
    # full chunk dump would swamp the reply.
    trimmed = {k: v for k, v in data.items() if k != "context"}
    return json.dumps(trimmed, indent=2, ensure_ascii=False)


@mcp.tool()
def iqoo_index_code(filename: str, content: str) -> str:
    """Push a document to the phone and embed it into the on-device index.

    The text is embedded on the device; the vectors never come back. Use this
    for material that should not be sent to a cloud model.
    """
    try:
        data = _post(
            "/api/index",
            {"filename": filename, "content": content},
            timeout=200.0,
        )
    except urllib.error.HTTPError as exc:
        return f"Index failed ({exc.code}): {exc.read().decode('utf-8')}"
    except Exception as exc:  # noqa: BLE001
        return _bridge_down(exc)

    if "error" in data:
        return data["error"]

    return (
        f"Indexed {filename} on the phone: +{data.get('chunks_added', '?')} "
        f"chunks in {data.get('elapsed_ms', '?')} ms "
        f"({data.get('ms_per_chunk', '?')} ms/chunk). "
        f"Vault now holds {data.get('total_indexed', '?')} chunks."
    )


if __name__ == "__main__":
    mcp.run()
