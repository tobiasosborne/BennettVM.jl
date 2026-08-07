# test/test_57hd_value_identity_vm.jl — the BennettVM (downstream) half of
# Bennett.jl bead `Bennett-57hd` (xkl frontier wall 10), ADR 0017 §4b.
#
# # What upstream changed
#
# A THIRD admission contract for `ptrtoint` under `ptr_cells`, and the
# STRONGEST of the three. Bennett-583s admits a difference whose two bases are
# the SAME SSA VALUE; Bennett-foz5 §4a admits a difference it CANNOT prove and
# confines to a halting branch; §4b proves the two coerced pointers are COPIES
# OF ONE VALUE — related through an aggregate store and a same-slot reload
# rather than through one SSA name — so the difference is IDENTICALLY ZERO:
#
#     canon(%S) === canon(%T)  ==>  sub(ptrtoint %S, ptrtoint %T) ≡ 0
#
# in the native program AND in BennettVM, on every input, under ANY map φ from
# native addresses to pointer cell values. `φ(p) − φ(p) = 0 = p − p` needs no
# property of φ: not injectivity (which Bennett-jbko needs), not
# translation-cancellation within a region (which Bennett-583s needs), not the
# byte tier. The value may therefore ESCAPE without restriction — and in the
# `push!` corpus it does, into a live grow-or-not branch and into two
# closure-env slots that `_growend!` reads as an ALLOCATION SIZE and a MEMMOVE
# LENGTH.
#
# # BennettVM src changes: ZERO. This file is the proof, not the assertion.
#
# `sub` and `udiv` were already first-class (`src/ir/operators.jl`), with
# non-injective-op history capture in `src/ir/arithmetic_assignment.jl`. The
# `udiv exact` costs HISTORY, not CAPABILITY. Gate (2) pins that no new
# instruction kind appears; if a future change reaches for one, it turns red.
#
# # What this file pins (Rule 4 — known values, never "didn't throw")
#
#   (1) HANDOFF SHAPE — the `ParsedIR` BVM receives carries BOTH coercions as
#       the `IRBinOp(:or, _, 0, 64)` cell identity (byte-identical to what
#       Bennett-583s and Bennett-foz5 emit), plus the `:sub` and the `:udiv`.
#   (2) ZERO NEW INSTRUCTION KINDS after `lower_vm`.
#   (3) THE §4b CLAIM, EXECUTED — the difference is run on the VM and is `0`.
#       Not asserted about the IR: OBSERVED. This is a STRONGER runtime leg
#       than `test_bvmd_byte_tier_vm.jl`'s, because the claim under test
#       (`d == 0`) is directly observable rather than inferred.
#   (4) NON-VACUITY, AS AN ASSERTION AND NOT A COMMENT — MANDATORY. The
#       theorem's own failure mode is DEGENERATE AGREEMENT: `0 − 0 = 0` too,
#       and ADR 0018 §E reads a never-written cell as `0`. So a collapse to
#       two unmaterialised cells would make gate (3) pass FOR THE WRONG
#       REASON. This gate asserts the two coerced cells are NON-ZERO, EQUAL,
#       and equal to the arena address of the object the aggregate store
#       actually wrote — and that the OTHER header field holds a DIFFERENT
#       address, so a shared or mis-stamped cell cannot masquerade as a pass.
#   (5) THE ESCAPE IS EXERCISED — the quotient reaches an `IntrinsicGCAlloc`
#       SIZE operand and a `VarGEP` element ADDRESS, and the program's return
#       value is oracle-exact. This is the executable refutation of the "the
#       index escapes into an allocation size, so it cannot be admitted"
#       objection: it CAN, once it is PROVED.
#   (6) ORACLE under both history regimes, EXACT `unrun!`, per-step inverse.
#
# # The fixture, and why the oracle is sensitive to the index
#
# `%sz = idx + n` is the allocation size handed to a THIRD `gc_alloc_obj`, and
# `%eptr = data + idx*8` is the element address written. The read-back is at
# `%data` — element ZERO — so the returned value is `n` ONLY IF `idx == 0`,
# i.e. only if the admitted difference really was zero. A non-zero index writes
# somewhere else and the read-back returns `0` (ADR 0018 §E), not `n`. The
# oracle therefore FAILS LOUD on exactly the miscompile this contract could
# cause, rather than being insensitive to it.
#
# # Ref
#   * `../Bennett.jl/test/test_57hd_value_identity.jl` — the upstream gates,
#     including (S), the three-way corpus partition.
#   * `../Bennett.jl/src/extract/instructions.jl` — `_57hd_value_identity_cluster`,
#     `_57hd_canon`, `_57hd_write_footprint`, `_57hd_roots_disjoint`.
#   * ADR 0017 §4b (this contract), §4a (the confined-value contract it composes
#     with and does NOT weaken), ADR 0018 §A/§E.
#   * `test_bvmd_byte_tier_vm.jl` — the precedent this file is shaped after; its
#     gate (2) already executes the store/load round-trip half of premise (P3).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 11 (literate).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BV7 = BennettVM
const _BN7 = Bennett

# ---------------------------------------------------------------------------
# The fixture: the `push!` root's `%top` block, distilled to what the contract
# needs, plus a live escape.
#
#   leg 1  a `{i64, ptr}` GenericMemory header and its data block
#   leg 2  the `MemoryRef` built IN-BODY by an `insertvalue` chain and stored
#          WHOLE into a fresh 24-byte box                — the aggregate store
#   leg 3  both halves reloaded, and `.mem`'s `.data` reloaded through the
#          reloaded `.mem`                                — the same-slot reload
#   leg 4  the two coercions and the `sub`                — WALL 10's cluster
#   leg 5  `udiv exact 8`, then the quotient as an ALLOCATION SIZE and as an
#          element ADDRESS                                — the ESCAPE
#
# The allocator declaration carries the two attributes Julia's own codegen
# emits and the contract READS rather than assumes: `noalias` on the return
# (freshness) and `memory(argmem: read, inaccessiblemem: readwrite)` (writes no
# IR-visible object memory). Strip either and the upstream predicate declines.
# ---------------------------------------------------------------------------
const _IR_57HD = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"

declare noalias ptr @julia.gc_alloc_obj(ptr, i64, ptr) memory(argmem: read, inaccessiblemem: readwrite)

define i64 @vi_e2e(ptr %task, ptr %tag, i64 %n) {
top:
  ; ---- leg 1: the header and its data block ----
  %mem  = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 16, ptr %tag)
  %data = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %tag)
  %lg = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 0
  store i64 8, ptr %lg, align 8
  %dg = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  store ptr %data, ptr %dg, align 8

  ; ---- leg 2: the MemoryRef, built in-body and stored WHOLE ----
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %md, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1
  %obj = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  store { ptr, ptr } %ref, ptr %obj, align 8

  ; ---- leg 3: both halves back out, and `.mem`'s `.data` through the reload ----
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %f1p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1
  %f1 = load ptr, ptr %f1p, align 8
  %md2p = getelementptr inbounds { i64, ptr }, ptr %f1, i32 0, i32 1
  %md2 = load ptr, ptr %md2p, align 8

  ; ---- leg 4: WALL 10's cluster ----
  %a = ptrtoint ptr %f0 to i64
  %b = ptrtoint ptr %md2 to i64
  %d = sub i64 %a, %b
  %idx = udiv exact i64 %d, 8

  ; ---- leg 5: THE ESCAPE — an allocation size and an element address ----
  %sz = add i64 %idx, %n
  %sz8 = mul i64 %sz, 8
  %new = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 %sz8, ptr %tag)
  %eoff = mul i64 %idx, 8
  %eptr = getelementptr i8, ptr %data, i64 %eoff
  store i64 %sz, ptr %eptr, align 8
  %rb = load i64, ptr %data, align 8
  ret i64 %rb
}
"""

_vi7_build() = mktempdir() do dir
    path = joinpath(dir, "vi_e2e.ll")
    write(path, _IR_57HD)
    p = _BN7.extract_parsed_ir_from_ll(path; entry_function="vi_e2e",
                                       ptr_cells=true)
    return (p, _BV7.lower_vm(p))
end

_vi7_insts(pir) = [i for b in pir.blocks for i in b.instructions]

@testset "Bennett-57hd — value identity runs and reverses on the VM (ADR 0017 §4b)" begin

    # ==================================================================
    # (1) THE HANDOFF SHAPE. Both coercions are the SAME cell-identity node
    #     Bennett-583s and Bennett-foz5 emit — nothing is fabricated, and no
    #     new node form was invented for this contract.
    # ==================================================================
    @testset "(1) the ParsedIR carries two `:or` cell identities + sub + udiv" begin
        pir, _ = _vi7_build()
        insts = _vi7_insts(pir)
        ors = [i for i in insts if i isa _BN7.IRBinOp && i.op === :or &&
                                   i.width == 64 &&
                                   i.op2 isa _BN7.ConstOperand && i.op2.value == 0]
        @test Set(o.dest for o in ors) ⊇ Set([:a, :b])
        # the arithmetic is emitted VERBATIM by the ordinary paths
        sub = only([i for i in insts if i isa _BN7.IRBinOp && i.dest === :d])
        @test sub.op === :sub
        div = only([i for i in insts if i isa _BN7.IRBinOp && i.dest === :idx])
        @test div.op === :udiv
        # ... and the escape is present in the handoff, not optimised away
        @test any(i -> i isa _BN7.IRBinOp && i.dest === :sz && i.op === :add, insts)
    end

    # ==================================================================
    # (2) ZERO NEW INSTRUCTION KINDS. If a future change to this contract
    #     reaches for a new BVM node, this gate turns red — that is a
    #     late-firing upgrade trigger, not a detail.
    # ==================================================================
    @testset "(2) lower_vm produces only pre-existing instruction kinds" begin
        _, prog = _vi7_build()
        body = [i for b in prog.blocks for i in b.instructions]
        kinds = Set(typeof.(body))
        @test kinds ⊆ Set([_BV7.Define, _BV7.IntrinsicGCAlloc, _BV7.MemoryLoad,
                           _BV7.MemoryStore, _BV7.VarGEP])
        @test count(i -> i isa _BV7.IntrinsicGCAlloc, body) == 4
        @test count(i -> i isa _BV7.VarGEP, body) >= 1
    end

    # ==================================================================
    # (3)+(4)+(5)+(6) THE CLAIM EXECUTED, NON-VACUOUSLY, WITH THE ESCAPE
    #     LIVE, ORACLE-EXACT UNDER BOTH HISTORY REGIMES, AND EXACTLY
    #     REVERSIBLE.
    # ==================================================================
    @testset "(3)-(6) the difference is 0 on the VM, non-vacuously" begin
        _, prog = _vi7_build()
        regimes = (("L2 (compute_must_cache)", _BV7.compute_must_cache(prog)),
                   ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))
        for (rlabel, mcs) in regimes, n in Int64[1, 5, 7]
            s = _BV7.initial_state(prog, Dict(:task => Int64(0),
                                              :tag => Int64(0), :n => n))
            init = deepcopy(s.current)
            _BV7.run!(s, prog; max_steps=50_000, checkpoint_interval=4,
                      must_cache_set=mcs)
            # ANCHOR ($rlabel, n = $n)
            @test _BV7.is_halted(s)
            @test s.current.status === :halted
            res = _BV7.result(s)

            # ---- (3) THE §4b CLAIM, EXECUTED ----
            @test res[:d] == 0
            @test res[:idx] == 0

            # ---- (4) NON-VACUITY — MANDATORY, and the reason is in the
            # header: `0 − 0 = 0` too, and ADR 0018 §E reads a never-written
            # cell as `0`, so gate (3) alone would pass for a collapse to two
            # unmaterialised cells. These four lines are what make it a proof.
            @test res[:f0] != 0                    # the cell was MATERIALISED
            @test res[:md2] != 0                   # ... so was the other one
            @test res[:f0] == res[:md2]            # ... and they AGREE
            @test res[:f0] == res[:data]           # ... on the address STORED
            # ... while the OTHER header field holds a DIFFERENT address, so a
            # shared or mis-stamped cell cannot masquerade as agreement.
            @test res[:f1] == res[:mem]
            @test res[:mem] != res[:data]

            # ---- (5) THE ESCAPE IS LIVE AND ORACLE-EXACT ----
            # `%sz` is the allocation size of a real `IntrinsicGCAlloc`, and
            # `%idx` is the element index of a real `VarGEP`. The read-back is
            # at element ZERO, so `rb == n` holds ONLY IF the index was 0.
            @test res[:sz] == n
            @test res[:new] != 0
            @test res[:rb] == n

            # ---- (6) EXACT REVERSAL: the Bennett-1973 invariant ----
            _BV7.unrun!(s, prog; max_unsteps=100_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end

        for K in (1, 4)
            @test per_step_inverse_check(prog,
                    Dict(:task => Int64(0), :tag => Int64(0), :n => Int64(5));
                    checkpoint_interval=K,
                    label="57hd/e2e/L3/K=$K") === nothing
            @test per_step_inverse_check(prog,
                    Dict(:task => Int64(0), :tag => Int64(0), :n => Int64(5));
                    checkpoint_interval=K,
                    must_cache_set=_BV7.compute_must_cache(prog),
                    label="57hd/e2e/L2/K=$K") === nothing
        end
    end
end
