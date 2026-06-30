```@meta
CurrentModule = BennettVM
```

# BennettVM.jl

*The reversible-VM backend for [Bennett.jl](https://github.com/tobiasosborne/Bennett.jl) —
it runs a terminating computation forward, then un-runs it step by step back to the start,
with no information lost.*

A reversible **circuit** is a fixed permutation: no program counter, no runtime-sized
memory, so every loop must be statically bounded. A `while` loop whose length the *input*
decides cannot be a fixed circuit at all. **BennettVM is the second lowering target** that
closes the gap — a reversible *interpreter* carrying a three-layer history tape instead of
a fixed gate sequence.

```
                 ┌──────── target = :gate_count / :depth ──►  fixed permutation circuit
Julia source ──► │ Bennett.jl frontend (LLVM IR → lowering)
                 └──────── target = :reversible_vm ─────────►  BennettVM
```

```julia
using Bennett, BennettVM

prog = reversible_compile(collatz_steps, Int64; target = :reversible_vm)   # → VMProgram

s = initial_state(prog, Dict(Symbol("n::Int64") => 27))   # keyed by the lowered argument name
run!(s, prog)                             # forward to halt
result(s)                                 # the answer
unrun!(s, prog)                           # reverse back to the start
@assert s.current == s.initial && isempty(s.history)
```

`run!` then `unrun!` returns the machine to its exact initial state — the load-bearing
correctness invariant.

## Documentation map

This site follows the [Diátaxis](https://diataxis.fr) structure.

**Learn**
- [Quick start](getting_started/quickstart.md)

**Understand**
- [What BennettVM is](explanation/what_is_bennettvm.md)
- [The instruction set & state model](explanation/instruction_set.md)
- [The reversibility model](explanation/reversibility_model.md)
- [Integration with Bennett.jl](explanation/integration.md)

**Look up**
- [API reference](reference/api.md)

## Status

Phase 2 (production), in active development. [`PHASE.md`](https://github.com/tobiasosborne/BennettVM.jl/blob/master/PHASE.md)
is authoritative; the controlling specification is `bennettvm_prd.md` (PRD v4). The
Collatz capstone (M13) is complete; the current frontier is closed-world `fdict`
extraction.

## Building these docs

```bash
cd docs
julia --project -e 'using Pkg; Pkg.develop(path="../../Bennett.jl"); Pkg.develop(path=".."); Pkg.instantiate()'
julia --project make.jl
```
