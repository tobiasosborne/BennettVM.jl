# test/test_cwd4_genericmemory.jl — bead `bennettvm-9n3y` (CW-D4): faithful
# reversible GenericMemory allocation model + the byte-granular Julia heap tier.
#
# # What this file pins (Rule 4 — known values, not "didn't throw")
#
# The CW-D4 wall (scratchpad/scout-cwd4-element-traffic.md): the VM never wrote
# the GenericMemory data-pointer field (`jl_alloc_genericmemory_unchecked`
# lowered to a bare bump alloc), so slots/keys/vals all read data-ptr = absent
# = 0 and collapsed onto ONE cell (`vals` overwrote `keys`, read-back missed,
# `__unreachable__`). A second defect compounded it: `gc_alloc_obj` reserved
# `nbytes ÷ 8` cells while Julia struct-field GEPs are BYTE-granular, so a
# 64-byte Dict reserved 8 cells and the next Memory's header landed INSIDE the
# Dict's field footprint (Dict.keys@+8 clobbered by the slots Memory length).
#
# CW-D4 (architecture = design-cwd4-A, mechanics adopted from design-cwd4-B):
#
#   * `IntrinsicGenericMemoryAlloc(dest, nbytes_data, tag)` materialises a
#     BYTE-granular {length@+0, data-ptr@+8, inline data@+16} object: reserves
#     `GM_HEADER_CELLS(16) + nbytes_data` cells and its `forward` writes
#     `M[base+8] = base+16` (the ONE field the native runtime — not emitted IR
#     — sets). Length stays the program's own explicit store
#     (callee_rehash!.ll:737). Reversal: the inherited `_ArenaAlloc` L2
#     (base, cells) region-delete (the data-ptr cell was absent pre-alloc, so
#     the unconditional delete restores absent-ness — the IntrinsicCalloc
#     precedent).
#   * `IntrinsicGCAlloc` (Julia boxed structs) reserves `nbytes` BYTE-cells
#     (was `÷8` — defect D-b), so byte-offset Dict fields 0..56 fit.
#   * The C/malloc tier is UNTOUCHED (`÷8`, SWAR memset, wide loads).
#     Mixed C+Julia allocs in one program fail loud; a Julia-tier program's
#     `memset` is rewritten to the byte-exact `IntrinsicMemsetBytes`;
#     Julia-tier `memcpy`/`memmove` fail loud (unmodeled byte-tier span).
#
# The e2e deliverable: fdict(3,7) == 7 AND fdict(5,9) == 9 with a full
# round-trip to the exact initial state + EMPTY history (R3 guard from design
# B: value-correctness asserted ALONGSIDE reversibility — reversibility alone
# hides self-aliasing miscompiles).
#
# # Ref
#   * scratchpad/scout-cwd4-element-traffic.md — the root-cause trace.
#   * scratchpad/design-cwd4-A.md (base) / design-cwd4-B.md (mechanics).
#   * scratchpad/callee_rehash!.ll:736-737 (length store), :755-769 (fill!
#     reads data-ptr via the BYTE-shaped `gep i8 %m, 8` — the dual-shape
#     ground truth that forced byte granularity).
#   * src/ir/intrinsics_genericmemory.jl — the implementation.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BVc = BennettVM
const _Bc  = Bennett
const _ABc = BennettVM.ARENA_BASE

# The entry function's single return SSA name (the EndInstruction.returns of
# the entry block) — the test_c_hashtable_e2e idiom; result(rs) keys by SSA name.
function _cwd4_return_symbol(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BVc.EndInstruction && b.exit.label === entry &&
           !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

@testset "bennettvm-9n3y CW-D4 — GenericMemory model + byte-granular Julia tier" begin

    # ------------------------------------------------------------------
    # (i-a) unit: IntrinsicGenericMemoryAlloc forward — header + data-ptr.
    # ------------------------------------------------------------------
    @testset "unit: forward writes data-ptr@+8 = base+16; reserves 16+nbytes" begin
        IS = _BVc.IState
        s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        pre = deepcopy(s)
        instr = _BVc.IntrinsicGenericMemoryAlloc(:m, Int64(16), Int64(99))
        p = _BVc.predelta_payload(instr, s)          # PRE-forward L2 capture
        @test p.base == _ABc
        @test p.cells == 32                          # 16 header + 16 data bytes
        _BVc.forward(instr, s)
        @test _BVc.active_locals(s)[:m] == _ABc      # first alloc → ARENA_BASE+0
        @test s.arena_top == 32
        # data-ptr @ byte-cell +8 points at the inline data region @ +16.
        @test s.memory[_ABc + 8] == _ABc + 16
        # length (@+0) is NOT written by the alloc — the program's own store owns it.
        @test !haskey(s.memory, _ABc + 0)
        # inverse: region-delete restores ABSENT-ness of the data-ptr cell
        # (delete!, never a phantom {addr=>0}) + retracts cursor + pointer.
        _BVc.inverse(instr, s, p)
        @test s == pre
        @test s.arena_top == 0
        @test isempty(s.memory)                      # no phantom data-ptr cell
        @test !haskey(_BVc.active_locals(s), :m)
    end

    @testset "unit: type_tag is metadata — SSA tag never read by the transition" begin
        IS = _BVc.IState
        s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        # :typ deliberately NOT in locals — forward must not resolve it.
        instr = _BVc.IntrinsicGenericMemoryAlloc(:m, Int64(8), :typ)
        _BVc.forward(instr, s)
        @test s.memory[_ABc + 8] == _ABc + 16
        @test s.arena_top == 24                      # 16 + 8
    end

    # ------------------------------------------------------------------
    # (i-b) unit: gc_alloc_obj byte-span reservation — the exact regression
    # from the scout diagnosis: a 64-byte Dict must cover byte-offsets 0..63,
    # so the NEXT Memory header lands at +64, NOT inside the Dict footprint
    # (pre-fix it landed at +8 == Dict.keys — the header/field clobber).
    # ------------------------------------------------------------------
    @testset "unit: gc_alloc_obj(64) reserves 64 byte-cells; next alloc disjoint" begin
        IS = _BVc.IState
        s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        _BVc.forward(_BVc.IntrinsicGCAlloc(:d, Int64(64), Int64(0)), s)
        @test _BVc.active_locals(s)[:d] == _ABc
        @test s.arena_top == 64                      # BYTE-cells (was 8 — defect D-b)
        _BVc.forward(_BVc.IntrinsicGenericMemoryAlloc(:m, Int64(16), Int64(0)), s)
        # The Memory base clears the whole Dict field footprint (fields @ 0..56).
        @test _BVc.active_locals(s)[:m] == _ABc + 64
        @test _BVc.active_locals(s)[:m] > _ABc + 56
        # Its data-ptr cell (+8 within ITS OWN header) is at Dict+72 — not Dict.keys@+8.
        @test s.memory[_ABc + 64 + 8] == _ABc + 64 + 16
        @test !haskey(s.memory, _ABc + 8)            # Dict.keys cell untouched
    end

    # ------------------------------------------------------------------
    # (i-c) unit: IntrinsicMemsetBytes — byte-exact fill (each byte-cell holds
    # the fill byte; no SWAR smear), L2 per-cell delta round-trip.
    # ------------------------------------------------------------------
    @testset "unit: IntrinsicMemsetBytes byte-exact fill + inverse" begin
        IS = _BVc.IState
        s = IS(1, Dict{Symbol,Int64}(:p => _ABc), :running,
               Dict{Int64,Int64}(_ABc + 1 => Int64(555)))   # pre-existing cell
        pre = deepcopy(s)
        instr = _BVc.IntrinsicMemsetBytes(:p, Int64(0xAB), Int64(3))
        p = _BVc.predelta_payload(instr, s)
        _BVc.forward(instr, s)
        @test s.memory[_ABc + 0] == 0xAB             # byte VALUE, not 0xABAB…AB
        @test s.memory[_ABc + 1] == 0xAB             # overwrote the 555
        @test s.memory[_ABc + 2] == 0xAB
        @test !haskey(s.memory, _ABc + 3)            # span is EXACTLY nbytes cells
        _BVc.inverse(instr, s, p)
        @test s == pre                               # 555 restored, absents restored
    end

    # ------------------------------------------------------------------
    # (ii) ingest: the genericmemory arm emits the NEW intrinsic; a Julia-tier
    # program's memset is rewritten to IntrinsicMemsetBytes.
    # ------------------------------------------------------------------
    @testset "ingest: jl_alloc_genericmemory_unchecked → IntrinsicGenericMemoryAlloc" begin
        call = _Bc.IRCall(:m, :jl_alloc_genericmemory_unchecked,
                          _Bc.IROperand[_Bc.ssa(:ptls), _Bc.iconst(16), _Bc.iconst(99)],
                          [64, 64, 64], 64)
        instr = _BVc._lower_intrinsic_call(call, :jl_alloc_genericmemory_unchecked)
        @test instr isa _BVc.IntrinsicGenericMemoryAlloc
        @test instr.dest === :m
        @test instr.nbytes_operand == Int64(16)      # a[2] = DATA bytes (smul product)
        @test instr.type_tag == Int64(99)            # a[3] = metadata (ptls dropped)
    end

    @testset "ingest: Julia-tier memset rewritten to IntrinsicMemsetBytes" begin
        # gc_alloc_obj(:d) then memset(d, 0, 16) — the rehash! fill!(slots, 0x0)
        # shape. The tier pass must swap the word-granular SWAR memset for the
        # byte-exact variant.
        alloc = _Bc.IRCall(:d, :gc_alloc_obj,
                           _Bc.IROperand[_Bc.iconst(64), _Bc.iconst(0)], [64, 64], 64)
        mset = _Bc.IRCall(:z, :memset,
                          _Bc.IROperand[_Bc.ssa(:d), _Bc.iconst(0), _Bc.iconst(16)],
                          [64, 64, 64], 64)
        blk = _Bc.IRBasicBlock(:entry, _Bc.IRInst[alloc, mset],
                               _Bc.IRRet(_Bc.SSAOperand(:d), 64))
        prog = _BVc.lower_vm(_Bc.ParsedIR(64, [(:x, 64)], [blk], [64]))
        insts = reduce(vcat, [b.instructions for b in prog.blocks];
                       init = _BVc.Instruction[])
        @test any(i -> i isa _BVc.IntrinsicMemsetBytes, insts)
        @test !any(i -> i isa _BVc.IntrinsicMemset, insts)
    end

    # ------------------------------------------------------------------
    # (iii) adversarial fail-louds — unmodeled shapes reject with named
    # constructs (Rule 1; the CW-D4 fail-loud completeness clause).
    # ------------------------------------------------------------------
    @testset "adversarial: negative data-byte size fails loud" begin
        IS = _BVc.IState
        s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        @test_throws ErrorException _BVc.forward(
            _BVc.IntrinsicGenericMemoryAlloc(:m, Int64(-8), Int64(0)), s)
    end

    @testset "adversarial: mixed C + Julia allocs in one program fail loud" begin
        alloc_c = _Bc.IRCall(:p, :malloc, _Bc.IROperand[_Bc.iconst(32)], [64], 64)
        alloc_j = _Bc.IRCall(:d, :gc_alloc_obj,
                             _Bc.IROperand[_Bc.iconst(64), _Bc.iconst(0)], [64, 64], 64)
        blk = _Bc.IRBasicBlock(:entry, _Bc.IRInst[alloc_c, alloc_j],
                               _Bc.IRRet(_Bc.SSAOperand(:d), 64))
        parsed = _Bc.ParsedIR(64, [(:x, 64)], [blk], [64])
        threw = false; msg = ""
        try
            _BVc.lower_vm(parsed)
        catch e
            threw = true; msg = sprint(showerror, e)
        end
        @test threw
        @test occursin("mixed", lowercase(msg))
        @test occursin("gc_alloc", lowercase(msg)) || occursin("julia", lowercase(msg))
    end

    @testset "adversarial: Julia-tier memcpy fails loud (unmodeled byte-tier span)" begin
        alloc_j = _Bc.IRCall(:d, :gc_alloc_obj,
                             _Bc.IROperand[_Bc.iconst(64), _Bc.iconst(0)], [64, 64], 64)
        mcpy = _Bc.IRCall(:z, :memcpy,
                          _Bc.IROperand[_Bc.ssa(:d), _Bc.ssa(:q), _Bc.iconst(16)],
                          [64, 64, 64], 64)
        blk = _Bc.IRBasicBlock(:entry, _Bc.IRInst[alloc_j, mcpy],
                               _Bc.IRRet(_Bc.SSAOperand(:d), 64))
        parsed = _Bc.ParsedIR(64, [(:q, 64)], [blk], [64])
        threw = false; msg = ""
        try
            _BVc.lower_vm(parsed)
        catch e
            threw = true; msg = sprint(showerror, e)
        end
        @test threw
        @test occursin("memcpy", lowercase(msg)) || occursin("memmove", lowercase(msg))
    end

    # ------------------------------------------------------------------
    # (iv) E2E — THE DELIVERABLE. fdict(a,b) == b for TWO input pairs, with a
    # full round-trip to the exact initial state + EMPTY history. Plus the
    # disjointness pin: exactly three Memory data-ptr headers whose data
    # regions are pairwise disjoint (the scout's collapse bug, inverted).
    # ------------------------------------------------------------------
    @testset "e2e: fdict stores + finds its key — value + round-trip" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = _Bc.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                                   ptr_cells = true)
        prog = _BVc.lower_vm(set; entry = first(set).first)
        mc = _BVc.compute_must_cache(prog)
        entry_vm = _BVc._vm_funcname(first(set).first)
        ret = _cwd4_return_symbol(prog, entry_vm)
        entry_args = first(set).second.args

        for (a, b) in ((Int64(3), Int64(7)), (Int64(5), Int64(9)))
            inputs = Dict(n => v for ((n, _w), v) in zip(entry_args, (a, b)))
            rs = _BVc.initial_state(prog, inputs)
            init = deepcopy(rs.current)
            _BVc.run!(rs, prog; max_steps = 500_000, checkpoint_interval = 32,
                      must_cache_set = mc)
            # (R3 guard) VALUE correctness alongside reversibility: the halted
            # run RETURNS b — a self-aliasing miscompile would still round-trip.
            @test _BVc.is_halted(rs)
            @test _BVc.result(rs)[ret] == b

            if a == 3
                # Disjointness pin: exactly 3 GenericMemory headers (slots /
                # keys / vals), each data-ptr@+8 → its own +16 data base, and
                # the three 16-byte data windows are pairwise disjoint.
                mem = rs.current.memory
                dp = sort([addr for (addr, v) in mem
                           if addr >= _ABc && v == addr + 8])   # data-ptr cells
                @test length(dp) == 3
                bases = [mem[a_] for a_ in dp]                  # data region bases
                @test all(b1 -> all(b2 -> b1 == b2 || abs(b1 - b2) >= 16, bases),
                          bases)
            end

            # ROUND-TRIP to the exact initial state + EMPTY history.
            _BVc.unrun!(rs, prog; max_unsteps = 500_000)
            @test rs.current == init
            @test isempty(rs.history)
            @test rs.step_count == 0
        end
    end

    # ------------------------------------------------------------------
    # (v) per-step inverse on the full fdict(3,7) trajectory: after EVERY
    # unstep!, rs.current equals the corresponding forward snapshot (the
    # M8.2 per_step_inverse_check pattern, inlined — the helper is local to
    # test_per_step_inverse.jl).
    # ------------------------------------------------------------------
    @testset "e2e: per-step inverse over the fdict trajectory" begin
        fdict_d1b2(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = _Bc.extract_parsed_ir_set_from_julia(fdict_d1b2, Tuple{Int8,Int8};
                                                   ptr_cells = true)
        prog = _BVc.lower_vm(set; entry = first(set).first)
        mc = _BVc.compute_must_cache(prog)
        entry_args = first(set).second.args
        inputs = Dict(n => v for ((n, _w), v) in
                      zip(entry_args, (Int64(3), Int64(7))))
        rs = _BVc.initial_state(prog, inputs)
        init = deepcopy(rs.current)
        snaps = _BVc.IState[]
        nmax = 100_000
        while !_BVc.is_halted(rs)
            _BVc.step!(rs, prog; checkpoint_interval = 32, must_cache_set = mc)
            push!(snaps, deepcopy(rs.current))
            length(snaps) <= nmax || error("fdict forward exceeded $nmax steps")
        end
        ok = true
        while rs.step_count > 0
            _BVc.unstep!(rs, prog)
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
end
