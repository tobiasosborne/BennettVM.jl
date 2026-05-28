"""
    lower_vm(parsed::Bennett.ParsedIR; opts=nothing) :: VMProgram

Phase-2 lowering entry point: consume a Bennett.jl `ParsedIR` and produce
a runnable `VMProgram`. **M_UNBOUNDED.1 — the real pass** (bd
`bennettvm-c39`, ADR 0012). Replaces the M0.2 digest-only stub: it now
delegates to `_lower_parsed_ir` (`src/ir/ingest.jl`), which translates
the input CFG of `IRBasicBlock`s into paired-Entry/Exit `BasicBlock`s
whose **forward** `run!` reproduces the irreversible Julia oracle
bit-for-bit (verified on `collatz_steps`, the PRD v4 §3.6.2 Case D
load-bearing motivating case).

# Handoff A contract (PRD v4 §3.7)

BennettVM consumes Bennett.jl's `ParsedIR` *unchanged*. The Bennett.jl
pin is `877341e` and Rule 14 forbids mutation of `../Bennett.jl/src/`.
The ingest pass touches `args` (for the routine's formal params + arg
widths), `blocks` (the CFG it lowers), and `ret_elem_widths` (the
`return_widths` metadata). `globals`, `memssa`, and
`synth_ptr_provenance` are deliberately not inspected — they belong to
memory-aware passes (a later milestone) and the collatz slice does not
need them.

# What the lowering does (ADR 0012 §D1–D5; see `src/ir/ingest.jl`)

  * `IRBinOp` / `IRICmp` → `Define` (the non-destructive SSA-create;
    comparisons carried per §D2).
  * `IRSelect`           → `SelectInstruction` (the reversible 2-to-1 MUX).
  * `IRPhi`              → a block **parameter** (φ on joins, Mogensen
    RSSA §3); resolved by the M3.6 args→params rename.
  * `IRBranch`           → `Conditional`/`UnconditionalExit` plus a
    **critical-edge-split trampoline** per edge, so each edge carries
    its own φ-arg list (the single-arg-list-to-two-targets problem).
  * `IRRet`              → the routine's `EndInstruction.returns`.
  * Constant φ-incomings → synthetic `Define(:_phi_const_…, v, :add, 0)`
    in the predecessor block (§D5).

The routine is framed by `BeginInstruction(:<routine>, [arg names])` on
the entry block and `EndInstruction(:<routine>, [ret name])` on the
ret block.

# Routine name

`opts` may be `nothing` (default) or a `Symbol` naming the routine; when
`nothing`, the routine name defaults to `:main` (matching the historical
empty-blocks-stub `entry_label`). The name is metadata on the Begin/End
markers and the `BeginInstruction.params` validation in
`initial_state`; it does not affect forward execution otherwise.

# The digest (preserved, now computed from the real output)

The M0.2 four-line digest STDOUT is preserved for M0.4 ADR transcription
and `grep`-friendliness, but the numbers are now read off the **lowered**
`VMProgram` (block + instruction counts after critical-edge splitting),
not the raw `ParsedIR`. A future agent comparing the digest to the raw
ParsedIR block count should expect them to differ: the lowered program
has more blocks (one trampoline per CFG edge) and more instructions
(synthetic constant creates + the per-block entry/exit markers).

# Width note (ADR 0012 R1)

`locals` are `Int64`; the lowering does not mask to the IRInst `width`.
Oracle agreement holds for inputs whose trajectory stays in the source
width's range; the round-trip invariant is width-independent. Per-width
masking is a follow-up bead.

Ref: docs/adr/0012-collatz-lowering.md §D1–D5
     src/ir/ingest.jl — `_lower_parsed_ir` (the real pass body)
     /home/tobias/Projects/Bennett.jl/src/ir_types.jl:299-372 (ParsedIR shape)
     bennettvm_prd.md §3.7 (Handoff A), §3.6.2 Case D, §6 SC9
"""
function lower_vm(parsed::Bennett.ParsedIR; opts=nothing)::VMProgram
    routine = opts isa Symbol ? opts : :main
    prog = _lower_parsed_ir(parsed, routine)

    # Digest, computed from the lowered VMProgram (post-edge-split).
    # Multi-line, two-space-indented, grep-friendly — the M0.4 ADR
    # transcription anchor. `println` over a single string preserves
    # order and avoids `@info`'s `[ Info: ` decoration.
    println("lower_vm digest:")
    println("  blocks       = ", length(prog.blocks))
    println("  instructions = ", n_instructions(prog))
    println("  args         = ", prog.arg_widths)
    println("  returns      = ", prog.return_widths)

    return prog
end
