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

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TIER = ROOT / "test-tier"
MODFILE = TIER / "bielik-tools.Modfile"
LITELLM_CONFIG = TIER / "litellm-config.yaml"
BOOTSTRAP = TIER / "test-tier-bootstrap.sh"

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


def main() -> int:
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

    if failed:
        print(f"\n{len(failed)} check(s) failed")
        return 1
    print("\nALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
