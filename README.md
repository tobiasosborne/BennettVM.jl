# BennettVM.jl

[![License](https://img.shields.io/badge/License-MIT-7aa2f7.svg?style=flat-square)](LICENSE)
[![Julia](https://img.shields.io/badge/Julia-1.10%2B-9558B2.svg?style=flat-square)](https://julialang.org/)
[![Upstream](https://img.shields.io/badge/frontend-Bennett.jl-f24f4f.svg?style=flat-square)](../Bennett.jl)
[![Phase](https://img.shields.io/badge/phase-2_·_production-2ea043.svg?style=flat-square)](PHASE.md)

**The reversible-VM backend for [Bennett.jl](../Bennett.jl) — it runs a terminating
computation forward, then *un-runs* it step by step back to the start, with no
information lost.**

[Bennett.jl](../Bennett.jl) compiles a Julia function to a *fixed reversible circuit* —
the right artifact for a quantum oracle, but a circuit is a fixed permutation: it has no
program counter and no runtime-sized memory, so every loop must be statically bounded.
A `while` loop whose length the *input* decides — a Collatz orbit, a search to a
data-dependent fixpoint — cannot be a fixed circuit at all. **BennettVM is the second
lowering target that closes the gap:** a reversible *interpreter* that executes the
lowered program and can walk it backward to the initial state, carrying a three-layer
**history tape** instead of a fixed gate sequence.

```
                 ┌──────── target = :gate_count / :depth ──►  fixed permutation circuit
Julia source ──► │ Bennett.jl frontend (LLVM IR → lowering)
                 └──────── target = :reversible_vm ─────────►  BennettVM   ◄── this repo
```

The two backends are semantically distinct — not a fork, not a replacement. They share
Bennett.jl's LLVM-IR frontend and diverge at the lowering target.

## How it plugs into Bennett.jl

The integration is a load-time registration hook, not a package dependency cycle: when you
`using BennettVM`, its `__init__` registers `lower_vm` into `Bennett._REVERSIBLE_VM_BACKEND`.
After that, a `:reversible_vm` compile dispatches to the VM and returns a `VMProgram`
instead of a `ReversibleCircuit`:

```julia
using Bennett, BennettVM

prog = reversible_compile(collatz_steps, Int64; target = :reversible_vm)   # → VMProgram
```

Until `using BennettVM` runs, a `:reversible_vm` compile raises a clear "requires
`using BennettVM`" error — never a silent fallback to a circuit. End-to-end Collatz
round-trips through the VM today (milestone **M13**).

## Run a round-trip

A `VMProgram` is executed (and reversed) through the interpreter's four primitives —
`run!` / `unrun!` forward and backward, with `step!` / `unstep!` underneath:

```julia
using Bennett, BennettVM

prog = reversible_compile(collatz_steps, Int64; target = :reversible_vm)

s = initial_state(prog, Dict(Symbol("n::Int64") => 27))   # keyed by the lowered argument name
run!(s, prog)                             # forward to halt, building the history tape
answer = result(s)                        # the register file at halt

unrun!(s, prog)                           # reverse every step back to the start
@assert s.current == s.initial            # exact round-trip …
@assert isempty(s.history)                # … and the tape is empty again
```

`run!` then `unrun!` returns the machine to its *exact* initial state — that round-trip is
the load-bearing correctness invariant, checked across the test suite. Both drivers
fail loud on their step guards (`max_steps` / `max_unsteps`) and leave the machine
mid-flight for inspection; never a silent partial result.

## What's inside

The production VM is a small, auditable core:

| Piece | Role |
|-------|------|
| **`IState`** | one execution snapshot: `pc`, a `frames` call stack (the active register file is `frames[end].locals`), `status`, a cell-addressed `Int64` heap, a reversible-map register, and bump cursors for the dynamic / arena / stack segments |
| **`RState`** | the trajectory: `current` `IState`, the `history` tape, `step_count`, and the `initial` anchor |
| **History tape** | three layers (below) — the reversible record that lets `unstep!`/`unrun!` reconstruct any prior state |
| **Instruction set** | ~34 RSSA-derived `Instruction` subtypes (6 control-flow markers) covering 18 of Bennett.jl's 20 `IRInst` types |
| **`lower_vm`** | the ingest pass: `Bennett.ParsedIR` → `VMProgram` (φ-nodes → block params, critical-edge-split trampolines, a bump/arena/stack memory model, closed-world reversible calls) |

**Public API** (the 10 exported symbols): `VMProgram`, `lower_vm`, `n_instructions`,
`initial_state`, `is_halted`, `result`, `step!`, `run!`, `unstep!`, `unrun!`.

## The reversibility model

How does a non-injective step (a `Define` that overwrites a register, a store that clobbers
a cell) get reversed? With a **three-layer history tape** (PRD v4 §3.3), tried in order of
preference so the tape stays minimal:

1. **L1 — no log.** Injective instructions (swaps, the control markers, an `xor`-modop
   assignment, …) are bijections on the state they touch; reversing them needs *nothing*
   recorded. The `is_injective` trait gates the push.
2. **L2 — delta min-cut.** A non-injective instruction with a cheap inverse records only
   the *minimal* value its forward step is about to destroy — an Enzyme-style min-cut
   `DeltaEntry`. `unstep!` pops it and applies the per-instruction inverse directly.
3. **L3 — checkpoint + replay.** Everything else is reversed the robust way (rr-style):
   take a full snapshot every K=64 steps; to go backward, restore the nearest snapshot
   at-or-before the target and deterministically replay forward. The `initial` state is
   the step-0 anchor.

This is BennettVM's realisation of Bennett's 1973 compute → copy → retrace, generalised
to an interpreter: most instructions cost no history, the expensive ones are bounded by the
checkpoint interval, and correctness never depends on a hand-written inverse for every
opcode.

## The four motivating computations

BennettVM is driven by four cases a fixed circuit cannot handle (PRD v4 §3.6.2):

| Case | Shape | Status |
|------|-------|--------|
| **D — `collatz_steps`** | unbounded `while` to a data-dependent fixpoint | ✅ end-to-end (M13) |
| **C — `matrix_sum`** | nested loops | ingest landed |
| **B — `frtN`** | dynamic-size loop | ingest landed |
| **A — `fdict`** | a `Dict` as a reversible map | in progress (closed-world `fdict` workstream) |

Case D — the load-bearing gate — round-trips scalar Collatz end-to-end via the public
`reversible_compile(…; target = :reversible_vm)` API. The active 2026-mid workstream is
**closed-world extraction** (ADR 0017): acquiring the *internals* of Julia's `Dict` so a
bare `fdict` round-trips from source — knocking down Bennett.jl-side extraction walls
(pointer-cell width, heterogeneous sret) wall by wall.

## Status

**Phase 2 (production), in active development.** PRD v4 is the controlling spec
(ratified 2026-05-25). The source tree holds the full VM — ingest, interpreter, three-layer
history, a cell-addressed heap with reversible calls and bounded intrinsics — across ~38
`src/*.jl` files, with ~67 test files. Milestone M13 (the Collatz capstone) is complete;
the current frontier is the closed-world `fdict` epic. [`PHASE.md`](PHASE.md) is the
authoritative status; [`WORKLOG.md`](WORKLOG.md) is the session-by-session log.

> **A note on the spike.** Phase 0 was a *deliberately throwaway* Bennett-1973 trace VM
> (eight bytecodes, `Int64` only), archived read-only as `spike-0-archived` under
> `spike/`. None of it was promoted — Phase 2 started from an empty tree built on PRD v4.
> Three lessons from it are load-bearing in production and worth knowing:
>
> 1. **`Base.==`/`Base.hash` on the state must content-compare.** Julia's default `==`
>    identity-compares `Dict` fields, so without the overrides the round-trip invariant
>    silently never holds. (Encoded in `IState`'s equality.)
> 2. **Forward before push.** `step!` runs `forward()` and only *then* records history —
>    the reverse ordering corrupts the tape on a throwing step.
> 3. **Test the per-step inverse, not just the aggregate.** A leading instruction's inverse
>    can mask corruption left by a mid-stream one; snapshot every pre-step state and assert
>    per-step on the way back.

## Architecture

```
Bennett.jl ParsedIR
        │  lower_vm  (src/ir/ingest.jl)
        ▼
   VMProgram ── blocks · LabelTable · FunctionEntry table
        │  initial_state(prog, input)
        ▼
   RState{ current::IState, history, step_count, initial }
        │  run! / step!  ──►  forward + 3-layer history push
        │  unrun! / unstep!  ◄──  L2 delta fast-path | L3 checkpoint-restore + replay
        ▼
   result(s)              (forward answer; unrun! returns to s.initial)
```

| Path | What |
|------|------|
| `src/ir/` | the instruction set, the `IState`/`RState` state model, `VMProgram`, and the ingest pass (`ingest.jl`, `ingest_body.jl`, `ingest_call.jl`, `ingest_phi.jl`, …) |
| `src/history/` | the three-layer tape: `Injective.jl` (L1), `delta.jl` (L2), `CheckpointEntry.jl` (L3), `Replay.jl` (`unstep!`/`unrun!`) |
| `src/interpreter/` | the forward engine (`step!`/`run!`) and cross-block / call dispatch |
| `src/analysis/` | the min-cut liveness pass that selects L2 slots |
| `src/lower_vm.jl` | the registered backend entry point |
| `docs/adr/` | the architecture decision records (the real design rationale) |
| `bennettvm_prd.md` | PRD v4 — the controlling specification |

The in-source docstrings, the ADR set, and `docs/coverage-matrix.md` (which tracks the
`IRInst` → instruction coverage) are the authoritative design record.

## Documentation

A [Diátaxis](https://diataxis.fr)-structured site under [`docs/src/`](docs/src/) — build
with `julia --project=docs docs/make.jl`, or read the Markdown directly:

- **Learn** — [quick start](docs/src/getting_started/quickstart.md)
- **Understand** — [what BennettVM is](docs/src/explanation/what_is_bennettvm.md) ·
  [the instruction set & state model](docs/src/explanation/instruction_set.md) ·
  [the reversibility model](docs/src/explanation/reversibility_model.md) ·
  [integration with Bennett.jl](docs/src/explanation/integration.md)
- **Look up** — [API reference](docs/src/reference/api.md)

## Reading order

1. [`bennettvm_prd.md`](bennettvm_prd.md) — PRD v4, the controlling document.
2. [`CLAUDE.md`](CLAUDE.md) (= `AGENTS.md`) — the Laws, the Rules, phase discipline.
3. [`PHASE.md`](PHASE.md) — current phase and gates.
4. [`../Bennett.jl/README.md`](../Bennett.jl) — the upstream frontend.
5. [`docs/adr/`](docs/adr/) — the decision records for whatever subsystem you touch.
6. [`WORKLOG.md`](WORKLOG.md) — session history and the next-agent brief.

The Bennett.jl version this repo builds against is recorded in
[`BENNETT_JL_PIN.md`](BENNETT_JL_PIN.md) (the single source of truth for the pin).

## Acknowledgements

Builds on five decades of reversible-computing literature — Bennett (1973, 1989), Knill
(1995) on the pebble game, Mogensen's RSSA, the Pendulum / BobISA reversible ISA, Enzyme's
min-cut history selection (Moses & Churavy 2020), and rr-style record-and-replay
(O'Callahan 2017). See `bennettvm_prd.md` Part II for the full reading list. The closest
existing analogue is the [RC3](https://git.thm.de/thm-rc3/release) Janus toolchain, which
BennettVM learns from rather than rebuilds (RC3 does compile-time RSSA reversal; BennettVM
keeps a runtime history tape).

## License

[MIT](LICENSE).
