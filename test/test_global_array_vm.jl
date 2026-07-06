# test_global_array_vm.jl — bead `bennettvm-416r.4` (const globals as
# initialized read-only VM memory segments) + Bennett-dzd (stack arrays).
#
# THE ACCEPTANCE GATE: a C `static const uint8_t rom[8] = {…}` read at a RUNTIME
# index — `gtest(i) = rom[i & 7]` — runs end-to-end on the VM, forward matching
# the NATIVE clang binary bit-for-bit (Rule 4) AND reversing (`unrun!`) to the
# EXACT initial state (memory, cursors, ==). This is the shape a NES ROM
# (`const uint8_t rom[16384]`) needs; the 16 KB case below proves it at scale
# AND asserts the ROM is NOT copied into L3 checkpoints (the read-only design).
#
# What this exercises end-to-end:
#   * Front-end (Bennett.jl `src/extract/instructions.jl`, Case C): the
#     two-index array GEP `getelementptr [N x iM], ptr @rom, i64 0, i64 %idx`
#     → `IRVarGEP(:rom, %idx, M)` (previously the Bennett-qal5 / U16 reject);
#     the SAME arm closes Bennett-dzd for a local alloca-backed stack array.
#   * VM (BennettVM): `GLOBAL_BASE = 2^48` read-only segment (`intrinsics.jl`),
#     `IState.globals::GlobalROM` (shared, excluded from ==/hash, NOT
#     per-checkpoint-copied — `IState.jl`), the prepended `Define(:rom, base)`
#     entry binding + ROM materialization (`ingest.jl` `_global_segment`),
#     `initial_state` seeding, the `MemoryLoad` global read + `MemoryStore`
#     read-only fail-loud (`memory_floor.jl`).
#
# clang-gated: emits fresh `.ll` + native golden into a tempdir at test time
# (the spec's "emit fresh small ones in a tmp dir"), SELF-SKIPS if clang is
# absent (the T5-corpus / CLAUDE.md clang-self-skip convention). Present in the
# dev environment (clang 18.1.3), so this runs there.

using Test
using BennettVM
import Bennett

const _BVGA = BennettVM

# --- helpers -----------------------------------------------------------------

# Emit `-O0` LLVM IR for a C source that defines ONLY the accessor (no `main`,
# no libc) so `extract_parsed_ir_set_from_ll` walks exactly the target function.
function _emit_ll(dir::AbstractString, base::AbstractString, csrc::AbstractString)
    cpath = joinpath(dir, base * ".c")
    llpath = joinpath(dir, base * ".O0.ll")
    write(cpath, csrc)
    run(`clang -O0 -S -emit-llvm -o $llpath $cpath`)
    return llpath
end

# Compile a self-contained C driver (accessor + a `main` printing one integer
# per line) with clang and run it, returning the printed integers — the NATIVE
# golden master (Rule 4 / Law 1: a miscompile cannot hide behind a
# self-consistent round-trip).
function _native_golden(dir::AbstractString, base::AbstractString,
                        driver_src::AbstractString)::Vector{Int}
    cpath = joinpath(dir, base * "_drv.c")
    exe = joinpath(dir, base * "_drv")
    write(cpath, driver_src)
    run(`clang -O0 -o $exe $cpath`)
    out = readchomp(`$exe`)
    return parse.(Int, split(out))
end

# Ingest a single-function `.ll` → `VMProgram` (single-function `lower_vm`, so
# the const-global segment is wired — the multi-function path defers globals).
function _ingest(llpath::AbstractString)::VMProgram
    parsed = Bennett.extract_parsed_ir_set_from_ll(llpath; ptr_cells=true)[1].second
    return lower_vm(parsed)
end

# Derive the entry-arg names + the single return name from the Begin/End markers
# (robust to extraction renames — the test_e2e_collatz.jl pattern).
function _derive_keys(vm::VMProgram)
    begin_inst = nothing
    end_inst = nothing
    for b in vm.blocks
        b.entry isa _BVGA.BeginInstruction && (begin_inst = b.entry)
        b.exit isa _BVGA.EndInstruction && (end_inst = b.exit)
    end
    @assert begin_inst !== nothing "no BeginInstruction in lowered program"
    @assert end_inst !== nothing && length(end_inst.returns) == 1
    return (begin_inst.params, end_inst.returns[1])
end

const _CLANG = Sys.which("clang")

@testset "bennettvm-416r.4 — const globals as read-only VM segments" begin

    if _CLANG === nothing
        @info "test_global_array_vm: clang not found — skipping clang-gated e2e " *
              "(the const-global segment mechanism is still unit-tested below)."
    else
      mktempdir() do dir

        # ---------------------------------------------------------------------
        # (1) Front-end extraction: the 2-index array GEP no longer throws qal5;
        #     the block carries IRVarGEP(:rom, %and, 8) + IRLoad(8), and
        #     parsed.globals[:rom] == ([10..80], 8).
        # ---------------------------------------------------------------------
        gtest_src = """
        #include <stdint.h>
        static const uint8_t rom[8] = {10,20,30,40,50,60,70,80};
        int64_t gtest(int64_t i){ return (int64_t)rom[i & 7]; }
        """
        gll = _emit_ll(dir, "gtest", gtest_src)

        @testset "(1) front-end: 2-index array GEP → IRVarGEP + globals" begin
            parsed = Bennett.extract_parsed_ir_set_from_ll(gll; ptr_cells=true)[1].second
            @test haskey(parsed.globals, :rom)
            data, ew = parsed.globals[:rom]
            @test ew == 8
            @test data == UInt64[10,20,30,40,50,60,70,80]
            # find the IRVarGEP + the i8 IRLoad it feeds
            var_geps = Bennett.IRVarGEP[]
            i8_loads = Bennett.IRLoad[]
            for b in parsed.blocks, inst in b.instructions
                inst isa Bennett.IRVarGEP && push!(var_geps, inst)
                inst isa Bennett.IRLoad && inst.width == 8 && push!(i8_loads, inst)
            end
            @test length(var_geps) == 1
            g = var_geps[1]
            @test g.base isa Bennett.SSAOperand && g.base.name === :rom
            @test g.index isa Bennett.SSAOperand           # runtime index (%and)
            @test g.elem_width == 8
            @test length(i8_loads) == 1                    # the `load i8` off the GEP
        end

        # ---------------------------------------------------------------------
        # (2) THE GATE — gtest e2e: forward == native C over all 0:255, and
        #     unrun! restores the EXACT initial state.
        # ---------------------------------------------------------------------
        @testset "(2) gtest e2e: forward == native + exact round-trip (0:255)" begin
            vm = _ingest(gll)
            # ROM materialized as 8 cells at GLOBAL_BASE.
            @test length(vm.globals.cells) == 8
            @test vm.globals.cells[_BVGA.GLOBAL_BASE] == 10
            @test vm.globals.cells[_BVGA.GLOBAL_BASE + 7] == 80

            params, ret_key = _derive_keys(vm)
            @test length(params) == 1
            arg_key = params[1]

            # Native golden image: [gtest(0)…gtest(7)]; expected(i)=image[(i&7)+1].
            drv = """
            #include <stdint.h>
            #include <stdio.h>
            static const uint8_t rom[8] = {10,20,30,40,50,60,70,80};
            int64_t gtest(int64_t i){ return (int64_t)rom[i & 7]; }
            int main(void){ for(int64_t i=0;i<8;i++) printf("%ld\\n",(long)gtest(i)); return 0; }
            """
            image = _native_golden(dir, "gtest", drv)
            @test image == [10,20,30,40,50,60,70,80]      # sanity on the golden

            for i in 0:255
                want = image[(i & 7) + 1]
                rs = initial_state(vm, Dict(arg_key => Int64(i)))
                run!(rs, vm; max_steps=10_000, checkpoint_interval=4)
                @test is_halted(rs)
                @test result(rs)[ret_key] == want         # forward == native C
                unrun!(rs, vm)
                @test rs.current == rs.initial            # exact reverse
                @test isempty(rs.history)
                @test rs.step_count == 0
            end
        end

        # ---------------------------------------------------------------------
        # (3a) Store-to-global fails loud (writing a `const` is a miscompile).
        # ---------------------------------------------------------------------
        @testset "(3a) MemoryStore to GLOBAL_BASE fails loud" begin
            s = _BVGA.IState(1, Dict{Symbol,Int64}(:p => _BVGA.GLOBAL_BASE + 3),
                             :running)
            st = _BVGA.MemoryStore(:p, Int64(99))
            @test_throws ErrorException _BVGA.forward(st, s)
            # a normal stack store is unaffected
            s2 = _BVGA.IState(1, Dict{Symbol,Int64}(:q => Int64(5)), :running)
            _BVGA.forward(_BVGA.MemoryStore(:q, Int64(42)), s2)
            @test s2.memory[5] == 42
        end

        # ---------------------------------------------------------------------
        # (3b) Bennett-dzd closure: a C `uint8_t a[8]` written + read at a
        #     RUNTIME index (2-index array GEP with a LOCAL alloca base)
        #     round-trips, matching native C.
        # ---------------------------------------------------------------------
        @testset "(3b) dzd — local stack array written+read at runtime index" begin
            atest_src = """
            #include <stdint.h>
            int64_t atest(int64_t i, int64_t v){
                uint8_t a[8];
                a[i & 7] = (uint8_t)(v & 0xff);
                return (int64_t)a[i & 7];
            }
            """
            all = _emit_ll(dir, "atest", atest_src)
            vm = _ingest(all)
            @test isempty(vm.globals.cells)                # no const globals here
            params, ret_key = _derive_keys(vm)
            @test length(params) == 2

            # Native golden image over v (result is v&0xff, independent of i):
            # [atest(0,0)…atest(0,255)]; expected(i,v)=image[(v & 0xff)+1].
            drv = """
            #include <stdint.h>
            #include <stdio.h>
            int64_t atest(int64_t i, int64_t v){
                uint8_t a[8]; a[i & 7] = (uint8_t)(v & 0xff); return (int64_t)a[i & 7];
            }
            int main(void){ for(int64_t v=0;v<256;v++) printf("%ld\\n",(long)atest(0,v)); return 0; }
            """
            image = _native_golden(dir, "atest", drv)

            for i in Int64[0,1,3,7,8,15], v in Int64[0,1,50,127,200,255,256,257,-1]
                want = image[(v & 0xff) + 1]
                rs = initial_state(vm, Dict(params[1] => i, params[2] => v))
                run!(rs, vm; max_steps=10_000, checkpoint_interval=4)
                @test result(rs)[ret_key] == want
                unrun!(rs, vm)
                @test rs.current == rs.initial
                @test isempty(rs.history)
            end
        end

        # ---------------------------------------------------------------------
        # (4) Scale: a 256-byte const array, then a 16 KB const array (a NES
        #     ROM) at a masked runtime index — forward == native + exact
        #     round-trip, AND the ROM is NEVER copied into an L3 checkpoint
        #     (the read-only design: shared GlobalROM, no global keys in any
        #     snapshot.memory).
        # ---------------------------------------------------------------------
        @testset "(4) 256-byte and 16 KB const arrays at masked runtime index" begin
            for (n, base, pat) in [(256, "b256", k -> (13*k + 5) & 0xff),
                                   (16384, "rom16k", k -> (37*k + 11) & 0xff)]
                init = join((pat(k) for k in 0:(n-1)), ",")
                mask = n - 1
                acc = """
                #include <stdint.h>
                static const uint8_t arr[$n] = {$init};
                int64_t f(int64_t i){ return (int64_t)arr[i & $mask]; }
                """
                ll = _emit_ll(dir, base, acc)
                vm = _ingest(ll)
                @test length(vm.globals.cells) == n

                params, ret_key = _derive_keys(vm)
                arg_key = params[1]

                drv = """
                #include <stdint.h>
                #include <stdio.h>
                static const uint8_t arr[$n] = {$init};
                int64_t f(int64_t i){ return (int64_t)arr[i & $mask]; }
                int main(void){ for(int64_t i=0;i<$n;i++) printf("%ld\\n",(long)f(i)); return 0; }
                """
                image = _native_golden(dir, base, drv)
                @test length(image) == n

                # representative sample (edges + spread + a few random), each
                # forward-checked against native and fully round-tripped.
                idxs = Int64.(vcat(0:8, [mask, mask+1, 2*mask+3, n÷2, n-1],
                                   rand(0:(4*n), 24)))
                for i in idxs
                    want = image[(i & mask) + 1]
                    rs = initial_state(vm, Dict(arg_key => i))
                    run!(rs, vm; max_steps=10_000, checkpoint_interval=2)
                    @test result(rs)[ret_key] == want
                    # READ-ONLY DESIGN: every checkpoint SHARES the one ROM object
                    # and copies NO global cell into its snapshot memory (so a
                    # 16 KB ROM is materialized once, never per-checkpoint-copied).
                    for e in rs.history
                        if e isa _BVGA.CheckpointEntry
                            @test e.snapshot.globals === vm.globals
                            @test !any(k -> k >= _BVGA.GLOBAL_BASE,
                                       keys(e.snapshot.memory))
                        end
                    end
                    unrun!(rs, vm)
                    @test rs.current == rs.initial
                    @test isempty(rs.history)
                    @test rs.step_count == 0
                end
            end
        end

      end  # mktempdir
    end
end
