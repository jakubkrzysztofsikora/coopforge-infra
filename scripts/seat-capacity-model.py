#!/usr/bin/env python3
"""How many seats can a tier sell before members notice contention?

The KV ceiling is not the seat count. Members arrive burstily and hold a stream
only while their agent is thinking, so the binding question is:

    given S seats, what is the probability that more than C members are active
    at once, and what queue wait results?

This models that directly rather than assuming a smooth average.

Model
-----
- Each member is active with probability `a` at any instant (duty cycle), and
  independently of the others (the optimistic case; real bursts correlate).
- Active members need one stream each. Capacity is C streams.
- More than C active means queueing. Wait is estimated with M/M/c.

The duty cycle is the parameter to measure. It is NOT the same as "seats
utilised": a member who runs an agent ten minutes an hour has a = 1/6.

Usage
-----
    python3 seat-capacity-model.py --streams 28 --seats 120 --duty 0.10
    python3 seat-capacity-model.py --streams 28 --duty 0.10 --sweep
"""

from __future__ import annotations

import argparse
import math


def active_probability_exceeds(seats: int, streams: int, duty: float) -> float:
    """P(more than `streams` of `seats` members are active at once).

    Binomial tail. Independent arrivals are the optimistic assumption; a shared
    Monday-morning burst is strictly worse, so treat this as a floor on
    contention.
    """
    p = 0.0
    for k in range(streams + 1, seats + 1):
        p += math.comb(seats, k) * duty**k * (1 - duty) ** (seats - k)
    return p


def erlang_c(offered: float, servers: int) -> float:
    """Probability an arriving request queues (M/M/c)."""
    if servers <= 0:
        return 1.0
    if offered >= servers:
        return 1.0
    rho = offered / servers
    # Erlang B recursion, then Erlang C from it.
    b = 1.0
    for i in range(1, servers + 1):
        b = (offered * b) / (i + offered * b)
    return b / (1 - rho * (1 - b))


def active_probability_exceeds(seats: int, streams: int, duty: float) -> float:
    """P(more than `streams` of `seats` members are active at once).

    Binomial tail, which assumes members act independently. Real activity
    correlates (Monday morning, a standup, a CI failure), and correlated demand
    has higher variance, so this is a FLOOR on contention — the optimistic case.
    Use `with_bursts` for the realistic figure.
    """
    p = 0.0
    for k in range(streams + 1, seats + 1):
        p += math.comb(seats, k) * duty**k * (1 - duty) ** (seats - k)
    return p


def with_bursts(
    seats: int, streams: int, duty: float, burst_prob: float, burst_duty: float
) -> float:
    """P(over capacity) allowing for correlated bursts.

    Two regimes: normal (each member active with probability `duty`) and burst
    (`burst_prob` of the time, everyone active at `burst_duty`). Crude, but it
    shows the thing that actually matters: a rare correlated burst dominates the
    tail, so an independence-only answer is misleadingly reassuring.
    """
    return (1 - burst_prob) * active_probability_exceeds(
        seats, streams, duty
    ) + burst_prob * active_probability_exceeds(seats, streams, burst_duty)


def wait_seconds(offered: float, servers: int, mean_service_s: float) -> float:
    """Mean queue wait, M/M/c. Infinite if the system is unstable."""
    if offered >= servers:
        return float("inf")
    c = erlang_c(offered, servers)
    return c / (servers - offered) * mean_service_s



def report(streams: int, seats: int, duty: float, service_s: float) -> None:
    offered = seats * duty
    p_over = active_probability_exceeds(seats, streams, duty)
    wait = wait_seconds(offered, streams, service_s)
    print(f"streams={streams} seats={seats} duty={duty:.0%}")
    print(f"  offered load      : {offered:.1f} streams (rho = {offered / streams:.2f})")
    print(f"  P(over) independent: {p_over:.1%}")
    # The independent figure is the floor. Bursts are what members actually feel,
    # so they are reported by default rather than hidden behind a flag.
    burst = with_bursts(seats, streams, duty, 0.05, 0.60)
    print(f"  P(over) with bursts: {burst:.1%}  (5% of the time everyone runs at 60%)")
    print(f"  mean queue wait   : {'unstable' if wait == float('inf') else f'{wait:.1f}s'}")
    if offered >= streams:
        print("  VERDICT           : unstable — members queue indefinitely")
    elif burst > 0.10:
        print("  VERDICT           : overcommitted — bursts cause visible contention")
    elif wait > 60:
        print("  VERDICT           : waits exceed a minute; expect complaints")
    else:
        print("  VERDICT           : healthy")


def sweep(streams: int, duty: float, service_s: float) -> None:
    print(f"streams={streams} duty={duty:.0%} service={service_s:.0f}s")
    print(f"{'seats':>6} {'offered':>8} {'rho':>6} {'P(over)':>8} {'wait':>9}")
    for seats in range(streams, streams * 12 + 1, max(1, streams // 2)):
        offered = seats * duty
        p_over = active_probability_exceeds(seats, streams, duty)
        wait = wait_seconds(offered, streams, service_s)
        w = "unstable" if wait == float("inf") else f"{wait:.0f}s"
        print(f"{seats:6} {offered:8.1f} {offered / streams:6.2f} {p_over:8.1%} {w:>9}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--streams", type=int, required=True, help="KV-feasible concurrent streams")
    ap.add_argument("--seats", type=int, help="seats sold (omit with --sweep)")
    ap.add_argument("--duty", type=float, default=0.10, help="fraction of the time a member is active")
    ap.add_argument("--service-s", type=float, default=30.0, help="mean seconds one stream holds")
    ap.add_argument("--sweep", action="store_true")
    args = ap.parse_args()

    if args.sweep:
        sweep(args.streams, args.duty, args.service_s)
    elif args.seats:
        report(args.streams, args.seats, args.duty, args.service_s)
    else:
        ap.error("pass --seats or --sweep")


if __name__ == "__main__":
    main()
