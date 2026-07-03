# emulator-mvp — E0: a reversible MOS 6502, proven

Reproducible spike backing [`../emulator-on-bennettvm.md`](../emulator-on-bennettvm.md)
§3. A genuine tiny 6502 fetch-decode-execute core runs hand-assembled machine
code on BennettVM, matches native C bit-for-bit, and un-runs to its exact
initial state.

## Files

| File | What |
|---|---|
| `mos6502.c` | The 6502 core (8 sparse opcodes) + a hand-assembled guest program computing `5·n`. Heap-backed RAM (`calloc` → single-index GEPs the `ptr_cells` ingester handles). |
| `mos6502.O0.ll` | LLVM IR from `clang -O0 -S -emit-llvm -fno-discard-value-names`. Regenerate if you edit the C. |
| `mos6502_golden.txt` | Native-C golden master (`n → result`), the oracle. |
| `run_mvp.jl` | Ingest → `lower_vm` → `run!`/`unrun!`; asserts forward==golden + full round-trip. |
| `smoke6502.jl` | Requirements 1–3 probes: A scalar loop, B opcode dispatch, C dynamic RAM. |
| `smoke_dispatch.jl` | Dispatch-encoding probes D1 (sparse), D2 (tree), D3 (divergent) — why sparse 6502 opcodes dodge the switch-lookup-table wall. |

## Reproduce

```bash
cd docs/design/emulator-mvp
# (only if you edit mos6502.c)
clang -O0 -S -emit-llvm -fno-discard-value-names -std=c11 mos6502.c -o mos6502.O0.ll
julia --project=../../.. run_mvp.jl
```

Expected: every `n` prints `PASS` (VM result == native, round-trip ✓), ending
`=== MVP GREEN ===`. Extraction ~24 s, then each input is sub-second forward /
seconds reverse (reverse is L3-replay-bound — see the design note §7).

## What it proves / doesn't

Proves: unbounded loop + runtime-index RAM r/w + sparse opcode dispatch +
reversible round-trip all work **today** on the C path. Does **not** yet cover:
output/input tapes (§5), ROM-as-globals (`bennettvm-416r.4`), the Julia-native
array path (`movq %fs:0` GC-alloc inline-asm wall, `bennettvm-m9i`), or a full
opcode set (milestone E1).
