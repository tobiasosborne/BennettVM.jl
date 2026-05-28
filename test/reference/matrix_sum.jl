# test/reference/matrix_sum.jl — golden-master oracle + lowering helper
# for the nested-loop vertical slice. SC9 Case C (`bennettvm-k7b`,
# ADR 0010).
#
# # Why this file exists
#
# PRD v4 §3.14 binds the golden-master co-location rule: every Phase-2
# test program factory MUST sit beside a reference irreversible Julia
# oracle in the same file (or a sibling under `test/reference/`), and
# forward execution of the lowered VM MUST agree with the oracle
# bit-for-bit on the same inputs. `matrix_sum_while(::Int8)` is the
# *nested-loop* shape of PRD v4 §3.6.2 Case C — the doubly-nested
# counting loop and the load-bearing SC9 motivating case (PRD v4 §6)
# that the circuit backend cannot represent (a runtime-bounded loop
# nest of statically-unknown trip count).
#
# # Why a `while`-nest, not the PRD's literal `for` (ADR 0010)
#
# PRD v4 §3.6.2 Case C writes the case as
# `matrix_sum(n) = (s=0; for i in 1:n, j in 1:n; s+=1; end; s)`. That
# literal source does NOT survive Julia's optimizer as a nested-loop
# CFG: the body has no loop-carried dependence other than the counter,
# so LLVM folds the whole nest to the closed form `n*n` (or
# auto-vectorises it) — there is no nested-loop control flow left for
# Bennett.jl's `extract_parsed_ir` to hand BennettVM. This is the SAME
# lesson collatz (Case D) taught: express the loop in a form the
# optimizer is forced to preserve. The explicit doubly-nested `while`
# below carries a genuine 5-block nested-loop CFG (outer cond, inner
# preheader, inner body, inner-exit, outer-exit) that `extract_parsed_ir`
# accepts and `lower_vm` lowers to a 12-block VMProgram with ZERO source
# changes to `src/` — the existing M_UNBOUNDED ingest already handles
# the multi-level BasicBlock structure. See ADR 0010 for the full
# while-form finding (the orchestrator authors that ADR in parallel).
#
# This file co-locates three artifacts that must move together:
#
#   1. `matrix_sum_while(n::Int8) -> Int8` — the irreversible Julia
#      oracle: a doubly-nested `while` counting `n*n` increments for
#      `n >= 1`, `0` for `n <= 0`. The inner loop runs `n` times for
#      each of the `n` outer iterations, so the returned `s` is exactly
#      `n*n`. Int8 is the argument width; valid inputs keep `n*n <= 127`
#      ⇒ `n ∈ 1..11` (the self-check below uses `n ∈ 1..6`, peak 36).
#
#   2. `matrix_sum_ref(n) -> Int64` — a SECOND, structurally-independent
#      oracle computing the same value by the closed form
#      `n >= 1 ? n*n : 0`. It is deliberately NOT the nested loop: the
#      golden master is strongest when the reference does not share the
#      VM's control-flow shape (the loop nest and its closed form must
#      agree). The include-time `@assert` pins `matrix_sum_ref ==
#      matrix_sum_while` for `n ∈ 1..6` so a drift in either oracle
#      fails fast at load (Rule 1, Rule 4).
#
#   3. `matrix_sum_vm() -> VMProgram` — the lowering helper: pull the
#      `matrix_sum_while` ParsedIR via Bennett.jl's exported frontend
#      and run it through the real `lower_vm` (M_UNBOUNDED.1). NOT
#      hand-built — the factory IS part of what is under test, exactly
#      as `collatz_vm` is.
#
# # Width caveat (mirrors ADR 0012 R1 for collatz)
#
# `IState.locals` are `Int64`; `matrix_sum_while` is i8. The lowering
# does not mask to width, so the VM and the i8 oracle agree only for
# inputs whose accumulator stays in i8 range (`n*n <= 127`, i.e.
# `n <= 11`). The forward / round-trip gates pick such inputs; the
# round-trip invariant itself is width-independent.
#
# # Ref
#
#   * bennettvm_prd.md (PRD v4) §3.14 (golden-master co-location),
#     §3.6.2 Case C (nested loops), §6 SC9; Phase-0 gating P0.5
#     (golden master required), P0.6 (round-trip is load-bearing).
#   * docs/adr/0010-nested-loops.md — the while-form finding (authored
#     in parallel by the orchestrator).
#   * docs/adr/0012-collatz-lowering.md — the lowering design the
#     existing ingest realises (Case D); Case C reuses it unchanged.
#   * test/reference/collatz.jl — the co-location pattern this mirrors.
#   * test/reference/countdown.jl — the include-time `@assert`
#     self-check pattern this mirrors.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct values),
#     Rule 11 (literate top-of-file docstrings).

using BennettVM
import Bennett

# Re-include guard. Keyed on `matrix_sum_vm` (the factory UNIQUE to this
# reference file), mirroring `collatz.jl`'s guard. The oracle functions
# `matrix_sum_while` / `matrix_sum_ref` are defined inside the guard so
# they are not re-evaluated on a second include; the include-time
# self-check `@assert` below sits OUTSIDE the guard so it re-fires on
# every include (cheap; the golden-master gate every consumer re-confirms
# at load time — the `countdown.jl` convention).
if !@isdefined(matrix_sum_vm)

# ---------------------------------------------------------------------
# 1. The irreversible Julia oracle (nested-loop form).
# ---------------------------------------------------------------------

"""
    matrix_sum_while(n::Int8) -> Int8

The irreversible Julia reference for SC9 Case C (nested loops; PRD v4
§3.6.2). A doubly-nested `while` that counts `n*n` increments: the
outer loop runs `i` from 1..n, and for each `i` the inner loop runs `j`
from 1..n incrementing the accumulator `s` once per inner iteration.
Returns `n*n` for `n >= 1` and `0` for `n <= 0` (the outer guard `i <=
n` is false immediately).

Written as an explicit `while`-nest rather than the PRD's literal
`for i in 1:n, j in 1:n` because the latter folds to the closed form
`n*n` (or auto-vectorises) under Julia's optimizer, leaving no
nested-loop CFG for Bennett.jl's `extract_parsed_ir` to lower (ADR
0010). The golden master for BennettVM's lowered `matrix_sum_vm`
VMProgram.

Int8 width keeps the result `n*n <= 127` ⇒ valid inputs `n ∈ 1..11`.
"""
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

# ---------------------------------------------------------------------
# 2. A structurally-independent closed-form oracle.
# ---------------------------------------------------------------------

"""
    matrix_sum_ref(n) -> Int64

A SECOND, structurally-independent irreversible reference for the same
value: `n*n` for `n >= 1`, `0` for `n <= 0`. Deliberately the closed
form (NOT the nested loop) so the golden master cross-checks two
distinct computations of the same quantity — the nested `while`
(`matrix_sum_while`) and its arithmetic identity. The include-time
self-check pins their agreement for `n ∈ 1..6` (Rule 4). Returns
`Int64` so it compares directly to the `Int64`-valued `result(rs)`
entries (`IState.locals` are `Int64`; cf. `countdown_ref`'s rationale).
"""
matrix_sum_ref(n) = n >= 1 ? Int64(n) * Int64(n) : Int64(0)

# ---------------------------------------------------------------------
# 3. The lowering helper: ParsedIR → VMProgram via the real lower_vm.
# ---------------------------------------------------------------------

"""
    matrix_sum_parsed() -> Bennett.ParsedIR

Pull the `matrix_sum_while(::Int8)` `ParsedIR` via Bennett.jl's
exported frontend (`extract_parsed_ir`). Kept separate from
`matrix_sum_vm` so a test can inspect the raw ParsedIR (block count,
φ shape) without re-running the lowering. Mirrors `collatz_parsed`.
"""
matrix_sum_parsed() = Bennett.extract_parsed_ir(matrix_sum_while, Tuple{Int8})

"""
    matrix_sum_vm() -> VMProgram

Lower `matrix_sum_while`'s ParsedIR to a runnable VMProgram via the
real `lower_vm` (M_UNBOUNDED.1, ADR 0012), naming the routine
`:matrix_sum`. The returned program's entry block is `:top`; its single
formal parameter is `Symbol("n::Int8")` (the i8 argument's SSA name).
The lowered program has 12 blocks (the nested-loop CFG with
critical-edge trampolines) and returns via `Symbol("value_phi1.lcssa")`
— exercising BOTH the inner- and outer-loop bodies under L3
checkpoint-replay reversal with ZERO `src/` changes.
"""
matrix_sum_vm() = lower_vm(matrix_sum_parsed(); opts=:matrix_sum)

end  # if !@isdefined(matrix_sum_vm) — re-include guard.

# ---------------------------------------------------------------------
# 4. Include-time self-check (golden master cross-validation).
#
# Rule 4: assert against a known-correct value, not "didn't throw". Pins
# the two oracles agree on `n ∈ 1..6` (peak result 36, well inside i8).
# Runs at include-time regardless of how this file is loaded (the
# `countdown.jl` convention): if either oracle drifts, every consumer
# fails fast at include (Rule 1). Re-fires on every include — by design,
# cheap (microseconds), and the golden-master gate the VM gates depend on.
# ---------------------------------------------------------------------

for _n in 1:6
    _want = matrix_sum_ref(_n)
    _got = Int64(matrix_sum_while(Int8(_n)))
    @assert _got == _want "matrix_sum oracle self-check: matrix_sum_while($_n)=$_got but matrix_sum_ref($_n)=$_want (golden-master mismatch, PRD v4 §3.14, CLAUDE.md Rule 4)"
    # Pin the arithmetic identity too: both must equal n*n for n>=1.
    @assert _got == _n * _n "matrix_sum oracle self-check: matrix_sum_while($_n)=$_got, expected $(_n*_n)=n*n (nested-loop trip-count wrong, PRD v4 §3.6.2 Case C)"
end
