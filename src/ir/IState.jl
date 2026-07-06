"""
    IState

Per-step interpreter state for BennettVM's forward and inverse loops.
`IState` is the atom that `step!` and `unstep!` mutate; every other
runtime structure (history element, `RState` wrapper, output channel)
is built on top of it.

# What this is

An `IState` value names *everything the next instruction is allowed to
read or write*: the program counter, the register file, and the
running/halted/error status bit. The interpreter loop is, in pseudocode,
`while s.status === :running; step!(s, prog); end` — so `IState` is the
fixed-point of one `step!` iteration. Phase-2 milestone M2.1 lands the
struct only; `step!`/`unstep!` arrive later (M3.x), and `Base.==` /
`Base.hash` overrides are added in M2.2 (`bennettvm-6b4`).

CW-B2 chunk 1 (ADR 0019 §1) refactored the register file from a single
flat `locals::Dict{Symbol,Int64}` field into a `frames::Vector{Frame}`
call stack (see `src/ir/call_frames.jl`). The ACTIVE register file is
`frames[end].locals`, read through the `active_locals(s)` accessor; the
old flat `locals` dict is wrapped at construction into the bottom
(`:__entry`) frame, so every existing constructor keeps its arity and
argument order and single-function programs are byte-identical (the
stack has exactly one frame). `CallEnter` / `ReturnExit` (the call/return
transitions that push and pop frames) arrive in later CW-B2 chunks.

# Field-by-field rationale

- `pc::Int`. Index into the *current basic block's* instruction vector,
  not a global program-wide counter. The RSSA-derived Phase-2 IR carries
  control flow at the block boundary (paired `Conditional{Entry,Exit}`
  dispatch, locked in `docs/adr/0001-rc3-rvm-smoke.md` §Observations
  decision table row "Φ-node placement"); within a block, `pc` is a flat
  index. `Int` rather than `Int32` because Julia's natural integer
  width matches `eachindex` semantics and no realistic block exceeds
  `typemax(Int32)` anyway.

- `frames::Vector{Frame}`. The call stack (ADR 0019 §1; CW-B2 chunk 1).
  NEVER empty — `frames[1]` is the entry activation, and the ACTIVE
  register file is `frames[end].locals`, reached via `active_locals(s)`
  (defined just below the struct). This field REPLACES the former flat
  `locals::Dict{Symbol,Int64}` field; the old register-file rationale
  carries over unchanged to each frame's `locals` dict. That dict is
  keyed by the SSA variable name: the `Symbol` key type matches
  Bennett.jl's `IRInst` SSA-naming convention — every concrete `IRInst`
  subtype carries a `dest::Symbol` field naming the SSA value it produces
  (see `/home/tobias/Projects/Bennett.jl/src/ir_types.jl:56` for the
  abstract `IRInst`, and lines 58-72 / 74-87 for `IRBinOp` / `IRICmp`
  using `dest::Symbol`). Using the same key type means register lookups
  during lowering and during interpretation share a single identity space
  — no symbol-table indirection. The value type is `Int64` because at the
  spike level all registers were 64-bit (see
  `docs/adr/0001-rc3-rvm-smoke.md` §Observations, where the bit-width
  parametrization is flagged as future work). M2.x keeps the spike's
  choice; arbitrary-width / `Bool` typing arrives with a later milestone.
  Frame isolation (each activation's SSA names live in its OWN dict) is
  what makes recursion collision-free without name mangling (ADR 0019 §5);
  for a single-function program the stack has exactly one frame, so
  `active_locals(s)` IS the bottom frame's dict and behaviour is
  byte-identical to the pre-CW-B2 flat `locals`. The wrapping happens in
  every constructor below — the `locals::Dict` argument is the bottom
  frame's `locals`, so every existing call site is untouched.

- `status::Symbol`. One of three legal values:
  * `:running` — the interpreter loop continues; `step!` will execute
    the instruction at `pc`.
  * `:halted` — normal termination (a `Halt` or `Return` instruction
    fired). `result(s)` is callable.
  * `:error` — abnormal termination (division by zero, overflow,
    unsupported instruction, …). `result(s)` is *not* callable; the
    state remains reversible via `unstep!` only if the erroring
    instruction had observable side effects on `pc` or `locals` (the
    discard-pop predicate, PRD v4 §3.12).
  Stored as `Symbol` rather than an `@enum` for cheap printability and
  to match the spike's choice that survived retrospective Q4 review.

- `memory::Dict{Int64,Int64}`. The addressable heap, as a sparse map
  from `Int64` address to `Int64` cell value. This is the Phase-2
  baseline memory model — the simplest thing that could possibly work
  to give the three memory instructions (`MemoryAssignment` M2.11,
  `MemoryExchange` M2.12, `MemorySwap` M2.13) a state to mutate.
  Default is an empty `Dict`; most M2.x instructions (`ArithmeticAssignment`,
  `SwapInstruction`, the six control-flow markers) don't touch it.

  Why a `Dict`, not a `Vector{Int64}`. The address space is sparse:
  in any realistic program — and certainly in the four motivating
  cases of PRD v4 §3.6.2 — only a small subset of addressable
  positions is ever written, often clustered far apart in the
  address range (heap-allocated objects at distinct upstream
  pointer bases, function locals spilled to the stack frame, etc.).
  A `Vector{Int64}` would force us either to allocate the whole
  reachable address range up front (`zeros(Int64, typemax(Int64))`
  is impossible; even `zeros(Int64, 2^32)` is 32 GiB) or to
  maintain a base-address bias and resize on every out-of-range
  write — and resize is exactly the operation a reversible heap
  cannot perform cleanly. The `Dict` sidesteps both: present keys
  carry written values, absent keys default to `0` (the zero-init
  convention, codified by the M2.11 memory instructions in their
  `forward`/`inverse` methods). The Bennett.jl `MemSSA` / `globals`
  model — a persistent-tree representation with snapshot semantics
  — is the richer target that informs a later milestone; for M2.11–
  M2.13 baseline we want the simplest representation that supports
  read-and-write-back-via-modop, and `Dict{Int64,Int64}` is exactly
  that.

  Why `Int64` keys (the address-width choice). Bennett.jl produces
  IR for an x86_64 LLVM target, where pointers are 64-bit. Matching
  the upstream pointer width here means an `IRLoad` / `IRStore`
  address lowered from Bennett.jl can be carried into BennettVM
  without truncation or sign-extension. Phase-2 does NOT yet
  parametrise the address width — narrower-pointer targets (32-bit,
  16-bit embedded) will arrive with a typed-pointer milestone in a
  later phase. Until then, every memory key is `Int64`, and that
  matches the source IR.

  Why `Int64` values. Same reason as the `locals` value type: every
  scalar in M2.x is 64-bit (ADR 0001 §Observations, future-work
  bit-width row). Cell-level typing — `Bool`, narrow int, FP via the
  M_FP SoftFloat dispatch — arrives with the same milestone that
  parametrises register widths.

  The empty-default rule (set via the inner 3-arg constructor below)
  matters for backwards compatibility: every existing `IState(pc,
  locals, status)` call site in M2.x test files and lowering code
  continues to compile and behave identically. Code that wants a
  populated heap calls the 4-arg constructor explicitly.

# Why mutable

Declared `mutable struct` because `step!` and `unstep!` mutate `pc`,
`locals`, and `status` in place during the interpreter's tight inner
loop. The Phase-0 retrospective (`spike/RETROSPECTIVE.md` Q1) identified
this as a PRD-level fix: the original v3 §5.3 template wrote
`struct IState` (immutable), but in practice an immutable `IState`
would force every `step!` call to allocate a fresh struct and rebind
the caller's variable, defeating the in-place mutation convention the
`run!` loop depends on and forcing a full `Dict` copy per step. PRD v4
§3.9 ratifies the mutable choice as binding.

# Cross-reference

- PRD v4 §3.9 ("API and naming conventions"): `IState` MUST contain at
  minimum `pc`, `locals`, and `status` (other fields permitted later).
- PRD v4 §3.10: `Base.==` / `Base.hash` overrides on `IState` are
  unconditional — arriving in M2.2.
- `docs/adr/0001-rc3-rvm-smoke.md` §Observations: RC3's analogue of a
  direction flag (`direction::Direction`) lives at the VM level (one
  per-VM enum flipped at run start), *not* at the IState level. The
  decision table row "Direction flag" makes this explicit. Do not be
  tempted to add a direction field here; it belongs on the `RState`-
  level wrapper that lands in a later bead.

- `revmap::RevMap` (= `Dict{Int64,Int64}`). The BennettVM reversible-map
  ADT (`src/ir/revmap.jl`, ADR 0008 Decision 1; SC9 Case B). A single
  hash-table-valued register for the three `IRMap*` ops
  (`IRMapInsert` / `IRMapDelete` / `IRMapGet`), modelling a Julia
  `Dict{Int64,Int64}` whose `setindex!` / `delete!` history is replayable.
  It is a **dedicated field, NOT in `locals`** (which is scalars only),
  and it mirrors `memory::Dict{Int64,Int64}` exactly — same `Dict` type,
  same empty default, same participation in `==`/`hash`/`deepcopy`/L3
  checkpoint. ADR 0008 **Finding 3** is the load-bearing reason it must
  live *inside* `IState`: an external map would (a) be invisible to
  `IState.==`, so a round-trip test that never reversed the map would
  spuriously pass (Rule 4 — a test that passes without checking the
  invariant is broken), and (b) be omitted from `CheckpointEntry`'s
  `deepcopy(IState)` snapshot, corrupting L3 replay. v1 is a SINGLE map
  per IState (the canonical `fdict` body has one `Dict`); the three ops
  operate on `s.revmap` with no map-handle operand. Multi-map is out of
  scope (a follow-up bead). Default is an empty `RevMap`, set by the 3-
  and 4-arg constructors, so every existing `IState(pc, locals, status)`
  and `IState(pc, locals, status, memory)` call site (111 of them across
  `src/` + `test/`) keeps compiling and behaving identically; the 5-arg
  constructor sets it explicitly (used by the `IRMap*` unit tests).

- `heap_top::Int64` (the runtime bump-pointer OFFSET; ADR 0009 Decision 2a
  multi-array refinement, bead `bennettvm-uil`). The running total of
  dynamic-array cells allocated so far, expressed as an OFFSET from each
  `DynAlloca`'s frozen compile-time base — STARTING AT 0. This is the one
  piece of runtime allocator state `IState` lacked (the "no runtime bump
  pointer exists" finding of the 2026-05-31 Decision-2a refinement,
  `src/ir/alloca.jl` §"Frozen base + runtime heap_top offset"). Its presence
  lifts the single-dynamic-array floor to >=2 dynamic-N allocas:
  `DynAlloca.forward` now computes its region base as
  `base = instr.base + s.heap_top` and advances `s.heap_top += n`, so the
  k-th dynamic alloca owns the disjoint window
  `[instr.base + offset_k, instr.base + offset_k + n_k)` where `offset_k`
  is `heap_top` at its alloc time; the L2 `(base, n)` inverse retracts
  `s.heap_top -= n`, so `heap_top` round-trips `0 -> ... -> 0`.

  Why an OFFSET (default 0), not an absolute cursor. A single dynamic
  alloca gets `base = instr.base + 0 == instr.base` — BYTE-IDENTICAL to the
  pre-`uil` frozen-base behaviour. So this field needs NO `VMProgram` /
  `initial_state` change and NO churn to the 111 existing call sites: the
  3-/4-/5-arg constructors default it to 0, every single-DynAlloca program
  (`frtN`, `test_dyn_roundtrip`, …) is unchanged, and only a program with
  >=2 dynamic allocas observes a non-zero offset. An `Int64` rides L3
  checkpoints automatically (`deepcopy(IState)` copies it — no custom
  method needed) and participates in `==`/`hash` via the same
  content-comparison pattern as `memory` / `revmap` (so a round-trip test
  that failed to restore `heap_top` would FAIL — Rule 4), which is the
  load-bearing reason it lives INSIDE `IState` rather than as an external
  cursor (the ADR 0008 Finding-3 argument for `revmap`, applied here). v1
  admits >=2 dynamic allocas reached AT MOST ONCE each; in-loop / back-edge
  re-execution (same dest) and a static alloca after a dynamic one stay
  fail-loud (deferred follow-up beads — ADR 0009 §Consequences).

- `stack_top::Int64` (the runtime CALL-STACK bump-pointer OFFSET; CW-C3,
  bead `bennettvm-416r.10`). The architectural piece that makes multi-function
  C round-trip. A C `-O0` translation unit stores EVERY local in an `alloca`
  (memory-backed), and the VM's `s.memory` is GLOBAL across call frames (ADR
  0019 §1 — frames carry registers, never memory). The static-alloca bump
  cursor RESETS to cell 1 per function (`_lower_parsed_ir`, `alloca_cursor`),
  so without a runtime offset a callee's stack allocas land at the SAME
  absolute cells as its caller's — a nested call CLOBBERS the caller's
  memory-backed locals, and the caller reads garbage after the call returns
  (the exact CW-C3 wall: `ht_demo_basic`'s `t` pointer was overwritten by a
  nested `ht_get`/`ht_third_pass` and the final `ht_free(t)` got a garbage
  address).

  The fix mirrors `heap_top` exactly: a runtime OFFSET (starting at 0) added
  to each STATIC alloca's compile-time cell so each call frame occupies a
  DISJOINT region of the stack segment. `CallEnter` advances `s.stack_top` by
  the CALLER's frame size (the cells the caller occupies) BEFORE the callee's
  allocas run, so the callee's compile-time cells `1…F` land at
  `stack_top + 1 … stack_top + F`, past every ancestor frame; the matching
  `ReturnExit` retracts `s.stack_top` by the same caller frame size, so it
  round-trips `0 → … → 0`. Recursion is safe (each activation's `CallEnter`
  advances the cursor again, so every activation's allocas get fresh cells —
  no per-frame alloca-name mangling needed, mirroring the frame-register
  isolation of ADR 0019 §5). A SINGLE-function program never calls, so
  `stack_top` stays 0 throughout and `StackAlloca(dest, base).forward`
  computes `dest = base + 0 == base` — BYTE-IDENTICAL to the pre-CW-C3
  absolute-address behaviour (no churn to the collatz / arena / single-fn
  tests).

  Why an OFFSET inside `IState` (the ADR 0008 Finding-3 / `heap_top`
  argument, applied a third time): an `Int64` rides L3 checkpoints
  automatically (`deepcopy`), and it MUST participate in `==`/`hash` so a
  round-trip test that failed to restore the call-stack cursor FAILS (Rule 4)
  rather than passing spuriously. Default 0 in every constructor keeps all
  111+ existing `IState(...)` call sites byte-identical.

  The cursor is LIFO (advance at `CallEnter`, retract the SAME amount at the
  matching `ReturnExit`), so `stack_top` is bounded by live call DEPTH, not
  total call count — a returned frame's stack region is reused by the next
  sibling call (the C activation-record discipline). This is correct because
  a returned frame's allocas are dead at the C level (the fixture never leaks
  a stack address out of a function). The dead cell CONTENTS linger in
  `s.memory` until the run's reverse retracts the whole call (the
  correctness-first leak floor, like `free`); only the ADDRESS space is reused,
  bounded by depth. The cursor itself round-trips 0 to ... to 0 because every
  advance has a matching retract; an L2 payload on `ReturnExit` carries the
  amount so the inverse re-advances exactly (CW-C3).

- `globals::GlobalROM` (READ-ONLY const-global segment; bead
  `bennettvm-416r.4`). The fourth address-space tier beside the alloca-stack
  (`stack_top`), the malloc-arena (`arena_top`), and the heap. A C/Rust/Julia
  `const` array (`static const uint8_t rom[8] = {…}`) lowers to an
  initialized read-only VM memory segment based at `GLOBAL_BASE = 2^48`
  (`src/ir/intrinsics.jl`), disjoint from the stack `[1, 2^40)` and arena
  `[2^40, 2^48)` tiers (one-comparison segment test). A `MemoryLoad` of an
  address `>= GLOBAL_BASE` reads the ROM cell (`get(g.cells, addr, 0)`); a
  `MemoryStore` to such an address FAILS LOUD (writing a `const` global is a
  miscompile — Rule 1).

  Why a dedicated `GlobalROM` wrapper, NOT a bare `Dict{Int64,Int64}` field,
  and why it is EXCLUDED from `==`/`hash`/`deepcopy`. The ROM is materialized
  ONCE (in the `VMProgram`, seeded into `initial_state`'s IState) and is
  read-only for the whole run — it NEVER changes, so it is invariant between
  the initial and final states and need not participate in the round-trip
  equality invariant. Crucially, it must NOT be deep-copied into every L3
  `CheckpointEntry` snapshot: a 16 KB NES ROM copied every K steps is the
  scale-killer this design avoids. `GlobalROM` carries a custom
  `Base.deepcopy_internal(g::GlobalROM, ::IdDict) = g` (below) that returns the
  SAME object, so `deepcopy(::IState)` — used by `CheckpointEntry`, `RState`,
  and `initial_state` — SHARES the one ROM reference across every snapshot
  (materialized once, never per-checkpoint-copied). Excluding it from `==`/
  `hash` (the hand-written methods below simply do not mention it) avoids
  hashing/comparing 16 KB on every state comparison AND is sound precisely
  because it is invariant + shared. This is the "read-only design" (proposer
  A) realised WITHOUT a fragile custom `deepcopy_internal(::IState, …)`: the
  override lives on the small `GlobalROM` type, so IState's default field-by-
  field deepcopy still copies every mutable field correctly (a future field is
  never silently dropped). Default is the shared empty `_EMPTY_GLOBAL_ROM`, set
  by every constructor, so all 111+ existing `IState(...)` call sites and every
  globals-free program (collatz, arena, hashtable) stay byte-identical.
"""

# --- GlobalROM: the read-only const-global segment (bead bennettvm-416r.4) ---
#
# A thin wrapper around the ROM cell map so the deepcopy override targets THIS
# type (not IState). Immutable by convention: the segment is READ-ONLY (a
# `MemoryStore` to `>= GLOBAL_BASE` fails loud in `memory_floor.jl`), so the
# inner `cells` dict is never mutated after `initial_state` seeds it.
struct GlobalROM
    cells::Dict{Int64,Int64}
end

# Empty default: a globals-free program shares this one read-only empty ROM.
GlobalROM() = GlobalROM(Dict{Int64,Int64}())

# The materialized-once / never-per-checkpoint-copied contract (see the
# `globals` field rationale above). `deepcopy(::IState)` recurses field-by-
# field via `deepcopy_internal`; for the `globals::GlobalROM` field this
# override returns the SAME object, so every checkpoint snapshot, RState anchor,
# and initial-state copy SHARES the one ROM reference rather than deep-copying
# its (potentially 16 KB) cell map. Sound because the ROM is read-only.
Base.deepcopy_internal(g::GlobalROM, ::IdDict) = g

# Shared empty singleton — the default `globals` for every existing constructor.
const _EMPTY_GLOBAL_ROM = GlobalROM()

mutable struct IState
    pc::Int
    frames::Vector{Frame}       # call stack (ADR 0019 §1); never empty.
    status::Symbol              #   active register file = frames[end].locals.
    memory::Dict{Int64,Int64}
    revmap::Dict{Int64,Int64}   # RevMap, the reversible-map ADT (ADR 0008).
    heap_top::Int64             # runtime bump-pointer offset (ADR 0009; uil).
    arena_top::Int64            # malloc-arena bump-pointer offset (ADR 0018; CW-A2).
    stack_top::Int64            # runtime call-stack bump offset (CW-C3; see below).
    globals::GlobalROM          # read-only const-global segment (416r.4; see above).
                                #   EXCLUDED from ==/hash/deepcopy (shared, invariant).

    # 3-arg constructor: preserves every existing call site (M2.1
    # through M2.10) — empty memory AND empty revmap are the right
    # defaults for any instruction that touches neither heap nor map.
    # `heap_top = 0` (no dynamic allocation yet) keeps a single DynAlloca
    # byte-identical (base = instr.base + 0 == instr.base; bead `bennettvm-uil`).
    # CW-B2 (ADR 0019 §1): the `locals` argument is WRAPPED into the bottom
    # (`:__entry`) frame — the field is now `frames`, but the constructor
    # arity/argument-order is unchanged so every existing call site compiles
    # and behaves identically (single frame ⇒ byte-identical register file).
    IState(pc::Int, locals::Dict{Symbol,Int64}, status::Symbol) =
        new(pc, [Frame(0, Symbol[], locals, :__entry)], status,
            Dict{Int64,Int64}(), Dict{Int64,Int64}(), Int64(0), Int64(0), Int64(0),
            _EMPTY_GLOBAL_ROM)

    # 4-arg constructor: explicit memory, empty revmap. Used by M2.11+
    # tests and by any lowering pass that materializes a heap snapshot up
    # front. Preserved verbatim so the memory-floor / array-floor call
    # sites keep their meaning (memory explicit, revmap defaulted empty);
    # `heap_top` defaults to 0 (uil) — a pre-populated heap snapshot is taken
    # at the start, before any dynamic alloc has advanced the cursor.
    # CW-B2: `locals` wrapped into the bottom frame (see 3-arg note).
    IState(pc::Int, locals::Dict{Symbol,Int64}, status::Symbol,
           memory::Dict{Int64,Int64}) =
        new(pc, [Frame(0, Symbol[], locals, :__entry)], status, memory,
            Dict{Int64,Int64}(), Int64(0), Int64(0), Int64(0), _EMPTY_GLOBAL_ROM)

    # 5-arg constructor: explicit memory AND revmap (ADR 0008 Decision 1).
    # Used by the `IRMap*` unit tests to build an IState with a populated
    # map. The trailing `revmap` is unambiguous — distinct in arity from
    # the 4-arg form — so adding it does not change which constructor any
    # existing 3-/4-arg call site resolves to. `heap_top` defaults to 0 (uil).
    # CW-B2: `locals` wrapped into the bottom frame (see 3-arg note).
    IState(pc::Int, locals::Dict{Symbol,Int64}, status::Symbol,
           memory::Dict{Int64,Int64}, revmap::Dict{Int64,Int64}) =
        new(pc, [Frame(0, Symbol[], locals, :__entry)], status, memory, revmap,
            Int64(0), Int64(0), Int64(0), _EMPTY_GLOBAL_ROM)

    # 6-arg constructor: explicit `heap_top` (bead `bennettvm-uil`). Used
    # ONLY by the multi-DynAlloca unit tests to build an IState mid-stream (a
    # non-zero cursor). The trailing `heap_top` is unambiguous — distinct in
    # arity from the 5-arg form — so adding it changes no existing call site's
    # resolution. `Integer` is coerced to `Int64` for caller convenience.
    # CW-B2: `locals` wrapped into the bottom frame (see 3-arg note).
    IState(pc::Int, locals::Dict{Symbol,Int64}, status::Symbol,
           memory::Dict{Int64,Int64}, revmap::Dict{Int64,Int64},
           heap_top::Integer) =
        new(pc, [Frame(0, Symbol[], locals, :__entry)], status, memory, revmap,
            Int64(heap_top), Int64(0), Int64(0), _EMPTY_GLOBAL_ROM)

    # 7-arg constructor: explicit `arena_top` (ADR 0018 §A; bead CW-A2). Used
    # ONLY by the malloc-arena unit tests to build an IState mid-stream (a
    # non-zero arena cursor). The trailing `arena_top` is unambiguous —
    # distinct in arity from the 6-arg form — so adding it changes no existing
    # call site's resolution. `Integer` is coerced to `Int64` for caller
    # convenience, exactly as the 6-arg `heap_top` form does.
    # CW-B2: `locals` wrapped into the bottom frame (see 3-arg note).
    IState(pc::Int, locals::Dict{Symbol,Int64}, status::Symbol,
           memory::Dict{Int64,Int64}, revmap::Dict{Int64,Int64},
           heap_top::Integer, arena_top::Integer) =
        new(pc, [Frame(0, Symbol[], locals, :__entry)], status, memory, revmap,
            Int64(heap_top), Int64(arena_top), Int64(0), _EMPTY_GLOBAL_ROM)

    # 8-arg constructor: explicit `stack_top` (CW-C3). Used ONLY by the
    # StackAlloca / cross-frame stack unit tests to build an IState mid-stream
    # (a non-zero call-stack cursor). Trailing + unambiguous in arity, so no
    # existing call site's resolution changes. `Integer` coerced to `Int64`.
    IState(pc::Int, locals::Dict{Symbol,Int64}, status::Symbol,
           memory::Dict{Int64,Int64}, revmap::Dict{Int64,Int64},
           heap_top::Integer, arena_top::Integer, stack_top::Integer) =
        new(pc, [Frame(0, Symbol[], locals, :__entry)], status, memory, revmap,
            Int64(heap_top), Int64(arena_top), Int64(stack_top), _EMPTY_GLOBAL_ROM)
end

"""
    active_locals(s::IState) -> Dict{Symbol,Int64}

The ACTIVE register file: `s.frames[end].locals` (ADR 0019 §1; CW-B2
chunk 1). This is the accessor that REPLACES the removed `IState.locals`
field — every old `s.locals` read/write migrates to `active_locals(s)`.
Returns the LIVE `Dict` (not a copy), so the old in-place mutation
semantics are preserved exactly: `active_locals(s)[dest] = val` mutates
the top frame's dict precisely as `s.locals[dest] = val` mutated the flat
dict before. For a single-function program `frames` has one element, so
`active_locals(s)` IS the bottom (`:__entry`) frame's dict — byte-identical
to the pre-CW-B2 `locals`.

`s.frames` is never empty (every constructor seeds `frames[1]`), so
`frames[end]` never throws here; an empty stack would be a frame-underflow
bug the later `ReturnExit` fail-loud guard (ADR 0019 §6d) defends against,
not a condition this accessor must tolerate.

Defined here (not in `call_frames.jl`) because it dispatches on `IState`,
which is defined in THIS file; `Frame` (referenced by the `frames` field)
is defined earlier in `call_frames.jl`, included before this file.

Ref: docs/adr/0019-reversible-calls.md §1.
"""
active_locals(s::IState) = s.frames[end].locals

"""
    Base.:(==)(a::IState, b::IState) -> Bool

Structural equality on `IState`: two states are equal iff their `pc`,
`status`, and (the *content of* their) `frames`, `memory`, `revmap`,
`heap_top`, and `arena_top` agree. The register file lives inside
`frames` (CW-B2, ADR 0019 §1) — `frames[end].locals` is the active dict,
and the bottom frame's `locals` is the old flat register file — so
comparing `frames` content-compares every activation's registers in one
clause (the former `a.locals == b.locals` clause is subsumed; no
double-count, because the register file is now ONLY in `frames`).

# Why we override it

Julia's autogenerated `==` for a `mutable struct` falls back to
field-by-field `==`. For the scalar fields (`pc::Int`, `status::Symbol`)
that already does the right thing. For `locals::Dict`, however, the
*spike's* round-trip assertions only worked because we happened to be
asserting against the same `Dict` instance — see `spike/RETROSPECTIVE.md`
Q2.1: distinct `Dict` values with identical key/value content can
appear unequal under naive identity comparisons, which silently
breaks the load-bearing round-trip invariant
`unrun!(run!(s, prog)) == initial(s)`. M2.2 (`bennettvm-6b4`) closes
that trap by pinning `==` to *content* equality on every field.

# Why `a.frames == b.frames` is the right primitive

The register file is now `frames[end].locals` (CW-B2, ADR 0019 §1), and
`frames` is a `Vector{Frame}`. `Frame` carries a content-comparing `==`
(`src/ir/call_frames.jl`) whose `locals` clause delegates to Julia's
stdlib content-comparing `==` for `Dict` (`Base.:(==)(::AbstractDict,
::AbstractDict)` in `base/abstractdict.jl`): two dicts are `==` iff they
have the same key set and each key maps to an `==`-equal value, regardless
of internal slot layout or `objectid`. `Vector` then content-compares
element-wise (and length-wise). So `a.frames == b.frames` carries the same
spike-Q2.1 "use `==` not `===`" guarantee the old `a.locals == b.locals`
clause did — now lifted over the whole call stack so a round-trip that
fails to restore ANY suspended activation's registers FAILS (Rule 4). The
method is written out (not autogenerated) to keep that intent visible to a
reader who searches for `==`.

# Why `status` uses `===`

`Symbol` values in Julia are interned; `a.status === b.status` and
`a.status == b.status` always agree for `Symbol`s. Spelling it
`===` documents that we intend identity-of-interned-symbol semantics,
which is the natural intent for a small finite tag set
(`:running`, `:halted`, `:error`) — see the `status` field's
rationale in this file's top-of-module docstring.

# The hash contract

`Base.hash(::IState, ::UInt)` (below) is overridden in lock-step so
that the invariant `a == b ⟹ hash(a) == hash(b)` holds. This is what
makes `IState` safe to use as a `Dict` key or `Set` element, which
the test suite exercises explicitly via `haskey(d, equivalent_state)`.
`Frame`'s `hash` composes its fields' content hashes (its `locals` clause
uses `Dict`'s commutative content hash), and `Vector`'s `hash` composes
its elements' hashes in order, so the `hash(s.frames, h)` line is the
counterpart to the `a.frames == b.frames` line above — content in,
content hashed.

Ref: spike/RETROSPECTIVE.md Q2.1 (the Dict-identity trap that
     motivated this override).
Ref: bennettvm_prd.md §3.10 (`Base.==`/`Base.hash` overrides are
     unconditional on `IState`).
Ref: docs/adr/0008-dict-reversibility.md Finding 3 — the `revmap`
     field MUST participate in `==`/`hash` (and hence the round-trip
     invariant), or a `Dict` round-trip test that never reversed the
     map would spuriously pass; the same content-comparing pattern as
     `memory`.
"""
function Base.:(==)(a::IState, b::IState)
    a.pc == b.pc &&
    a.status === b.status &&
    a.frames == b.frames &&  # CW-B2 (ADR 0019 §1): Vector{Frame}, content-
                             # comparing; subsumes the old `a.locals == b.locals`
                             # (the register file is now frames[end].locals).
    a.memory == b.memory &&  # M2.11: same content-comparing pattern.
    a.revmap == b.revmap &&  # ADR 0008 Finding 3: RevMap content participates.
    a.heap_top == b.heap_top &&  # uil: the runtime bump offset MUST round-trip.
    a.arena_top == b.arena_top &&  # ADR 0018 §H: the malloc-arena cursor MUST
                                 # round-trip — omitting it would make a
                                 # round-trip test pass spuriously when a
                                 # malloc inverse forgot to retract the cursor.
    a.stack_top == b.stack_top   # CW-C3: the runtime call-stack bump offset MUST
                                 # round-trip — omitting it would make a round-trip
                                 # test pass spuriously when a CallEnter advanced
                                 # the cursor but the matching ReturnExit inverse
                                 # forgot to retract it (same Rule-4 argument as
                                 # heap_top / arena_top).
end

function Base.hash(s::IState, h::UInt)
    h = hash(s.pc, h)
    h = hash(s.status, h)
    h = hash(s.frames, h)   # CW-B2 (ADR 0019 §1): Vector{Frame} content hash;
                            # subsumes the old `hash(s.locals, h)`.
    h = hash(s.memory, h)   # M2.11: heap content participates in hash.
    h = hash(s.revmap, h)   # ADR 0008 Finding 3: RevMap content participates.
    h = hash(s.heap_top, h) # uil: hash the bump offset in lock-step with ==.
    h = hash(s.arena_top, h) # ADR 0018 §H: hash the malloc-arena cursor in
                             # lock-step with == (preserves a==b ⟹ hash(a)==hash(b)).
    h = hash(s.stack_top, h) # CW-C3: hash the call-stack cursor in lock-step with
                             # == (preserves a==b ⟹ hash(a)==hash(b)).
    return h
end
