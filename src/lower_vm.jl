"""
    lower_vm(parsed::Bennett.ParsedIR; opts=nothing) :: VMProgram

Phase-2 lowering entry point: consume a Bennett.jl `ParsedIR` and produce
a `VMProgram`. **M0.2 stub** — walks the input, prints a four-field
digest, and returns a populated stub `VMProgram`. The real lowering
pass (RSSA basic-block construction, paired Entry/Exit synthesis,
LabelTable population) lands at M3.x onward.

# Handoff A contract (PRD v4 §3.7)

BennettVM consumes Bennett.jl's `ParsedIR` *unchanged*. The Bennett.jl
pin is `877341e` and Rule 14 forbids mutation of `../Bennett.jl/src/`.
Anything BennettVM needs from the upstream package must be expressible
in terms of `ParsedIR` fields and the `IR*` instruction structs defined
at `/home/tobias/Projects/Bennett.jl/src/ir_types.jl:347-372`:

```
struct ParsedIR
    ret_width::Int                                       # line 348
    args::Vector{Tuple{Symbol, Int}}                     # line 349
    blocks::Vector{IRBasicBlock}                         # line 350
    ret_elem_widths::Vector{Int}                         # line 351
    globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}    # line 356
    memssa::Union{Nothing, MemSSAInfo}                   # line 361
    synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}   # line 371
end

struct IRBasicBlock                                      # line 299
    label::Symbol
    instructions::Vector{IRInst}        # non-terminator instructions
    terminator::IRInst                  # IRBranch or IRRet
end
```

This stub touches only the four "shape" fields: `args`, `blocks`,
`ret_elem_widths`. `globals`, `memssa`, and `synth_ptr_provenance` are
deliberately not inspected here — they belong to memory-aware passes
(M3.x for globals, M4.x for memssa) and the smoke does not need them.

# Motivating cases (digest = pre-flight check for M0.4 ADR)

The four motivating-case `ParsedIR`s (PRD v4 §3.6.2 — `fdict`, `frtN`,
`matrix_sum`, `collatz_steps`) will each be piped through this stub at
M0.4, and the four digest lines per program will be transcribed into
the ADR. The digest is therefore the **first quantitative observation
of Phase-2 IR**: how big is a `collatz_steps` `ParsedIR`, how many
blocks does `matrix_sum` decompose into, how wide are their arguments?
M0.4 derives the Phase-2 IR sizing budget from these numbers.

The digest format is deliberately scannable by eye and `grep`-friendly
for M0.3's test:

```
lower_vm digest:
  blocks       = <N>
  instructions = <M>           # sum of non-terminator + terminator counts
  args         = [<w1>, <w2>, ...]
  returns      = [<w1>, <w2>, ...]
```

# What is deliberately stubbed

Everything past the digest. In particular:

  * No `BasicBlock` construction — M2.7.
  * No `LabelTable` synthesis — M2.10.
  * No Conditional{Entry,Exit} pairing — M2.8.
  * No instruction-level RSSA lowering — M3.x.
  * No history-layer planning — M4.x.
  * `opts` is accepted but ignored; its schema lands at M2.17 alongside
    the real `VMProgram`.

Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations (12-instruction taxonomy)
     /home/tobias/Projects/Bennett.jl/src/ir_types.jl:299-372
     bennettvm_prd.md §3.7 (Handoff A)
"""
function lower_vm(parsed::Bennett.ParsedIR; opts=nothing)::VMProgram
    # --- M0.2 digest walk ---
    # Block count: trivially `length(parsed.blocks)`.
    n_blocks = length(parsed.blocks)

    # Instruction count: per IRBasicBlock (ir_types.jl:299), the
    # non-terminator instructions live in `b.instructions::Vector{IRInst}`
    # and the terminator (`IRBranch` or `IRRet`) is a separate field.
    # Total dynamic instruction count therefore sums both — a block with
    # zero non-terminator instructions still has one terminator
    # (otherwise the block would be malformed; constructor would have
    # rejected it upstream).
    n_instructions = 0
    for b in parsed.blocks
        n_instructions += length(b.instructions) + 1  # +1 for terminator
    end

    # Argument widths: `args::Vector{Tuple{Symbol, Int}}` per ir_types.jl:349
    # — each tuple is (ssa_name, bit_width). The lowering pass only needs
    # the widths; names are an IR-layer concern.
    arg_widths = Int[w for (_name, w) in parsed.args]

    # Return widths: `ret_elem_widths::Vector{Int}` per ir_types.jl:351 —
    # `[8]` for an i8 scalar return, `[8, 8]` for a `[2 x i8]` aggregate.
    # Already the per-element vector, so a direct copy. (Using `copy` so
    # the VMProgram owns its slice and is independent of later mutation
    # of `parsed.ret_elem_widths` — defensive at near-zero cost.)
    return_widths = copy(parsed.ret_elem_widths)

    # --- Emit the digest ---
    # Multi-line block, indented two spaces, in the format M0.3's test
    # will grep. Using `println` over a single string preserves order and
    # avoids `@info`'s `[ Info: ` prefix decoration (which would force
    # the test to match a moving target if Julia's logging changes).
    println("lower_vm digest:")
    println("  blocks       = ", n_blocks)
    println("  instructions = ", n_instructions)
    println("  args         = ", arg_widths)
    println("  returns      = ", return_widths)

    # M2.17 reshape: VMProgram no longer stores `n_blocks` /
    # `n_instructions` as fields. The digest STDOUT above carries the
    # regression-anchor numbers (M0.3); the returned `VMProgram` uses
    # the empty-blocks digest-stub convenience constructor, which
    # populates `arg_widths` / `return_widths` (the authentic
    # ParsedIR-handoff metadata) and defaults `blocks` / `label_table`
    # / `entry_label` to empty / empty / `:main` until M3.x's full
    # lowering pass lands.
    return VMProgram(arg_widths, return_widths)
end
