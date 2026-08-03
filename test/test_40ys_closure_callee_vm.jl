# test/test_40ys_closure_callee_vm.jl — the BennettVM (downstream) half of
# Bennett.jl bead `Bennett-40ys`: an INSTANCE-LESS callee end-to-end.
#
# # What upstream changed, and why this file exists
#
# `Bennett.extract_parsed_ir_set_from_julia` keys each callee by its `specTypes`
# head. For a plain function that head is a SINGLETON `typeof(g)` and the
# producer recovered the callable as `g = k.instance`. Julia 1.12 outlines
# `_growend!`'s slow path into a CLOSURE, so any `push!`-bearing root yields a
# head like `Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, …}` — a
# concrete callable type with EIGHT FIELDS and therefore no `.instance`. Reading
# it produced a bare `UndefRefError: access to undefined reference`, from a
# registration loop outside any try/catch, so even `on_extract_error=:skip`
# could not rescue it.
#
# The fix moves the producer from a VALUE interface to a SIGNATURE interface:
# Julia's own codegen consumes the callable only via
# `signature_type(f, t) == Tuple{typeof(f), t...}`, which is exactly the
# `specTypes` the call graph already holds, so `Bennett.extract_parsed_ir_by_sig`
# emits the body from the type alone. That covers closures AND functors — the
# same Julia concept, "a callable type with fields".
#
# **The upstream bead cannot prove the downstream half.** Two claims it makes
# are BennettVM's to verify, and both are load-bearing:
#
#   1. The extracted set is SELF-CONSISTENT — the caller's `IRCall` to an
#      instance-less callee must carry the BARE canonical name, not the
#      drift-prone mangled `j_<name>_<NNN>`, or `_vm_dispatch_name` (which does
#      no demangling) will never agree with the table key's `_vm_funcname` and
#      guard-5 resolution fails.
#   2. The by-pointer captured-state ABI — the caller allocas the callable's
#      fields, stores into them, and passes the ADDRESS as a 64-bit cell; the
#      callee reads its fields back through `IRLoad`/`IRPtrOffset` from that
#      cell. Nothing had exercised a cross-frame pointer-into-the-caller's-frame
#      read at a `CallEnter` boundary on the Julia track.
#
# **This file is that proof**, and it is a cross-repo contract test: it fails if
# Bennett.jl reverts to emitting mangled callee symbols, if the digest stops
# producing the `#<8hex>` shape `_vm_funcname` requires, or if BVM stops
# resolving a bare `Symbol` callee against the function table.
#
# # The fixture, and why it is synthetic
#
# `push!` itself still does NOT extract: its outlined closure returns
# `sret({ ptr, ptr })` and `_sret_struct_fields` admits only fixed-width integer
# bits-struct fields. That is bead `Bennett-dv1z`, the NEXT wall, deliberately
# not cleared by 40ys (upstream gate (I) asserts the wall is reached and NAMED).
#
# So the capability is proven on the smallest HONEST arrangement that produces a
# genuine instance-less `:invoke` edge while clearing dv1z: a FUNCTOR with a
# single `Int64` field and an `i64` return (no sret, no pointer captures).
# `@noinline` on its call method is what keeps the edge an `:invoke` instead of
# being inlined into the root — without it Julia folds the whole thing away and
# `transitive_callees` returns an empty set. A closure with `Int`-only captures
# works identically (upstream gate (D) covers it); the functor is used here
# because it also demonstrates that the arm is keyed on the general property
# "callable type with no `.instance`", not on "closure".
#
# The captured state is INTEGER ONLY, deliberately: a `Vector`/`Memory` capture
# would re-introduce the dv1z ptr-field wall this bead does not clear.
#
# # What it pins (Rule 4 — known values, never "didn't throw")
#
#   (a) EXTRACT — a 2-body closed-world set; the callee key is
#       content-addressed `Adder40ys#<8hex>`; the call site carries the BARE
#       `:Adder40ys`, and NO mangled `j_`/`julia_` symbol survives anywhere.
#   (b) NAME BINDING — `_vm_funcname(table key) === _vm_dispatch_name(call site)`.
#       This is the exact equality the whole linkage rests on; asserted directly
#       so a future sanitisation change breaks loudly HERE rather than as a
#       mystery guard-5 failure.
#   (c) INGEST — `lower_vm` builds a `VMProgram` with both functions, and the
#       call really became a `CallEnter` to the callee (not a `SoftCall`).
#   (d) RUN — `_root40ys(x)` against the native Julia oracle for several `x`,
#       then `unrun!` to the EXACT initial state with EMPTY history, under both
#       the L2 (`compute_must_cache`) and L3 (empty must_cache) regimes.
#   (e) PER-STEP INVERSE over the whole trajectory (the M8.2 discipline: an
#       aggregate round-trip can mask a mid-trajectory inverse bug).
#   (f) THE ABI — the cross-frame read is REAL: the callee's `IRLoad` of the
#       captured field must observe the value the CALLER stored, which is the
#       only way the oracle can match. Non-vacuity is asserted (the load must
#       actually execute).
#
# # Ref
#   * `../Bennett.jl/test/test_40ys_instanceless_callees.jl` — the upstream half.
#   * `../Bennett.jl/docs/design/40ys/proposal_A.md` / `proposal_B.md`.
#   * `../Bennett.jl/src/extract/sig_llvm.jl` — the by-signature mechanism.
#   * `test/test_a70z_dict64_roundtrip.jl` — the template for this file.
#   * `src/ir/ingest_multi.jl` `_vm_funcname` / `ingest_body.jl` `_vm_dispatch_name`.

using Test
using BennettVM
import Bennett

const _BV40 = BennettVM
const _B40 = Bennett

# The instance-less callee: a functor. `isdefined(Adder40ys, :instance) == false`
# for the same reason a closure type's is — it has a field.
struct Adder40ys
    n::Int64
end
@noinline (a::Adder40ys)(x::Int64) = x + a.n * 3

# The root. `@noinline` above is what keeps this an `:invoke` edge.
_root40ys(x::Int64) = Adder40ys(x)(x + 1)

# The irreversible native oracle (Rule 4), a DISTINCT binding so neither can be
# silently constant-folded into the other.
_oracle40ys(x::Int64) = x + 1 + x * 3

# ---- the TWO-field (16-byte) capture, for gate (g) ----
#
# `Adder40ys` is 8 bytes, so its callee-side arg width (`8 * sizeof`) happens to
# equal the caller-side 64-bit cell width. That agreement — asserted in gate (a)
# — is a coincidence of SIZE, not an invariant. A 16-byte capture breaks it: the
# caller passes one 64-bit cell while the callee's `ParsedIR.args` declares 128
# (bead **Bennett-ce9t**, pinned upstream in
# `../Bennett.jl/test/test_40ys_instanceless_callees.jl` gate (K)).
#
# It is INERT here, and gate (g) is the proof: `lower_vm` builds its param list
# as `Symbol[n for (n, _w) in parsed.args]` (`ingest_multi.jl`), dropping widths
# entirely, and `CallEnter` binds args positionally by name — so the wrong
# number is never read, and the fixture runs and reverses correctly.
#
# That is a load-bearing claim, not a footnote: if a future change starts
# CONSUMING `parsed.args` widths (an ABI check, a masking pass), this gate goes
# RED and Bennett-ce9t stops being inert. When that happens, fix ce9t — do not
# delete the gate.
struct Pair40ys
    a::Int64
    b::Int64
end
@noinline (p::Pair40ys)(x::Int64) = x * p.a + p.b
_root2_40ys(x::Int64) = Pair40ys(x, x + 7)(x + 1)
_oracle2_40ys(x::Int64) = (x + 1) * x + (x + 7)

# The entry function's single return SSA name (`result(rs)` keys by SSA name).
function _ret_symbol40ys(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BV40.EndInstruction && b.exit.label === entry &&
           !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

const _SET40  = _B40.extract_parsed_ir_set_from_julia(_root40ys, Tuple{Int64};
                                                      ptr_cells = true)
const _PROG40 = _BV40.lower_vm(_SET40; entry = first(_SET40).first)

const _SET40B  = _B40.extract_parsed_ir_set_from_julia(_root2_40ys, Tuple{Int64};
                                                       ptr_cells = true)
const _PROG40B = _BV40.lower_vm(_SET40B; entry = first(_SET40B).first)

@testset "Bennett-40ys — instance-less (functor) callee: extract → ingest → run → reverse" begin

    # ------------------------------------------------------------------
    # (a) EXTRACT — a self-consistent 2-body set with a BARE call site.
    # ------------------------------------------------------------------
    @testset "(a) extract: 2-body set, bare callee symbol, no mangled names" begin
        @test length(_SET40) == 2
        keys_ = [p.first for p in _SET40]
        @test startswith(String(keys_[1]), "_root40ys#")     # entry-first ordering
        @test startswith(String(keys_[2]), "Adder40ys#")
        # Content-addressed shape is what `_vm_funcname` requires.
        @test all(k -> occursin(r"#[0-9a-fA-F]{8}$", String(k)), keys_)

        calls = [i for (_k, pir) in _SET40 for b in pir.blocks
                 for i in b.instructions if i isa _B40.IRCall]
        @test length(calls) == 1
        @test calls[1].callee === :Adder40ys        # BARE, not j_Adder40ys_<NNN>
        # Nothing anywhere in the set carries a drift-prone mangled symbol.
        @test !any(c -> occursin(r"^(?:j|julia)_", String(_BV40._callee_sym(c.callee))),
                   calls)

        # The ABI the VM must bind: 2 args each side, all 64-bit cells.
        callee_pir = _SET40[2].second
        @test calls[1].arg_widths == [w for (_n, w) in callee_pir.args] == [64, 64]
        @test calls[1].ret_width == callee_pir.ret_width == 64
        # The captured state travels BY POINTER: the caller allocas it, stores
        # into it, and passes the address as arg 1.
        root_insts = [i for b in _SET40[1].second.blocks for i in b.instructions]
        @test any(i -> i isa _B40.IRAlloca, root_insts)
        @test any(i -> i isa _B40.IRStore, root_insts)
        @test calls[1].args[1] isa _B40.SSAOperand
        @test calls[1].args[1].name === only(i.dest for i in root_insts
                                             if i isa _B40.IRAlloca)
    end

    # ------------------------------------------------------------------
    # (b) NAME BINDING — the exact equality the linkage rests on.
    # ------------------------------------------------------------------
    @testset "(b) _vm_funcname(table key) === _vm_dispatch_name(call site)" begin
        callee_key = _SET40[2].first
        call = only(i for (_k, pir) in _SET40 for b in pir.blocks
                    for i in b.instructions if i isa _B40.IRCall)
        @test _BV40._vm_funcname(callee_key) === _BV40._vm_dispatch_name(call.callee)
        @test _BV40._vm_funcname(callee_key) === :Adder40ys

        # The same identity must hold for a '#'-bearing CLOSURE barename, which
        # is the shape the real `push!` corpus produces once Bennett-dv1z lands.
        # Pinned here (rather than left to that bead) because it is BVM's half of
        # the contract and costs nothing: key `#_growend!##0#a7027856`, call site
        # `#_growend!##0`.
        @test _BV40._vm_funcname(Symbol("#_growend!##0#a7027856")) ===
              _BV40._vm_dispatch_name(Symbol("#_growend!##0")) ===
              Symbol("._growend!..0")
    end

    # ------------------------------------------------------------------
    # (c) INGEST — both functions in the table; a real CallEnter.
    # ------------------------------------------------------------------
    @testset "(c) ingest: lower_vm binds the call to the in-set callee" begin
        @test _PROG40 isa _BV40.VMProgram
        @test haskey(_PROG40.functions, :Adder40ys)
        @test haskey(_PROG40.functions, :_root40ys)

        vmins = [i for b in _PROG40.blocks for i in b.instructions]
        # Guard-5 resolved it: a CallEnter, NOT a SoftCall degrade.
        enters = [i for i in vmins if i isa _BV40.CallEnter]
        @test length(enters) == 1
        @test !any(i -> i isa _BV40.SoftCall, vmins)
        # It carries the two cells and expects one return.
        @test length(enters[1].args) == 2
        @test length(enters[1].targets) == 1
    end

    # ------------------------------------------------------------------
    # (d) RUN — value vs the native oracle, then exact reverse, L2 and L3.
    # ------------------------------------------------------------------
    @testset "(d) e2e: _root40ys(x) matches the oracle, then unrun! is exact" begin
        entry_vm   = _BV40._vm_funcname(first(_SET40).first)
        ret        = _ret_symbol40ys(_PROG40, entry_vm)
        entry_args = first(_SET40).second.args
        @test length(entry_args) == 1

        mc = _BV40.compute_must_cache(_PROG40)
        for (label, mcs) in (("L2 (compute_must_cache)", mc),
                             ("L3 (empty must_cache)", Set{Tuple{Symbol,Int}}()))
            for x in (Int64(5), Int64(0), Int64(-3), Int64(1_000_003))
                inputs = Dict(first(entry_args[1]) => x)
                rs = _BV40.initial_state(_PROG40, inputs)
                init = deepcopy(rs.current)
                _BV40.run!(rs, _PROG40; max_steps = 100_000,
                           checkpoint_interval = 32, must_cache_set = mcs)
                @test _BV40.is_halted(rs)
                # Value correctness ALONGSIDE reversibility: a self-aliasing
                # miscompile would still round-trip. The oracle is computed
                # natively, so this is the cross-frame captured-state read
                # ((f)) landing on the right number.
                @test _BV40.result(rs)[ret] == _oracle40ys(x)
                @test _BV40.result(rs)[ret] == _root40ys(x)

                _BV40.unrun!(rs, _PROG40; max_unsteps = 100_000)
                @test rs.current == init          # exact reverse ($label)
                @test isempty(rs.history)
                @test rs.step_count == 0
            end
        end
    end

    # ------------------------------------------------------------------
    # (e) PER-STEP INVERSE over the whole trajectory.
    # ------------------------------------------------------------------
    @testset "(e) per-step inverse holds at every step of the trajectory" begin
        inputs = Dict(first(first(_SET40).second.args[1]) => Int64(5))
        mc = _BV40.compute_must_cache(_PROG40)
        rs = _BV40.initial_state(_PROG40, inputs)
        init = deepcopy(rs.current)
        snaps = _BV40.IState[]
        while !_BV40.is_halted(rs)
            _BV40.step!(rs, _PROG40; checkpoint_interval = 32, must_cache_set = mc)
            push!(snaps, deepcopy(rs.current))
            length(snaps) <= 100_000 ||
                error("40ys _root40ys forward exceeded 100000 steps")
        end
        @test length(snaps) > 3                   # non-vacuous
        ok = true
        while rs.step_count > 0
            _BV40.unstep!(rs, _PROG40)
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
    # (f) THE ABI — the cross-frame captured-state read really executes.
    #     Without this, (d) could pass on a trajectory that never touched
    #     the caller's frame from the callee.
    # ------------------------------------------------------------------
    @testset "(f) the callee's load of the caller-stored capture executes" begin
        callee_pir = _SET40[2].second
        loads = [i for b in callee_pir.blocks for i in b.instructions
                 if i isa _B40.IRLoad]
        @test length(loads) == 1
        load_dest = loads[1].dest
        # The loaded value must be the `x` the CALLER stored into the alloca.
        x = Int64(5)
        inputs = Dict(first(first(_SET40).second.args[1]) => x)
        mc = _BV40.compute_must_cache(_PROG40)
        rs = _BV40.initial_state(_PROG40, inputs)
        seen = Int64[]
        nsteps = 0
        while !_BV40.is_halted(rs)
            _BV40.step!(rs, _PROG40; checkpoint_interval = 32, must_cache_set = mc)
            nsteps += 1
            nsteps <= 100_000 ||
                error("40ys _root40ys forward exceeded 100000 steps")
            # `active_locals` is FRAME-scoped: reading it (rather than a
            # name-only global scan) is what attributes the value to the
            # CALLEE's frame, which is the whole point of this gate.
            loc = _BV40.active_locals(rs.current)
            haskey(loc, load_dest) && push!(seen, loc[load_dest])
        end
        @test !isempty(seen)                       # NON-VACUITY: it executed
        @test all(==(x), seen)                     # and it read the stored capture
    end

    # ------------------------------------------------------------------
    # (g) A 16-BYTE capture: the width coincidence broken, end-to-end.
    #
    # `Adder40ys` is 8 bytes, so gate (a)'s
    # `arg_widths == callee arg widths` holds only because `8*8 == 64`.
    # `Pair40ys` is 16 bytes: the caller passes ONE 64-bit cell while the
    # callee declares 128 (Bennett-ce9t). This gate proves the mismatch
    # is INERT — the capability is real for captures of any size, not
    # just the one where the numbers happen to line up — and it is the
    # tripwire that fires the day anything starts consuming those widths.
    #
    # Same battery as (a)+(d)+(e), on the 2-field fixture.
    # ------------------------------------------------------------------
    @testset "(g) 16-byte capture: width mismatch is inert; e2e + round-trip" begin
        # -- the mismatch, pinned on both sides (Bennett-ce9t) --
        @test length(_SET40B) == 2
        @test startswith(String(_SET40B[1].first), "_root2_40ys#")
        @test startswith(String(_SET40B[2].first), "Pair40ys#")
        call = only(i for (_k, pir) in _SET40B for b in pir.blocks
                    for i in b.instructions if i isa _B40.IRCall)
        @test call.callee === :Pair40ys                     # still BARE-bound
        callee_widths = [w for (_n, w) in _SET40B[2].second.args]
        @test call.arg_widths  == [64, 64]                  # caller: cells
        @test callee_widths    == [128, 64]                 # callee: 8*sizeof
        @test call.arg_widths != callee_widths              # THE GAP
        # ...and this is exactly why BVM does not notice:
        @test _BV40._vm_funcname(_SET40B[2].first) === :Pair40ys
        @test haskey(_PROG40B.functions, :Pair40ys)
        @test _PROG40B.functions[:Pair40ys].params ==
              [n for (n, _w) in _SET40B[2].second.args]     # names only, no widths

        enters = [i for b in _PROG40B.blocks for i in b.instructions
                  if i isa _BV40.CallEnter]
        @test length(enters) == 1
        @test length(enters[1].args) == 2
        @test !any(i isa _BV40.SoftCall
                   for b in _PROG40B.blocks for i in b.instructions)

        # -- RUN + REVERSE, L2 and L3, incl. negative and large captures --
        entry_vm   = _BV40._vm_funcname(first(_SET40B).first)
        ret        = _ret_symbol40ys(_PROG40B, entry_vm)
        entry_args = first(_SET40B).second.args
        @test length(entry_args) == 1

        mc = _BV40.compute_must_cache(_PROG40B)
        for (label, mcs) in (("L2 (compute_must_cache)", mc),
                             ("L3 (empty must_cache)", Set{Tuple{Symbol,Int}}()))
            for x in (Int64(5), Int64(0), Int64(1), Int64(-3), Int64(-1_000_003),
                      Int64(2_147_483_647), Int64(-2_147_483_648))
                inputs = Dict(first(entry_args[1]) => x)
                rs = _BV40.initial_state(_PROG40B, inputs)
                init = deepcopy(rs.current)
                _BV40.run!(rs, _PROG40B; max_steps = 100_000,
                           checkpoint_interval = 32, must_cache_set = mcs)
                @test _BV40.is_halted(rs)
                # BOTH captured fields must have crossed the boundary: the
                # oracle mixes `a` (multiplied) and `b` (added), so getting
                # either wrong changes the answer.
                @test _BV40.result(rs)[ret] == _oracle2_40ys(x)
                @test _BV40.result(rs)[ret] == _root2_40ys(x)

                _BV40.unrun!(rs, _PROG40B; max_unsteps = 100_000)
                @test rs.current == init          # exact reverse ($label)
                @test isempty(rs.history)
                @test rs.step_count == 0
            end
        end

        # -- PER-STEP INVERSE over the whole trajectory --
        inputs = Dict(first(entry_args[1]) => Int64(-1_000_003))
        rs = _BV40.initial_state(_PROG40B, inputs)
        init = deepcopy(rs.current)
        snaps = _BV40.IState[]
        while !_BV40.is_halted(rs)
            _BV40.step!(rs, _PROG40B; checkpoint_interval = 32, must_cache_set = mc)
            push!(snaps, deepcopy(rs.current))
            length(snaps) <= 100_000 ||
                error("40ys _root2_40ys forward exceeded 100000 steps")
        end
        @test length(snaps) > 3                             # non-vacuous
        ok = true
        while rs.step_count > 0
            _BV40.unstep!(rs, _PROG40B)
            expected = rs.step_count > 0 ? snaps[rs.step_count] : init
            if rs.current != expected
                ok = false
                break
            end
        end
        @test ok
        @test rs.step_count == 0
        @test rs.current == init

        # -- the SECOND field really is read across the frame boundary --
        callee_insts = [i for b in _SET40B[2].second.blocks for i in b.instructions]
        @test count(i -> i isa _B40.IRLoad, callee_insts) == 2      # a and b
        @test any(i -> i isa _B40.IRPtrOffset && i.offset_bytes == 8, callee_insts)
    end
end
