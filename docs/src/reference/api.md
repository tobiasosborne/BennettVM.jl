# API Reference

*Dry, complete reference for the ten symbols `BennettVM` exports: the lowered-program type, the lowering entry point, and the forward/reverse execution surface. Signatures are transcribed from source; line citations are to files under [`src/`](../../../src).*

`BennettVM` is the reversible-VM backend for [Bennett.jl](../../../../Bennett.jl). After `using BennettVM`, `Bennett.reversible_compile(f, T; target=:reversible_vm)` returns a [`VMProgram`](#vmprogram) instead of a circuit (the registration hook is in `src/BennettVM.jl` `__init__`, ADR [0003](../../adr/0003-target-reversible-vm-dispatch.md)). You then run the program forward with [`run!`](#run) and roll it back with [`unrun!`](#unrun).

## Exported surface

`export` (`src/BennettVM.jl:577`) names exactly these ten symbols. Everything else is reached as `BennettVM.X` — see [Not exported](#not-exported).

| Symbol | Kind | Role |
| --- | --- | --- |
| [`VMProgram`](#vmprogram) | type | The lowered reversible program. |
| [`lower_vm`](#lower_vm) | function | `ParsedIR → VMProgram` (single- and multi-function). |
| [`n_instructions`](#n_instructions) | function | Flat-stream instruction count of a program. |
| [`initial_state`](#initial_state) | function | Build the starting `RState` from a program + input. |
| [`run!`](#run) | function | Forward driver: `step!` until halted. |
| [`step!`](#step) | function | Advance one instruction; push history. |
| [`is_halted`](#is_halted) | function | Has the entry routine reached its `End`? |
| [`result`](#result) | function | Read the halted register file. |
| [`unrun!`](#unrun) | function | Reverse driver: `unstep!` back to step 0. |
| [`unstep!`](#unstep) | function | Reverse exactly one step. |

---

## `VMProgram`

The artifact `lower_vm` returns and `target=:reversible_vm` hands the caller. Defined at `src/ir/VMProgram.jl:160`.

```julia
struct VMProgram
    blocks::Vector{BasicBlock}
    label_table::LabelTable
    entry_label::Symbol
    arg_widths::Vector{Int}
    return_widths::Vector{Int}
    functions::Dict{Symbol,FunctionEntry}   # CW-B2 / ADR 0019 §2
    entry_function::Symbol
end
```

| Field | Type | Meaning |
| --- | --- | --- |
| `blocks` | `Vector{BasicBlock}` | The post-edge-split CFG, in flat order. Each block lays out `[entry, body…, exit]`. |
| `label_table` | `LabelTable` | Symbol → flat-stream address map. Invariant: `length(label_table) == length(blocks)`. |
| `entry_label` | `Symbol` | Label of the entry block (`:main` on the user path). Must resolve in `label_table` for a non-empty program. |
| `arg_widths` | `Vector{Int}` | Per-argument source bit widths (threaded from `ParsedIR.args`). |
| `return_widths` | `Vector{Int}` | Per-return bit widths (from `ParsedIR.ret_elem_widths`). |
| `functions` | `Dict{Symbol,FunctionEntry}` | Function table for multi-function programs (empty for single-function). |
| `entry_function` | `Symbol` | Name of the entry-routine activation (`:main` default). |

`BasicBlock`, `LabelTable`, and `FunctionEntry` are internal types (not exported). Notes:

- **Inner constructor** enforces `length(label_table) == length(blocks)` and, when `blocks` is non-empty, that `entry_label` is present in `label_table` (`src/ir/VMProgram.jl:169`).
- **Convenience constructor** `VMProgram(arg_widths::Vector{Int}, return_widths::Vector{Int})` builds an empty-blocks digest stub (`src/ir/VMProgram.jl:214`). A stub is a legal value but `initial_state` rejects it — real `lower_vm` output always has blocks.
- `Base.length(p::VMProgram) == length(p.blocks)` (block count, not instruction count — use `n_instructions` for the latter).

---

## `lower_vm`

`ParsedIR → VMProgram`. Two methods.

### Single-function

```julia
lower_vm(parsed::Bennett.ParsedIR; opts=nothing)::VMProgram
```

`src/lower_vm.jl:77`. The backend entry point Bennett.jl calls on the `target=:reversible_vm` path. Delegates to the ingest pass (`_lower_parsed_ir`, `src/ir/ingest.jl`). `opts` is `nothing` (→ routine `:main`) or a `Symbol` naming the routine; Bennett.jl always calls it with one positional arg, so a user compile always yields routine `:main`. Emits a `@debug` digest gated behind `JULIA_DEBUG=BennettVM` (silent by default).

| Argument | Type | Default | Meaning |
| --- | --- | --- | --- |
| `parsed` | `Bennett.ParsedIR` | — | Single-function IR from `Bennett.extract_parsed_ir`. |
| `opts` | `Nothing` / `Symbol` | `nothing` | Routine name; `nothing` ⇒ `:main`. |

Of `ParsedIR`'s fields, ingest consumes only `args`, `blocks`, and `ret_elem_widths`; `globals`, `memssa`, `synth_ptr_provenance`, and `ret_width` are not inspected.

### Multi-function

```julia
lower_vm(funcs::Vector{<:Pair{Symbol,Bennett.ParsedIR}}; entry::Symbol = first(funcs).first)::VMProgram
```

`src/ir/ingest_multi.jl:79`. Builds a function table, lowers each function with `#`-qualified labels, and merges them into one flat-stream `VMProgram` with populated `functions` / `entry_function`. Not reachable from Bennett.jl's single-function `ParsedIR` — fed by hand-built or `.ll` multi-function inputs. Raises (fail-loud, Rule 1) on an empty vector, a `#` in a name, duplicate names, or an `entry` not in the table.

| Argument | Type | Default | Meaning |
| --- | --- | --- | --- |
| `funcs` | `Vector{<:Pair{Symbol,ParsedIR}}` | — | Named functions to merge. |
| `entry` | `Symbol` | `first(funcs).first` | Entry-routine name. |

---

## `n_instructions`

```julia
n_instructions(p::VMProgram)::Int
```

`src/ir/VMProgram.jl:234`. Total flat-stream instruction count: each block contributes `1 + length(b.instructions) + 1` (the entry and exit markers plus its body). Derived, not stored — useful as a `pc` upper bound. Counts the *lowered* program, so it does not match the raw `ParsedIR` instruction count (edge-split adds trampoline blocks and synthetic `Define`s).

---

## `initial_state`

```julia
initial_state(prog::VMProgram, input::AbstractDict)::RState
```

`src/interpreter/Interpreter.jl:170`. Builds the starting `RState`: `pc` = entry block forward address, the active register file seeded from `input` (coerced to `Int64`), `status = :running`, empty memory/revmap, empty history, `step_count = 0`, `initial = deepcopy(current)`.

| Argument | Type | Meaning |
| --- | --- | --- |
| `prog` | `VMProgram` | A non-empty lowered program. |
| `input` | `AbstractDict` | Entry-parameter bindings, keyed by argument SSA-name `Symbol`, values coerced to `Int64`. |

**Raises** (Rule 1) on an empty-blocks program, an unresolvable `entry_label`, or a key mismatch: when the entry marker is a `BeginInstruction`, `Set(keys(input))` must equal `Set(params)`.

> `initial_state` takes **two** arguments. The single-arg `initial_state(prog)` shown in older PRD / README copy is stale and will not run.

---

## `run!`

```julia
run!(s::RState, prog::VMProgram;
     max_steps::Int = 10_000,
     checkpoint_interval::Int = 64,
     must_cache_set::Set{Tuple{Symbol,Int}} = Set(),
     replay_mode::Bool = false)
```

`src/interpreter/Interpreter.jl:1674`. Forward driver: loops `step!` (forwarding all kwargs) while `!is_halted(s)`. Mutates `s` in place. **Raises descriptively** (with `pc` and `status`) if `max_steps` is exceeded — it does *not* reset state, leaving `s` mid-run for inspection or `unrun!`. No silent partial return.

| Keyword | Type | Default | Meaning |
| --- | --- | --- | --- |
| `max_steps` | `Int` | `10_000` | Loud step budget. |
| `checkpoint_interval` | `Int` | `64` | L3 full-snapshot period `K` (must be `> 0`). |
| `must_cache_set` | `Set{Tuple{Symbol,Int}}` | `Set()` | Body slots opted into L2 delta history (from `compute_must_cache`). |
| `replay_mode` | `Bool` | `false` | Suppress L2 **and** L3 pushes (used internally during reverse replay). |

---

## `step!`

```julia
step!(s::RState, prog::VMProgram;
      checkpoint_interval::Int = 64,
      must_cache_set::Set{Tuple{Symbol,Int}} = Set(),
      replay_mode::Bool = false)::RState
```

`src/interpreter/Interpreter.jl:888`. Advances one instruction, mutating `s` in place and returning it. Order: no-op return if `status !== :running`; resolve the instruction at `pc`; `forward(instr, s.current)` mutates in place; cross-block / call dispatch; halt detection (set `:halted` on the entry routine's `EndInstruction`); then `step_count += 1` and the **three-layer history push gate** — L1 no-log for injective instructions, L2 `DeltaEntry` for must-cache / unconditional-L2 slots, else L3 `CheckpointEntry` every `K` steps. The push happens *after* `forward` (forward-before-push invariant); kwargs match `run!`'s history kwargs.

`step_count` increments on every successful forward step (even injective ones that push nothing); it is decoupled from `length(history)`.

---

## `is_halted`

```julia
is_halted(s::RState)::Bool
```

`src/interpreter/Interpreter.jl:284`. Returns `s.current.status === :halted`. The `run!` loop terminator and the `unrun!` halt-boundary check.

---

## `result`

```julia
result(s::RState)
```

`src/interpreter/Interpreter.jl:324`. Returns `copy(active_locals(s.current))` — a copy of the halted register file (`Dict{Symbol,Int64}`). The copy means callers cannot corrupt live interpreter state. **Raises** (Rule 1) if `!is_halted(s)`, naming the actual status.

---

## `unstep!`

```julia
unstep!(s::RState, prog::VMProgram)::RState
```

`src/history/Replay.jl:294`. Reverses exactly one step. **Raises** if `step_count <= 0`. Two paths producing the same result:

- **L2 fast path** — if the top of `history` is a `DeltaEntry` whose `step == s.step_count`, pop it, call `inverse(entry.instruction, s.current, entry.payload)`, decrement `step_count` (O(1)).
- **L3 path** — otherwise restore the nearest `CheckpointEntry` at or before the target (or fall back to `s.initial`), `deepcopy` it into `s.current`, truncate later history, and replay `step!` forward to the target with `checkpoint_interval = typemax(Int)` and `replay_mode = true` (no spurious pushes).

Reverse execution is checkpoint-replay, not per-instruction `inverse` — most non-injective instructions' `inverse` deliberately raises and is off this path.

---

## `unrun!`

```julia
unrun!(s::RState, prog::VMProgram; max_unsteps::Int = 10_000)::RState
```

`src/history/Replay.jl:709`. Backward driver: loops `unstep!` while `step_count > 0`, then asserts `isempty(s.history)`. **Raises descriptively** if `max_unsteps` is exceeded, leaving `s` mid-reverse.

| Keyword | Type | Default | Meaning |
| --- | --- | --- | --- |
| `max_unsteps` | `Int` | `10_000` | Loud reverse-step budget. |

**Round-trip contract.** After `run!(s, prog)` then `unrun!(s, prog)`: `s.step_count == 0`, `isempty(s.history)`, and `s.current == s.initial`. `unrun!` asserts the first two structurally; `current == initial` (which relies on the content-comparing `Base.==`/`Base.hash` on `RState`/`IState`) is left to the caller's round-trip test by design.

---

## A complete round-trip

```julia
using Bennett, BennettVM

# Lower a plain Julia function to a reversible VM program.
prog = reversible_compile(x -> x + Int8(1), Int8; target=:reversible_vm)
prog isa VMProgram          # true
n_instructions(prog)        # flat-stream instruction count

# Build the starting state. The Dict key is the entry parameter's SSA name
# (the argument name); values are coerced to Int64.
input = Dict(:x => 41)      # :x is illustrative — use the real entry param name
s = initial_state(prog, input)

run!(s, prog)               # forward to :halted
is_halted(s)                # true
answer = result(s)          # copy of the halted register file (Dict{Symbol,Int64})

unrun!(s, prog)             # roll back to the initial state
s.step_count == 0           # true
isempty(s.history)          # true
s.current == s.initial      # true (content equality)
```

There is no one-shot compile-and-run helper exposed from Bennett.jl; execution is entirely through this exported surface.

---

## Internal types you will touch

These are **not exported** but you read their fields when inspecting state. Reach them as `BennettVM.IState`, `BennettVM.RState`, `BennettVM.active_locals`.

### `IState`

`mutable struct`, `src/ir/IState.jl:257`. The per-step snapshot `step!` / `unstep!` mutate.

```julia
mutable struct IState
    pc::Int
    frames::Vector{Frame}        # call stack; never empty
    status::Symbol               # :running / :halted / :error
    memory::Dict{Int64,Int64}    # sparse cell-addressed Int64 heap (absent ⇒ 0)
    revmap::Dict{Int64,Int64}    # reversible-map register (ADR 0008)
    heap_top::Int64              # dynamic-alloca bump cursor
    arena_top::Int64             # malloc-arena bump cursor (ADR 0018)
    stack_top::Int64             # call-stack bump cursor (CW-C3)
end
```

| Field | Type | Meaning |
| --- | --- | --- |
| `pc` | `Int` | Flat-stream program counter. |
| `frames` | `Vector{Frame}` | Call stack. **There is no flat `locals` field** — the active register file is `frames[end].locals`. |
| `status` | `Symbol` | `:running`, `:halted`, or `:error`. |
| `memory` | `Dict{Int64,Int64}` | Cell-addressed heap (one `Int64` per cell, not byte-addressed); absent key ⇒ 0. |
| `revmap` | `Dict{Int64,Int64}` | Reversible-map ADT register. |
| `heap_top` / `arena_top` / `stack_top` | `Int64` | Bump cursors for dynamic-alloca / malloc-arena / call-stack segments; default 0 and round-trip 0 → … → 0. |

`IState` defines content-comparing `Base.==` / `Base.hash` over its fields. This is **mandatory**: Julia's default identity-compares the `Dict` fields, under which the round-trip `current == initial` would silently never hold.

### `RState`

`mutable struct`, `src/ir/RState.jl:253`. The trajectory wrapper the engine pivots on.

```julia
mutable struct RState
    current::IState
    history::Vector{AbstractHistoryEntry}
    step_count::Int
    initial::IState
end
```

| Field | Type | Meaning |
| --- | --- | --- |
| `current` | `IState` | The live snapshot the next `step!` / `unstep!` operates on. |
| `history` | `Vector{AbstractHistoryEntry}` | The reversibility tape (`DeltaEntry` / `CheckpointEntry`); empty after a full `unrun!`. |
| `step_count` | `Int` | Count of successful forward steps; canonical, decoupled from `length(history)`. |
| `initial` | `IState` | Step-0 anchor pinned (deepcopied) at construction; `unstep!` falls back to it past the first checkpoint. |

`RState` also carries content-comparing `Base.==` / `Base.hash` over all four fields — same reason as `IState`.

### `active_locals`

```julia
active_locals(s::IState) = s.frames[end].locals
```

`src/ir/IState.jl:363`. The accessor for the active register file (`Dict{Symbol,Int64}`, keyed by SSA name). `result(s)` returns a copy of `active_locals(s.current)`. For a single-function program the stack has exactly one frame, so this is the bottom (`:__entry`) frame's dict.

---

## Not exported

Public API is the ten symbols above and nothing else. The following are intentionally internal — reach them as `BennettVM.X`:

- **Types:** `IState`, `RState`, `Frame`, `BasicBlock`, `LabelTable`, `FunctionEntry`, `AbstractHistoryEntry`, `DeltaEntry`, `CheckpointEntry`.
- **Instructions:** the abstract `Instruction` / `ControlInstruction` and ~34 concrete subtypes (`Define`, `ArithmeticAssignment`, `CastInstruction`, `SelectInstruction`, `SwapInstruction`, `SoftCall`, the `Memory*` ops, `IRMapInsert`/`IRMapDelete`/`IRMapGet`, `CallEnter`/`ReturnExit`, the heap intrinsics, and the six `*Instruction` / `*Entry` / `*Exit` control markers).
- **Passes & traits:** `_lower_parsed_ir`, `is_injective`, `compute_must_cache`, `must_cache`, `active_locals`, and the flat-stream resolvers `_instruction_at` / `_block_index_at`.

---

## See also

- [`bennettvm_prd.md`](../../../bennettvm_prd.md) — PRD v4, the controlling spec.
- ADR [0003](../../adr/0003-target-reversible-vm-dispatch.md) — the `target=:reversible_vm` dispatch hook.
- [`docs/coverage-matrix.md`](../../coverage-matrix.md) — Bennett.jl IR-instruction coverage.
- [`BENNETT_JL_PIN.md`](../../../BENNETT_JL_PIN.md) — the single source of truth for the tested-against Bennett.jl commit (cite this file rather than pasting a SHA).
- [`README.md`](../../../README.md) — project overview.
