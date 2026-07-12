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
    elseif callee === :gc_alloc_obj
        # Julia typed-GC allocation (CW-D3 Lever 3; Bennett-iwo9 decision 5; ADR
        # 0021 D3 floor). Bennett.jl emits `[size, tag]` (the `task` arg is
        # dropped upstream). Both lower via `_lower_operand` (size: a value used
        # by `_alloc_cells`; tag: METADATA carried but STRUCTURALLY UNREAD by any
        # state transition — the tag never influences VM state).
        _need(2)
        return IntrinsicGCAlloc(inst.dest, _lower_operand(a[1]), _lower_operand(a[2]))
    elseif callee === :jl_alloc_genericmemory_unchecked
        # Julia Memory{T} backing alloc (CW-D2 / 416r.12; model CW-D4 /
        # bennettvm-9n3y). Bennett's generic C-call arm carries [ptls, nbytes,
        # typ] (VERIFIED — 3 args, ptls NOT dropped upstream). Drop a[1]=ptls
        # (TLS ptr, no VM meaning); size=a[2] (the lbot-fused smul product,
        # DATA bytes = nelems×elsize, header-exclusive); tag=a[3] (metadata,
        # structurally unread — ADR 0021 D3). CW-D4: a bare bump alloc is NOT
        # enough — a GenericMemory is a self-describing {length, data-ptr}
        # whose data-ptr the native RUNTIME sets (no IR store site exists), so
        # this lowers to the dedicated `IntrinsicGenericMemoryAlloc`, which
        # reserves 16 header byte-cells + the data bytes and writes the
        # data-ptr in its forward (`src/ir/intrinsics_genericmemory.jl`).
        # Reversal still inherits the _ArenaAlloc L2 region-delete.
        _need(3)
        return IntrinsicGenericMemoryAlloc(inst.dest, _lower_operand(a[2]),
                                           _lower_operand(a[3]))
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
    # bennettvm-90l mirror of the Bennett.jl front-end determinism classifier
    # (`_IDENTITY_HASH_GOT_CALLEES` in src/extract/constexpr.jl): the RESOLVED
    # runtime-callee names an `objectid`-hashed Dict key demangles to from its
    # `@"jlplt_<callee>_<N>_got"` GOT stub. `ijl_object_id` is the live-verified
    # stub name (2026-07-12); the others are the `jl_`-prefixed / bare variants.
    # These extend the SAME identity-hash family as `:objectid` above so the two
    # repos' denylists stay in sync (test_fail_loud_completeness.jl pins it).
    :ijl_object_id, :jl_object_id, :object_id,      # objectid family (address hash)
    :jl_pointer_from_objref, :ijl_pointer_from_objref,  # pointer-identity variants
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
    :gc_alloc_obj,                                  # Julia typed-GC alloc (CW-D3
                                                    # Lever 3; tag IGNORED, ADR 0021 D3)
    :jl_alloc_genericmemory_unchecked,              # Julia Memory{T} backing alloc
                                                    # (CW-D2 / 416r.12; ptls dropped,
                                                    # tag IGNORED — IntrinsicGCAlloc-shaped)
))

# ---------------------------------------------------------------------
# Benign modeled-cell callees (bead `bennettvm-p81t`): non-heap Julia
# runtime intrinsics that lower to a NON-INJECTIVE `Define` create (an
# aliased or fixed Int64 cell), reversed by L3 checkpoint-replay (ADR 0012
# §D1) — NOT an `Intrinsic*` heap op (contrast `_HEAP_DISPATCH`). A hit is
# dispatched to `_lower_benign_cell_call`; the IRCall-arm check MUST sit
# where the old inline `julia.gc_loaded` arm was — after the nondeterminism +
# `_HEAP_DISPATCH` guards, BEFORE the Float32 guard + SoftCall constructor
# (ADR 0018 §C). This is the set the old gc_loaded arm's comment anticipated
# ("lift to a set beside `_HEAP_DISPATCH` if more such callees arrive"):
# `julia.get_pgcstack` is that second callee.
#
# TLS sentinel tier: julia.get_pgcstack returns the per-task pgcstack
# pointer, which has NO VM meaning; under the deterministic VM it is a FIXED
# cell. `2^56` continues the ascending tier convention (stack < 2^40 ≤ arena
# < 2^48 ≤ globals) with a 2^48-cell margin above GLOBAL_BASE — unreachable
# by any real global. Derived addresses (current_task = TLS_BASE-152,
# ptls_field = TLS_BASE+16) stay in the tier; the one IRLoad through them
# reads an absent cell (zero-init) whose value feeds only
# jl_alloc_genericmemory_unchecked's DROPPED ptls arg (ADR 0021 D3) —
# structurally dead, so any constant is sound; this one is collision-free by
# construction.
const TLS_BASE = Int64(1) << 56

# The TLS sentinel tier's neighborhood radius (bead `bennettvm-416r.13`). The GC
# preamble derives addresses OFF `TLS_BASE` by small signed cell offsets
# (`current_task = TLS_BASE - 152`, `ptls_field = TLS_BASE + 16`), so a TLS-tier
# read can land slightly BELOW `TLS_BASE`. `[TLS_BASE - _TLS_TIER_GUARD, ∞)` is
# the TLS band; a `MemoryLoad` there reads an ABSENT cell → zero-init (the
# structurally-dead pgcstack/ptls read, ingest_call.jl:175-184). `2^32` dwarfs
# every GC-preamble offset (a few hundred cells) yet stays ~2^24× below the
# `2^56 - 2^48` gap to the globals tier — so it never swallows a real globals-
# tier read. Consumed by `MemoryLoad.forward`'s read-window trap (memory_floor.jl).
const _TLS_TIER_GUARD = Int64(1) << 32

const _BENIGN_CELL_DISPATCH = Set{Symbol}((
    Symbol("julia.gc_loaded"),      # data-ptr launder (Bennett-igr3): Define(dest, args[2])
    Symbol("julia.get_pgcstack"),   # TLS base (bennettvm-p81t): nullary fixed cell
))

"""
    _lower_benign_cell_call(inst::Bennett.IRCall, callee::Symbol) -> Instruction

Lower a benign modeled-cell `IRCall` (`callee ∈ _BENIGN_CELL_DISPATCH`) to a
non-injective `Define` create (bead `bennettvm-p81t`; ADR 0018 §C; ADR 0012
§D1). Both arms emit a `Define` reversed by L3 checkpoint-replay — no new
inverse code.

  * `julia.gc_loaded(mem, data)` — Julia's GC-rooting data-pointer launder
    (Bennett-igr3; downstream of Bennett-qmv7). It RETURNS the data pointer
    (args[2]); `mem` (args[1]) only keeps the Memory GC-rooted and is
    STRUCTURALLY UNREAD by any VM state transition (the gc_alloc_obj type-tag
    pattern, ADR 0021 D3). In the cell-addressed VM the laundered data pointer
    IS the heap-Memory virtual base cell — the base Bennett.jl's qmv7
    IRVarGEP/IRLoad/IRStore re-root onto — so alias `dest := data` via the
    established pointer-identity create `Define(dest, data, :add, 0)` (a
    pointer is just an Int64 cell; cf. `src/ir/array_index.jl:15`, the
    alloca-base idiom). Keyed on the UN-canonicalised LLVM name
    `Symbol("julia.gc_loaded")` — verified empirically against the qmv7
    `GCL_I8` fixture and `fdict_O0.ll` (operand order `[mem, data]`); contrast
    `:gc_alloc_obj`, which Bennett.jl canonicalises.

  * `julia.get_pgcstack()` — the per-task pgcstack pointer (bennettvm-p81t),
    a NULLARY named intrinsic with no VM meaning. Emit the fixed TLS-sentinel
    create `Define(dest, TLS_BASE, :add, 0)` (see `TLS_BASE`).
"""
function _lower_benign_cell_call(inst::Bennett.IRCall, callee::Symbol)::Instruction
    if callee === Symbol("julia.gc_loaded")
        length(inst.args) == 2 ||
            error("lower_vm: julia.gc_loaded (dest=", inst.dest, ") expects 2 ",
                  "args (mem, data), got ", length(inst.args),
                  " — malformed IR (Rule 1 fail-loud).")
        # `data` (args[2]) is a Memory data pointer — lower via the SSA-ptr
        # path (fail loud on a non-SSA pointer, matching the IRStore/IRLoad/
        # IRVarGEP pointer-operand discipline); it returns the SSA name a
        # `Define` lhs accepts (a pointer is just an Int64 cell).
        return Define(inst.dest,
                      _lower_ptr_operand(inst.args[2], Symbol("julia.gc_loaded"),
                                         inst.dest),
                      :add, Int64(0))
    else  # julia.get_pgcstack
        isempty(inst.args) ||
            error("lower_vm: julia.get_pgcstack (dest=", inst.dest, ") expects 0 args, got ",
                  length(inst.args), " (args=", inst.args, ") — the per-task pgcstack ",
                  "pointer is nullary (Bennett src/extract/julia_set.jl GC preamble; ",
                  "Rule 1 fail-loud).")
        return Define(inst.dest, TLS_BASE, :add, Int64(0))
    end
end
