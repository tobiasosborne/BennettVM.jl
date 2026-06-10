"""
    ParsedIR ingest — call dispatch (heap intrinsics + nondeterminism +
    Float32 guards) (CW-A, ADR 0018 §C–D; ADR 0011 §D2)

Split out of `src/ir/ingest.jl` per bead `bennettvm-u110` / Rule 10 (the
~200-LOC ceiling): a PURE MOVE of the `IRCall` dispatch unit — the
`_lower_intrinsic_call` heap-intrinsic lowerer and the two callee
allowlist/denylist sets (`_NONDETERMINISTIC_CALLEES`, `_HEAP_DISPATCH`).
This trio is kept INTACT as a unit because the IRCall-arm guard ordering
is load-bearing (ADR 0018 §C: the `_HEAP_DISPATCH` check MUST precede the
Float32 guard and the SoftCall constructor). The IRCall *arm* itself
(which consults these in order) lives inside `_lower_body_inst`
(`src/ir/ingest_body.jl`); this file holds the dispatch tables and the
intrinsic lowerer the arm calls.

Included into the same `BennettVM` module before `ingest_body.jl` (which
references all three names) and after `ingest_operands.jl` (this file's
`_lower_intrinsic_call` uses `_lower_operand` / `_lower_ptr_operand`).

Future guard-5 (ADR 0019 §8, CW-B2): the function-table resolution miss
(`functions` lookup ⇒ `error()` on a closed-world miss) is guard 5 in the
IRCall-arm ordering (1: `_NONDETERMINISTIC_CALLEES`, 2: `_HEAP_DISPATCH`,
3–4: SoftCall Float32/allowlist, 5: `functions`). When CW-B2 lands it adds
the `functions`-resolution step to the IRCall arm in `ingest_body.jl`
AFTER the Float32 guard; any new function-table dispatch table it needs
belongs HERE, beside `_HEAP_DISPATCH`, to keep the allowlists co-located.

Controlling decisions: `docs/adr/0018-heap-floor.md` §C (ordering), §D
(intrinsic semantics); `docs/adr/0011-fp-inheritance.md` §D2 (Float32);
`docs/opcode-coverage-plan.md` (Nondeterminism row). See the original
`ingest.jl` docstring for the full M_UNBOUNDED.1 framing.
"""

"""
    _lower_intrinsic_call(inst::Bennett.IRCall, callee::Symbol) -> Instruction

Lower a whitelisted heap `IRCall` (`callee ∈ _HEAP_DISPATCH`) to its
`Intrinsic*` instruction (CW-A, ADR 0018 §C–D). The arg positions follow the
C signatures: `malloc(nbytes)`, `calloc(n, sz)`, `realloc(ptr, nbytes)`,
`free(ptr)`, `memset(ptr, byte, nbytes)`, `memcpy/memmove(dest, src, nbytes)`.
Allocation-size operands lower via `_lower_operand` (SSA ref OR LLVM constant
— byte→cell conversion is deferred to the intrinsic's `_cell_count` at run
time, the `IRPtrOffset` cell-index discipline); pointer operands via
`_lower_ptr_operand` (must be SSA). A wrong arg count for the named intrinsic
is malformed IR — fail loud (Rule 1). Extracted into this helper to keep the
`IRCall` arm small (`ingest.jl` is over the Rule-10 cap, bead `u110`).
"""
function _lower_intrinsic_call(inst::Bennett.IRCall, callee::Symbol)::Instruction
    a = inst.args
    _need(k) = length(a) == k ||
        error("lower_vm: heap intrinsic :", callee, " (dest=", inst.dest,
              ") expects ", k, " arg(s), got ", length(a),
              " — malformed IR (Rule 1 fail-loud).")
    if callee === :malloc
        _need(1); return IntrinsicMalloc(inst.dest, _lower_operand(a[1]))
    elseif callee === :calloc
        _need(2)
        return IntrinsicCalloc(inst.dest, _lower_operand(a[1]), _lower_operand(a[2]))
    elseif callee === :realloc
        _need(2)
        return IntrinsicRealloc(inst.dest,
                                _lower_ptr_operand(a[1], callee, inst.dest),
                                _lower_operand(a[2]))
    elseif callee === :free
        _need(1)
        return IntrinsicFree(_lower_ptr_operand(a[1], callee, inst.dest))
    elseif callee === :memset
        _need(3)
        return IntrinsicMemset(_lower_ptr_operand(a[1], callee, inst.dest),
                               _lower_operand(a[2]), _lower_operand(a[3]))
    elseif callee === :memcpy
        _need(3)
        return IntrinsicMemcpy(_lower_ptr_operand(a[1], callee, inst.dest),
                               _lower_ptr_operand(a[2], callee, inst.dest),
                               _lower_operand(a[3]))
    else  # :memmove (the only remaining _HEAP_DISPATCH key)
        _need(3)
        return IntrinsicMemmove(_lower_ptr_operand(a[1], callee, inst.dest),
                                _lower_ptr_operand(a[2], callee, inst.dest),
                                _lower_operand(a[3]))
    end
end

# ---------------------------------------------------------------------
# Nondeterminism guard: callees that have NO deterministic forward and so
# can never be reversed by replay (the doubly-fatal class).
# ---------------------------------------------------------------------

# Callee `nameof`s whose result is NOT a deterministic function of the VM
# state — a fresh random draw, a process-/time-/identity-derived value, or
# a pointer-identity hash. The whole L3 reversal mechanism is *periodic
# checkpoint + deterministic forward REPLAY* (ADR 0012; rr's lesson —
# O'Callahan–Huey 2017, "record nondeterminism, replay determinism"). A
# nondeterministic callee breaks the replay leg outright: re-running the
# forward step from a checkpoint would draw a DIFFERENT value, so the
# pre-image is unrecoverable. It is *doubly* fatal here — there is also no
# deterministic forward to begin with, so even plain re-execution diverges
# (docs/opcode-coverage-plan.md "Genuinely impossible", Nondeterminism row:
# "objectid/identity hashing …, rand/RDRAND, pointer-identity. (Doubly
# fatal for reversibility — no replay.)").
#
# Identity-based hashing (`objectid`, `pointer_from_objref`) is the
# specific CLAUDE.md hallucination-callout case: `objectid` is a hash of
# the *runtime allocation address*, not of the value, so it is
# nondeterministic across runs and aliases distinct values that happen to
# share an address slot — the Dict-key-determinism guard (`bennettvm-90l` /
# Bennett-`klgz`) handles the in-program Dict-key surface; THIS guard is the
# ingest-boundary catch for any such callee arriving as a raw `IRCall`.
#
# Bennett.jl's `extract` already refuses these upstream (U14 atomic/volatile,
# U15 inline-asm/opaque-call, U4eu indirectbr) so they never reach a
# `ParsedIR`; this is the belt-and-suspenders defensive MIRROR on the
# BennettVM ingest side, with a SPECIFIC diagnostic (Rule 1) so a future
# regression that lets one through fails loud and *legibly*, not as the
# generic "unknown SoftFloat callee" message.
const _NONDETERMINISTIC_CALLEES = Set{Symbol}((
    :rand, :rand!, :randn, :randexp,                # PRNG draws (hardware
                                                    # RDRAND surfaces as one of
                                                    # these Julia callees, not
                                                    # a bare `rdrand` Function)
    :objectid, :pointer_from_objref,                # identity / pointer hash
    :time, :time_ns, :getpid,                       # wall-clock / process id
))

# ---------------------------------------------------------------------
# Heap-intrinsic whitelist (CW-A, ADR 0018 §C–D): the bounded set of
# libc/runtime heap callees that get hand-written reversible semantics
# (`src/ir/intrinsics.jl`). An IRCall whose `nameof(callee)` is in this set
# routes to `_lower_intrinsic_call` and emits an `Intrinsic*` instruction; a
# miss falls through to the Float32 guard + SoftCall path (and ultimately the
# fail-loud allowlist reject). This is the same name→handler allowlist pattern
# as `_SOFT_DISPATCH` (the Rule-1 boundary, ADR 0017 item 4). The `_HEAP_DISPATCH`
# check MUST precede the Float32 guard and the SoftCall constructor in the
# IRCall arm (ADR 0018 §C) — a heap intrinsic must never reach those.
# ---------------------------------------------------------------------
const _HEAP_DISPATCH = Set{Symbol}((
    :malloc, :calloc, :realloc, :free,              # allocation / reclamation
    :memset, :memcpy, :memmove,                     # bulk memory
))
