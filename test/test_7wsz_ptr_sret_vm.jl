# test/test_7wsz_ptr_sret_vm.jl — the BennettVM (downstream) half of Bennett.jl
# bead `Bennett-7wsz`: a POINTER-TYPED sret struct FIELD, end-to-end.
#
# # What upstream changed
#
# `Bennett-dv1z` taught the extractor to model a heterogeneous bits-struct sret
# pointee (`{i64,i8}`) as a packed aggregate, and deliberately rejected every
# non-integer field. That reject was the wall the `bennettvm-xkl` (P0) chain hit
# after Bennett-40ys: Julia's outlined `_growend!` closure returns a `MemoryRef`,
# i.e. LLVM `sret({ptr,ptr})`.
#
# 7wsz admits a `PointerType` sret field as ONE 64-bit VM cell (ADR 0018 §A) —
# gated on `ptr_cells=true`, because on the circuit path pointer args are
# DROPPED from `ParsedIR.args` and an ungated admission is a silent miscompile.
# Two admission arms upstream: the field-layout predicate
# (`_sret_struct_fields`) and the field STORE (`_try_handle_sret_scalar_store!`,
# `store ptr` — what Julia emits post-auto-SROA).
#
# # Why BVM has to prove it (and why ZERO BVM src changes is the claim)
#
# The upstream bead cannot verify the consumer end. Three claims are BVM's:
#
#   1. **guard-5's ABI discriminator still lands the value ABI.** It compares
#      `IRCall.ret_width == sum(FunctionEntry.ret_elem_widths)`. A ptr-field
#      aggregate is `128 == 64 + 64`; the historical failure mode (`64 != 72`)
#      was a MISMATCH, never a width cap. If the multi-key `_agg_slot_name`
#      family did not land, the call would degrade to a `SoftCall`.
#   2. **`IRInsertBits` with a `ConstOperand` value.** Every bits-struct field
#      BVM had seen came from an SSA store. Julia's split-roots ABI writes the
#      literal `i64 -1` SENTINEL into the sret slot of a GC-tracked field, so
#      the const-operand path is now load-bearing (upstream risk R4).
#   3. **`return_roots` as an ordinary out-pointer.** Upstream models the split
#      VERBATIM — no fusion (see the SEMANTICS block in
#      `../Bennett.jl/src/extract/sret.jl`). That means a callee STORES through
#      a caller-provided pointer cell and the caller reads it back AFTER
#      `ReturnExit`; that write must be visible and must `unrun!` (risk R5).
#
# # Fixtures
#
#   * `_use7wsz` / `_mk7wsz` (Julia) — the honest E2E. The pointer is a
#     PARAMETER (constructing one from an integer emits `inttoptr`, which walls
#     at the pre-existing Bennett-iwo9 determinism guard — a fixture artefact,
#     not a 7wsz wall) and is NEVER dereferenced, so its cell value is arbitrary
#     and the native oracle `_use7wsz(Ptr{Int64}(0), 5) == 7` is exactly
#     reproducible on the VM.
#   * `rr_callee` / `rr_caller` (hand-built `.ll`) — the split-roots shape
#     verbatim: `sret({ptr,ptr})` + a `return_roots` out-pointer + the `i64 -1`
#     sentinel + a caller that reads ALL THREE places. This is the `_growend!`
#     closure's ABI reduced to what it is. It discharges claims 2 and 3.
#
# `push!` itself still does NOT run: after 7wsz its closure walls on
# `load ptr, ptr @jl_diverror_exception` (an unrecognised Julia JIT global,
# bennettvm-416r.13) and its root on the U15 `movq %fs:0` pgcstack read
# (Bennett-5oyt). Both are unrelated to sret.
#
# # Ref
#   * `../Bennett.jl/test/test_7wsz_ptr_sret_fields.jl` — the upstream half.
#   * `../Bennett.jl/docs/design/7wsz/proposal_A.md` / `proposal_B.md`.
#   * `test/test_40ys_closure_callee_vm.jl` — the template for this file.

using Test
using BennettVM
import Bennett

const _BV7 = BennettVM
const _B7  = Bennett

# ---- the Julia fixture (pointer is a PARAM, never dereferenced) ----
struct _P7wsz
    p::Ptr{Int64}
    a::Int64
end
@noinline _mk7wsz(p::Ptr{Int64}, x::Int64) = _P7wsz(p, x + 1)
_use7wsz(p::Ptr{Int64}, x::Int64) = (r = _mk7wsz(p, x); r.a + 1)

# The irreversible native oracle (Rule 4), a DISTINCT binding so neither can be
# silently constant-folded into the other.
_oracle7wsz(x::Int64) = x + 2

# ---- the hand-built split-roots `.ll` pair ----
const _7wsz_dl = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
const _7wsz_rr_body = """
define void @rr_callee(ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %sret_return, ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %return_roots, ptr %data, ptr %mem) {
top:
  store ptr %data, ptr %sret_return, align 8
  store ptr %mem, ptr %return_roots, align 8
  %g = getelementptr inbounds i8, ptr %sret_return, i64 8
  store i64 -1, ptr %g, align 8
  ret void
}

define i64 @rr_caller(ptr %data, ptr %mem) {
top:
  %box = alloca [2 x i64], align 8
  %rr = alloca ptr, align 8
  call void @rr_callee(ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %box, ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %rr, ptr %data, ptr %mem)
  %f0 = load i64, ptr %box, align 8
  %g1 = getelementptr inbounds i8, ptr %box, i64 8
  %f1 = load i64, ptr %g1, align 8
  %r0 = load i64, ptr %rr, align 8
  %s = add i64 %f0, %r0
  %s2 = add i64 %s, %f1
  ret i64 %s2
}
"""

function _7wsz_rr_set()
    path = tempname() * ".ll"
    open(path, "w") do io
        write(io, "target datalayout = \"$_7wsz_dl\"\n\n")
        write(io, _7wsz_rr_body)
    end
    try
        return _B7.extract_parsed_ir_set_from_ll(path; ptr_cells = true)
    finally
        rm(path; force = true)
    end
end

# The entry function's single return SSA name (`result(rs)` keys by SSA name).
function _ret_symbol7wsz(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BV7.EndInstruction && b.exit.label === entry &&
           !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

const _SET7  = _B7.extract_parsed_ir_set_from_julia(_use7wsz,
                                                    Tuple{Ptr{Int64}, Int64};
                                                    ptr_cells = true)
const _PROG7 = _BV7.lower_vm(_SET7; entry = first(_SET7).first)

const _SET7RR  = _7wsz_rr_set()
const _PROG7RR = _BV7.lower_vm(_SET7RR; entry = :rr_caller)

@testset "Bennett-7wsz — ptr-typed sret field: extract → ingest → run → reverse" begin

    # ------------------------------------------------------------------
    # (a) EXTRACT — the value ABI, with a 128-bit ptr-field aggregate.
    # ------------------------------------------------------------------
    @testset "(a) extract: 2-body set; callee returns {ptr,i64} as [64,64]" begin
        @test length(_SET7) == 2
        keys_ = [p.first for p in _SET7]
        @test startswith(String(keys_[1]), "_use7wsz#")   # entry-first ordering
        @test startswith(String(keys_[2]), "_mk7wsz#")

        callee_pir = _SET7[2].second
        @test callee_pir.ret_width == 128                 # THE bead: was a reject
        @test callee_pir.ret_elem_widths == [64, 64]

        call = only(i for (_k, pir) in _SET7 for b in pir.blocks
                    for i in b.instructions if i isa _B7.IRCall)
        # guard-5's discriminator, on the Bennett.jl side of the wire.
        @test call.ret_width == sum(callee_pir.ret_elem_widths) == 128
        # the pointer travels as an ordinary 64-bit cell argument
        @test call.arg_widths == [w for (_n, w) in callee_pir.args] == [64, 64]
    end

    # ------------------------------------------------------------------
    # (b) INGEST — the multi-key slot family lands (NOT a SoftCall degrade).
    # ------------------------------------------------------------------
    @testset "(b) ingest: guard-5 lands the value ABI at 128 == 64+64" begin
        @test _PROG7 isa _BV7.VMProgram
        callee_vm = _BV7._vm_funcname(_SET7[2].first)
        @test haskey(_PROG7.functions, callee_vm)
        fe = _PROG7.functions[callee_vm]
        @test fe.ret_elem_widths == [64, 64]
        @test length(fe.returns) == 2          # the multi-key _agg_slot_name family

        vmins = [i for b in _PROG7.blocks for i in b.instructions]
        enters = [i for i in vmins if i isa _BV7.CallEnter]
        @test length(enters) == 1
        @test !any(i -> i isa _BV7.SoftCall, vmins)
        @test length(enters[1].targets) == 2   # two return slots, not one
    end

    # ------------------------------------------------------------------
    # (c) RUN — native oracle, then exact reverse, L2 and L3.
    # ------------------------------------------------------------------
    @testset "(c) e2e: _use7wsz matches the oracle, then unrun! is exact" begin
        entry_vm   = _BV7._vm_funcname(first(_SET7).first)
        ret        = _ret_symbol7wsz(_PROG7, entry_vm)
        entry_args = first(_SET7).second.args
        @test length(entry_args) == 2

        mc = _BV7.compute_must_cache(_PROG7)
        for (label, mcs) in (("L2 (compute_must_cache)", mc),
                             ("L3 (empty must_cache)", Set{Tuple{Symbol,Int}}()))
            for x in (Int64(5), Int64(0), Int64(-3), Int64(1_000_003))
                # arg 1 is the pointer cell — NEVER dereferenced, so any value
                # works; two distinct values are swept to prove the aggregate's
                # field 0 does not leak into the result.
                for pcell in (Int64(0), Int64(0x7fff_0000))
                    inputs = Dict(entry_args[1][1] => pcell,
                                  entry_args[2][1] => x)
                    rs = _BV7.initial_state(_PROG7, inputs)
                    init = deepcopy(rs.current)
                    _BV7.run!(rs, _PROG7; max_steps = 100_000,
                              checkpoint_interval = 32, must_cache_set = mcs)
                    @test _BV7.is_halted(rs)
                    @test _BV7.result(rs)[ret] == _oracle7wsz(x)
                    @test _BV7.result(rs)[ret] == _use7wsz(Ptr{Int64}(0), x)

                    _BV7.unrun!(rs, _PROG7; max_unsteps = 100_000)
                    @test rs.current == init          # exact reverse ($label)
                    @test isempty(rs.history)
                    @test rs.step_count == 0
                end
            end
        end
    end

    # ------------------------------------------------------------------
    # (d) PER-STEP INVERSE over the whole trajectory (M8.2 discipline: an
    #     aggregate round-trip can mask a mid-trajectory inverse bug).
    # ------------------------------------------------------------------
    @testset "(d) per-step inverse holds at every step" begin
        entry_args = first(_SET7).second.args
        inputs = Dict(entry_args[1][1] => Int64(0), entry_args[2][1] => Int64(5))
        mc = _BV7.compute_must_cache(_PROG7)
        rs = _BV7.initial_state(_PROG7, inputs)
        init = deepcopy(rs.current)
        snaps = _BV7.IState[]
        while !_BV7.is_halted(rs)
            _BV7.step!(rs, _PROG7; checkpoint_interval = 32, must_cache_set = mc)
            push!(snaps, deepcopy(rs.current))
            length(snaps) <= 100_000 ||
                error("7wsz _use7wsz forward exceeded 100000 steps")
        end
        @test length(snaps) > 3                   # non-vacuous
        ok = true
        while rs.step_count > 0
            _BV7.unstep!(rs, _PROG7)
            expected = rs.step_count > 0 ? snaps[rs.step_count] : init
            if rs.current != expected
                ok = false
                break
            end
        end
        @test ok
        @test rs.step_count == 0
        @test rs.current == init
    end

    # ------------------------------------------------------------------
    # (e) THE SPLIT-ROOTS SHAPE — `return_roots` + the `i64 -1` sentinel,
    #     verbatim, end-to-end. Discharges upstream risks R4 and R5.
    #
    #     The oracle is arithmetic on three separately-sourced values:
    #       sret field 0 (= %data), the SENTINEL in sret field 1 (= -1), and
    #       return_roots[0] (= %mem, written by the CALLEE through a pointer
    #       cell the CALLER allocated). Getting ANY of them wrong changes the
    #       number, so this is not a "didn't throw" test.
    # ------------------------------------------------------------------
    @testset "(e) return_roots + `i64 -1` sentinel run and reverse verbatim" begin
        @test length(_SET7RR) == 2
        callee = only(p.second for p in _SET7RR if p.first === :rr_callee)
        @test callee.ret_width == 128
        @test callee.ret_elem_widths == [64, 64]
        # `return_roots` is an ORDINARY 64-bit cell param (no fusion, no elision)
        @test (:return_roots, 64) in callee.args
        cinsts = [i for b in callee.blocks for i in b.instructions]
        # R4: the sentinel is a ConstOperand INSIDE an IRInsertBits chain —
        # a value shape no in-corpus bits-struct had produced before 7wsz.
        ib = [i for i in cinsts if i isa _B7.IRInsertBits]
        @test length(ib) == 2
        @test ib[2].val isa _B7.ConstOperand && ib[2].val.value == -1
        # R5: the callee writes the GC-root through the caller's cell.
        st = only(i for i in cinsts if i isa _B7.IRStore)
        @test st.width == 64
        @test st.ptr isa _B7.SSAOperand && st.ptr.name === :return_roots

        @test haskey(_PROG7RR.functions, :rr_callee)
        vmins = [i for b in _PROG7RR.blocks for i in b.instructions]
        @test count(i -> i isa _BV7.CallEnter, vmins) == 1
        @test !any(i -> i isa _BV7.SoftCall, vmins)

        ret        = _ret_symbol7wsz(_PROG7RR, :rr_caller)
        entry_args = only(p.second for p in _SET7RR if p.first === :rr_caller).args
        @test [n for (n, _w) in entry_args] == [:data, :mem]

        mc = _BV7.compute_must_cache(_PROG7RR)
        for (label, mcs) in (("L2 (compute_must_cache)", mc),
                             ("L3 (empty must_cache)", Set{Tuple{Symbol,Int}}()))
            for (dat, mem) in ((Int64(100), Int64(7)), (Int64(0), Int64(0)),
                               (Int64(-9), Int64(1_000_003)))
                inputs = Dict(:data => dat, :mem => mem)
                rs = _BV7.initial_state(_PROG7RR, inputs)
                init = deepcopy(rs.current)
                _BV7.run!(rs, _PROG7RR; max_steps = 100_000,
                          checkpoint_interval = 32, must_cache_set = mcs)
                @test _BV7.is_halted(rs)
                # data (sret f0) + mem (via return_roots) + (-1) (the sentinel)
                @test _BV7.result(rs)[ret] == dat + mem - 1

                _BV7.unrun!(rs, _PROG7RR; max_unsteps = 100_000)
                @test rs.current == init          # exact reverse ($label)
                @test isempty(rs.history)
                @test rs.step_count == 0
            end
        end

        # per-step inverse on the roots fixture too
        rs = _BV7.initial_state(_PROG7RR, Dict(:data => Int64(100),
                                               :mem  => Int64(7)))
        init = deepcopy(rs.current)
        snaps = _BV7.IState[]
        while !_BV7.is_halted(rs)
            _BV7.step!(rs, _PROG7RR; checkpoint_interval = 32, must_cache_set = mc)
            push!(snaps, deepcopy(rs.current))
            length(snaps) <= 100_000 ||
                error("7wsz rr_caller forward exceeded 100000 steps")
        end
        @test length(snaps) > 3
        ok = true
        while rs.step_count > 0
            _BV7.unstep!(rs, _PROG7RR)
            expected = rs.step_count > 0 ? snaps[rs.step_count] : init
            if rs.current != expected
                ok = false
                break
            end
        end
        @test ok
        @test rs.current == init
    end
end
