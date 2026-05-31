# test/test_handoff_smoke.jl — M0.3 Handoff-A integration smoke.
#
# # Why this test exists
#
# M0.3 (bd `bennettvm-c72`) is the load-bearing milestone that proves
# BennettVM can ingest a real Bennett.jl `ParsedIR` *unchanged* through
# the Handoff-A interface (PRD v4 §3.7). Without this end-to-end check,
# the M0.2 stub digest in `src/lower_vm.jl` could silently rot the next
# time Bennett.jl moves; we need a regression anchor whose numbers come
# from running `extract_parsed_ir` on a real Julia function, not from a
# hand-rolled `ParsedIR` literal.
#
# `collatz_steps(::Int8)` was chosen because it is PRD v4 §3.6.2 Case D
# — the unbounded `while` loop that the circuit backend cannot compile,
# and the load-bearing motivating case for SC9 (PRD v4 §6). If Handoff
# A breaks on Case D, BennettVM has no reason to exist; if M0.3 cannot
# even run `lower_vm` on its `ParsedIR`, every later milestone is built
# on sand. Asserting the digest fields here makes the failure mode
# visible at the very first `Pkg.test()` invocation rather than at M3.x.
#
# # How the ParsedIR is obtained
#
# Via `Bennett.extract_parsed_ir(collatz_steps, Tuple{Int8})`. This is
# the exported Phase-1 frontend entry (Bennett.jl `src/Bennett.jl:65`,
# `src/extract/entry.jl:41`); it routes Julia → LLVM IR via `code_llvm`
# and walks the result into `ParsedIR` (see Bennett.jl's
# `_module_to_parsed_ir`). Rule 14 forbids mutating Bennett.jl source
# but explicitly permits read-only consumption of its exported API.
#
# The body of `collatz_steps` is copied verbatim from
# `/home/tobias/Projects/Bennett.jl/test/test_y986_loop_header_dispatch.jl:129-140`
# so the two repos compute identical LLVM IR for identical input. The
# digest numbers below were captured by piping the resulting `ParsedIR`
# through `lower_vm` on Bennett.jl pin `877341e` (see
# `BENNETT_JL_PIN.md`); if a future Bennett.jl bump alters block layout
# for `collatz_steps`, these assertions go RED and the maintainer is
# forced to consciously re-pin or rebaseline — exactly the regression-
# anchor behavior CLAUDE.md Rule 4 demands.
#
# # What this asserts now (M_UNBOUNDED.1 — real lower_vm)
#
# M_UNBOUNDED.1 (`bennettvm-c39`, ADR 0012) replaced the M0.2 digest
# stub with the real `ParsedIR` → `VMProgram` ingest pass. This smoke
# now asserts the REAL lowered shape: a populated `blocks` vector, a
# matching `LabelTable`, and the `:top` entry label, alongside the
# preserved `arg_widths` / `return_widths` handoff metadata. The
# detailed forward-correctness + round-trip gate lives in
# `test/test_collatz_forward.jl`; this file stays at the Handoff-A
# integration-smoke layer (Bennett.jl `extract_parsed_ir` → `lower_vm`
# returns a well-formed program with the expected coarse shape).
#
# # M2.17 reshape note
#
# M2.17 reshaped `VMProgram`: the M0.2 stub fields `n_blocks` and
# `n_instructions` were removed in favor of the real RSSA-derived
# shape (`blocks::Vector{BasicBlock}`, `label_table::LabelTable`,
# `entry_label::Symbol`, plus the preserved `arg_widths` and
# `return_widths` metadata). The block/instruction-count regression
# anchors live in the digest `@debug`-log assertions below; M_UNBOUNDED.1
# made these the COUNTS OF THE LOWERED PROGRAM (post critical-edge
# split: 3 original blocks + 4 trampolines = 7 blocks), not of the
# raw ParsedIR.
#
# # Digest is now `@debug`, not STDOUT (ADR 0003 side-fix 0)
#
# `lower_vm` is the library entry point on the `target=:reversible_vm`
# dispatch path; an unconditional `println` would spam stdout on every
# compile. The digest is therefore emitted via `@debug` (silent unless
# `JULIA_DEBUG=BennettVM`). This test asserts the library-quietness
# invariant (`lower_vm` writes NOTHING to stdout, via a redirected
# `Pipe`) AND the lowered-program regression anchors (block / instruction
# counts) directly on the returned `VMProgram`, not by parsing the log.
#
# Ref: /home/tobias/Projects/Bennett.jl/src/Bennett.jl:65 (export)
#      /home/tobias/Projects/Bennett.jl/src/extract/entry.jl:41 (signature)
#      /home/tobias/Projects/Bennett.jl/test/test_y986_loop_header_dispatch.jl:129
#      bennettvm_prd.md §3.7 (Handoff A), §3.6.2 Case D, §6 SC9
#      BENNETT_JL_PIN.md (pin 877341e)

using Test
using BennettVM
import Bennett

# Verbatim copy of collatz_steps from
# /home/tobias/Projects/Bennett.jl/test/test_y986_loop_header_dispatch.jl:129
# The `steps < Int8(20)` self-cap is what makes Bennett.jl's
# `max_loop_iterations=20` lowering byte-accurate; for BennettVM the
# cap is irrelevant (we lower the *symbolic* loop), but copying the
# function body verbatim keeps the LLVM IR — and therefore the digest
# numbers below — identical between the two repos.
function collatz_steps(x::Int8)
    steps = Int8(0); val = x
    while val > Int8(1) && steps < Int8(20)
        if val % Int8(2) == Int8(0)
            val = val >> Int8(1)
        else
            val = Int8(3) * val + Int8(1)
        end
        steps += Int8(1)
    end
    return steps
end

@testset "Handoff A: collatz_steps" begin
    # (a) Pull a real ParsedIR via Bennett.jl's exported frontend.
    #     `extract_parsed_ir` is exported (Bennett.jl src/Bennett.jl:65)
    #     so the qualified `Bennett.extract_parsed_ir` form is purely
    #     stylistic — Rule 14's import-not-using stance applied to a
    #     symbol we touch in exactly one place.
    parsed = Bennett.extract_parsed_ir(collatz_steps, Tuple{Int8})

    # Sanity-check the Bennett.jl side before blaming BennettVM: if
    # `extract_parsed_ir` ever changes shape, we want the failure
    # message to point at the upstream contract, not at lower_vm.
    @test parsed isa Bennett.ParsedIR
    @test length(parsed.blocks) == 3
    @test parsed.ret_elem_widths == [8]
    @test length(parsed.args) == 1
    @test parsed.args[1][2] == 8  # single i8 argument

    # (b) Library-quietness invariant (ADR 0003 side-fix 0): `lower_vm`
    #     must write NOTHING to stdout. The digest moved to `@debug`, so
    #     with the default logger (Debug suppressed) a redirected stdout
    #     stays empty. On Julia 1.12+ `redirect_stdout` insists on a real
    #     stream (no IOBuffer overload), so we route through a `Pipe`:
    #     write end becomes stdout while `lower_vm` runs, read end is
    #     drained afterwards. The `close(write-end)` is what makes
    #     `read(...)` return instead of blocking forever.
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
    result = redirect_stdout(pipe.in) do
        r = lower_vm(parsed)
        flush(stdout)
        r
    end
    close(pipe.in)
    stdout_text = read(pipe.out, String)
    close(pipe.out)
    @test isempty(stdout_text)   # a library entry point is silent on stdout

    # (c) Assert on the lowered VMProgram against known-correct values.
    #     M_UNBOUNDED.1: `lower_vm` now produces the REAL RSSA-derived
    #     program. The block count is 7 (3 original blocks — top, L8,
    #     L46 — plus 4 critical-edge trampolines: top→L46, top→L8,
    #     L8→L46, L8→L8). The LabelTable has one entry per block. The
    #     entry label is `:top` (the ParsedIR's first block). The
    #     `arg_widths` / `return_widths` carry the preserved handoff
    #     metadata. (The default routine name is `:main` when `opts` is
    #     not a Symbol, but the entry LABEL is the block label `:top`,
    #     not the routine name — those are distinct, see ADR 0012 §D4.)
    @test result isa VMProgram
    @test length(result.blocks) == 7
    @test length(result.label_table) == 7
    @test result.entry_label === :top
    @test result.arg_widths == [8]
    @test result.return_widths == [8]

    # (d) Instruction-count regression anchor — asserted DIRECTLY on the
    #     VMProgram, not by parsing the `@debug` digest record (Rule 4:
    #     assert the value, not a logged copy of it; this also keeps
    #     `Logging` out of the test deps). 26 = the flat-stream instruction
    #     count of the LOWERED program post edge-split (per-block entry+exit
    #     markers + lowered body + synthetic constant creates). The digest
    #     `@debug` (ADR 0003 side-fix 0) reports this same number; M0.4's
    #     ADR transcribes it, so it is part of the contract.
    @test n_instructions(result) == 26
end
