# test/test_dyn_roundtrip.jl — SC9 Case A END-TO-END round-trip gate (the
# `frtN` executable proof; bead `bennettvm-xld`, ADR 0009 Decision 3).
#
# # What this gate proves, and why it is Case A's reason to exist
#
# ADR 0009 Decision 3 defines `frtN` as THE SC9 Case A canonical program — a
# C function that allocates a RUNTIME-sized (VLA) `int` array, writes a
# data-dependent pattern into it, reduces it, and returns a scalar:
#
#     int frtN(int n) {
#         int a[n];                                   // dynamic-N alloca
#         for (int i = 0; i < n; i++) a[i] = i * i;   // data-dependent stores
#         int s = 0;
#         for (int i = 0; i < n; i++) s += a[i];      // reduce
#         return s;                                   // = sum_{i<n} i^2
#     }
#
# with the co-located irreversible oracle (golden-master convention,
# ADR 0009 Decision 3):
#
#     frtN_oracle(n) = sum(i^2 for i in 0:n-1)        # 0 for n <= 0
#
# This file is the END-TO-END witness that BennettVM lowers and round-trips
# the full Case A program — dynamic-N `alloca`, single-index VLA `getelementptr`
# (`IRVarGEP`), indexed lossy stores, two heap-state loops, and a reduction —
# from a committed C `.ll`, all the way to empty history. It composes every
# Case A rung beneath it (the static array floor, the indexed-store `(addr,
# old_value)` L2 delta, and the dynamic-N alloca `(base, n)` L2 delta) on a
# REAL clang-emitted program rather than a hand-built `ParsedIR`.
#
# # Emitter-agnostic, clang-free at test time (the through_mem.ll discipline)
#
# Like `test_memory_floor_cll.jl` (ADR 0014 §D5), the verified clang-18 output
# is committed at `test/reference/frtN.ll`, so the test needs NO clang on the
# test machine (CLAUDE.md Rule 12). The C source `frtN.c` is committed as
# provenance. The test reads ONLY the `.ll` via Bennett's language-agnostic
# `extract_parsed_ir_from_ll` — the same entry point a Rust or hand-written
# `.ll` would use.
#
# ## The committed `.ll` is HAND-TRIMMED + HAND-NAMED — exactly what changed
#
# The verbatim `clang-18 -O0 -S -emit-llvm` emission of `frtN.c` cannot be
# ingested as-is for TWO reasons, both documented in `frtN.ll`'s header and
# both verified empirically in the bead-xld spike:
#
#   (1) VLA stack-management scaffolding. `-O0` emits a
#       `llvm.stacksave`/`llvm.stackrestore` pair (with two helper allocas and
#       a never-read VLA-size spill) around the dynamic alloca. The extractor
#       has no registered intrinsic handler for `llvm.stacksave.p0`
#       (Bennett-5oyt / U15) and REJECTS the verbatim IR. These intrinsics are
#       pure stack-pointer bookkeeping; none of the removed values feed `ret`.
#       They were removed; the genuine `%11 = alloca i32, i64 %9` (the
#       dynamic-N alloca) was KEPT VERBATIM.
#
#   (2) Numerically-labelled basic blocks. `-O0` emits blocks labelled `12:`,
#       `16:`, … which have no TEXTUAL name; the extractor maps an unnamed
#       block to `Symbol("")` (Bennett `module_walk.jl:168`), collapsing all 9
#       blocks to one label and producing un-lowerable IR. Block names are
#       SEMANTICALLY INERT in LLVM, so each block was given a textual name
#       (entry / l1_cond / l1_body / l1_inc / l1_end / l2_cond / l2_body /
#       l2_inc / l2_end) — a faithful relabel, NOT a semantic change.
#
# The trimmed-and-named `.ll` was proven semantics-preserving two ways: (a)
# `opt-18 -passes=verify` reports it well-formed; (b) JIT-executing it with
# `lli-18` reproduces the oracle bit-for-bit (`frtN(5)=30`, `frtN(7)=91`).
# SSA value numbers are unchanged from the -O0 emission, so the IR remains
# line-diffable against the original.
#
# # The result KEY and arg KEY (pinned empirically — bead-xld spike)
#
# The extracted ParsedIR has `args = [(:__v1, 32)]` (the i32 argument `n`),
# `ret_elem_widths = [32]`, and the `IRRet` operand is `SSAOperand(:__v47)`,
# so the routine result lives in `result(rs)[:__v47]`. The dynamic alloca is
# `IRAlloca(:__v9, 32, SSAOperand(:__v8))` (n_elems is an SSAOperand — the
# Case A shape), and the array accesses are SINGLE-index `IRVarGEP`s
# (a VLA `int a[n]` avoids the 2-index getelementptr a STATIC `int a[N]`
# emits, which the frontend rejects — bead `bennettvm-dzd`). There are ZERO
# `IRPhi` nodes: at `-O0` the loop counters `i`/`s` live in heap cells, so the
# loops are reversed entirely by L3 checkpoint-replay of `IState.memory`.
# These keys are PINNED so a future extractor renaming surfaces as a failed
# assertion, not a silent miss.
#
# # The mixed L2/L3 history (ADR 0009 Decision 4 rung 7 — the deep interaction)
#
# `frtN`'s two `for` loops are reversed by L3 checkpoint-replay (ADR 0010),
# while their array element writes push L2 `(addr, old_value)` deltas (Decision
# 2b) and the dynamic alloca pushes an L2 `(base, n)` delta (Decision 2a) — so
# `frtN`'s history is a MIXED L2-`DeltaEntry` / L3-`CheckpointEntry` stack. This
# composition is the deep interaction Rule 2 warns about; the gate MUST exercise
# it, not just isolated L2 or L3 cases (Rule 4). At `checkpoint_interval = 4`,
# n = 5, the spike measured 1 DynAlloca delta + 24 MemoryStore deltas + 30 L3
# checkpoints — a genuinely mixed stack. The default `checkpoint_interval`
# yields an all-L2 stack (0 checkpoints), so K=4 is used to FORCE the mix.
#
# # Width (bead `bgc`) is NOT on this gate's critical path
#
# `IState` cells are `Int64`; the lowering does not mask to the i32 element
# width. For `frtN`, `sum(i^2)` overflows i32 only for n in the thousands
# (element `i*i` overflows i32 at i >= 46341; the running sum near n ~= 1860),
# far above every n exercised here. The spike confirmed the VM (Int64) and the
# i32-wrapped C oracle AGREE through n = 100 (result 328350). So width-masking
# is NOT needed for the frtN(5) gate — only for overflowing inputs.
#
# # Tests (Rule 4 — every assert against a known value)
#
#   1. The committed `.ll` exists.
#   2. Extracted ParsedIR pins: arg/result keys, the dynamic-N alloca, the
#      single-index VarGEP (dzd), zero phi nodes.
#   3. lower_vm succeeds (the path that previously raised at a dynamic alloca).
#   4. Forward result == frtN_oracle(n) bit-for-bit across several n (incl. 5).
#   5. Round-trip (run! then unrun!) -> initial, empty history, count 0.
#   6. MIXED L2/L3 history occurred (DeltaEntry >= 1 AND CheckpointEntry >= 1),
#      including the DynAlloca (base, n) delta and MemoryStore (addr, old)
#      deltas (rung 7).
#   7. per_step_inverse_check (mid-instruction inverse bugs) at K in {1, 4}.
#   8. Headline: a C VLA program round-trips end-to-end.
#
# # Ref
#
#   * `docs/adr/0009-dynamic-size-memory.md` Decision 3 (frtN + oracle),
#     Decision 4 rung 7 (mixed L2/L3 history), Decision 2a (DynAlloca (base,n)
#     L2 delta), Decision 2b (indexed store (addr,old) L2 delta + VarGEP).
#   * `test/reference/frtN.c` / `frtN.ll` — the C source + the committed,
#     hand-trimmed/named clang-18 `.ll` (header documents every edit).
#   * `test/test_memory_floor_cll.jl` — the scalar emitter-agnostic gate this
#     mirrors; `test/test_alloca_delta.jl` — the DynAlloca L2 unit gate.
#   * `test/test_per_step_inverse.jl` — the `per_step_inverse_check` scaffold.
#   * `../Bennett.jl/src/extract/entry.jl` — `extract_parsed_ir_from_ll`.
#   * CLAUDE.md Rule 1 (fail loud), Rule 2 (deep bugs), Rule 4 (known values),
#     Rule 11 (literate), Rule 12 (clang-free at test time).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# The committed clang-18 `.ll` (hand-trimmed/named — see file header). No clang
# at test time (Rule 12).
const _FRTN_PATH = joinpath(@__DIR__, "reference", "frtN.ll")

# Pinned IR keys (verified in the bead-xld spike — see this file's docstring).
const _FRTN_ARG_KEY    = :__v1    # the i32 argument `n`'s SSA name
const _FRTN_RESULT_KEY = :__v47   # the IRRet operand — the routine result

# The C function's semantics, as the irreversible oracle (ADR 0009 Decision 3;
# Rule 4). `init=0` makes n <= 0 yield 0 (the empty-VLA case).
frtN_oracle(n::Integer) = sum(i^2 for i in 0:(n - 1); init = 0)

@testset "frtN — SC9 Case A end-to-end round-trip (ADR 0009 Decision 3)" begin
    # (1) The committed `.ll` exists (the gate's input).
    @test isfile(_FRTN_PATH)

    # (2) Extract the ParsedIR from the C-emitted `.ll` via Bennett's
    #     language-agnostic entry point, and pin the verified shape.
    p = Bennett.extract_parsed_ir_from_ll(_FRTN_PATH; entry_function = "frtN")

    @testset "extracted ParsedIR shape (pins the verified spike dump)" begin
        @test p.args == [(_FRTN_ARG_KEY, 32)]
        @test p.ret_elem_widths == [32]
        @test length(p.blocks) == 9
        @test allunique(b.label for b in p.blocks)   # no Symbol("")-collapse

        # The dynamic-N alloca: exactly ONE IRAlloca whose n_elems is an
        # SSAOperand (the Case A shape). The four scalar allocas (arg spill,
        # the i/s loop-counter cells) are ConstOperand(1).
        all_allocas = [inst for b in p.blocks for inst in b.instructions
                       if inst isa Bennett.IRAlloca]
        dyn_allocas = [a for a in all_allocas if a.n_elems isa Bennett.SSAOperand]
        @test length(dyn_allocas) == 1
        @test dyn_allocas[1].dest == :__v9

        # The array access is a SINGLE-index IRVarGEP (the dzd avoidance: a VLA
        # `int a[n]` lowers to a plain i32* alloca + single-index GEP, NOT the
        # 2-index getelementptr a static `int a[N]` emits which the frontend
        # rejects). Two of them — one per loop.
        geps = [inst for b in p.blocks for inst in b.instructions
                if inst isa Bennett.IRVarGEP]
        @test length(geps) == 2
        @test all(g -> g.base == Bennett.SSAOperand(:__v9), geps)

        # Zero phi nodes: at -O0 the loop state lives in heap cells, so the
        # loops are reversed by L3 checkpoint-replay (not phi/block-param
        # threading). This is WHY the history is mixed L2/L3 (rung 7).
        @test count(inst -> inst isa Bennett.IRPhi,
                    (inst for b in p.blocks for inst in b.instructions)) == 0

        # The terminator returns the pinned result key.
        @test p.blocks[end].terminator isa Bennett.IRRet
        @test p.blocks[end].terminator.op == Bennett.SSAOperand(_FRTN_RESULT_KEY)
    end

    # (3) Lower to a runnable VMProgram via the real `lower_vm` — the path that
    #     previously raised at a dynamic-N IRAlloca (this is the gap Case A
    #     closes). 9 original blocks + 10 critical-edge trampolines = 19.
    vm = lower_vm(p; opts = :frtN)
    @test vm isa VMProgram
    @test length(vm.blocks) == 19

    # The global must-cache set: `compute_must_cache(vm)` marks every
    # L2-capable non-injective slot (DynAlloca + MemoryStore here) and lets the
    # L3-only creates (VarGEP / MemoryLoad / Define / Cast) fall through to L3
    # (bead `bennettvm-5pp`). Safe to pass as a global set.
    mcs = BennettVM.compute_must_cache(vm)
    @test !isempty(mcs)

    # The inputs exercised. n=0 (empty VLA → 0), n=1 (→0), small values, and
    # the n=5 keystone (→30). All well below i32 overflow, so width-masking
    # (bead `bgc`) is NOT needed here.
    frtN_inputs = (Int64(0), Int64(1), Int64(2), Int64(5), Int64(8))

    # ------------------------------------------------------------------
    # (4)+(5) Forward result == oracle bit-for-bit, then round-trips (P0.6).
    #         checkpoint_interval = 4 to FORCE the mixed L2/L3 stack.
    # ------------------------------------------------------------------
    @testset "forward == frtN_oracle and round-trips to empty history" begin
        for n in frtN_inputs
            rs = initial_state(vm, Dict(_FRTN_ARG_KEY => n))
            initial_snap = deepcopy(rs.initial)

            run!(rs, vm; checkpoint_interval = 4, must_cache_set = mcs)
            @test is_halted(rs)
            # ANCHOR: the VM's forward result is bit-for-bit the C oracle.
            @test result(rs)[_FRTN_RESULT_KEY] == frtN_oracle(n)

            unrun!(rs, vm)
            @test rs.current == rs.initial      # P0.6 — reversed to start
            @test isempty(rs.history)           # P0.6 — history drained
            @test rs.step_count == 0            # P0.6 — step counter reset
            @test rs.initial == initial_snap    # rs.initial never mutated
        end
    end

    # ------------------------------------------------------------------
    # (6) MIXED L2/L3 history (ADR 0009 Decision 4 rung 7). The two loops
    #     reverse via L3 CheckpointEntrys; the array element writes push L2
    #     (addr, old_value) DeltaEntrys; the dynamic alloca pushes an L2
    #     (base, n) DeltaEntry. The gate MUST exercise the mix, not just
    #     isolated L2 or L3 (Rule 4). n=5: 1 alloca delta + 24 store deltas
    #     + 30 checkpoints (spike-measured at K=4).
    # ------------------------------------------------------------------
    @testset "mixed L2/L3 history occurs (rung 7)" begin
        rs = initial_state(vm, Dict(_FRTN_ARG_KEY => Int64(5)))
        run!(rs, vm; checkpoint_interval = 4, must_cache_set = mcs)
        @test is_halted(rs)
        @test result(rs)[_FRTN_RESULT_KEY] == frtN_oracle(5)

        deltas = filter(e -> e isa BennettVM.DeltaEntry, rs.history)
        ckpts  = filter(e -> e isa BennettVM.CheckpointEntry, rs.history)
        @test length(deltas) >= 1     # L2 fired
        @test length(ckpts)  >= 1     # L3 fired — genuinely MIXED

        # The dynamic alloca pushed an L2 (base, n) delta (Decision 2a)...
        alloca_deltas = filter(e -> e.instruction isa BennettVM.DynAlloca, deltas)
        @test length(alloca_deltas) == 1
        @test haskey(alloca_deltas[1].payload, :base)
        @test haskey(alloca_deltas[1].payload, :n)
        @test alloca_deltas[1].payload.n == 5

        # ...and the indexed element writes pushed L2 (addr, old_value) deltas
        # (Decision 2b) — at least the n=5 array stores plus the scalar spills.
        store_deltas = filter(e -> e.instruction isa BennettVM.MemoryStore, deltas)
        @test length(store_deltas) >= 5

        # Drain it to confirm the mixed stack reverses clean (the rung-7 deep
        # interaction: L3 replay must NOT double-push the interleaved L2 deltas).
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end

    # ------------------------------------------------------------------
    # (7) Per-step (mid-instruction) inverse under the mixed history — the
    #     finer-grained gate the aggregate round-trip can mask. K=1 (push
    #     every step) and K=4 (the mixed-stack density).
    # ------------------------------------------------------------------
    @testset "per-step inverse (mixed L2/L3) at K in {1, 4}" begin
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(_FRTN_ARG_KEY => Int64(5));
                checkpoint_interval = K,
                must_cache_set = mcs,
                label = "frtN/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (8) THE headline assertion — one clearly-named claim.
    # ------------------------------------------------------------------
    # A C VLA program (compiled clang-18 -O0, NOT Julia) with a runtime-sized
    # array, two heap-state loops, indexed stores, and a reduction round-trips
    # end-to-end through BennettVM: frtN(5) == 30 (= sum i^2 for i<5), reversed
    # to empty history. The SC9 Case A executable proof (ADR 0009 Decision 3).
    @testset "headline: a C VLA program round-trips end-to-end" begin
        rs = initial_state(vm, Dict(_FRTN_ARG_KEY => Int64(5)))
        run!(rs, vm; checkpoint_interval = 4, must_cache_set = mcs)
        @test is_halted(rs)
        @test result(rs)[_FRTN_RESULT_KEY] == 30          # frtN(5) == 30
        @test result(rs)[_FRTN_RESULT_KEY] == frtN_oracle(5)
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end
end
