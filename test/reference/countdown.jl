# test/reference/countdown.jl — golden-master oracle + program factory
# + self-check for the countdown family. M8.1 (`bennettvm-do7`).
#
# # Why this file exists, and why three things live in it
#
# This file is the load-bearing fixture for every countdown-shaped
# test in the suite (M3.8 forward integration, M4.2 checkpoint push,
# M4.3 unstep!, M4.4 unrun!, M4.5 round-trip, M6.4 zero-history,
# M7.4 unstep delta, M7.6 delta push, M7.7 delta round-trip). It
# co-locates three artifacts that must move together or the
# golden-master contract silently rots:
#
#   1. `countdown_ref(n::Int64) -> Int64` — the **irreversible Julia
#      oracle**. PRD v4 §3.14 binds this co-location: "Every Phase-2
#      test program factory MUST be co-located with a reference
#      irreversible Julia oracle in the same file (or sibling file
#      under `test/reference/`). Forward execution of the Phase-2
#      program MUST agree bit-for-bit with the oracle on the same
#      inputs." The oracle is the source of truth; the VM is the
#      thing being verified.
#
#   2. `countdown_program(n::Int) -> VMProgram` — the **VMProgram
#      factory**. Hand-built (M3.8 predates lower_vm — `lower_vm` is
#      still the M0.2 digest-stub at this milestone). The unrolled
#      `n + 2`-block layout — `:b_start` + `n` `_decrement_block`s +
#      `:b_done` — is the canonical multi-block fixture every
#      cross-block-dispatch-aware test reuses.
#
#   3. A **self-check `@assert`** that runs at include-time. Forward
#      execution of `countdown_program(N)` on `(:n0 => N, :steps0 => 0)`
#      MUST land at halt with (a) `result[Symbol("steps", N)] ==
#      countdown_ref(N)` AND (b) `result[Symbol("n", N)] == 0`. The
#      conjunction is load-bearing (Rule 4): because the program is a
#      straight-line unrolling of exactly `n` decrement blocks, the
#      steps-equals-oracle clause alone is insensitive to the direction
#      of the n-decrement (flipping `:sub` to `:add` leaves `steps == n`
#      because the block count is fixed). The terminal `n == 0` clause
#      pins the n-arithmetic direction. Without both clauses, an edit
#      that broke the oracle-program agreement (whether by perturbing
#      block count, steps direction, or n direction) could silently
#      propagate to every downstream test. The check covers the mutation
#      classes that touch the visible halt-state of `(:steps_N, :n_N)`;
#      it does not pretend to catch arbitrary semantic edits (e.g., a
#      mutation that leaves both terminal values intact but corrupts an
#      intermediate `:n_k` would slip past — that's what the per-step
#      M3.8 / M7 testsets are for).
#
# # Why an `@assert`, not a `@testset`
#
# A `@testset` only fires when a test runner picks up this file. This
# file is loaded by every consumer via `include`, including from
# tests that don't use `@testset` framing (and historically, by
# tests that picked up `build_countdown_vm` transitively from
# `test_forward_interpreter.jl`). A top-level `@assert` runs at
# include-time regardless of how the file is loaded; if the oracle/
# program agreement breaks, every consumer fails at include —
# fast-fail (Rule 1), no escape hatch. The assertion compares
# against a *known-correct value* (Rule 4); a bare `run!(...)`
# would only catch crashes, not wrong-answer regressions.
#
# # Why this refactor (M8.1) exists
#
# Before M8.1, `build_countdown_vm` lived inside
# `test/test_forward_interpreter.jl` (the M3.8 capstone), and seven
# downstream test files (`test_roundtrip`, `test_unrun`, `test_unstep`,
# `test_checkpoint_push`, `test_delta_push`, `test_delta_roundtrip`,
# `test_liveness`) all depended on `runtests.jl`'s include order to
# have the symbol in scope when they ran. The include-order coupling
# was a smell multiple files documented as a temporary workaround.
# M8.1 hoists `countdown_program` (renamed from `build_countdown_vm`)
# and its `_decrement_block` helper here, where they belong by PRD v4
# §3.14, and consumers `include` this reference file directly instead.
#
# # Ref
#
#   * `bennettvm_prd.md` (PRD v4) §3.13 (per-step inverse test —
#     the M8 family's anchoring discipline), §3.14 (golden-master
#     co-location — the rule this file embodies), §3.15 (property
#     test discipline — what M8.4 / M8.5 build on top of this file).
#   * `spike/RETROSPECTIVE.md` Q4 §"Test patterns worth keeping":
#     "Golden master with explicit oracle. A reference irreversible
#     Julia function in `test/reference/countdown.jl` co-located with
#     the program factory. Every forward-execution test cross-checks
#     against the oracle." — direct continuation of that pattern.
#   * `bd bennettvm-do7` (M8.1) — this milestone.
#   * `bd bennettvm-mqh` (M3.8) — the original consumer; the layout
#     pinned by the four `@testset`s in `test_forward_interpreter.jl`
#     is the canonical decrement-block shape this file preserves.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (every test pins a
#     known-correct value), Rule 11 (literate top-of-file docstrings).
#   * CLAUDE.md Phase-0 gating P0.5 — golden master required.

using BennettVM

# Re-include guard. This file is `include`d directly from every
# countdown-consuming test file (test_forward_interpreter, test_unstep,
# test_unrun, test_roundtrip, test_checkpoint_push, test_delta_push,
# test_delta_roundtrip, test_liveness). Without this guard, the same
# `function` definitions would be re-evaluated 8x in a single
# `runtests.jl` session, producing benign-but-noisy
# "Method definition ... overwritten on the same line" warnings. The
# `@isdefined(countdown_ref)` check is the canonical Julia idiom for
# "include this file at most once per session": cheap, clear, no
# external machinery (no `if !@isdefined` macro, no `@__MODULE__`
# rebinding). The self-check `@assert` below still re-fires on every
# include — by design — because asserting against `countdown_ref` is
# cheap (microseconds) and is the golden-master gate every consumer
# wants to re-confirm at load time.
if !@isdefined(countdown_ref)

# ---------------------------------------------------------------------
# 1. The irreversible Julia oracle.
# ---------------------------------------------------------------------

"""
    countdown_ref(n::Int64) -> Int64

The irreversible Julia reference for `countdown(n)`. For non-negative
`n`, returns `n` itself (the number of decrement steps required to
reach 0 starting from `n`). The golden master for BennettVM's
hand-built `countdown_program` VMProgram across the M3/M4/M6/M7 test
families.

The implementation is a plain `while` loop — irreversible by
construction (the loop counter `n` is destructively decremented, and
`steps` is destructively incremented). The BennettVM equivalent is a
straight-line unrolling into `n` decrement blocks (`countdown_program`
builds `n + 2` basic blocks: entry + `n` decrement + done), each of
which performs its decrement reversibly via `ArithmeticAssignment`
with modop `:sub`. The two computations must produce the same
`steps` value despite differing radically in their internal
mechanics; agreement is the load-bearing assertion (Rule 4).

# Why `Int64` and not `Int` (the platform default)

`IState.locals` is declared `Dict{Symbol,Int64}` (src/ir/IState.jl
M2.1), so every value the BennettVM interpreter produces is `Int64`.
Typing the reference function the same way prevents a Julia-on-32-bit
platform surprise where `Int === Int32` and the reference would
compare unequal to the BennettVM output even though both computed
"3".

# Ref

  * CLAUDE.md Rule 4 + Phase-0 gating P0.5 — known-correct reference.
  * `src/ir/IState.jl` (M2.1) — `Dict{Symbol,Int64}` element-type
    constraint motivates the `Int64` signature here.
  * `bennettvm_prd.md` (PRD v4) §3.14 — golden-master co-location.
"""
function countdown_ref(n::Int64)
    steps = Int64(0)
    while n > 0
        n -= 1
        steps += 1
    end
    return steps
end

# ---------------------------------------------------------------------
# 2. Hand-built VMProgram factory + decrement-block helper.
# ---------------------------------------------------------------------

"""
    _decrement_block(label, n_in, s_in, n_out, s_out, next_label) -> BasicBlock

Build a single decrement basic block: `UnconditionalEntry(label,
[n_in, s_in])` → two `ArithmeticAssignment`s that decrement n_in and
increment s_in → `UnconditionalExit(next_label, [n_out, s_out])`.

The `op=:and, lhs=Int64(1), rhs=Int64(1)` pattern produces the
literal `1` inside `_apply_binop` (M2.6) without consuming an SSA
variable. Both operands are `Int64` literals — `ArithmeticAssignment`'s
constructor accepts `Union{Symbol,Int64}` for both `lhs` and `rhs`
(M2.6 inner-constructor signature). Underscore-prefixed because it's
a file-private helper for `countdown_program`; no consumer outside
this file should depend on it.
"""
function _decrement_block(label::Symbol, n_in::Symbol, s_in::Symbol,
                          n_out::Symbol, s_out::Symbol, next_label::Symbol)
    BennettVM.BasicBlock(
        label,
        BennettVM.UnconditionalEntry(label, [n_in, s_in]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(n_out, n_in, :sub,
                                           Int64(1), :and, Int64(1)),
            BennettVM.ArithmeticAssignment(s_out, s_in, :add,
                                           Int64(1), :and, Int64(1)),
        ],
        BennettVM.UnconditionalExit(next_label, [n_out, s_out]),
    )
end

"""
    countdown_program(n::Int) -> VMProgram

Hand-build the unrolled `countdown(n)` VMProgram. Layout:

  * `:b_start` — `BeginInstruction(:countdown, [:n0, :steps0])` →
    empty body → `UnconditionalExit(:b_step1, [:n0, :steps0])`.
    (Or `:b_done` directly for the degenerate `n == 0` case.)
  * `:b_step1` ... `:b_step{n}` — each one is `_decrement_block` reading
    `:n{i-1}, :steps{i-1}` and producing `:n{i}, :steps{i}`, exiting to
    `:b_step{i+1}` (or `:b_done` for the last block).
  * `:b_done` — `UnconditionalEntry(:b_done, [:n{n}, :steps{n}])` →
    empty body → `EndInstruction(:countdown, [:steps{n}])`.

Total blocks: `n + 2` (entry + n decrement + done). For n=0 the chain
degenerates to `:b_start` → `:b_done` directly.

Inputs: caller passes `Dict(:n0 => Int64(n), :steps0 => Int64(0))`
to `initial_state`. Output (at halt): `result(s)[Symbol("steps", n)]`
holds the decrement count, which MUST equal `countdown_ref(Int64(n))`
(the include-time self-check at the bottom of this file pins exactly
this invariant for n=3 and n=5).
"""
function countdown_program(n::Int)
    n >= 0 || error("countdown_program: n must be non-negative, got $n")
    blocks = BennettVM.BasicBlock[]

    # Entry block. For n == 0, exit directly to :b_done (skipping the
    # nonexistent :b_step1). For n >= 1, exit to :b_step1.
    first_exit_label = n == 0 ? :b_done : :b_step1
    push!(blocks, BennettVM.BasicBlock(
        :b_start,
        BennettVM.BeginInstruction(:countdown, [:n0, :steps0]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(first_exit_label, [:n0, :steps0]),
    ))

    # n decrement blocks, labelled :b_step1 ... :b_step{n}. Block i
    # reads :n{i-1}, :steps{i-1} and produces :n{i}, :steps{i}, then
    # exits to :b_step{i+1} (or :b_done at the end of the chain).
    for i in 1:n
        next_label = i < n ? Symbol("b_step", i+1) : :b_done
        push!(blocks, _decrement_block(
            Symbol("b_step", i),
            Symbol("n", i-1), Symbol("steps", i-1),
            Symbol("n", i),   Symbol("steps", i),
            next_label,
        ))
    end

    # Done block. Its UnconditionalEntry params MUST match whatever the
    # last sender's args were: for n >= 1 that's :n{n}, :steps{n}; for
    # n == 0 that's :n0, :steps0 (the entry block exits to :b_done
    # directly carrying its inputs).
    done_params = [Symbol("n", n), Symbol("steps", n)]
    push!(blocks, BennettVM.BasicBlock(
        :b_done,
        BennettVM.UnconditionalEntry(:b_done, done_params),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:countdown, [Symbol("steps", n)]),
    ))

    return VMProgram(blocks, BennettVM.LabelTable(blocks), :b_start,
                     [64, 64], [64])
end

end  # if !@isdefined(countdown_ref) — re-include guard.

# ---------------------------------------------------------------------
# 3. Include-time self-check (golden master cross-validation).
#
# Rule 4: every assertion compares against a known-correct value, not
# just "didn't throw". Two clauses per N:
#   (a) `result[:steps_N] == countdown_ref(N)` — oracle agreement.
#   (b) `result[:n_N] == 0` — n-decrement direction. Required because
#       (a) alone is insensitive to flipping the n-decrement modop
#       from `:sub` to `:add`: the unrolled layout always runs `n`
#       blocks, so `steps` lands at `n` either way (Rule 4 — sufficient
#       known-correct value, not just any known-correct value).
# Sizes N=3 and N=5 cover the two configurations the M3.8 capstone
# `@testset`s in `test/test_forward_interpreter.jl` pin; if either
# clause breaks for either N, every downstream consumer fails at
# include-time rather than producing a silent wrong-answer regression.
# Spike RETROSPECTIVE Q4 §"Test patterns worth keeping" — "every
# forward-execution test cross-checks against the oracle."
# ---------------------------------------------------------------------

for _N in (3, 5)
    let vm = countdown_program(_N),
        rs = initial_state(vm, Dict(:n0 => Int64(_N),
                                    :steps0 => Int64(0)))
        run!(rs, vm)
        @assert is_halted(rs) "countdown_program($_N): forward run did not halt"
        _got = result(rs)[Symbol("steps", _N)]
        _want = countdown_ref(Int64(_N))
        @assert _got == _want "countdown_program($_N) self-check: VM produced steps=$_got but countdown_ref returned $_want (golden-master mismatch, PRD v4 §3.14)"
        # Additionally pin the n-counter terminal value. Without this,
        # the steps-vs-oracle check above is insufficient (Rule 4): the
        # unrolled `n + 2`-block layout always executes exactly `n`
        # decrement blocks regardless of body arithmetic, so `steps`
        # accumulates to `n` whether the n-decrement modop is `:sub`
        # (correct) or `:add` (a mutation). Asserting `n_N == 0` pins
        # the n-decrement direction explicitly: `:sub` → 0, `:add` → 2N.
        _got_n = result(rs)[Symbol("n", _N)]
        @assert _got_n == Int64(0) "countdown_program($_N) self-check: terminal n=$_got_n, expected 0 (n-decrement direction wrong — modop should be :sub, PRD v4 §3.14, CLAUDE.md Rule 4)"
    end
end
