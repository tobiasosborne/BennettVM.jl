# How `target=:reversible_vm` reaches BennettVM

*Why a `reversible_compile(...; target=:reversible_vm)` call lands in this package at all — the load-time hook that wires the two repos together without a dependency cycle, and the IR contract that crosses the seam.*

## Two backends, one frontend

[Bennett.jl](https://github.com/tobiasosborne/Bennett.jl) has a single LLVM-IR frontend and two lowering targets. The default path (`target=:gate_count` or `:depth`) lowers a Julia function to a *fixed reversible circuit* — a permutation with no program counter and no runtime-sized memory, so every loop has to be statically bounded. BennettVM is the **second** target: a reversible *interpreter* that runs the lowered program forward and then un-runs it, carrying a three-layer history tape instead of a fixed gate sequence. That is what lets it execute a data-dependent `while` — a Collatz orbit, a search to a fixpoint — which cannot be a fixed circuit at all.

The two backends are semantically distinct, and they diverge at exactly one decision: the value of the `target` keyword. Everything before that point — `code_llvm`, the C-API walk, the `ParsedIR` — is shared Bennett.jl machinery. This page is about the *seam*: how the `target=:reversible_vm` value, chosen in Bennett.jl, ends up calling code in this repository.

A subtlety worth pinning down first, because the stale docs get it wrong: **there is no `:circuit` symbol.** `target` is otherwise an optimization *objective* whitelisted to `(:gate_count, :depth)` — the only value that selects a *backend* is `:reversible_vm`. The "`:circuit`" you may see in old diagrams is illustrative shorthand for the default circuit path, never a real dispatch symbol.

## The registration hook (no dependency cycle)

The hard constraint shaping the whole design: **Bennett.jl must never name BennettVM.** The dependency arrow points up only — BennettVM depends on Bennett, and a reverse hard-dep would be a forbidden cycle (and a packaging headache, since Bennett.jl ships independently as a quantum-oracle compiler that should not pull in an interpreter it does not need).

The resolution is a runtime *registration* hook rather than a compile-time dependency. On the Bennett.jl side there is a single mutable slot, initialized empty:

```julia
# Bennett.jl/src/Bennett.jl
const _REVERSIBLE_VM_BACKEND = Ref{Any}(nothing)
```

BennettVM fills that slot at **load time** from its module initializer (`src/BennettVM.jl`):

```julia
function __init__()
    Bennett._REVERSIBLE_VM_BACKEND[] = lower_vm
end
```

Three things make this the right hook:

- It runs in `__init__`, *after* the module image loads — not during precompilation, where cross-module global mutation is illegal. So the assignment is legal and happens exactly once per process (idempotent under repeated loads / Revise).
- BennettVM reaches the Bennett name because it does `import Bennett` (by type only — never `using`), which keeps every upstream reference spelled `Bennett.<Name>` and makes the Handoff-A contract visually auditable. Bennett.jl, for its part, never writes the string `BennettVM` anywhere.
- The registered value is the function `lower_vm` itself, stored as `Any`. Bennett.jl calls it indirectly through the `Ref`; it never needs the concrete type.

The consequence is that the seam is *inert until you load the backend*. Without `using BennettVM`, `_REVERSIBLE_VM_BACKEND[]` is still `nothing`, and a `:reversible_vm` compile fails loudly rather than silently — it tells you to `using BennettVM` to register the backend.

## The interception point

With the slot filled, the dispatch happens inside `reversible_compile(::Bennett.ParsedIR; ...)`. The `:reversible_vm` arm sits *before* the circuit pipeline and before the compile cache:

```julia
# Bennett.jl/src/Bennett.jl — reversible_compile(parsed::ParsedIR; ...)
if target === :reversible_vm
    _REVERSIBLE_VM_BACKEND[] === nothing && error(
        "reversible_compile(target=:reversible_vm) requires the BennettVM " *
        "backend to be loaded: `using BennettVM` registers it. ...")
    return _REVERSIBLE_VM_BACKEND[](parsed)   # → BennettVM.VMProgram
end
```

Two design points are load-bearing here:

1. **It intercepts before `_compile_cache`.** That cache is a `Dict{Tuple,ReversibleCircuit}`; the VM arm returns a `VMProgram`, a different type entirely, so it must bypass the cache rather than poison it. (VM-program memoisation is a separate, later concern.)
2. **The circuit-optimization carve-outs are guarded against the VM path.** Bennett.jl can short-circuit a compile into a QROM/tabulate lookup (an explicit-tabulate route, and an `:auto` cost-model diversion). Both are gated by `target !== :reversible_vm` so that a VM compile is never diverted away from the interpreter into a circuit-shaped lookup table.

So from the caller's point of view the whole integration is one keyword:

```julia
using Bennett, BennettVM   # the `using BennettVM` is what arms the seam

prog = reversible_compile(collatz_steps, Int64; target = :reversible_vm)
# prog isa BennettVM.VMProgram  — not a ReversibleCircuit
```

## `lower_vm`: the ingest entry and its IR contract

The registered backend is `lower_vm`, defined in `src/lower_vm.jl`:

```julia
lower_vm(parsed::Bennett.ParsedIR; opts=nothing)::VMProgram
```

Bennett.jl always calls it with one positional argument and no `opts`, so the user-facing path always lowers a routine named `:main`. (`opts` may name the routine for hand-built inputs; there is also a multi-function method `lower_vm(funcs::Vector{<:Pair{Symbol,ParsedIR}}; ...)` for `.ll`/`.bc` call graphs, which Bennett's single-function `ParsedIR` never reaches.) `lower_vm` is a thin wrapper: it delegates to `_lower_parsed_ir` in `src/ir/ingest.jl` and emits a `@debug` digest. The digest is `@debug`-gated on purpose — `lower_vm` runs on *every* `:reversible_vm` compile, and an unconditional `println` would spam stdout and pollute `Pkg.test()`. It is silent unless `JULIA_DEBUG=BennettVM`.

The interesting part of the contract is **which `ParsedIR` fields cross the seam.** `ParsedIR` (defined in `Bennett.jl/src/ir_types.jl`) has seven fields, but the ingest pass consumes only three:

| Field | Consumed? | Role in lowering |
| --- | --- | --- |
| `args::Vector{Tuple{Symbol,Int}}` | yes | formal parameter names + arg widths → entry-block params |
| `blocks::Vector{IRBasicBlock}` | yes | the CFG it lowers, block by block |
| `ret_elem_widths::Vector{Int}` | yes | → `VMProgram.return_widths` |
| `ret_width::Int` | no | (return width derived per-element instead) |
| `globals` | no | memory-aware passes, a later milestone |
| `memssa` | no | "" |
| `synth_ptr_provenance` | no | "" |

This is a deliberately narrow handshake — the documented "Handoff A" contract from PRD v4 §3.7. BennettVM consumes Bennett's `ParsedIR` *unchanged*; it does not reach into globals, MemorySSA, or pointer-provenance metadata. Each `IRBasicBlock` is a `label` plus a vector of non-terminator `IRInst`s plus a terminator (`IRBranch` or `IRRet`).

What `_lower_parsed_ir` does with those blocks is the subject of [ADR 0012](../../adr/0012-collatz-lowering.md); in brief, it translates the `IRBasicBlock` CFG into paired Entry/Exit `BasicBlock`s and maps each IR instruction to a VM instruction:

- `IRBinOp` / `IRICmp` → `Define` (the non-destructive SSA-create);
- `IRSelect` → `SelectInstruction`; `IRCast` → `CastInstruction`;
- `IRStore`/`IRLoad`/`IRVarGEP` → the memory instructions; `IRMapInsert`/`IRMapGet`/`IRMapDelete` → the reversible-map ops;
- `IRPhi` → a block **parameter**, not a body instruction — CFG edges are split into per-edge trampoline blocks and the positional-args-to-params rename *is* the φ merge;
- `IRBranch` → `Conditional`/`UnconditionalExit`; `IRRet` → the routine's `EndInstruction.returns`.

The result is a `VMProgram` whose forward `run!` reproduces the irreversible Julia oracle bit-for-bit, and which can be walked backward to its initial state. The coverage today is 18 of Bennett.jl's 20 `IRInst` types (see [`docs/coverage-matrix.md`](../../coverage-matrix.md)); the round-trip and execution surface — `initial_state`, `run!`, `result`, `unrun!` — is documented in the [API reference](../reference/api.md).

## The version pin

Because the two repos live side by side (`../Bennett.jl` is a path dependency, so the working tree is authoritative), there is no package-registry version to pin against. Instead the tested-against Bennett.jl commit is recorded in **[`BENNETT_JL_PIN.md`](../../../BENNETT_JL_PIN.md)** at the repo root, which is the *single source of truth* for the pin. Several older docstrings (including `lower_vm.jl`'s own header and the BennettVM README file map) quote a stale SHA inline — do not trust those; cite the pin file, not a pasted hash.

The pin moves additively. The discipline is that BennettVM only repins when an *additive* Bennett.jl frontend change is required for a new feature — the file records each repin with its date, the Bennett.jl HEAD summary, the motivating bead, and a full `Pkg.test` validation count on both sides. This insulates BennettVM development from unrelated frontend churn while keeping the seam reproducible.

## Proof the seam works: the M13 Collatz e2e

The integration is not asserted, it is *exercised*. Milestone M13 (`test/test_e2e_collatz.jl`) compiles an unbounded `while`-loop Collatz oracle through the *real* dispatch arm and round-trips it:

```julia
using Bennett, BennettVM

vm = Bennett.reversible_compile(collatz_steps, Int64; target = :reversible_vm)
@assert vm isa VMProgram

# The input is a Dict keyed by the entry-block parameter Symbols (the argument
# names); the test derives the key from the Begin marker rather than hard-coding
# it, since the extractor chooses the SSA name. Illustratively:
input = Dict(:x => Int64(27))        # arg name → coerced-Int64 value

rs = initial_state(vm, input)        # RState seeded from the input Dict
run!(rs, vm; max_steps = 10_000, checkpoint_interval = 8)

result(rs)[ret_key] == collatz_steps(Int64(27))   # forward answer == oracle (== 20)

unrun!(rs, vm)                       # walk the whole program backward
@assert rs.step_count == 0           # back to the start: counter reset
@assert isempty(rs.history)          # history tape fully drained
@assert rs.current == rs.initial     # exact initial state restored
```

This is the integration proof end to end: the `target=:reversible_vm` dispatch arm, `lower_vm`, the ingest pass, the forward interpreter, and the checkpoint-replay reverse all participate. The forward result is anchored against the irreversible Julia oracle (Rule 4: a passing test checks the actual answer, not just "ran without error"), and the reverse satisfies the round-trip invariant — `step_count==0`, empty history, `s.current == s.initial` — for every sampled input. Collatz is the load-bearing case precisely because its loop length is *input-decided*, which the circuit backend cannot represent at all.

## The current frontier: closed-world `fdict`

The active mid-2026 workstream pushes the seam from hand-shaped IR toward *bare, idiomatic source*. The motivating goal (ADR 0017, "closed-world reversible execution") is the north star where a programmer writes completely normal Julia/Rust/C — unbounded loops, floats, `Dict`s — with no side effects and no opaque syscalls, and the toolchain yields a reversible program with no manual annotation.

The obstacle surfaced by a 2026-06 probe of a bare `fdict`: at `optimize=false`, Julia's `Dict` backings are interned *globals* (the empty-Dict singleton), the *write* is an opaque callee (`setindex!`) the VM never sees the opcodes of, and only the `getindex` read is inlined. A circuit/interpreter cannot reverse a write whose body it cannot observe. [ADR 0017](../../adr/0017-closed-world-execution.md) chose Option C — extract and inline the opaque callees and model the global backings — and tracks four motivating cases: A (`fdict`), B (dynamic-loop `frtN`), C (nested-loop `matrix_sum`), and D (unbounded-`while` Collatz). **Case D is M13 — complete, end to end.** Case A, the bare `fdict` round-trip, is the case in progress, and it is what the closed-world fdict extraction work is currently driving toward.

---

**See also:** the [API reference](../reference/api.md) for the full execution surface; [PRD v4](../../../bennettvm_prd.md) §3.7 (Handoff A) for the integration contract; [ADR 0003](../../adr/0003-target-reversible-vm-dispatch.md) for the dispatch-hook decision record.
