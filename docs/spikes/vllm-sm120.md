# Spike — does the pinned vLLM image run on sm_120 (RTX PRO 4000 / RTX PRO 6000 Blackwell)?

Date: 2026-10-18
Status: answered. The pin **stands** — `vllm/vllm-openai:v0.31.0` ships sm_120 kernels.
Two host-side requirements and two open upstream defects come with it. Live engine startup is
still unverified (no Hetzner credentials, ruling R3).

## Verdict

| Question | Answer |
| --- | --- |
| Does `vllm/vllm-openai:v0.31.0` build for sm_120? | Yes. `TORCH_CUDA_ARCH_LIST` in the image config includes `12.0` |
| Is sm_120 the right target for both Hetzner GPUs? | Yes. RTX PRO 4000 Blackwell SFF and RTX PRO 6000 Blackwell Max-Q are both compute capability 12.0 |
| Does the pin need to move? | No |
| Minimum CUDA requirement | The default tag is CUDA 13.0 → **host driver R580 or later** |
| Fallback tag if the host cannot take an R580 driver | `vllm/vllm-openai:v0.31.0-cu129` (CUDA 12.9.1, driver ≥ 575.51.03, same arch list) |

## Evidence

Image config blobs read from the Docker Hub registry API on 2026-10-18 (amd64 manifests):

| Tag | Manifest digest (amd64) | `CUDA_VERSION` | `TORCH_CUDA_ARCH_LIST` | Built | `VLLM_BUILD_COMMIT` |
| --- | --- | --- | --- | --- | --- |
| `v0.31.0` | `sha256:a4a4c0437bf7…` | 13.0.2 | `7.5 8.0 8.6 8.9 9.0 10.0 12.0` | 2026-10-03 | `db9527a46873454610df6dbedf79a36d6bf1a7f6` |
| `v0.31.0-cu129` | `sha256:b18abb2df97b…` | 12.9.1 | `7.5 8.0 8.6 8.9 9.0 10.0 12.0` | 2026-10-03 | `db9527a46873454610df6dbedf79a36d6bf1a7f6` |

Both tags carry `VLLM_ENABLE_CUDA_COMPATIBILITY=0`, so the forward-compatibility libraries are off
and the real driver floor is the toolkit's, not the relaxed `NVIDIA_REQUIRE_CUDA` compatibility
list.

CUDA driver pairing (NVIDIA CUDA Toolkit release notes, "CUDA Toolkit and Corresponding Driver
Branch" and "Minimum Required Driver Version"):

| CUDA Toolkit | Driver branch | Minimum driver for minor-version compatibility |
| --- | --- | --- |
| 13.0 | R580 | ≥ 580 |
| 12.9 | R575 | ≥ 575.51.03 |

`cuda-drivers-580` is published for both Ubuntu 22.04 and 24.04 in NVIDIA's CUDA repository
(listing verified 2026-10-18), so the bootstrap in Task 8 can pin driver 580 without a PPA.

The vLLM v0.31.0 release notes list SM120 work in the same release: DeepGEMM pin bump with SM120
fixes (#57218) and a FlashInfer SM120 backend for NoPE sparse MLA (#55277). sm_120 is a maintained
target, not an afterthought.

## Known sm_120 gaps that shape the deployment

All open upstream on 2026-10-18:

| Issue | Effect | Mitigation in our compose |
| --- | --- | --- |
| [#54225](https://github.com/vllm-project/vllm/issues/54225) — FlashInfer attention backend causes CUDA illegal memory access on sm_120 with NVFP4 + fp8 KV cache (reproduced on RTX PRO 6000 Blackwell Max-Q, i.e. our GEX63) | Engine crash under load | Set `--attention-backend FLASH_ATTN` explicitly. Do not leave the backend on auto |
| [#57932](https://github.com/vllm-project/vllm/issues/57932) — GLM-5.3-Flash fails with the FlashInfer attention backend on SM120 / RTX PRO 6000 | Tier-specific engine failure | Same flag. No GLM tier is scheduled for Hetzner, so this is a Scaleway-only risk |
| [#43507](https://github.com/vllm-project/vllm/issues/43507) — CUTLASS MoE backend unavailable on SM_120 for tensor/token-scaled FP8; the selector picks Triton | MoE expert dispatch runs on the slower Triton path | Fix is PR [#43814](https://github.com/vllm-project/vllm/pull/43814), still open. Accept the Triton path and measure against the tier's tok/s target |
| [#51525](https://github.com/vllm-project/vllm/issues/51525) — explicit CUTLASS NVFP4 MoE selection silently produces empty completions on SM_120 | Silent wrong output | Do not select NVFP4 MoE explicitly on sm_120 |
| [#36579](https://github.com/vllm-project/vllm/issues/36579) — Marlin PTX JIT fails on a too-old driver | W4A16 quantized models fail to start | Driver R580 satisfies it. Verify at first startup, not by assumption |

MLA-specific sm_120 defects ([#60172](https://github.com/vllm-project/vllm/issues/60172)) are not
relevant: no tier in the catalog serves an MLA model.

## Impact on the two Hetzner tiers' model and quant choices

### seed-24g — blocked as specified

`manifest/tiers.json` and the catalog declare `quant: INT4` with repo
`Qwen/Qwen3-Coder-30B-A3B-Instruct`. That repo is the BF16 release: 16 safetensors shards,
**61.07 GB** total (Hugging Face API, 2026-10-18). It cannot load on a 24 GB card, at any context
length. The official FP8 variant (`Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8`) is still ~30 GB and also
does not fit.

So the tier has no artifact that matches its own declared quant. Options, none of which this spike
may choose unilaterally:

1. Pin a prequantized INT4 artifact (~17-18 GB). Community AWQ/GPTQ builds exist
   (`cyankiwi/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit`, `QuantTrio/…-AWQ`, `jart25/…-Int4-gptq`);
   none is first-party, so this is a supply-chain decision, and it needs `sha` pinned.
2. Change the tier's model to something that fits 24 GB in a first-party quantization.
3. Drop the tier.

**Blocker B1** — Task 8 cannot produce a working `MODEL_PULL` stage for `seed-24g` until this is
resolved. The manifest entry stays as it is (R9) and the gap is reported rather than papered over.

### everyday-96g — works, with a measured-performance risk

`Qwen/Qwen3.6-35B-A3B-FP8` at sha `95a723d08a9490559dae23d0cff1d9466213d989` is FP8 MoE (~36 GB)
and fits 96 GB comfortably. On sm_120 the FP8 MoE path falls back to Triton (gap table above), so
the tier's `target_tok_s: 32` is provisional until measured on real hardware. If the Triton MoE path
misses the target, the levers are, in order: accept, raise `recommended_member_quota` (which lowers
the seat price), or move the tier back to Scaleway `power-h100` (+€19.15/seat, Task 11 rollback
table).

### The five Scaleway tiers

Unaffected. sm_120 only applies to the two Hetzner boxes.

## What must be measured live (deferred per R3)

| Check | Stage | Pass condition |
| --- | --- | --- |
| Driver version on the provisioned host | BOOTSTRAP | `nvidia-smi` reports R580+ and the GPU is visible in the container |
| Engine starts on sm_120 | MODEL_PULL | `vllm serve` reaches `/health` 200 with `--attention-backend FLASH_ATTN` |
| INT4 quant loads (seed-24g) | MODEL_PULL | blocked by B1 |
| Time to first token / tok/s | REGISTER | within `target_ttft_ms` / `target_tok_s`; the FP8 MoE Triton fallback is the main suspect |
| Soak | REGISTER | no CUDA illegal-memory-access crash under concurrent load (gap #54225) |
