# Postmortem: checkout slowdown, 2026-10-24

**Impact:** checkout p99 above 2s for 40 minutes.

## Timeline

- 14:02 ShopHighLatency fired.
- 14:10 The on-call engineer saw node_context_switches_total climbing on the shop host:
  a noisy neighbour was thrashing the CPU.
- 14:42 The neighbour was moved; latency recovered.

## Follow-up

Watch context switches on the shop host during the next load test.
