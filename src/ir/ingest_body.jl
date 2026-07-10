"""
    ParsedIR ingest — body-instruction + alloca lowering
    (M_UNBOUNDED.1, ADR 0012 §D1–D3; ADR 0009/0013/0014/0011/0008/0018)

Split out of `src/ir/ingest.jl` per bead `bennettvm-u110` / Rule 10 (the
~200-LOC ceiling): a PURE MOVE of the per-instruction translation layer —
`_lower_body_inst` (one non-terminator `IRInst` → one BennettVM body
`Instruction`, or `nothing` for `IRPhi`) and `_lower_alloca!` (the
bump-allocator lift, needing the routine-scope cursor and so kept out of
the pure per-instruction dispatch).

Included into the same `BennettVM` module AFTER `ingest_operands.jl`
(uses `_lower_operand` / `_lower_bool_operand`) and `ingest_call.jl` (the
`IRCall` arm consults `_NONDETERMINISTIC_CALLEES` / `_HEAP_DISPATCH` and
calls `_lower_intrinsic_call`), and BEFORE `ingest.jl`'s driver
(`_lower_parsed_ir`), which calls both functions in its body loop.

The `IRCall`-arm guard ordering is load-bearing (ADR 0018 §C): heap
dispatch BEFORE the Float32 guard BEFORE the SoftCall constructor. See
`ingest_call.jl` for the dispatch tables and the future guard-5
(ADR 0019 §8 `functions`-resolution) slot. Controlling decisions live in
the original `ingest.jl` docstring and the per-arm ADR citations inline.
"""

# ---------------------------------------------------------------------
# Body-instruction translation: the six IRInst types, generically.
# ---------------------------------------------------------------------

"""
    _lower_body_inst(inst::Bennett.IRInst) -> Union{Instruction,Nothing}

Translate one non-terminator `IRInst` to a BennettVM body `Instruction`,
or `nothing` for `IRPhi` (which becomes a block parameter, not a body
instruction — see this file's docstring §1).

  * `IRBinOp(dest, op, op1, op2)`  → `Define(dest, lower(op1), op, lower(op2))`.
  * `IRICmp(dest, predicate, …)`   → `Define(dest, lower(op1), predicate, lower(op2))`
    (the predicate is a valid `_apply_binop` comparison op — ADR 0012 §D2).
  * `IRSelect(dest, cond, op1, op2)`→ `SelectInstruction(dest, cond.name,
    lower(op1), lower(op2))` (cond is an `SSAOperand`, ADR 0012 §D3).
  * `IRCast(dest, op, operand, fw, tw)`→ `CastInstruction(dest, op,
    lower(operand), fw, tw)` (`op ∈ {:sext,:zext,:trunc}`, ADR 0013 §D-5).
  * `IRStore(ptr, val, width)`     → `MemoryStore(ptr.name, lower(val))`
    (the scalar memory floor, ADR 0014 §D2; `ptr` is an `SSAOperand` naming
    an alloca dest — a pointer is an `Int64` address in `locals`). IRStore
    produces NO SSA value (void), so this arm returns a real `Instruction`,
    NOT `nothing` — the caller appends it unconditionally.
  * `IRLoad(dest, ptr, width)`     → `MemoryLoad(dest, ptr.name)` (the scalar
    memory floor, ADR 0014 §D2).
  * `IRVarGEP(dest, base, index, elem_width)` → `VarGEP(dest, base.name,
    lower(index), stride=1)` (the array element-address create, ADR 0009
    Decision 2b). `base` is an `SSAOperand` naming an alloca dest. The cell
    stride is `1` (the VM is CELL-addressed, one `Int64` per cell, so
    `elem_width` (in BITS) does NOT enter the address) — it matches the bump
    allocator's `+N` cursor step. The produced pointer flows unchanged into a
    downstream `MemoryStore` / `MemoryLoad`. `IRVarGEP` produces an SSA value
    (`dest`), so this returns a real `Instruction`, NOT `nothing`.
  * `IRPhi`                         → `nothing` (handled as a param).

`IRAlloca` is NOT handled here — it needs the bump-allocator state threaded
through `_lower_parsed_ir` (ADR 0014 §D1), so it is lowered at the call site,
not in this pure per-instruction dispatch.

Any other `IRInst` subtype is rejected loudly (Rule 1).
"""

# Resolve an `IRCall.callee` to its dispatch NAME (a `Symbol`). Bennett.jl
# widened `IRCall.callee` to `Union{Function,Symbol}` (Bennett-k3ej / BVM ADR
# 0020 D1): a Julia-sourced callee is a `Function` (named via `nameof`), a
# C-track `.ll`-sourced callee is already a bare `Symbol` (name-only — no Julia
# `Function` object exists to bind). Every IRCall-arm dispatch decision
# (`_NONDETERMINISTIC_CALLEES`, `_HEAP_DISPATCH`, the SoftCall allowlist, and
# the guard-5 function table) keys off this name, so both inputs collapse to a
# `Symbol` here. NOT type-piracy on `Base.nameof` (CLAUDE.md Rule 14 / the
# explicit chunk-C directive): a local helper, defined for exactly the two
# `IRCall.callee` shapes.
_callee_sym(callee::Function) = nameof(callee)
_callee_sym(callee::Symbol)   = callee

# Resolve an `IRCall.callee` to its guard-5 DISPATCH name, converging with the
# multi-function table key (`_vm_funcname` in `ingest_multi.jl`). Call sites carry
# BARE names (no content-addressed `#<8hex>` digest to strip — a Julia set's
# in-set call site is a bare `nameof` `Function`), so ONLY the closure-'#'
# sanitise applies: a closure barename `#9` (whose table key is `#9#<digest>` →
# `_vm_funcname` → `.9`) becomes `.9` here too. A '#'-free callee is a fixed
# point, so intrinsic / soft / C-track callees (and every non-closure name) are
# untouched. Used for guard-5 resolution ONLY; the nondeterminism / heap /
# gc_loaded / Float32 guards stay on the raw `_callee_sym` byte-identically.
_vm_dispatch_name(callee) = Symbol(replace(String(_callee_sym(callee)), '#' => '.'))

function _lower_body_inst(inst::Bennett.IRInst,
                          functions::Dict{Symbol,FunctionEntry} =
                              Dict{Symbol,FunctionEntry}()
                          )::Union{Instruction,Nothing}
    if inst isa Bennett.IRBinOp
        # i1 (width==1) boolean algebra: a `ConstOperand` operand of an i1 op
        # is a 1-bit literal, but LLVM renders `true` as the SIGN-EXTENDED `-1`
        # (`xor i1 %c, true` — the boolean-NOT idiom). The cell-addressed VM is
        # unmasked Int64, so `%c ⊻ -1` would yield `-2` (a spurious "true" under
        # the nonzero=true branch convention) instead of the logical NOT. Mask
        # an i1 const operand to its low bit (`& 1`): `-1→1`, `0`/`1` unchanged,
        # so `%c ⊻ 1` is the correct NOT for `%c ∈ {0,1}`. This is the targeted
        # i1-boolean fix the multi-block Julia-O0 CFG needs. (Full per-`width`
        # masking — bead `bennettvm-bgc` — is now done via the `inst.width`
        # threaded into the `Define` below; for a true i1 op `width == 1`, the
        # `_apply_binop` `& mask` collapses to `& 1`, so this const-operand mask
        # and the in-op mask agree.) It is sound because an i1 value is always
        # 0/1 and i1 algebra over {0,1} is exact in Int64.
        return Define(inst.dest, _lower_bool_operand(inst.op1, inst.width),
                      inst.op, _lower_bool_operand(inst.op2, inst.width),
                      inst.width)
    elseif inst isa Bennett.IRICmp
        # IRICmp.width is the OPERAND width (the i1 result is never masked);
        # `_apply_binop` extends the operands per the predicate's signedness
        # at this width, then returns the unmasked 0/1 i1 result (ADR 0012
        # R1 / §D2, bead `bennettvm-bgc`).
        return Define(inst.dest, _lower_operand(inst.op1), inst.predicate,
                      _lower_operand(inst.op2), inst.width)
    elseif inst isa Bennett.IRSelect
        if inst.cond isa Bennett.ConstOperand
            # Const-cond fold (bead bennettvm-416r.14). A closed-world Julia set
            # extracted at optimize=false mirrors LLVM's UNFOLDED
            # `select i1 <const>, t, f` verbatim — Bennett does NO IR-level fold
            # (its circuit path folds these at the GATE level via _fold_constants;
            # BVM the interpreter has no gate layer). Statically resolve the taken
            # arm and emit the established non-injective Define create (Define and
            # SelectInstruction are both is_injective==false, reversed by the SAME
            # L3 checkpoint-replay — reversibility-neutral; cf. the p81t Define
            # idiom, ingest_call.jl). i1 const encoding: 0 (false), 1, or
            # sign-extended -1 (true) — mask to the low bit; on this whitelist
            # `(c & 1) == 1` equals the interpreter's own `cond != 0` predicate
            # (select_instruction.jl), so the fold is behaviorally identical to the
            # select it replaces. NO width masking: SelectInstruction never masks
            # its arms, so the fold must not either (default-width-64 identity
            # copy; also correct for the width==0 ptr sentinel — pointers are
            # Int64 cells). The UNTAKEN arm is NEVER resolved — if it names a
            # dead SSA value on a pruned edge this fold references nothing
            # (false-path-safe by construction).
            c = Int64(inst.cond.value)
            c in (Int64(0), Int64(1), Int64(-1)) ||
                error("lower_vm: IRSelect const cond value ", c, " (dest=", inst.dest,
                      ") is not a valid i1 constant (expected 0, 1, or sign-extended ",
                      "-1). A non-boolean select condition is a malformed or ",
                      "unmodelled IR shape (bead bennettvm-416r.14; Rule 1 fail-loud).")
            taken = (c & Int64(1)) == Int64(1) ? inst.op1 : inst.op2
            return Define(inst.dest, _lower_operand(taken), :add, Int64(0))
        end
        inst.cond isa Bennett.SSAOperand ||
            error("lower_vm: IRSelect cond is ", typeof(inst.cond),
                  " (dest=", inst.dest, "); ADR 0012 §D3 requires an ",
                  "SSAOperand predicate produced by an upstream IRICmp, or a ",
                  "ConstOperand folded statically (bead bennettvm-416r.14).")
        # op1 is the TRUE arm, op2 the FALSE arm — Bennett.jl pins this
        # (Bennett.jl/src/ir_types.jl:89-93: `op1::IROperand # true value`,
        # `op2::IROperand # false value`), matching LLVM `select i1 c, t, f`
        # and SelectInstruction's `val_true`/`val_false` (ADR 0012 §D3). A
        # swap here would invert collatz's even/odd branch and fail the
        # forward golden-master — so this mapping is also empirically pinned.
        return SelectInstruction(inst.dest, inst.cond.name,
                                 _lower_operand(inst.op1),
                                 _lower_operand(inst.op2))
    elseif inst isa Bennett.IRCast
        # LLVM width cast (sext/zext/trunc) → the non-destructive width-cast
        # SSA-create (ADR 0013 §D-5 step 1). The operand is READ, never
        # destroyed (mirrors Define/SelectInstruction); the per-op bit
        # semantics live in CastInstruction._apply_cast. The op symbol is
        # validated against `_CAST_OPS` by the CastInstruction constructor.
        return CastInstruction(inst.dest, inst.op,
                               _lower_operand(inst.operand),
                               inst.from_width, inst.to_width)
    elseif inst isa Bennett.IRStore
        # LLVM `store value, ptr` → the plain non-injective heap write (ADR
        # 0014 §D2). `ptr` is an SSAOperand naming an alloca dest (a pointer
        # is an Int64 address in `locals`, materialised by the bump allocator
        # — `_lower_alloca!`). IRStore is void (no SSA dest), so this returns
        # a real `Instruction`, not `nothing`. The value may be an SSAOperand
        # or a ConstOperand (LLVM stores constants), handled by `_lower_operand`.
        inst.ptr isa Bennett.SSAOperand ||
            error("lower_vm: IRStore ptr is ", typeof(inst.ptr),
                  " — the memory floor (ADR 0014 §D1) requires an SSAOperand ",
                  "pointer naming an alloca dest or a GEP create (a pointer is ",
                  "an Int64 address in locals; IRVarGEP / IRPtrOffset both ",
                  "produce an SSAOperand-named pointer). A non-SSA ptr means a ",
                  "malformed store (Rule 1 fail-loud).")
        return MemoryStore(inst.ptr.name, _lower_operand(inst.val))
    elseif inst isa Bennett.IRLoad
        # LLVM `dest = load ptr` → the plain non-injective heap read (ADR
        # 0014 §D2). `ptr` is an SSAOperand naming an alloca dest. Zero-init
        # convention: a load of a never-stored address reads as 0
        # (`MemoryLoad.forward`).
        inst.ptr isa Bennett.SSAOperand ||
            error("lower_vm: IRLoad ptr is ", typeof(inst.ptr),
                  " (dest=", inst.dest, ") — the memory floor (ADR 0014 §D1) ",
                  "requires an SSAOperand pointer naming an alloca dest or a ",
                  "GEP create (a pointer is an Int64 address in locals; ",
                  "IRVarGEP / IRPtrOffset both produce an SSAOperand-named ",
                  "pointer). A non-SSA ptr means a malformed load (Rule 1 ",
                  "fail-loud).")
        return MemoryLoad(inst.dest, inst.ptr.name)
    elseif inst isa Bennett.IRVarGEP
        # LLVM `getelementptr` → the runtime element-address create (ADR 0009
        # Decision 2b, SC9 Case A Unit 1). `dest := base + index*stride`,
        # stride in CELLS. `base` is an SSAOperand naming an alloca dest (a
        # pointer is an Int64 cell address in `locals`, materialised by the
        # bump allocator — `_lower_alloca!`). `index` is the 0-based element
        # index (a runtime SSAOperand or an LLVM constant index), lowered via
        # `_lower_operand`. The VM is CELL-addressed (one Int64 per cell), and
        # the bump allocator reserves one cell per element, so the cell stride
        # is `1` REGARDLESS of `inst.elem_width` (which is in BITS and does NOT
        # enter the address) — it matches `_lower_alloca!`'s `+N` cursor step
        # so `gep(arr, i)` lands on the cell the alloca reserved for element i
        # (see `src/ir/array_index.jl` "stride is in cells"). The produced
        # pointer flows unchanged into a downstream MemoryStore / MemoryLoad
        # (whose `resolve_ptr` accepts any Int64 ptr value — no store/load
        # change, Law 2). The `dest` SSA value is the produced pointer, so this
        # returns a real `Instruction`, not `nothing`.
        inst.base isa Bennett.SSAOperand ||
            error("lower_vm: IRVarGEP base is ", typeof(inst.base),
                  " (dest=", inst.dest, ") — the array floor (ADR 0009 ",
                  "Decision 2b) requires an SSAOperand base naming an alloca ",
                  "dest (a pointer is an Int64 cell address in locals). A ",
                  "non-SSA base means a malformed or unsupported GEP shape ",
                  "(Rule 1 fail-loud).")
        return VarGEP(inst.dest, inst.base.name,
                      _lower_operand(inst.index), Int64(1))
    elseif inst isa Bennett.IRCall
        # LLVM `call @j_soft_f*` → the SoftFloat-dispatch SSA-create (ADR
        # 0011 §D1; M_FP.2, bead `bennettvm-8ox`). A Float64 program arrives
        # at BennettVM as an INTEGER program over UInt64 bit-patterns, every
        # FP op being an `IRCall` to a registered `soft_f*` callee — BennettVM
        # inherits Bennett.jl's bit-exact SoftFloat dispatch wholesale and
        # writes NO FP-reversibility code of its own (ADR 0011 D1). The callee
        # is stored language-neutrally as `_callee_sym(inst.callee)` (a Symbol),
        # NOT the Function (ADR 0013 callee_name direction); the SoftCall
        # constructor validates it against the `_SOFT_DISPATCH` allowlist
        # (built from Bennett.jl's FP callee groups). A NON-soft callee (a
        # general host call) is NOT a recognised reversible-by-replay
        # primitive — the SoftCall constructor's `haskey(_SOFT_DISPATCH, …)`
        # check FAILS LOUD on it (Rule 1), so this arm does not silently
        # accept an arbitrary `IRCall`. The args are READ, never destroyed —
        # the non-destructive create property (the `Define` template, NOT the
        # destructive `ArithmeticAssignment`; NOT the RSSA reversible-
        # subroutine `CallInstruction`, a soft_f* being an opaque host
        # primitive). Operands may be SSA refs or LLVM constants, handled by
        # `_lower_operand`. arg_widths / ret_width carry the f32(UInt32) /
        # f64(UInt64) bit-width metadata `SoftCall.forward` reinterprets with.
        # Float32 (the double-rounding case, ADR 0011 D2) is rejected upstream
        # in Bennett.jl (two-layer barrier: `_SUPPORTED_SCALAR_ARGS` + the
        # per-intrinsic `w==64` FP-intrinsic guards) AND, as the belt-and-
        # suspenders BennettVM mirror, ENFORCED at this ingest boundary by the
        # f32-touching guard below (bead `bennettvm-h0t`): any soft op with a
        # 32-bit result or operand is rejected. A pure-Float64 program (the SC10
        # gate) emits none, so the guard is unreachable-by-construction on
        # accepted f64 IR; it fires only if a mixed-precision `.ll` arrives.
        #
        # Nondeterminism guard (bead `bennettvm-0kl`, F1): a genuinely
        # nondeterministic callee (rand / RDRAND / objectid / time / getpid …)
        # has NO deterministic forward, so the L3 checkpoint-REPLAY reversal
        # cannot recover its pre-image — it is doubly fatal for reversibility
        # (docs/opcode-coverage-plan.md "Genuinely impossible", Nondeterminism
        # row). Reject it HERE with a SPECIFIC Rule-1 diagnostic, BEFORE the
        # `SoftCall` constructor, so it does not fall through to the generic
        # "unknown SoftFloat callee" message (which would misdescribe the
        # cause). A soft_f* callee is not in `_NONDETERMINISTIC_CALLEES`, so
        # the soft path is unaffected; a non-soft, non-nondeterministic callee
        # still reaches the SoftCall allowlist reject below.
        if _callee_sym(inst.callee) in _NONDETERMINISTIC_CALLEES
            error("lower_vm: IRCall to nondeterministic callee :",
                  _callee_sym(inst.callee), " (dest=", inst.dest, ") cannot be ",
                  "ingested — it has no deterministic forward, so the L3 ",
                  "checkpoint-replay reversal (ADR 0012; rr's record-",
                  "nondeterminism/replay-determinism lesson) cannot recover ",
                  "its pre-image. This is DOUBLY FATAL for reversibility: no ",
                  "deterministic forward AND no replay (docs/opcode-coverage-",
                  "plan.md \"Genuinely impossible\", Nondeterminism row). ",
                  "Rejected callees: ", sort!(collect(_NONDETERMINISTIC_CALLEES)),
                  " (Rule 1 fail-loud).")
        end
        # Heap-intrinsic dispatch (CW-A, ADR 0018 §C). MUST come BEFORE the
        # Float32 guard and the SoftCall constructor: a heap intrinsic
        # (malloc/calloc/realloc/free/memset/memcpy/memmove) is NOT a soft_f*
        # scalar create — it mutates `s.memory` / `s.arena_top` and reverses by
        # L2 delta (not the SoftCall L3-only path), so routing it through the
        # SoftCall path would mis-classify its reversal (ADR 0018 §C). A
        # `_HEAP_DISPATCH` hit emits the `Intrinsic*` family and returns; a miss
        # falls through to the Float32 guard + SoftCall below (and ultimately the
        # fail-loud allowlist reject).
        if _callee_sym(inst.callee) in _HEAP_DISPATCH
            return _lower_intrinsic_call(inst, _callee_sym(inst.callee))
        end
        # Benign modeled-cell callees (bead `bennettvm-p81t`): non-heap Julia
        # runtime intrinsics that lower to a NON-INJECTIVE `Define` create
        # (an aliased or fixed Int64 cell), reversed by L3 checkpoint-replay
        # (`Define` is non-injective; ADR 0012 §D1) — NOT an `Intrinsic*` heap
        # op. This is the SET the old inline `julia.gc_loaded` arm's comment
        # anticipated ("lift to a set beside `_HEAP_DISPATCH` if more such
        # callees arrive"): `julia.get_pgcstack` (the per-task pgcstack pointer)
        # is that second callee, so the lone-arm was lifted to
        # `_BENIGN_CELL_DISPATCH` + `_lower_benign_cell_call` (`ingest_call.jl`).
        # MUST come before the Float32 guard and the SoftCall constructor: a
        # benign cell callee is neither a `soft_f*` scalar create nor a heap
        # intrinsic, so routing it to SoftCall would fail-loud spuriously (the
        # pre-igr3 / pre-p81t behavior). Guard ORDER preserved: after the
        # nondeterminism + `_HEAP_DISPATCH` guards, before Float32 + SoftCall
        # (ADR 0018 §C).
        if _callee_sym(inst.callee) in _BENIGN_CELL_DISPATCH
            return _lower_benign_cell_call(inst, _callee_sym(inst.callee))
        end
        # Float32-touching soft op guard (bead `bennettvm-h0t`; ADR 0011 §D2,
        # Bennett-3rph). A soft op "touches f32" iff its result OR any operand
        # is 32-bit (`ret_width == 32 || any(==(32), arg_widths)`). This catches
        # exactly the double-rounding surface: `soft_fptrunc` (f64→f32, ret 32),
        # `soft_fpext` (f32→f64, arg 32), and any f32-OPERAND soft op. f32
        # arithmetic in mixed-precision IR is routed `soft_fpext → f64-op →
        # soft_fptrunc`, which DOUBLE-ROUNDS (rounds once at the f64 op, again at
        # the f32 mantissa boundary) and is therefore NOT bit-exact against
        # hardware f32 — a correctness defect, not a performance tradeoff (ADR
        # 0011 §D2; `../Bennett.jl/src/softfloat/fpconv.jl:1-37`; CLAUDE.md
        # rule 13). The bit-exact contract extends only to Float64.
        #
        # An ACCEPTED pure-Float64 program (the SC10 gate) emits NONE of these:
        # the SoftFloat wrapper carries f64 as UInt64 and yields integer-only IR
        # over 64-bit bit-patterns, and Bennett.jl rejects f32 at TWO upstream
        # barriers — `_SUPPORTED_SCALAR_ARGS` (no Float32 entry type) and the
        # per-intrinsic `w == 64` guards in the FP-intrinsic lowering. So this
        # guard is UNREACHABLE-BY-CONSTRUCTION on any accepted f64 program; it
        # is the fail-loud belt-and-suspenders if a MIXED-PRECISION `.ll` (the
        # `.bc` route) ever delivers an f32-touching soft op to ingest.
        #
        # No legitimate f64→intN conversion is over-rejected: a `fptosi`/`fptoui`
        # to a narrow width (e.g. f64→i32) is emitted upstream as an `IRCall`
        # with `ret_width = 64` PLUS a SEPARATE `IRCast(:trunc, 64→32)` — the
        # SoftCall keeps `ret_width = 64` and `arg_widths = [64]`, never a
        # 32-width soft op (`../Bennett.jl/src/extract/instructions.jl:2322-2345`,
        # verified). The guard fires ONLY on a genuine f32 width, never on a
        # legal f64 op nor on the f64-side of a conversion.
        #
        # Placed at INGEST (not the SoftCall constructor): `test/test_softcall.jl`
        # constructs `soft_fpext` / `soft_fptrunc` SoftCalls DIRECTLY to unit-test
        # the dispatch mechanism, and the SoftCall data type must keep supporting
        # the f32 widths for those tests (only the accepted-program ingest
        # BOUNDARY rejects them). See `src/ir/softcall_instruction.jl` §"Float32".
        if inst.ret_width == 32 || any(==(32), inst.arg_widths)
            error("lower_vm: IRCall to soft op :", _callee_sym(inst.callee),
                  " (dest=", inst.dest, ") touches Float32 (ret_width=",
                  inst.ret_width, ", arg_widths=", inst.arg_widths, ") — ",
                  "REJECTED at the BennettVM ingest boundary (ADR 0011 §D2, ",
                  "Bennett-3rph). f32 arithmetic routes soft_fpext → f64-op → ",
                  "soft_fptrunc, which DOUBLE-ROUNDS and is NOT bit-exact ",
                  "against hardware f32; BennettVM's bit-exact contract extends ",
                  "only to Float64. An accepted pure-Float64 program (the SC10 ",
                  "gate) emits no f32-touching soft op (the SoftFloat wrapper ",
                  "yields integer-only f64 IR; Bennett.jl rejects f32 at ",
                  "_SUPPORTED_SCALAR_ARGS + the per-intrinsic w==64 guards), so ",
                  "this is unreachable-by-construction on accepted f64 IR — it ",
                  "fails loud only if a mixed-precision `.ll` reaches ingest ",
                  "(Rule 1 fail-loud).")
        end
        # Guard 5 — closed-world function-table resolution (CW-B2, ADR 0019 §2,
        # §8 "Future guard-5"). AFTER the nondeterminism, heap, and Float32
        # guards (the ADR 0018 §C ordering, preserved). An `IRCall` whose
        # callee is a KNOWN in-module function (multi-function lowering passes
        # the module's full `Dict{Symbol,FunctionEntry}` here) is a reversible
        # VM call → emit a `CallEnter` (args = the `IRCall.args` SSA names). The
        # `targets` are the single `inst.dest` UNLESS the callee is VOID (zero
        # returns in its `FunctionEntry` — the C `ht_free` / `ht_put` shape), in
        # which case targets is EMPTY: a void callee's `ReturnExit` lands
        # nothing, so a `[dest]` target would mismatch its `[]` returns. When
        # `functions` is empty (the single-function `lower_vm(::ParsedIR)` path
        # — `Bennett.ParsedIR` is single-function only, so the table is never
        # populated there), this guard never fires and a non-soft, non-heap
        # callee still reaches the SoftCall allowlist reject below (unchanged).
        # Resolve the callee to its dispatch name ONCE (closure '#'→'.' sanitised
        # to converge with the `_vm_funcname` table key). Used for the table
        # lookup, the FunctionEntry fetch, AND the emitted CallEnter — the three
        # must agree so the interpreter can resolve the call to the callee's
        # `#`-qualified entry label.
        vmname = _vm_dispatch_name(inst.callee)
        if haskey(functions, vmname)
            fe = functions[vmname]
            callargs = Symbol[a.name for a in inst.args
                              if a isa Bennett.SSAOperand]
            length(callargs) == length(inst.args) ||
                error("lower_vm: IRCall to in-module function :", vmname,
                      " has a non-SSA (constant) arg in ",
                      inst.args, " — reversible VM-call args must be SSA names ",
                      "(the MOVE semantics, ADR 0019 §3; Rule 1 fail-loud). ",
                      "Materialise the constant via a synthetic Define first.")
            # Return-landing targets (CW-D blocker 4, bead `bennettvm-x3t0`).
            # `length(fe.returns)` is the callee's return ARITY:
            #   * n == 0 (void — the C `ht_free`/`ht_put` shape): EMPTY targets
            #     (a void `ReturnExit` lands nothing).
            #   * n == 1 (scalar): the single `inst.dest` (the pre-x3t0 shape).
            #   * n >= 2 (multi-key aggregate): the `_agg_slot_name` FAMILY of
            #     `inst.dest`, so the callee's slot-family End MOVEs each returned
            #     slot into the matching caller slot (the token then reads back
            #     via IRExtractValue / returns via a forwarding IRRet).
            # The multi-key case is GATED on the ABI discriminator
            # `inst.ret_width == sum(fe.ret_elem_widths)`: a value-return call
            # (ret_width == sum) is x3t0's scope; a call with ret_width ≠ the sum
            # is the sret_box MEMORY ABI (blocker 5) — fail loud STATICALLY here
            # (Rule 1, at the cause, not a downstream runtime arity symptom).
            n = length(fe.returns)
            if n <= 1
                targets = n == 0 ? Symbol[] : Symbol[inst.dest]
            else
                isempty(fe.ret_elem_widths) &&
                    error("lower_vm: IRCall to multi-return :", vmname,
                          " (dest=", inst.dest, ") — the callee's FunctionEntry ",
                          "has returns arity ", n, " but EMPTY ret_elem_widths; a ",
                          "multi-register return must carry its per-element widths ",
                          "(internal invariant — `ingest_multi.jl` populates them ",
                          "from parsed.ret_elem_widths). Rule 1 fail-loud.")
                total = sum(fe.ret_elem_widths)
                inst.ret_width == total ||
                    error("lower_vm: IRCall to multi-return :", vmname,
                          " (dest=", inst.dest, ") has ret_width=", inst.ret_width,
                          " but the callee returns a ", total,
                          "-bit aggregate (ret_elem_widths=", fe.ret_elem_widths,
                          ") — the caller is using the sret_box buffer ABI ",
                          "(explicit result-buffer arg; by-value portion only). ",
                          "DEFERRED: bead bennettvm-x3t0 scopes the value-return ",
                          "ABI (ret_width == sum); the sret_box memory ABI is the ",
                          "blocker-5 follow-up bead bennettvm-416r.16. Rule 1 fail-loud.")
                targets = Symbol[_agg_slot_name(inst.dest, k) for k in 0:n-1]
            end
            return CallEnter(vmname, callargs, targets)
        end
        return SoftCall(inst.dest, _callee_sym(inst.callee),
                        Union{Symbol,Int64}[_lower_operand(a)
                                            for a in inst.args],
                        inst.arg_widths, inst.ret_width)
    elseif inst isa Bennett.IRMapInsert
        # Bennett.jl `IRMapInsert(key, value)` → the VM-side reversible-map
        # insert (`src/ir/revmap.jl`; ADR 0008; SC9 Case B). The Dict is an
        # OPAQUE `RevMap` register — BennettVM does NOT model its hash-table
        # memory (contrast IRStore/IRVarGEP element traffic); the front-end
        # `mem=:vm` recogniser already dropped the Dict GC alloc + frame
        # skeleton and emitted this language-neutral op (ADR 0013 §D-3). The
        # Bennett-side struct field order is the logical (key, value) — the
        # value-before-key permutation of the Julia `setindex!(d, v, k)` callee
        # is un-done by the recogniser, NOT here. v1 RevMap is `Dict{Int64,
        # Int64}`, so key/value lower to `Union{Symbol,Int64}` via
        # `_lower_operand`; per-`width` masking is the documented follow-on
        # (bead `bennettvm-bgc`), and in-range i8 values (fdict's 3,7) store /
        # round-trip exactly without it. IRMapInsert is void (no SSA dest), so
        # this returns a real `Instruction`, not `nothing`.
        return IRMapInsert(_lower_operand(inst.key), _lower_operand(inst.value))
    elseif inst isa Bennett.IRMapGet
        # Bennett.jl `IRMapGet(dest, key)` → the VM-side reversible-map read
        # (`src/ir/revmap.jl`; ADR 0008 Finding 4). `dest` is the SSA name the
        # map value flows into (the MemoryLoad-style L3-reversed create — its
        # SSA dest is non-injective on a loop re-definition). The key lowers via
        # `_lower_operand`.
        return IRMapGet(inst.dest, _lower_operand(inst.key))
    elseif inst isa Bennett.IRMapDelete
        # Bennett.jl `IRMapDelete(key)` → the VM-side reversible-map delete
        # (`src/ir/revmap.jl`; ADR 0008 Finding 4, with the senior-grade
        # missing-sentinel hardening for absent-key delete). Void (no SSA dest).
        return IRMapDelete(_lower_operand(inst.key))
    elseif inst isa Bennett.IRExtractValue
        # RELOCATED to the body loop (bead `bennettvm-acq`, Rule 1/2 fix). The
        # aggregate-membership guard (`agg.name ∈ agg_dests`) needs the routine-
        # scope `agg_dests` registry, which is NOT visible from this pure per-
        # instruction dispatch — only from the body loop in `_lower_parsed_ir`,
        # where `IRExtractValue` (alongside `IRInsertValue`) is now handled. So
        # `extractvalue` must NOT reach here. If it does, the body loop missed a
        # branch — fail loud rather than emit an unguarded slot read (Rule 1).
        error("lower_vm: IRExtractValue reached _lower_body_inst (dest=",
              inst.dest, ") — it is handled in the body loop of ",
              "`_lower_parsed_ir` (where `agg_dests` is in scope for the ",
              "aggregate-membership guard), NOT here. Reaching this arm means ",
              "the body-loop branch was bypassed; that is a wiring bug (bead ",
              "`bennettvm-acq`, Rule 1 fail-loud).")
    elseif inst isa Bennett.IRPtrOffset
        # Cell-addressed STATIC GEP (ADR 0009 Decision 2b; bead bennettvm-b5x).
        # `IRPtrOffset(dest, base, offset_bytes, elem_width)` is a constant-
        # offset pointer create: `dest := base + element_index`. A pointer is an
        # Int64 CELL address in `locals`, and the bump allocator reserves one
        # cell per ELEMENT (VarGEP stride 1), so the cell offset is the ELEMENT
        # INDEX, not the byte offset. Bennett.jl stores the offset in BYTES
        # (`offset_bytes`, the circuit-backend unit) plus the source element bit
        # width (`elem_width`, the additive Bennett-xv0u field); the element
        # index is `offset_bytes ÷ (elem_width ÷ 8)`. This MIRRORS the IRVarGEP
        # arm above (`VarGEP(..., stride=1)`) for the constant-index case — both
        # land `dest` on the cell the alloca reserved for element `index`. The
        # produced pointer flows unchanged into a downstream MemoryStore /
        # MemoryLoad (no store/load change, Law 2). Returns a real `Instruction`.
        #
        # BVM only ingests `mem=:vm` ParsedIR, whose IRPtrOffset sites (the
        # integer-source constant-index GEP and vector-load lane offsets) store
        # TRUE BYTE offsets, so the `÷` is exact. Sub-element / struct offsets
        # (non-even division) are out of scope (BG3 / U16): fail loud rather than
        # silently misaddress (Rule 1, Rule 2 — never paper over).
        inst.base isa Bennett.SSAOperand ||
            error("lower_vm: IRPtrOffset base is ", typeof(inst.base),
                  " (dest=", inst.dest, ") — the array floor (ADR 0009 ",
                  "Decision 2b) requires an SSAOperand base naming an alloca ",
                  "dest (a pointer is an Int64 cell address in locals). A ",
                  "non-SSA base means a malformed or unsupported GEP shape ",
                  "(Rule 1 fail-loud).")
        ew_bits = inst.elem_width
        (ew_bits >= 8 && ew_bits % 8 == 0) ||
            error("lower_vm: IRPtrOffset elem_width=", ew_bits, " (dest=",
                  inst.dest, ") is not a whole positive byte count — cannot ",
                  "recover an element index from the byte offset (ADR 0009 ",
                  "Decision 2b; bead bennettvm-b5x, field Bennett-xv0u). ",
                  "Rule 1 fail-loud.")
        ew_bytes = ew_bits ÷ 8
        # NEGATIVE offsets are legitimate under ptr_cells (bead `bennettvm-p81t`):
        # the Julia GC preamble walks the current-task struct via
        # `gep i8 %pgcstack, -152` (current_task = TLS_BASE-152) → `gep +168`
        # (ptls_field = TLS_BASE+16). `Define(dest, base, :add, idx)` is EXACT
        # signed pointer arithmetic, and sub-element misalignment is still caught
        # by the divisibility guard below (sign-agnostic: `-152 % 1 == 0`,
        # `-3 % 2 != 0`). The guard's old premise ("no production site emits a
        # negative offset; Rule 1 fail-loud rather than misaddress") is FALSIFIED
        # by this site, so the hard `offset_bytes >= 0` error is removed. (A
        # taint-scoped tightening — reject a negative offset EXCEPT on a pgcstack-
        # derived pointer — was considered and DEFERRED until a second negative-
        # GEP source appears; while this is the only negative-GEP producer a
        # blanket relaxation is simpler and no less safe.)
        inst.offset_bytes % ew_bytes == 0 ||
            error("lower_vm: IRPtrOffset offset_bytes=", inst.offset_bytes,
                  " (dest=", inst.dest, ") is not evenly divisible by the ",
                  "element byte width ", ew_bytes, " (elem_width=", ew_bits,
                  " bits) — a sub-element / struct offset is out of scope ",
                  "(BG3 / U16). The cell-addressed VM addresses whole ",
                  "elements only; fail loud rather than silently misaddress ",
                  "(Rule 1, Rule 2).")
        return Define(inst.dest, inst.base.name, :add,
                      Int64(inst.offset_bytes ÷ ew_bytes))
    elseif inst isa Bennett.IRPhi
        return nothing   # φ → block parameter; not a body instruction.
    else
        error("lower_vm: unsupported IRInst body subtype ", typeof(inst),
              " — the slice handles IRBinOp / IRICmp / IRSelect / IRPhi ",
              "(ADR 0012), IRCast (ADR 0013 §D-5), IRStore / IRLoad (the ",
              "scalar memory floor, ADR 0014 §D2), IRVarGEP (the array ",
              "element-address create, ADR 0009 Decision 2b), IRCall to a ",
              "soft_f* callee (the SoftFloat-dispatch create, ADR 0011 §D1), ",
              "IRMapInsert / IRMapGet / IRMapDelete (the reversible-map ",
              "ops, ADR 0008 / 0013 §D-3, SC9 Case B), and IRExtractValue / ",
              "IRInsertValue (the ArrayType aggregate slot model, bead ",
              "`bennettvm-acq`; BOTH are lowered at the call site — insert ",
              "emits N slot Defines, and extract needs the `agg_dests` registry ",
              "for its aggregate-membership guard, in scope only there), ",
              "IRInsertBits (the heterogeneous `{i64,i8}` bits-struct sret ",
              "slot model, bead `bennettvm-416r.15`; lowered at the call site ",
              "beside IRInsertValue — the chain-follower field index needs the ",
              "`bits_index` registry, in scope only there), and ",
              "IRPtrOffset (the cell-addressed STATIC GEP, ADR 0009 Decision ",
              "2b, bead bennettvm-b5x). ",
              "IRAlloca is lowered at the ",
              "call site via the bump allocator (ADR 0014 §D1). (Rule 1.)")
    end
end

"""
    _lower_alloca!(inst::Bennett.IRAlloca, next_addr::Int64, saw_dynamic::Bool)
        -> Tuple{Instruction, Int64, Bool}

Lower one `IRAlloca(dest, elem_width, n_elems)` via the bump allocator
(ADR 0014 §D1 / ADR 0009 Decision 2a). Returns the lowered instruction, the
(possibly advanced) allocator cursor, and a flag recording whether THIS alloca
was dynamic-N (so the caller can enforce the static-after-dynamic invariant —
a STATIC alloca after a dynamic one still fails loud; bead `bennettvm-uil`).

**Static-size path (ADR 0014 §D1 + ADR 0009 Decision 4 rung 2):** when `n_elems`
is `ConstOperand(N)` with `N >= 1`, assign `dest` the current `next_addr` as its
`Int64` base, materialise that address into `locals` via a constant-create
`Define(dest, base, :add, 0)` (a pointer is just an `Int64`), and advance the
cursor by `N` cells, reserving cells `base … base+N-1` (one cell per element —
the VM is CELL-addressed, one `Int64` per cell, so `elem_width` (in bits) does
NOT enter the address; the cell stride a downstream `VarGEP` uses is `1`,
matching this `+N` step — `src/ir/array_index.jl` "stride is in cells").
`N == 1` is the scalar case (ADR 0014; `through_mem` allocates `__v2`→1,
`__v3`→2) — the `+N` advance specialises to `+1`. Cells default to `0` by the
zero-init convention; the allocator does not pre-populate `s.memory`. Returns
the `Define`, `next_addr + N`, and `false` (not dynamic).

**Dynamic-N path (ADR 0009 Decision 2a; beads `bennettvm-0zn` + `bennettvm-uil`):**
when `n_elems` is an `SSAOperand` (a C VLA / Julia `Vector{T}(undef, n)`), the
region size is unknown at lowering time, so the COMPILE-TIME cursor CANNOT
advance over it. Emit a `DynAlloca(dest, n_operand, base = next_addr)`
(`src/ir/alloca.jl`): `forward` materialises the pointer at `base +
s.heap_top` at runtime (the frozen compile-time base PLUS the runtime bump
offset), and an L2 `(base, n)` delta retracts the region on reverse. The cursor
is RETURNED UNCHANGED (all dynamic allocas anchor at the SAME frozen base and
offset apart at runtime via `s.heap_top`); the returned flag is `true`.

**≥2 dynamic arrays are admitted (bead `bennettvm-uil`).** The runtime
`IState.heap_top` offset (advanced by each alloca's runtime `n` in
`DynAlloca.forward`, retracted on reverse) distinguishes the disjoint regions of
multiple dynamic allocas, so a dynamic alloca AFTER a dynamic one is NOT
rejected. This is the gate for Case B's Dict (two `GenericMemory` backings). But
a STATIC alloca after a dynamic one STILL fails loud (`saw_dynamic == true` on
the static arm): a static alloca uses the compile-time cursor, which is frozen
at the first dynamic region's base and cannot step past a runtime-sized region —
mixed static/dynamic layout is the deferred bead (ADR 0009 §Consequences).

A non-positive `ConstOperand(N<=0)` is malformed IR and fails loud (an alloca
reserves at least one cell).
"""
function _lower_alloca!(inst::Bennett.IRAlloca,
                        next_addr::Int64,
                        saw_dynamic::Bool)::Tuple{Instruction,Int64,Bool}
    n = inst.n_elems
    if n isa Bennett.SSAOperand
        # Dynamic-N: emit a DynAlloca; do NOT advance the COMPILE-TIME cursor.
        # A dynamic-after-dynamic alloca IS now admitted (bead `bennettvm-uil`):
        # all dynamic allocas share the SAME frozen compile-time `base`
        # (next_addr); the RUNTIME `s.heap_top` offset (advanced by each
        # alloca's runtime `n` in `DynAlloca.forward`) distinguishes their
        # disjoint regions. So `saw_dynamic` does NOT gate a dynamic alloca, and
        # the cursor is NOT advanced — every dynamic alloca anchors at the same
        # frozen base and offsets apart at runtime (ADR 0009 Decision 2a multi-
        # array refinement). The returned flag stays `true` so a later STATIC
        # alloca still fails loud (below).
        return (DynAlloca(inst.dest, n.name, next_addr), next_addr, true)
    end
    # Static-after-dynamic invariant (Rule 1): a STATIC alloca may NOT follow a
    # dynamic-N one. A static alloca uses the COMPILE-TIME cursor (`next_addr`),
    # which is frozen at the first dynamic region's base and CANNOT step past a
    # runtime-sized region — so a static region placed there would ALIAS the
    # dynamic windows. (A dynamic alloca after a dynamic one IS admitted — it
    # rides the runtime `heap_top` offset; bead `bennettvm-uil`.) Mixed
    # static/dynamic layout needs the static cursor to advance past a
    # runtime-sized region, which is the deferred bead (ADR 0009 §Consequences).
    # Checked AFTER the dynamic arm so only the static-after-dynamic case fails.
    saw_dynamic &&
        error("lower_vm: STATIC IRAlloca(", inst.dest, ", elem_width=",
              inst.elem_width, ", n_elems=", inst.n_elems, ") follows a ",
              "dynamic-N alloca. A static alloca uses the COMPILE-TIME bump ",
              "cursor, frozen at the first dynamic region's base; it cannot ",
              "step past a runtime-sized region, so its region would ALIAS the ",
              "dynamic windows. Multi-DYNAMIC-array support landed (bead ",
              "`bennettvm-uil`, the runtime heap_top offset), but a STATIC ",
              "alloca after a dynamic one (mixed layout) is still deferred. ",
              "Rule 1 fail-loud — do not miscompile.")
    n isa Bennett.ConstOperand ||
        error("lower_vm: IRAlloca(", inst.dest, ", elem_width=",
              inst.elem_width, ", n_elems=", n, ") — n_elems must be a ",
              "ConstOperand (static-N) or SSAOperand (dynamic-N); a sentinel ",
              "operand here indicates an unhandled IR shape (Rule 1).")
    nelems = Int64(n.value)
    nelems >= 1 ||
        error("lower_vm: IRAlloca(", inst.dest, ", elem_width=",
              inst.elem_width, ", n_elems=ConstOperand(", nelems, ")) — a ",
              "static alloca must reserve at least one cell (N >= 1); ",
              "N=", nelems, " is malformed IR (Rule 1 fail-loud).")
    base = next_addr
    # Materialise the pointer FRAME-RELATIVELY via `StackAlloca(dest, base)`
    # (CW-C3, ADR 0019; `src/ir/stack_alloca.jl`): `dest := base + s.stack_top`,
    # so `dest` holds the compile-time per-frame cell `base` OFFSET by the
    # runtime call-stack cursor. For a single-function program `stack_top == 0`
    # throughout, so `dest == base` — BYTE-IDENTICAL to the pre-CW-C3
    # `Define(dest, base, :add, 0)` constant-create (every collatz / arena /
    # single-function test is unchanged). For a multi-function module the
    # CallEnter/ReturnExit `stack_top` advance/retract places each call frame's
    # allocas in a DISJOINT stack region, so a nested call no longer clobbers
    # its caller's memory-backed C `-O0` locals (the CW-C3 wall). Downstream
    # MemoryStore / MemoryLoad / VarGEP resolve `dest` as the cell base address
    # exactly as before (no store/load change, Law 2). The cursor advances by
    # `N` cells (CELL-addressed: one Int64 per element, cells base … base+N-1),
    # so a VarGEP with cell stride 1 lands on exactly the cell this alloca
    # reserved for element i (ADR 0009 Decision 2b).
    return (StackAlloca(inst.dest, base), next_addr + nelems, false)
end
