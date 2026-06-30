# What BennettVM is — and why a circuit is not enough

*The design rationale for BennettVM: why Bennett.jl needs a second backend, what a reversible virtual machine buys you that a fixed circuit cannot, and how the two targets relate.*

[Bennett.jl](https://github.com/tobiasosborne/Bennett.jl) — the upstream project — compiles a plain Julia
function into a *fixed reversible circuit*: a sequence of NOT, CNOT and Toffoli gates,
built by Bennett's 1973 construction so that every ancilla returns to zero. That is
exactly the right artifact for a quantum oracle. But it has a hard structural ceiling,
and BennettVM exists to lift it.

## Why a VM

A fixed reversible circuit is a **permutation**. It maps a bit-vector of one fixed width
to another bit-vector of the same width, bijectively. Everything about it is decided at
compile time:

- **There is no program counter.** A circuit is a static gate list. It does not "loop";
  the only way to express repetition is to *unroll* it into more gates. The trip count
  must therefore be a compile-time constant.
- **There is no runtime-sized memory.** Every wire is allocated up front. A circuit
  cannot grow a stack, push onto a heap, or size an array by a value it only learns at
  run time.

Together these mean a circuit can only encode computations whose entire *shape* — how
many iterations, how much memory — is fixed before any input arrives. A `while` loop
whose length the *input* decides cannot be a circuit at all. Neither can a function that
allocates `n` cells where `n` is an argument, nor one that mutates a hash table whose
occupancy is data-dependent.

**BennettVM closes that gap.** Instead of lowering the program to a fixed permutation,
it lowers to a `VMProgram` — an instruction stream with real control flow — and *runs* it
on a reversible interpreter. The interpreter has the two things a circuit lacks: a program
counter (so it can branch and loop a data-dependent number of times) and runtime-sized
state (a sparse cell-addressed heap and bump cursors for the dynamic / arena / stack
segments). It executes the program forward, then walks it **backward** to the exact
initial state — no information lost — by carrying a history tape rather than relying on the
permutation structure of a gate list.

You select this backend with one keyword:

```julia
using Bennett, BennettVM

# Same frontend, different lowering target:
prog = reversible_compile(collatz_steps, Int64; target = :reversible_vm)   # → VMProgram
```

The default circuit path optimises an objective (`target = :gate_count`, the default, or
`target = :depth`) and returns a `ReversibleCircuit`. `target = :reversible_vm` is the only
value that switches *backends* — it returns a `VMProgram` instead. (There is no `:circuit`
symbol; "circuit" is just the default path.)

## The circuit-vs-VM split

Both backends share Bennett.jl's LLVM-IR frontend and diverge only at the lowering target:

```
                 ┌──── target = :gate_count / :depth ──►  fixed permutation circuit
Julia source ──► │  Bennett.jl frontend (LLVM IR → lowering)        (ReversibleCircuit)
                 └──── target = :reversible_vm ────────►  BennettVM   ◄── this repo
                                                           (VMProgram, run on an
                                                            interpreter + history tape)
```

The deep difference is *how reversibility is obtained*:

| | Fixed circuit (Bennett.jl) | BennettVM |
|---|---|---|
| Artifact | gate list (`ReversibleCircuit`) | instruction stream (`VMProgram`) |
| Control flow | none — loops are unrolled at compile time | a program counter; real branches and data-dependent loops |
| Memory | every wire allocated up front | runtime-sized: sparse `Int64` heap + bump cursors |
| Reversed by | running the same gate list backward (it *is* a permutation) | replaying a **history tape** backward (`unrun!`) |
| Right for | quantum oracles, statically-bounded kernels | unbounded / data-dependent / heap-using computations |

A circuit reverses *because* it is a permutation; the inverse is just the gate list read
right-to-left. A VM run is not a permutation on a fixed bit-vector — the state grows and
shrinks — so BennettVM earns reversibility a different way. It records a three-layer
history tape (PRD v4 §3.3): injective instructions log nothing (L1), instructions with a
cheap inverse record only the minimal value about to be destroyed (L2 `DeltaEntry`,
Enzyme-style min-cut), and everything else is reversed rr-style by snapshotting every
`K = 64` steps and deterministically replaying forward (L3 `CheckpointEntry`). This is
Bennett's 1973 *compute → copy → retrace*, generalised from a gate list to an interpreter.
The mechanism is its own topic — see [the reversibility model](reversibility_model.md).

What the user sees is a round-trip. You seed the entry parameters, run forward to a halt,
read the answer, then un-run back to the start:

```julia
s = initial_state(prog, Dict(:n => 27))   # key = entry parameter name; value coerced to Int64
run!(s, prog)                             # forward to halt, building the history tape
answer = result(s)                        # the register file at halt

unrun!(s, prog)                           # reverse every step back to the start
@assert s.current == s.initial            # exact round-trip …
@assert s.step_count == 0                 # … back at step 0 …
@assert isempty(s.history)                # … and the tape is empty again
```

That `run!` then `unrun!` returns the machine to its *exact* initial state is the
load-bearing correctness invariant, checked across the test suite. (The friendly,
runnable version of this lives in the [quick start](../getting_started/quickstart.md); the
full surface — all ten exported symbols — is in the [API reference](../reference/api.md).)

## The four motivating computations

BennettVM is driven by four cases a fixed circuit provably cannot handle (PRD v4 §3.6.2).
Each one fails the circuit ceiling for a different structural reason:

| Case | Program | Why a circuit can't | Status |
|------|---------|---------------------|--------|
| **A — `fdict`** | a `Dict` used as a reversible map | hash-table occupancy is data-dependent | in progress (closed-world `fdict` workstream) |
| **B — `frtN`** | a dynamic-size loop | trip count set by an argument | ingest landed |
| **C — `matrix_sum`** | nested loops | not statically unrollable at the LLVM level | ingest landed |
| **D — `collatz_steps`** | an unbounded `while` to a data-dependent fixpoint | no compile-time bound on iterations | ✅ end-to-end (M13) |

**Case D is the load-bearing one.** Scalar Collatz — `while n != 1` with a trip count the
input decides — round-trips end-to-end today through the public
`reversible_compile(…; target = :reversible_vm)` API. That capstone is milestone **M13**,
and it is complete: the canonical example a circuit *cannot* express now compiles, runs,
and un-runs.

The active 2026-mid frontier is Case A. The work is **closed-world extraction**
([ADR 0017](../../adr/0017-closed-world-execution.md)): acquiring the *internals* of
Julia's `Dict` so that a bare `fdict` round-trips straight from source, knocking down the
Bennett.jl-side extraction walls (pointer-cell width, heterogeneous sret) one at a time.

## Relationship to Bennett.jl

BennettVM is the **second lowering target** for Bennett.jl — not a fork, not a
replacement, and not a rewrite of the circuit backend. The two are *semantically distinct*:
one produces a fixed permutation, the other an interpreted reversible program. They are
kept deliberately separate and share exactly one thing — the LLVM-IR frontend
(`extract_parsed_ir → Bennett.ParsedIR`). The split happens at the lowering target, and
nowhere else.

The wiring is a load-time registration hook, not a package dependency cycle. Bennett.jl
never names BennettVM; the dependency arrow points up only. When you `using BennettVM`, its
`__init__` (`src/BennettVM.jl`) registers `lower_vm` into `Bennett._REVERSIBLE_VM_BACKEND`.
After that, a `:reversible_vm` compile is intercepted *before* the circuit pipeline and
handed to `lower_vm`, which returns a `VMProgram`. Until `using BennettVM` has run, a
`:reversible_vm` compile raises a clear "requires `using BennettVM`" error — never a silent
fallback to a circuit. The mechanics of that handoff (the `ParsedIR` contract, the `__init__`
hook, the dispatch arm) are covered in [integration with Bennett.jl](integration.md) and
[ADR 0003](../../adr/0003-target-reversible-vm-dispatch.md).

The lowered instruction set tracks the frontend closely: BennettVM's ~34 RSSA-derived
`Instruction` subtypes (six of them control-flow markers) cover **18 of Bennett.jl's 20
`IRInst` types** — the other two are not applicable to a cell-addressed VM. The mapping is
tracked opcode-by-opcode in [the coverage matrix](../../coverage-matrix.md), and the
instruction set and state model are explained in
[the instruction set](instruction_set.md).

The exact Bennett.jl commit this repository builds against is recorded in
[`BENNETT_JL_PIN.md`](../../../BENNETT_JL_PIN.md), which is the single source of truth for
the pin — cite that file rather than any SHA pasted elsewhere.

## Status

BennettVM is in **Phase 2 (production)**, in active development. PRD v4
([`bennettvm_prd.md`](../../../bennettvm_prd.md)) is the controlling spec, ratified
2026-05-25. The source tree holds the full VM — `ParsedIR → VMProgram` ingest (single- and
multi-function), the forward interpreter (`step!` / `run!`), the three-layer history with
checkpoint-replay reverse (`unstep!` / `unrun!`), SoftFloat dispatch, and a cell-addressed
heap with reversible calls and bounded intrinsics — across ~38 `src/*.jl` files and ~67
test files (~6,900 passing tests). Milestone M13 (the Collatz capstone) is complete.

> **A note on the spike.** Phase 0 was a *deliberately throwaway* Bennett-1973 trace VM,
> archived read-only as `spike-0-archived` under `spike/`. None of it was promoted —
> Phase 2 started from an empty tree built on PRD v4. The framing of BennettVM as a
> "spike" or "skeleton" is stale history; it is a production VM.

[`PHASE.md`](../../../PHASE.md) is the authoritative status and the source of truth for the
current phase and its gates; defer to it rather than to any status line embedded in source
docstrings (several of those predate Phase 2 and are out of date).
