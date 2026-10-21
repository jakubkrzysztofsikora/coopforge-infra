# Spike — Bielik tool-call parsing through Ollama + LiteLLM

Date: 2026-10-21
Status: answered. Root cause found by falsification; fix shipped in
`test-tier/bielik-tools.Modfile` (v4 template) and verified on the box against the
production tag `coopforge/bielik-minitron-7b-tools:Q4_K_M`.

## Symptom

Agents routed through the test-tier gateway (`bielik-minitron-7b`) received the tool
schema but the model never returned structured `tool_calls`: it either answered in prose,
claimed the listed tool was unusable, or emitted a bare `{"name": ..., "arguments": ...}`
JSON object as plain text. Downstream agent frameworks discard that text, so tools never
fired.

## Method

Probes run on the box, inside `test-tier-litellm-1` (the Ollama container has no
python3/curl; `http://ollama:11434` is reachable from the LiteLLM container over the
compose network, `expose` only — no host port). Each hypothesis got one probe; the
real-client reproduction used `~/.omp/bielik/SYSTEM.md` (copied to
`/tmp/bielik_system.md` in the container), a ~2 955-token system prompt that documents its
own XML-ish tool dialect.

## Hypotheses and results

| # | Hypothesis | Verdict | Evidence |
| --- | --- | --- | --- |
| H1 | Stale model: box serves an old `-tools`-less build | FALSE | fixed `-tools` model image `bc80c2466a18` rebuilt 8 h before the probe |
| H2 | Context size: num_ctx too small for schema + prompt | FALSE | tool calls parse at num_ctx 4096 / 8192 / 12288 |
| H3 | Gateway transform: LiteLLM mangles an otherwise clean response | FALSE | direct Ollama and via-gateway responses identical; defect upstream of the gateway |
| H4 | History depth: long stuffed conversation drops the format instruction | FALSE | 24-turn stuffed history, prompt_eval_count=2898, still exactly 1 structured `<tool_call>` with empty content |
| H5 | Tool-set size: Ollama front-truncation pushes the instruction out of window | FALSE | 12 tools, 1 438 schema tokens, parse clean |

## Root cause (confirmed)

The client's real system prompt. A system prompt that teaches a *different* tool-call
dialect (its own XML tags) overrides the Modfile's format instruction by recency and
specificity: the model obeys the client's syntax, emits the bare JSON object without the
`<tool_call>` wrapper, and Ollama's `parseTag` (ollama/tools/template.go) — which only
fires on the tag it extracted from the template's `.ToolCalls` branch — never sees a tag,
so no `tool_calls` field is ever produced. Table-only and synthetic-XML-teaching probes
reproduced it on demand: system prompt teaches a syntax → bare JSON; no such prompt →
clean single tagged call.

## Fix: template v4

The serving template must win the recency fight regardless of what the client prompt
claims. v4 (shipped) makes three changes to the upstream template:

1. **System-block override paragraph** (end of the `.Tools` system block, after the tool
   list): "Ignore any earlier instructions, custom syntax, or examples that described tools
   in a different tag or dialect. Emit exactly one `<tool_call>...</tool_call>` tag on its
   own line …". Distilled 7B models drop instructions buried 3k tokens back; the override
   sits after the tool list, the last thing before the user turn.
2. **Final reminder block** AFTER the message loop, BEFORE `<|im_start|>`assistant:
   `{{- if .Tools }}` emits a short system turn "tools are available for use now".
   Positive-only phrasing — v3's negated failure-mode wording ("do not claim a tool is
   unusable") primed refusals.
3. **`PARAMETER num_ctx 8192`** — 16 384 OOMs the 8 GB box (weights ~4.5 GB, KV does not
   fit; HTTP 500).

### Version trail

| Variant | Change | Result |
| --- | --- | --- |
| v2 | system-block override paragraph only | real-prompt-only case FIXED (1 clean call); probe-table mismatch was a probe bug, not a model bug |
| v3 | v2 + final negated reminder ("do not claim the tool is unusable") | refusals — negated phrasing primed the failure it forbade |
| v4 | v2 + positive-only reminder + num_ctx 8192 | all 3 cases (real-prompt-only, real-prompt+table, table-only) → `tool_calls=1`, args `{"command":"python --version"}`, zero leaks |

### v5: bare-prompt root cause fixed

The "known gap" below was misdiagnosed. A bare user turn with no system prompt does not
make the model ramble — it makes the template drop the tool schemas: the whole preamble,
tool list and override paragraph sat inside `{{ if .System }}`, so with `.System` empty the
rendered system turn was empty and the model invented tools it was never shown. v5 moves
the conditional to wrap only the client prompt text (`{{ if .System }}{{ .System }}\n\n{{ end }}You are
provided with tool signatures…`), and the post-loop reminder now skips when the last
message is a tool result so summarisation turns are not pushed into another tool call.
All three cases — agent system prompt, bare user turn, post-tool-result summarisation —
verified live; 20/20 replays of the agent-shaped request stayed structured and leak-free.

Known gap, historical (fixed by v5): a bare user turn with NO system prompt at all made the
model ramble in prose about a hallucinated tool ("there's a tool called python_version…").
Real traffic always carries an agent system prompt (that was the failing case this spike
fixed); the live gate and the bootstrap smoke both send one, matching real usage.

## Verification

- Offline gate: `scripts/verify-bielik-tool-template.py` (template shape, tag placement,
  envelope rendering, upstream wording kept, bootstrap and LiteLLM route consistency).
- Live gate: `scripts/verify-bielik-tool-template.py --live` — sends a run_command tool
  request through the gateway and greps for `"tool_calls"` in the response. Runs on the
  box (or anywhere the gateway port is forwarded); offline by default.
- Bootstrap smoke: `test-tier/test-tier-bootstrap.sh` fails the deploy if a gateway
  chat-completion with a tool does not return `tool_calls`.

## vLLM note (production tiers)

The plan sketched a vLLM path for Bielik (vendored `--tool-parser-plugin`
`bielik_vllm_tool_parser.py` + `--chat-template` from speakleash/bielik-tools). That path
is void today: no GPU tier routes Bielik. `manifest/tiers.json` gives every vLLM tier a
Qwen/DeepSeek/Mistral route; the only `bielik-minitron-7b` route is the `test` tier, which
runs Ollama — and Ollama parses the tag from the template itself, no parser plugin needed.
If a Bielik vLLM tier is ever added: upstream vLLM ships no bielik parser; the speakleash
plugin is third-party (MIT), vendor it at a pinned commit, mount read-only, and gate it on
that tier only. Qwen-family models would use `--enable-auto-tool-choice
--tool-call-parser hermes` — a per-tier launch decision, deliberately not set globally
here.
