# The instruction set & state model

*Why BennettVM's IR looks the way it does — the ~34 reversible instruction
subtypes, the snapshot/trajectory split between `IState` and `RState`, and the
content-comparing equality that makes the round-trip invariant detectable at
all.*

BennettVM is a reversible *interpreter*, not a fixed circuit. Where the circuit
backend lowers a Julia function to a single permutation of bits — no program
counter, no runtime-sized memory — BennettVM keeps an explicit machine state and
walks it forward instruction by instruction, then un-walks it back to the start
with nothing lost. That demands two things the circuit world does not have: a
**typed instruction set** rich enough to express loads, stores, calls, heap
allocation and a reversible map; and a **state model** designed so that
`unrun!(run!(s))` lands back on the exact starting snapshot.

This page is the design tour of both. The dedicated mechanics of *how* reversal
works — the three-layer history tape, the `is_injective` trait, delta min-cut vs
checkpoint-replay — live in [the reversibility model](reversibility_model.md);
here we cover the *shapes* those mechanics operate on.

A note on namespacing up front. The public API is exactly ten exported symbols
(`VMProgram`, `lower_vm`, `n_instructions`, `initial_state`, `is_halted`,
`result`, `step!`, `run!`, `unstep!`, `unrun!`). Everything described below —
`IState`, `RState`, `Define`, every instruction subtype — is **not** exported;
reach it as `BennettVM.IState`, `BennettVM.Define`, and so on. The instruction
set is internal vocabulary, not a stable public surface.

## The instruction set

The IR is an abstract hierarchy rooted at `Instruction` (`src/ir/instructions.jl`),
with `ControlInstruction <: Instruction` as the marker for the six control-flow
ops. There are roughly **34 concrete `Instruction` subtypes**, each carrying its
own `forward(::T, ::IState)` method (mutate the state, advance `pc`) and — where
it is reversible per-instruction — an `inverse` method. The fallbacks in
`instructions.jl` deliberately error loudly (project Rule 1): an instruction type
with no concrete `forward`/`inverse` crashes with its type, `pc` and status
rather than silently doing nothing.

Every constructor enforces its RSSA single-assignment and Rule-1 invariants at
construction time. `Define` rejects `target ∈ {lhs, rhs}` and an `op` outside the
operator domains and a `width ∉ 1..64`; `SwapInstruction` rejects overlapping
targets and sources; `ConditionalEntry`/`ConditionalExit` reject degenerate
single-predecessor / single-target forms. A malformed instruction cannot exist as
a value.

Grouped by role:

| Role | Subtypes | Source |
| --- | --- | --- |
| **Control markers** (6) | `BeginInstruction`, `EndInstruction`, `UnconditionalEntry`, `UnconditionalExit`, `ConditionalEntry` (φ-merge join), `ConditionalExit` (predicated split) | `src/ir/control_instructions.jl` |
| **Arithmetic / create** | `Define` (non-destructive SSA-create), `ArithmeticAssignment` (destructive read-modify-write), `CastInstruction`, `SelectInstruction`, `SwapInstruction`, `SoftCall` (soft-float dispatch) | `define_instruction.jl`, `arithmetic_assignment.jl`, `cast_instruction.jl`, `select_instruction.jl`, `swap_instruction.jl`, `softcall_instruction.jl` |
| **Memory floor** | `MemoryStore`, `MemoryLoad` | `src/ir/memory_floor.jl` |
| **Memory read-modify-write** | `MemoryAssignment`, `MemoryInterchange`, `MemorySwap` | `src/ir/memory_instructions.jl` |
| **Alloca / addressing** | `StackAlloca`, `DynAlloca`, `VarGEP` | `stack_alloca.jl`, `alloca.jl`, `array_index.jl` |
| **Reversible map** | `IRMapInsert`, `IRMapDelete`, `IRMapGet` | `src/ir/revmap.jl` |
| **Calls** | `CallEnter` (push frame), `ReturnExit` (pop frame), plus a superseded `CallInstruction` stub | `call_transitions.jl`, `call_instruction.jl` |
| **Heap intrinsics** (8) | `IntrinsicMalloc`, `IntrinsicCalloc`, `IntrinsicGCAlloc`, `IntrinsicFree`, `IntrinsicRealloc`, `IntrinsicMemset`, `IntrinsicMemcpy`, `IntrinsicMemmove` | `intrinsics.jl`, `intrinsics_bulk.jl` |

A few of these carry the weight of the design and are worth naming directly.

**`Define` is the workhorse SSA-create.** It is the lowering target for both
`IRBinOp` and `IRICmp` from Bennett.jl — `Define{target, lhs, op, rhs, width}`,
where `op` ranges over the integer binary operators (`:add`, `:sub`, `:mul`,
`:and`, `:or`, `:xor`, the shifts, the div/rem family) and the ten comparison
predicates (`:eq`, `:ne`, `:ult`, …, `:sge`). It writes a *fresh* SSA name and
never overwrites an existing register, so it is non-destructive — but it is
**not** injective (two different inputs can yield the same `target`), which is why
its `inverse` deliberately raises: a `Define` is reversed by checkpoint-replay, not
by a per-instruction undo. Comparisons live *only* on `Define`; the destructive
assignment below rejects them.

**`ArithmeticAssignment` is the one destructive arithmetic op.** It expresses the
RC3-style read-modify-write `x := y ⊕ (lhs op rhs)`, with a `modop` combinator
restricted to `{:xor, :add, :sub}` — kept separate from the inner `op`
(an integer binary operator). `modop === :xor` is the single self-inverse case:
XOR-assignment is the one arithmetic instruction that is injective and needs no
history at all. `:add`/`:sub` are reversible but lossy enough to need a logged
delta.

**Floating point never reaches the arithmetic arm.** The FP binary operators
(`:fadd`, `:fsub`, `:fmul`, `:fdiv`) do *not* flow through `Define` or
`ArithmeticAssignment`; both constructors reject FP ops. Instead an `IRCall` to a
registered `soft_f*` callee lowers to `SoftCall`, which dispatches into Bennett.jl's
bit-exact soft-float library. This keeps the integer ALU and the soft-float path
cleanly separated.

**The memory model is a floor plus read-modify-write.** `MemoryStore`/`MemoryLoad`
are the scalar reversible store/load floor; `MemoryAssignment` is the in-place
`M[addr] ⊕= …` analogue of `ArithmeticAssignment`; `MemoryInterchange` (register↔memory
exchange) and `MemorySwap` (memory↔memory swap) are both injective — a swap is its
own inverse.

**The reversible map is a register, not a heap structure.** `IState.revmap` is a
`Dict{Int64,Int64}` held *alongside* the heap, and `IRMapInsert`/`IRMapDelete`/`IRMapGet`
operate on it. Note one deliberate asymmetry: `MemoryLoad` zero-initialises an absent
heap cell (an alloca'd-but-unwritten cell genuinely reads `0`), whereas `IRMapGet`
**fails loud** on an absent key — a missing map key is a bug, not a default.

**Calls are split into entry and exit transitions.** Rather than one monolithic
call instruction, a call lowers to a `CallEnter` (which pushes a `Frame` onto the
stack and is injective — zero history) paired with a `ReturnExit` (which pops the
frame and *is* non-injective, needing a logged delta). The older `CallInstruction`
struct is a superseded stub kept for reference.

### Coverage of Bennett.jl's IR

The instruction set is sized to *cover the Bennett.jl frontend*, not to be a
general assembly. Bennett.jl emits 20 `IRInst` types; BennettVM's ingest
(`src/ir/ingest.jl`, `_lower_parsed_ir`) maps **18 of them** onto the instruction
set above, with **0 gaps** and 2 marked N/A (see `docs/coverage-matrix.md`). The
mapping is mostly one-to-few:

- `IRBinOp` / `IRICmp` → `Define`
- `IRSelect` → `SelectInstruction`; `IRCast` → `CastInstruction`
- `IRStore` → `MemoryStore`; `IRLoad` → `MemoryLoad`; `IRVarGEP` → `VarGEP`; `IRPtrOffset` → `Define`
- `IRMapInsert` / `IRMapGet` / `IRMapDelete` → the `revmap` ops
- `IRBranch` → a `Conditional`/`Unconditional` exit; `IRRet` → `EndInstruction.returns`
- `IRCall` → a guard chain: reject nondeterministic calls, route heap intrinsics,
  launder `gc_loaded`, reject Float32, take the closed-world `CallEnter` path, or
  fall through to `SoftCall`.

`IRPhi` is the interesting one: it is **not** lowered to a body instruction at all.
CFG edges are split into trampoline blocks, and a φ-node becomes a *block parameter*
— the positional-argument-to-parameter rename at the block boundary *is* the phi
merge. This is what lets every basic block be a clean straight-line segment.

## The state model

Two types carry the running machine. `IState` is the **snapshot** — everything one
instruction may read or write at a single moment. `RState` is the **trajectory** —
the live snapshot plus the history tape that lets the interpreter walk backward.

### `IState` — the snapshot

`IState` (`src/ir/IState.jl`) is a `mutable struct` with eight fields:

```julia
mutable struct IState
    pc::Int                      # index within the CURRENT block, not global
    frames::Vector{Frame}        # the call stack; never empty
    status::Symbol               # :running | :halted | :error
    memory::Dict{Int64,Int64}    # sparse, cell-addressed heap; absent ⇒ 0
    revmap::Dict{Int64,Int64}    # the reversible-map register (RevMap)
    heap_top::Int64              # dynamic-alloca bump cursor
    arena_top::Int64             # malloc-arena bump cursor
    stack_top::Int64             # call-stack bump cursor
end
```

The single most important thing to know about `IState` is that **there is no flat
`locals` field**. The register file was refactored (ADR 0019 §1) into the
`frames` call stack, and the *active* register file is always the top frame's
locals:

```julia
active_locals(s::IState)  # === s.frames[end].locals :: Dict{Symbol,Int64}
```

Reading `s.locals` is a bug; go through `active_locals(s)`. The dict is keyed by
SSA variable name (`Symbol`, matching Bennett.jl's `IRInst.dest` naming), with
`Int64` values. Each `Frame` (`src/ir/call_frames.jl`) owns its own `locals`, so
recursion is collision-free without name mangling — each activation's SSA names
live in a separate dict. For a single-function program `frames` has exactly one
element (`:__entry`), so `active_locals(s)` behaves byte-identically to the old
flat register file.

The heap (`memory`) is **cell-addressed**: one `Int64` per cell, not byte-addressed,
and sparse — present keys carry written values, absent keys read as `0`. A `Dict`
rather than a `Vector` because the reachable address range is enormous and clustered;
pre-allocating it is impossible and resizing it is exactly the operation a reversible
heap cannot perform cleanly. Keys are `Int64` to match the upstream x86_64 pointer
width, so a lowered `IRStore`/`IRLoad` address carries through without truncation.

The three **bump cursors** (`heap_top`, `arena_top`, `stack_top`) keep the dynamic-alloca,
malloc-arena, and call-stack segments disjoint. All three default to `0` and the
round-trip invariant requires each to return `0 → … → 0`: every cursor that a
forward step advances, the matching inverse must retract. The equality override below
checks all three precisely so that a malloc-inverse that *forgot* to retract its cursor
cannot pass a round-trip test spuriously.

`status` is a plain `Symbol` (cheap to print): `:running` drives the loop,
`:halted` makes `result(s)` callable, `:error` does not.

A word on width. Registers and cells are `Int64`, but arithmetic is not blindly
64-bit: the `Define` lowering threads the *source width* of its `IRBinOp`/`IRICmp`
and computes in that width's semantics (per-width masking is in place). The
round-trip invariant itself is width-independent — it only cares that forward and
inverse compose to the identity.

### `RState` — the trajectory

`RState` (`src/ir/RState.jl`) is the history-bearing wrapper that the reversible
loop actually pivots on. Four fields:

```julia
mutable struct RState
    current::IState                          # the live snapshot
    history::Vector{AbstractHistoryEntry}    # the reversibility tape
    step_count::Int                          # how far forward we are
    initial::IState                          # deepcopy anchor for replay
end
```

The split between `IState` and `RState` is deliberate (PRD v4 §3.9). It keeps the
per-instruction `forward(instr, s::IState)::IState` contract innocent of history
machinery — a `forward` method computes only "what does the next snapshot look like".
Deciding *whether* and *what* to push onto the tape is the `step!` wrapper's job,
performed against an `RState`. That separation is what lets the three history layers
be pluggable without touching `IState` or any per-instruction `forward`.

`initial` is a deep copy of the snapshot taken at `initial_state` time. It is the
anchor that backward execution falls back to when no checkpoint sits at-or-before
the target step — the deepest replay floor. (It is a separate field rather than a
phantom step-0 entry on `history`, precisely so the `unrun!` exit invariant
`isempty(s.history)` stays clean.)

The whole point of `RState` is one invariant, established here and exercised by the
round-trip tests:

```julia
# after run! to halt, then unrun! all the way back:
unrun!(run!(s, prog)) == initial(s)  &&  isempty(s.history)  &&  step_count == 0
```

The user-facing round trip threads `IState`/`RState` entirely through the ten public
functions — you never touch the structs directly:

```julia
using Bennett, BennettVM

prog = reversible_compile(f, Int64; target = :reversible_vm)   # → VMProgram

# initial_state takes the program AND an input Dict keyed by the entry
# parameters (the argument names), values coerced to Int64:
s = initial_state(prog, Dict(:n => 27))   # :n here is illustrative — the key
                                          # is whatever the entry block's
                                          # parameter is named
run!(s, prog)                             # forward to :halted
answer = result(s)                        # copy(active_locals) — raises unless halted
unrun!(s, prog)                           # reverse, step by step, to the start
@assert s.current == s.initial && isempty(s.history)
```

`run!`/`unrun!` carry the tuning knobs (`max_steps`, `checkpoint_interval`,
`must_cache_set`, `replay_mode` on `run!`; `max_unsteps` on `unrun!`); see
[the API reference](../reference/api.md) and
[the reversibility model](reversibility_model.md) for what they control.

## The mandatory content-comparing `==` / `hash`

There is one non-obvious correctness rule that the whole round-trip rests on, and
it is worth stating in full because it is exactly the kind of bug that hides for
weeks.

Julia's default `==` on a `mutable struct` falls back to `===` (object identity)
on its fields. Two `IState`s with *equal-content* but *distinct* `Dict` objects
would therefore compare **not equal** — and the round-trip invariant
`s.current == s.initial` would silently never hold, no matter how correct the
inverse logic was. The spike hit exactly this trap (retrospective Q2.1).

So `IState`, `RState`, `Frame`, and `FunctionEntry` — every round-trip-bearing type
— **override `Base.==` and `Base.hash` to compare by content** (PRD v4 §3.10). On
`IState`, that means `pc`, `status` (by `===`, since it is an interned `Symbol`),
`frames`, `memory`, `revmap`, and all three cursors are compared field-by-field,
with the `Dict`/`Vector` fields using the stdlib's content-comparing `==`. The
`hash` override moves in lock-step so that `a == b ⟹ hash(a) == hash(b)` continues
to hold (the structs are usable as `Dict` keys and `Set` members). Omitting any one
cursor from the comparison would let a round-trip test pass spuriously when an
inverse forgot to retract that cursor — which is why all eight fields are there
explicitly.

If you add a field to `IState` that participates in execution state, you must add
it to *both* overrides. This is not optional polish; it is the mechanism that makes
reversibility *testable*.

## The RSSA lineage

The instruction set is not invented from scratch — it descends from **RSSA**
(reversible SSA), via the RC3 reference implementation (PRD v4 §3.1; ADR 0001).
RC3 (THM) is the canonical RSSA implementation and the closest existing analogue to
BennettVM; Phase 2 began by building and exercising RC3 in our own ADR before any
IR code was written, so that "reuse before reinvention" was honoured against an
artifact actually run rather than a paper read.

Three RSSA design choices show through into the types on this page:

1. **Paired control markers.** Every `BasicBlock` (`src/ir/basic_block.jl`) is
   `[entry::ControlInstruction, body…, exit::ControlInstruction]` with the body
   free of any control instruction. `entry` is one of `Begin` / `UnconditionalEntry`
   / `ConditionalEntry`; `exit` is one of `End` / `UnconditionalExit` /
   `ConditionalExit`. Reversible control flow needs *both* ends of a block to be
   explicit so that a backward jump can find its paired landing point — hence the
   dual `fwd_address`/`bwd_address` in the `LabelTable`.

2. **φ-nodes as block parameters.** Because RSSA makes control flow reversible at
   the block boundary, a φ-merge is expressed as a `ConditionalEntry` join with
   parameters, not as an in-body select — the positional-args-to-params rename *is*
   the merge (see the `IRPhi` mapping above).

3. **Single-assignment, enforced at construction.** RSSA's single-assignment
   discipline is the reason `Define` is non-destructive and every constructor checks
   its own SSA invariants. The destructive read-modify-write ops
   (`ArithmeticAssignment`, the `Memory*` family, the swaps) are the deliberate,
   reversibility-aware exceptions — each one is either injective or carries exactly
   enough logged delta to undo itself.

For the broader framing of *why* a reversible VM exists alongside the circuit
backend, see [What BennettVM is](what_is_bennettvm.md); for how a `:reversible_vm`
compile is dispatched from Bennett.jl, see [Integration with Bennett.jl](integration.md).
The controlling specification throughout is `bennettvm_prd.md` (PRD v4), and the
Bennett.jl version it is pinned against is recorded in `BENNETT_JL_PIN.md` (the
single source of truth — do not trust a SHA pasted elsewhere).
