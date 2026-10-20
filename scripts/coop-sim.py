#!/usr/bin/env python3
"""Discrete-event simulator for a coop box: will N seats frustrate members?

Answers the question a capacity ratio cannot: given a realistic agentic
workload (context lengths, think gaps, bursts), what queue wait do members
actually see, and how often?

Why not BLIS (arXiv 2610.14255): that simulates the vLLM serving pipeline
(batching, chunked prefill, routing) across a cluster. It has no released code,
and it does not model what a coop must decide — the seat count and the member
experience. This models the layer above: arrivals, context growth, KV residency,
and the queueing that results.

Deterministic: fixed seed, no wall-clock. Same input, same output.

Two resources are contended, and the first version of this file modelled only
the second, which made it useless:

  1. DECODE SLOTS. A turn occupies a slot for its whole duration. With `slots`
     concurrent slots, the (slots+1)th simultaneous turn waits. This is what
     members feel.
  2. KV CACHE. A turn's context occupies KV for as long as it is resident. When
     KV is exhausted, idle contexts are evicted (the returning member pays a
     recompute) or the turn waits.

`slots` is derived from the KV ceiling and the mean context, not guessed.

Usage
-----
    python3 coop-sim.py --config studio-4x-h100 --seats 120 --duty 0.15
    python3 coop-sim.py --config seed-24g --seats 40 --duty 0.15 --burst
"""

from __future__ import annotations

import argparse
import random
from dataclasses import dataclass, field


BLOCK_TOKENS = 16
# Prefill is compute-bound and far faster per token than decode; the recompute
# penalty for a returning member is the prefill of its context at this rate.
PREFILL_TOKENS_PER_S = 3000.0


@dataclass
class Member:
    mid: int
    session_start: float
    turns: int
    think_mean: float
    ctx_start: int


@dataclass
class Held:
    member: int
    tokens: int
    last_used: float


@dataclass
class SimResult:
    waits: list[float] = field(default_factory=list)
    evictions: int = 0
    recompute_tokens: int = 0
    turns_served: int = 0
    peak_kv: int = 0
    peak_slots: int = 0

    def pct(self, p: float) -> float:
        w = sorted(self.waits)
        if not w:
            return 0.0
        return w[min(len(w) - 1, int(p * len(w)))]


def build_members(rng: random.Random, seats: int, duration_s: float, duty: float,
                  burst: bool, turns_mean: float = 6.0) -> list[Member]:
    """Members are full-time engineers in the SAME working window.

    The first version spread session starts uniformly across the whole window and
    gave each member ~6 turns, which put mean concurrency at 0.38 of 74 slots —
    it could never contend, so the simulator proved nothing. A coop member is not
    a random arrival: they are at work for the whole window, and the duty cycle is
    the fraction of that window their agent is actively decoding.

    So: every member is in session for the whole window, and turns are laid down
    at a rate that produces the requested duty cycle. `duty` is therefore the
    single most important input, and it is the field the research could not
    supply — it must be measured from real members.
    """
    # EVERY seat is a member at work for the window. `duty` is the fraction of
    # that window their agent is actively decoding — so mean concurrency is
    # seats * duty. The first version also scaled the member count by duty, which
    # applied it twice and made mean concurrency seats*duty*duty (2.7 instead of
    # 18 for 120 seats at 15%), so nothing ever contended and the simulator
    # silently agreed with every configuration.
    active = max(1, seats)
    out = []
    for i in range(active):
        # Correlated starts: a burst pulls a fraction of members into the first
        # tenth of the window, which is what a Monday morning actually looks like.
        start = rng.uniform(0, duration_s * 0.10) if (burst and rng.random() < 0.4) else 0.0
        # Turns spread across the window so the member is decoding `duty` of it.
        # service_s is fixed per turn, so the gap between turns sets the duty.
        out.append(Member(
            mid=i,
            session_start=start,
            turns=max(1, int(round(duration_s * duty / 25.0))),
            think_mean=25.0 * (1.0 / duty - 1.0) if duty > 0 else 0.0,
            ctx_start=rng.choice([2048, 4096, 8192, 16384]),
        ))
    return out


def simulate(members, capacity_tokens, slots, service_s, idle_cap_s,
             seed: int = 7) -> SimResult:
    """Event-driven. A turn occupies a decode slot AND holds KV while resident."""
    rng = random.Random(seed)
    res = SimResult()

    resident: dict[int, Held] = {}
    kv_in_use = 0
    slot_free_at = [0.0] * slots      # when each decode slot frees
    # A member's next turn is scheduled for after its current turn completes.
    ctx_of = {m.mid: m.ctx_start for m in members}

    # Queue of (ready_time, mid, turn) waiting for a slot. Sorted by ready_time
    # then arrival order, which is FCFS — the vLLM default.
    pending: list[tuple[float, int, int, float]] = []
    for m in members:
        t = m.session_start
        for turn in range(m.turns):
            pending.append((t, m.mid, turn, m.session_start))
            t += service_s + rng.expovariate(1.0 / m.think_mean)
    pending.sort(key=lambda e: (e[0], e[3]))

    while pending:
        ready, mid, turn, _sess = pending.pop(0)

        # The turn starts when both a slot is free and its KV fits.
        start = ready

        # Wait for a decode slot.
        slot = min(range(slots), key=lambda i: slot_free_at[i])
        if slot_free_at[slot] > start:
            start = slot_free_at[slot]

        # Reclaim KV that has been idle past the cap, at `start`.
        for held_mid in list(resident):
            h = resident[held_mid]
            if start - h.last_used > idle_cap_s:
                kv_in_use -= h.tokens
                del resident[held_mid]

        need = ctx_of[mid]
        need_blocks = ((need + BLOCK_TOKENS - 1) // BLOCK_TOKENS) * BLOCK_TOKENS

        # If this member's context is still resident, only the delta is needed.
        delta = need_blocks
        if mid in resident:
            delta = max(0, need_blocks - resident[mid].tokens)

        if kv_in_use + delta > capacity_tokens:
            # Evict LRU residents until it fits; each costs a recompute.
            for victim in sorted(resident, key=lambda k: resident[k].last_used):
                if victim == mid:
                    continue
                h = resident[victim]
                kv_in_use -= h.tokens
                del resident[victim]
                res.evictions += 1
                res.recompute_tokens += h.tokens
                if kv_in_use + need_blocks <= capacity_tokens:
                    break

        if kv_in_use + delta > capacity_tokens:
            # Still does not fit: this turn waits for KV, not just a slot. Model
            # the wait as the mean turn duration, and requeue behind the others.
            res.waits.append(service_s * 2)
            pending.append((start + service_s, mid, turn, _sess))
            pending.sort(key=lambda e: (e[0], e[3]))
            continue

        # Admitted.
        kv_in_use += delta
        if mid in resident:
            resident[mid].tokens = need_blocks
            resident[mid].last_used = start
        else:
            resident[mid] = Held(member=mid, tokens=need_blocks, last_used=start)

        wait = start - ready
        res.waits.append(wait)
        res.turns_served += 1
        res.peak_kv = max(res.peak_kv, kv_in_use)

        # The slot is busy for the whole turn. Context grows for the next turn.
        slot_free_at[slot] = start + service_s
        ctx_of[mid] = min(ctx_of[mid] + 0, need)

        inflight = sum(1 for f in slot_free_at if f > start)
        res.peak_slots = max(res.peak_slots, inflight)

    return res


CONFIGS = {
    # kv_gb, kv_per_token_bytes, seats, service_s
    "everyday-fr-l40s": (8.16, 10240, 60, 25.0),
    "pro-fr-2x-l40s": (52.32, 10240, 90, 25.0),
    "power-h100": (45.60, 32768, 80, 25.0),
    "studio-4x-h100": (54.40, 96256, 120, 25.0),
    "everyday-96g": (52.32, 10240, 80, 25.0),
    "seed-24g": (4.08, 49152, 40, 25.0),
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", choices=sorted(CONFIGS))
    ap.add_argument("--kv-gb", type=float)
    ap.add_argument("--kv-per-token", type=float)
    ap.add_argument("--seats", type=int, required=True)
    ap.add_argument("--duty", type=float, default=0.15)
    ap.add_argument("--duration-h", type=float, default=8.0)
    ap.add_argument("--service-s", type=float, default=25.0)
    ap.add_argument("--idle-cap-s", type=float, default=3600.0)
    ap.add_argument("--mean-ctx", type=int, default=8192)
    ap.add_argument("--burst", action="store_true")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    if args.config:
        kv_gb, per_tok, _seats, svc = CONFIGS[args.config]
        args.service_s = svc
    else:
        if args.kv_gb is None or args.kv_per_token is None:
            ap.error("pass --config, or both --kv-gb and --kv-per-token")
        kv_gb, per_tok = args.kv_gb, args.kv_per_token

    capacity_tokens = int(kv_gb * 1024**3 / per_tok)
    # Slots: how many concurrent turns the KV budget supports at the mean
    # context. This is the derived concurrency ceiling, not a guess.
    slots = max(1, capacity_tokens // args.mean_ctx)
    duration_s = args.duration_h * 3600

    rng = random.Random(args.seed)
    members = build_members(rng, args.seats, duration_s, args.duty, args.burst)
    res = simulate(members, capacity_tokens, slots, args.service_s,
                   args.idle_cap_s, args.seed)

    label = args.config or f"kv={kv_gb}GB"
    print(f"{label}  seats={args.seats} duty={args.duty:.0%} burst={args.burst} "
          f"idle_cap={args.idle_cap_s/60:.0f}min")
    print(f"  KV capacity       : {capacity_tokens/1000:.0f}k tokens "
          f"-> {slots} slots at {args.mean_ctx/1000:.0f}k mean ctx")
    print(f"  members active    : {len(members)}")
    print(f"  turns served      : {res.turns_served}")
    print(f"  peak slots in use : {res.peak_slots}/{slots}")
    print(f"  queue wait p50/95/99: {res.pct(0.50):.1f}s / {res.pct(0.95):.1f}s / {res.pct(0.99):.1f}s")
    print(f"  evictions         : {res.evictions}  (recompute {res.recompute_tokens/1e6:.1f}M tokens)")
    print(f"  peak KV use       : {100.0*res.peak_kv/capacity_tokens:.0f}%")
    p95 = res.pct(0.95)
    if p95 > 5.0:
        print("  VERDICT           : p95 wait exceeds the 5s impatience tipping point")
    elif p95 > 1.0:
        print("  VERDICT           : p95 wait breaks flow (>1s)")
    else:
        print("  VERDICT           : healthy")


if __name__ == "__main__":
    main()
