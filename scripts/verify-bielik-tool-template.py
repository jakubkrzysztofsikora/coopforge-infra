#!/usr/bin/env python3
"""Check that the test tier serves Bielik with its native tool-call format.

Ollama only parses tool calls when the model's own chat template exposes the
tool-call tag: `parseTag` in ollama/tools/template.go looks for a `.ToolCalls`
node in the template and takes the first text inside it as the tag to watch for
in the output. A template without that node falls back to JSON mode, so the
the tool-call tag block Bielik was trained to emit is returned to the caller as
plain text and no `tool_calls` ever appear in the response.

The tag and the JSON envelope come from the model itself, not from this repo:
speakleash/bielik-tools ships the same format in its advanced chat template,
and the model emits it even when the system prompt asks for something else.

Run it when the test tier's serving template, model tag or route changes:

    python3 scripts/verify-bielik-tool-template.py
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
TIER = ROOT / "test-tier"
MODFILE = TIER / "bielik-tools.Modfile"
LITELLM_CONFIG = TIER / "litellm-config.yaml"
BOOTSTRAP = TIER / "test-tier-bootstrap.sh"

GATEWAY_URL_DEFAULT = "http://127.0.0.1:4000"

TOOL = {
    "type": "function",
    "function": {
        "name": "run_command",
        "description": "Run a shell command and return its output.",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "The command to run."}
            },
            "required": ["command"],
        },
    },
}
SYSTEM_PROMPT = (
    "You are a coding agent. When an action is needed, call the "
    "run_command tool with {\"command\": string}. Check the python "
    "version now."
)

# The tag Bielik v3.0 was trained to emit, and the one speakleash/bielik-tools
# uses in its advanced chat template.
OPEN_TAG = "<tool_call>"
CLOSE_TAG = "</tool_call>"

# The upstream system instruction (speakleash/bielik-tools advanced template).
# The model is trained against this wording, so the template must keep it.
TOOL_SIGNATURE_PROMPT = "You are provided with tool signatures that you can use to assist"

failed: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name}{': ' + detail if detail else ''}")
        failed.append(name)


def modfile_template(text: str) -> str:
    """Extract the TEMPLATE block of an Ollama Modfile."""
    match = re.search(r'TEMPLATE\s+"""(.*?)"""', text, re.DOTALL)
    return match.group(1) if match else ""


def model_name() -> str:
    """Read the Bielik model name from the LiteLLM config."""
    match = re.search(r'^\s*-\s*model_name:\s*"?([^"\s]+)"?', LITELLM_CONFIG.read_text(encoding="utf-8"), re.M)
    if not match:
        check("litellm config names the bielik route", False, f"no model_name entry in {LITELLM_CONFIG}")
        return "bielik-minitron-7b"
    return match.group(1)


def post(gateway_url: str, api_key: str | None, body: dict) -> dict | None:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(
        f"{gateway_url.rstrip('/')}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            return json.loads(resp.read().decode())
    except Exception as exc:  # noqa: BLE001
        check("live gateway request", False, str(exc))
        return None


def message(payload: dict | None) -> dict:
    if payload is None:
        return {}
    return payload["choices"][0]["message"]


def structured_call(msg: dict, leak_check: bool = True) -> tuple[bool, str]:
    calls = msg.get("tool_calls") or []
    if not calls:
        return False, "no structured tool_calls in the response"
    if calls[0]["function"]["name"] != "run_command":
        return False, f"wrong tool called: {calls[0]['function']['name']}"
    if leak_check and ("<tool_call>" in (msg.get("content") or "") or "<name>" in (msg.get("content") or "")):
        return False, "raw tool tag leaked into content"
    return True, ""


def live_check(gateway_url: str, api_key: str | None) -> None:
    """Send tool requests through the gateway; the responses must be structured."""
    model = model_name()

    # Probe 3: multi-turn — a user turn after a tool result must be answered in
    # prose with no further tool call (reminder still renders, $lastRole=user).
    # Probe 4: tool-result-final — the exact agent-loop shape the reminder skip
    # exists for: no reminder must render and the model must summarise.
    probes = [
        (
            "agent system prompt yields structured tool_calls",
            {
                "model": model,
                "temperature": 0.1,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": "Check the python version."},
                ],
                "tools": [TOOL],
                "tool_choice": "auto",
            },
            "tool_call",
        ),
        (
            "bare user turn (no system prompt) yields structured tool_calls",
            {
                "model": model,
                "temperature": 0.1,
                "messages": [{"role": "user", "content": "Check the python version."}],
                "tools": [TOOL],
                "tool_choice": "auto",
            },
            "tool_call",
        ),
        (
            "after a tool result the model answers in prose",
            {
                "model": model,
                "temperature": 0.1,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": "Check the python version."},
                    {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [
                            {
                                "id": "call_1",
                                "type": "function",
                                "function": {
                                    "name": "run_command",
                                    "arguments": json.dumps({"command": "python --version"}),
                                },
                            }
                        ],
                    },
                    {"role": "tool", "tool_call_id": "call_1", "content": "Python 3.14.0"},
                    {"role": "user", "content": "Report the version you found."},
                ],
                "tools": [TOOL],
                "tool_choice": "auto",
            },
            "prose",
        ),
        (
            "tool-result-final turn answers in prose without another call",
            {
                "model": model,
                "temperature": 0.1,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": "Check the python version."},
                    {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [
                            {
                                "id": "call_2",
                                "type": "function",
                                "function": {
                                    "name": "run_command",
                                    "arguments": json.dumps({"command": "python --version"}),
                                },
                            }
                        ],
                    },
                    {"role": "tool", "tool_call_id": "call_2", "content": "Python 3.14.0"},
                ],
                "tools": [TOOL],
                "tool_choice": "auto",
            },
            "prose",
        ),
    ]

    for name, body, kind in probes:
        payload = post(gateway_url, api_key, body)
        msg = message(payload)
        if kind == "prose":
            prose = (msg.get("content") or "").strip()
            wants = bool(prose) and "3.14" in prose and not (msg.get("tool_calls") or [])
            check(name, wants, "empty/unsummarised prose or another tool call fired" if not wants else "")
            if wants:
                print(f"      prose: {prose[:80]}")
        else:
            ok, detail = structured_call(msg)
            check(name, ok, detail)
            if ok:
                call = msg["tool_calls"][0]["function"]
                print(f"      tool: {call['name']}  args: {call['arguments']}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--live",
        action="store_true",
        help="additionally send a tool request through the gateway and require tool_calls",
    )
    ap.add_argument(
        "--gateway-url",
        default=GATEWAY_URL_DEFAULT,
        help=f"gateway base URL for --live (default {GATEWAY_URL_DEFAULT})",
    )
    ap.add_argument(
        "--api-key",
        default=os.environ.get("LITELLM_MASTER_KEY"),
        help="gateway bearer key for --live (default $LITELLM_MASTER_KEY)",
    )
    args = ap.parse_args()

    if not MODFILE.exists():
        check("modfile exists", False, f"{MODFILE} is missing")
        return 1

    modfile = MODFILE.read_text(encoding="utf-8")
    template = modfile_template(modfile)

    check("modfile has a template", bool(template), "no TEMPLATE block")
    check(
        "template exposes .ToolCalls",
        ".ToolCalls" in template,
        "ollama cannot detect the tool-call tag without a .ToolCalls node",
    )
    check(
        "template carries the native tool-call tag",
        OPEN_TAG in template and CLOSE_TAG in template,
        f"expected {OPEN_TAG!r} in the template",
    )
    check(
        "tool-call tag is the first text in the .ToolCalls branch",
        re.search(
            r"\{\{ if \.ToolCalls \}\}\s*(?:\{\{ range \.ToolCalls \}\})?\s*" + re.escape(OPEN_TAG),
            template,
        )
        is not None,
        "ollama takes the first text of that branch as the tag and stops at the first action",
    )
    check(
        "template renders the native tool-call envelope",
        '"name":' in template and '"arguments":' in template,
        "tool calls must be rendered as {\"name\": ..., \"arguments\": {...}}",
    )
    check(
        "template renders tool results as tool turns",
        "<|im_start|>tool" in template,
        "tool results must come back as <|im_start|>tool turns",
    )
    check(
        "template keeps the upstream tool instruction",
        TOOL_SIGNATURE_PROMPT in template,
        "the model is trained against the upstream wording",
    )
    check(
        "modfile builds on the pulled model",
        re.search(r"^FROM\s+\S+", modfile, re.MULTILINE) is not None,
        "no FROM line",
    )

    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    tools_tag = re.search(r"TOOLS_MODEL_TAG=\$\{TOOLS_MODEL_TAG:-([^}]+)\}", bootstrap)
    check("bootstrap defines a tool-aware model tag", tools_tag is not None)
    check(
        "bootstrap creates the tool-aware model",
        "bielik-tools.Modfile" in bootstrap and "ollama create" in bootstrap,
        "the tool-aware model is never created",
    )

    config = LITELLM_CONFIG.read_text(encoding="utf-8")
    route = re.search(r'model:\s*"openai/([^"]+)"', config)
    check("litellm route names a model", route is not None)
    if route and tools_tag:
        check(
            "litellm route serves the tool-aware model",
            route.group(1) == tools_tag.group(1),
            f"route is {route.group(1)!r}, expected {tools_tag.group(1)!r}",
        )

    if args.live:
        live_check(args.gateway_url, args.api_key)

    if failed:
        print(f"\n{len(failed)} check(s) failed")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
