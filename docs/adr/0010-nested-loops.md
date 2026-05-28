# ADR 0010 — Nested-loop CFG lowering (SC9 Case C)

> Status: **ACCEPTED** (2026-05-28). M_NESTED milestone (bd
> `bennettvm-b76`). Supersedes the bead-chain framing of `bennettvm-720`
> / `bennettvm-of5` ("intercept the nested-loop reject, emit multi-level
> BasicBlock") — see §Decision and §Consequences.

## Context

`matrix_sum` is PRD v4 §3.6.2 **Case C** (nested loops) and one of the
four SC9 motivating cases. The circuit backend rejects nested loops at
`Bennett.jl/src/lowering/cfg.jl` (`lower_loop!`: "nested loop header
inside body — nested loops not supported, Bennett-httg / U05 scope").
BennettVM's job is to lower the *symbolic* nested loop and round-trip it.

The bead chain (written 2026-05-25, before any empirical probe) assumed
BennettVM must "intercept the reject at `cfg.jl:111` and emit a
multi-level `BasicBlock` structure." Two facts found this session
falsify that framing.

### Ground truth (verified, Bennett.jl pin `877341e`)

**Citation drift corrected (Rule 3 / Law 1):** the bead cites
`Bennett.jl/src/extract/cfg.jl:111`. There is no `cfg.jl` under
`extract/`; the back-edge / nested-loop reject lives in
`Bennett.jl/src/lowering/cfg.jl` (`lower_loop!`) — the **circuit-lowering
path**, not the extractor. As with collatz (ADR 0012), there is **no
reject in `extract_parsed_ir` to intercept.**

**Finding 1 — the PRD's literal `for`-comprehension form does not
survive as a nested CFG.** `matrix_sum(n) = (s=0; for i in 1:n, j in
1:n; s += 1; end; s)` is folded by Julia's optimizer to `n*n` guarded by
a `select` (`sgt(n,0)`):

```
top: IRBinOp(__v1 = mul(n, n)); IRICmp(.inv = sgt(n, 0));
     IRSelect(spec.select = .inv ? __v1 : 0); IRRet(spec.select)
```

i.e. 1 block, 5 instructions — already lowerable by the collatz ingest,
but it exercises **no nested-loop machinery at all.** Landing a
round-trip on this folded form would be theatre (Rules 4, 9). A
triangular `for` variant (`for j in 1:i`) instead **auto-vectorizes**
and is rejected by the extractor (`unsupported vector opcode LLVMPHI`,
`vectors.jl`).

**Finding 2 — the explicit nested `while` form survives and already
round-trips with ZERO source changes.**

```julia
function matrix_sum_while(n::Int8)
    s = Int8(0); i = Int8(1)
    while i <= n
        j = Int8(1)
        while j <= n
            s += Int8(1); j += Int8(1)
        end
        i += Int8(1)
    end
    s
end
```

`Bennett.extract_parsed_ir(matrix_sum_while, Tuple{Int8})` yields a
genuine **5-block nested-loop CFG** (outer-header, inner-header,
inner-body with self back-edge, outer-latch, exit). BennettVM's
**existing** ingest (`src/ir/ingest.jl`, the generic critical-edge-split
pass from ADR 0012 §D4) lowers it to a runnable **12-block / 33-instruction
`VMProgram`** that runs forward matching the irreversible oracle and
round-trips to empty history. Verified in a REPL probe before this ADR:
`matrix_sum_while(Int8(2))→4`, `(3)→9`, `(4)→16`, each
`vm_result == oracle` and round-trip-clean (`rs.current == rs.initial`,
`isempty(rs.history)`, `step_count == 0`).

This is the same lesson as ADR 0012: **express the loop in a form the
optimizer preserves** (`while`, not the foldable/vectorizable `for`
comprehension). The work is *lowering*, not *interception*.

## Decision

1. **SC9 Case C is exercised via the `while`-form `matrix_sum_while`**,
   co-located with an irreversible oracle (`test/reference/matrix_sum.jl`),
   per the golden-master convention (PRD §3.14). Valid inputs are
   `n ∈ 1..11` (the `Int8` product `n*n ≤ 127` constraint).

2. **No new ingest code.** Nested loops are, structurally, just
   additional back-edges plus additional `ConditionalEntry`/`ConditionalExit`
   pairs — one per loop level. The ADR 0012 ingest emits these *per
   block* via critical-edge splitting and φ→block-param resolution; it
   is already generic over loop nesting depth. The bead-chain's
   "multi-level `BasicBlock`" (`bennettvm-720`) is therefore **already
   produced by the existing pass**, not new work.

3. **Reversibility is L3 checkpoint-replay** — the same cross-iteration
   crux as collatz (ADR 0012 §"The cross-iteration reversibility crux").
   The inner-loop temporaries and the inner counter `j` are SSA names
   reused (overwritten) every inner iteration, and `j` is re-initialised
   every outer iteration; overwriting without a record is irreversible,
   so the value instructions remain `is_injective == false` and reversal
   goes through the L3 trace-tape (`src/history/Replay.jl`), never
   per-instruction `inverse()`.

4. **Per-inner-loop history independence (`bennettvm-of5`) is automatic
   under L3.** Each `CheckpointEntry` is a full `IState` snapshot at a
   step index; it captures *all* loop levels uniformly. Forward-replay
   from the nearest checkpoint reconstructs the exact inner-loop state
   regardless of how many inner iterations ran at that outer step. There
   is no separate per-loop history to keep "independent" — the single
   step-indexed history is correct by construction (this is precisely why
   the L3 design was chosen for collatz).

## Consequences

- **`bennettvm-720`** (ingest: emit multi-level `BasicBlock`) and
  **`bennettvm-of5`** (verify independent per-inner-loop history) are
  **satisfied by the existing ingest + L3 history**, not new code. They
  close as *superseded-by-existing-ingest* (cf. collatz's
  `bennettvm-h7f`, closed superseded-by-L3). The acceptance gate
  **`bennettvm-k7b`** (the in-suite forward + round-trip test for
  `matrix_sum_while`) is the executable proof and is landed alongside
  this ADR.

- **This confirms the ADR 0012 generalization hypothesis.** The collatz
  ingest generalizes from a single loop to nested loops with zero
  changes — evidence that the critical-edge-split + φ-resolution design
  is CFG-shape-general, not collatz-specific.

- The **same L3-only reversal boundary** holds: the per-step inverse
  gate catches reversal bugs; an oracle-anchored forward assertion
  catches forward-semantic bugs (L3 replays a deterministic-but-possibly-
  wrong forward and still closes). Both halves are required (Rule 4).

## Reuse (Law 2)

Reuse: ADR 0012 critical-edge-split `ParsedIR→VMProgram` ingest
(`src/ir/ingest.jl`) + the L3 checkpoint-replay history layer
(`src/history/Replay.jl`).
Why not reuse further: none — nested loops required **no** new mechanism;
this ADR is a record that the existing pass already covers Case C.

## Refs

- `bennettvm_prd.md` (PRD v4) §3.6.2 Case C, §6 SC9; CLAUDE.md P0.6
  (round-trip invariant), Rule 4, Rule 9.
- `docs/adr/0012-collatz-lowering.md` — §D4 (IRBranch critical-edge
  split), §"cross-iteration reversibility crux", §R3 (L3-only reversal).
- `Bennett.jl/src/lowering/cfg.jl` — `lower_loop!` nested-loop reject
  (circuit path only; corrected from the bead's `extract/cfg.jl:111`).
- `test/reference/matrix_sum.jl`, `test/test_matrix_sum_forward.jl`,
  `test/test_matrix_sum_roundtrip.jl` — the Case C golden master + gates
  (`bennettvm-k7b`).
