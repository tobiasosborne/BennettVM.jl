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
# # What is intentionally NOT asserted
#
# Anything past the four digest fields. The M0.2 `VMProgram` is a stub
# (`src/ir/VMProgram.jl`); the real per-block structure lands at M2.7
# and beyond. Asserting more here would couple this test to design
# decisions that PRD v4 §3 still defers.
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

    # (b) Capture the digest emitted by lower_vm. On Julia 1.12+
    #     `redirect_stdout` insists on a real stream (no IOBuffer
    #     overload), so we route through a `Pipe`: write end becomes
    #     stdout while `lower_vm` runs, read end is drained afterwards.
    #     The `close(write-end)` is what makes `read(...)` return
    #     instead of blocking forever waiting for more bytes.
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
    result = redirect_stdout(pipe.in) do
        r = lower_vm(parsed)
        flush(stdout)
        r
    end
    close(pipe.in)
    digest = read(pipe.out, String)
    close(pipe.out)

    # (c) Assert on every digest field against a known-correct value.
    #     These four numbers are the M0.3 regression anchor; see the
    #     file-header docstring for the rebaselining contract.
    @test result isa VMProgram
    @test result.n_blocks == 3
    @test result.n_instructions == 17
    @test result.arg_widths == [8]
    @test result.return_widths == [8]

    # Loop-bearing sanity: collatz_steps has a while loop, so the
    # ParsedIR must decompose into more than one basic block. This is
    # the qualitative invariant the bead asks for; the `== 3` check
    # above is the quantitative refinement of the same property.
    @test result.n_blocks > 1
    @test result.n_instructions > 0

    # Digest format: the strings `"lower_vm digest:"` and
    # `"blocks       = "` are the grep-friendly anchors M0.2 chose
    # (`src/lower_vm.jl` lines 112-113). M0.4's ADR transcribes these
    # lines verbatim from the four motivating cases, so the exact
    # spelling — including the run of spaces before `=` — is part of
    # the contract, not incidental whitespace.
    @test occursin("lower_vm digest:", digest)
    @test occursin("blocks       = ", digest)
    @test occursin("blocks       = 3", digest)
    @test occursin("instructions = 17", digest)
    @test occursin("args         = [8]", digest)
    @test occursin("returns      = [8]", digest)
end
