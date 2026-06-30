# Quickstart: a reversible round-trip

*Compile a plain Julia function to a reversible VM program, run it forward to get an answer, then run it backward and watch the machine land exactly where it started.*

This is the shortest end-to-end path through BennettVM. By the end you will have a `VMProgram`, a forward result, and a verified round-trip — the invariant the whole VM exists to guarantee.

## Setup

BennettVM is the reversible-VM backend for **Bennett.jl** (the sibling package at `../Bennett.jl`). You load both:

```julia
using Bennett, BennettVM
```

Loading `BennettVM` runs its `__init__` hook (`src/BennettVM.jl:589`), which registers `lower_vm` as Bennett's reversible-VM backend (`Bennett._REVERSIBLE_VM_BACKEND[] = lower_vm`). That one line is what makes the `target=:reversible_vm` path below resolve. Without `using BennettVM`, asking Bennett for a `:reversible_vm` compile raises a loud *"requires `using BennettVM`"* error rather than silently doing the wrong thing.

## Compile

Take any plain Julia function on integers. We will use an unbounded Collatz step-counter — the canonical case the *circuit* backend cannot compile (it has a `while` loop with a data-dependent trip count), but the VM handles directly because it lowers the loop symbolically:

```julia
function collatz_steps(n::Int64)
    steps = Int64(0)
    val = n
    while val > 1
        if val % 2 == 0
            val = val >> 1
        else
            val = 3 * val + 1
        end
        steps += 1
    end
    return steps
end
```

Compile it with `target=:reversible_vm`. This intercepts *before* Bennett's circuit pipeline and hands you a `VMProgram` instead of a `ReversibleCircuit`:

```julia
prog = reversible_compile(collatz_steps, Int64; target=:reversible_vm)

prog isa BennettVM.VMProgram      # true
n_instructions(prog)              # total flat-stream instruction count
```

Under the hood, `reversible_compile` extracts the LLVM IR into a `Bennett.ParsedIR`, and the registered backend (`lower_vm`) lowers that into the `VMProgram` — paired entry/exit blocks, φ-nodes turned into block parameters, control edges split into trampolines. You do not touch any of that here; you just get a program you can run.

## Run forward, then backward

The execution surface is four verbs — `run!`/`unrun!` for whole-program forward/reverse, with `step!`/`unstep!` underneath for single instructions. You drive them through an `RState` (a reversible-execution *trajectory*: the live snapshot plus the history tape that lets the VM walk back).

```julia
# 1. Build the starting state. `initial_state` takes the program AND an input
#    Dict that binds the entry block's parameters.
s = initial_state(prog, Dict(Symbol("n::Int64") => Int64(27)))

# 2. Execute forward to completion.
run!(s, prog)
is_halted(s)        # true — the program reached its End marker

# 3. Read the answer: a copy of the active frame's register file
#    (a Dict{Symbol,Int64}); the return value lives among these registers.
answer = result(s)

# 4. Execute backward. Every instruction is undone in reverse order.
unrun!(s, prog)

# 5. The round-trip invariant: we are exactly back where we started.
@assert s.current == s.initial && isempty(s.history)
@assert s.step_count == 0
```

### A note on the input key

The `input` Dict is keyed by the **entry parameter name**, and BennettVM validates your keys against the entry block's parameters (`Set(keys(input))` must equal the parameter set) — a mismatch fails loud at `initial_state`, not later mid-run. The name is the function's argument as it appears in the lowered IR, which carries its type annotation: here `n::Int64` becomes `Symbol("n::Int64")`. If you are unsure of the exact spelling, hand `initial_state` any key and read the expected set straight out of the error message.

## What each call does

| Call | Role |
| --- | --- |
| `initial_state(prog, input)` | Builds the starting `RState` (`src/interpreter/Interpreter.jl:170`): resolves the entry block, validates `input` keys against the entry parameters, seeds the register file (values coerced to `Int64`), and deep-copies that snapshot into `s.initial` as the step-0 anchor. |
| `run!(s, prog)` | Forward driver (`Interpreter.jl:1674`): loops `step!` until the program halts. Raises (it does not silently stop) if `max_steps` is exceeded, leaving the state mid-run for inspection. |
| `is_halted(s)` | True once the entry routine's `End` marker has executed. |
| `result(s)` | Returns a *copy* of the active register file. Raises if the state is not halted (no silent partial results). |
| `unrun!(s, prog)` | Backward driver (`src/history/Replay.jl:709`): loops `unstep!` until `step_count == 0`, then asserts the history tape is empty. |

## The round-trip invariant

The assertion at the end is the heart of the VM. After `run!` then `unrun!`:

- `s.step_count == 0` — every forward step has been matched by a reverse step;
- `isempty(s.history)` — the history tape is fully consumed;
- `s.current == s.initial` — the machine state is *bit-for-bit identical* to where it began.

That last equality is non-trivial: `IState`/`RState` define content-comparing `==`/`hash` so two states are equal when their registers, memory, and cursors match — not merely when they are the same object. The reverse pass leaves no residue: scratch values are uncomputed, bump cursors return `0 → … → 0`, and ancilla-style state is cleaned. This is Bennett's 1973 construction realized as an interpreter — forward computes, backward un-computes, and the net effect on the machine is zero.

BennettVM gets there without re-running everything in reverse blindly. It keeps a three-layer history tape: injective instructions log nothing, most others store a minimal delta, and a full checkpoint is snapshotted periodically so reversal can restore-and-replay. You do not need to know which layer fired to use the round-trip — `unrun!` picks the right path for each step.

## Where to next

- **The why** — [the reversibility / round-trip invariant and the three-layer history tape](../explanation/reversibility_model.md) explain how the backward pass stays exact and cheap.
- **The full surface** — the [API reference](../reference/api.md) lists all ten exported symbols (`VMProgram`, `lower_vm`, `n_instructions`, `initial_state`, `is_halted`, `result`, `step!`, `run!`, `unstep!`, `unrun!`) with signatures and kwargs.
- **The integration boundary** — [ADR 0003](../../adr/0003-target-reversible-vm-dispatch.md) describes the `target=:reversible_vm` dispatch hook, and [ADR 0012](../../adr/0012-collatz-lowering.md) covers the Collatz lowering used above.
- **The controlling spec** — [`bennettvm_prd.md`](../../../bennettvm_prd.md) (PRD v4) is the source of truth for the VM's semantics.
