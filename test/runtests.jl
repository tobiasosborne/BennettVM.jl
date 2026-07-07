# test/runtests.jl — canonical Julia test entry for BennettVM.jl.
#
# Per CLAUDE.md Rule 4 ("'Runs without errors' is not a passing test"),
# every included file must assert against known-correct values, not just
# "didn't throw". Per Rule 7, the entire suite runs in a single Julia
# process — no parallelism between test files.
#
# Currently only the M0.3 Handoff-A smoke is wired up. M0.4 will add the
# remaining motivating-case smokes (fdict, frtN, matrix_sum) once their
# Bennett.jl `ParsedIR`s are nailed down for the ADR.

using Test
using BennettVM

@testset "BennettVM" begin
    include("test_handoff_smoke.jl")
    include("test_istate.jl")
    include("test_rstate.jl")
    include("test_dispatch.jl")
    include("test_operators.jl")
    include("test_arithmetic_assignment.jl")
    include("test_swap_instruction.jl")
    include("test_control_instructions.jl")
    include("test_memory_instructions.jl")
    include("test_call_instruction.jl")
    # M_UNBOUNDED (ADR 0012 §D1) — `Define`, the reversible SSA-create
    # instruction (`bennettvm-d3p`). Unit tests for forward (arithmetic +
    # comparison families), the operands-survive / overwrite-at-forward
    # properties, constructor validation, the load-bearing
    # `is_injective(Define) == false` pin, the deferred-`inverse` raise,
    # and an end-to-end two-block `run!`. Sits with the other M2.x
    # instruction unit tests; depends only on already-loaded symbols.
    include("test_define.jl")
    # M_UNBOUNDED (ADR 0012 §D3) — `SelectInstruction`, the reversible
    # 2-to-1 multiplexer (`bennettvm-8wj`). Unit tests for forward (arm
    # selection under cond=0/1/nonzero, literal operand), the
    # operands-survive / overwrite-at-forward properties, constructor
    # validation, the load-bearing `is_injective(SelectInstruction) ==
    # false` pin, the deferred-`inverse` raise, and an end-to-end
    # single-block `run!` (Define-builds-cond + SelectInstruction).
    # Sits right after `test_define.jl` — its sibling; depends only on
    # already-loaded symbols.
    include("test_select.jl")
    # M_OPCODE (ADR 0013 §D-5 step 1, ADR 0012 §D1 template) —
    # `CastInstruction`, the reversible width-cast SSA-create
    # (`bennettvm-hek`). Unit tests for forward (sext/zext/trunc with
    # hand-computed LLVM-semantics expected values, incl. high-bit-set
    # zext, negative-from-width sext, high-bit-dropping trunc), operand-
    # survives / overwrite-at-forward, literal operand, constructor
    # validation (op domain + width range + SSA single-assignment), the
    # load-bearing `is_injective(CastInstruction) == false` pin, and the
    # deferred-`inverse` raise. Sits right after `test_select.jl` — its
    # sibling create; depends only on already-loaded symbols.
    include("test_cast_instruction.jl")
    # M_FP.2 (ADR 0011 §D1; bead `bennettvm-8ox`) — `SoftCall`, the
    # SoftFloat-dispatch SSA-create. Op-level unit tests for forward (the
    # bit-pattern reinterpret through Bennett.jl's `soft_f*` primitives —
    # fmul/fadd/fsub arithmetic, the negative-bit-pattern carrier, the
    # ternary `soft_fma` arity, a literal operand), the args-survive /
    # overwrite-at-forward properties, the `_SOFT_DISPATCH` registry /
    # allowlist (built from Bennett.jl's FP callee groups), constructor
    # validation (unknown callee, dest∈args, length mismatch, width domain),
    # the load-bearing `is_injective(SoftCall) == false` and
    # `is_l2_capable(SoftCall) == false` pins, and the deferred-`inverse`
    # raise. Sits right after `test_cast_instruction.jl` — its sibling
    # create; depends only on already-loaded symbols.
    include("test_softcall.jl")
    include("test_basic_block.jl")
    include("test_label_table.jl")
    include("test_vmprogram.jl")
    include("test_ir_types.jl")
    include("test_injective.jl")
    include("test_injective_inverse.jl")
    # M6.4 capstone (bennettvm-moa). Integration test that composes
    # M6.1 (`is_injective` trait), M6.2 (`step!` gate), M6.3 (per-
    # instruction inverse contract): all-injective VM programs must
    # produce zero history at every step and round-trip via the
    # `s.initial` fallback path in Replay.jl.
    include("test_zero_history_roundtrip.jl")
    include("test_interpreter.jl")
    include("test_forward_interpreter.jl")
    # M7.5 — stub liveness / min-cut analysis (`bennettvm-46p`). Pure
    # analysis tests — no `step!` integration (that's M7.6). Pulls in
    # the multi-block `countdown_program` fixture via its own
    # `include("reference/countdown.jl")` (M8.1 — no transitive
    # include-order dependency).
    include("test_liveness.jl")
    include("test_checkpoint_entry.jl")
    # M7.2 — DeltaEntry{T} unit tests (`bennettvm-c4m`). L2 history
    # entry type for non-injective instructions; mirrors
    # test_checkpoint_entry.jl's pattern.
    include("test_delta_entry.jl")
    include("test_checkpoint_push.jl")
    include("test_unstep.jl")
    # M7.4 — unstep! L2 DeltaEntry fast-path tests (`bennettvm-bk5`).
    # Sits after test_unstep.jl so the M4.3 baseline tests run first.
    include("test_unstep_delta.jl")
    # M7.6 — L2 delta push integration into `step!` (`bennettvm-7e7`).
    # Sits after `test_unstep_delta.jl` because the M7.6 round-trip
    # test (`L2 suppressed in replay`) exercises the M7.4 unstep!
    # fast-path; that fast-path's baseline tests run first. Also
    # depends on `compute_must_cache` from test_liveness.jl's M7.5
    # subject.
    include("test_delta_push.jl")
    # M7.7 — milestone capstone (`bennettvm-94m`). Integration test
    # composing M7.2-M7.6 (delta entries, push site, liveness stub) with
    # M6 (L1 trait) and M4 (L3 checkpoint replay) — proves delta-
    # history correctness, sub-linear history scaling (PRD v4 §Part VI
    # SC4), and composition with the M6 L1 gate. Sits after
    # `test_delta_push.jl` because it builds on the same M7.6 push-site
    # contract.
    include("test_delta_roundtrip.jl")
    include("test_unrun.jl")
    include("test_roundtrip.jl")
    # M_UNBOUNDED.1 — the real `lower_vm` ParsedIR ingest (`bennettvm-c39`,
    # ADR 0012). Lowers `collatz_steps(::Int8)` (PRD v4 §3.6.2 Case D) to a
    # VMProgram and asserts FORWARD `run!` reproduces the irreversible
    # oracle bit-for-bit on three non-overflowing inputs, plus a single
    # round-trip smoke (run! → unrun! → initial + empty history). Sits
    # after the M4/M7 round-trip family because the smoke exercises the L3
    # checkpoint-replay `unrun!` those milestones land; pulls in the
    # oracle + `collatz_vm` factory via `test/reference/collatz.jl`.
    include("test_collatz_forward.jl")
    # SC9 Case C — matrix_sum (nested loops) forward gate (`bennettvm-k7b`,
    # ADR 0010). The nested-loop analogue of test_collatz_forward.jl:
    # lowers `matrix_sum_while(::Int8)` (PRD v4 §3.6.2 Case C) — a
    # doubly-nested counting `while` — to a 12-block VMProgram and asserts
    # FORWARD `run!` reproduces the irreversible oracle bit-for-bit on five
    # in-range inputs (headline: matrix_sum_while(3) == 9). The existing
    # M_UNBOUNDED ingest lowers the multi-level BasicBlock CFG with ZERO
    # `src/` changes (bead `bennettvm-720`). Sits after the collatz forward
    # gate; pulls in the oracles + `matrix_sum_vm` factory via
    # `test/reference/matrix_sum.jl`.
    include("test_matrix_sum_forward.jl")
    # M8.2 — per-step inverse test scaffold (`bennettvm-3d8`).
    # Sits AFTER test_delta_roundtrip.jl because the scaffold's M7
    # driver-layer testset depends on `compute_must_cache` (M7.5) and
    # the M7.6 push-site integration both being exercised first. The
    # scaffold itself is reusable infrastructure consumed by M8.3
    # (`bennettvm-2kl`, mutation-proof harness), M8.4
    # (`bennettvm-bii`, seeded random program generator), and M8.5
    # (`bennettvm-tnp`, 100-random-programs property test).
    include("test_per_step_inverse.jl")
    # M_UNBOUNDED.3 — collatz round-trip / SC9 Case D acceptance gate
    # (`bennettvm-hvx`, ADR 0012). The definitive round-trip proof for
    # the unbounded `while` the circuit backend cannot compile: per-step
    # inverse (L3) across multiple non-overflowing inputs at two K
    # densities, aggregate run!/unrun! anchored to the oracle, the SC9
    # headline assertion, and the L2-raises boundary documenting the
    # L3-only reversal contract. Sits AFTER test_per_step_inverse.jl
    # because it consumes the M8.2 `per_step_inverse_check` scaffold;
    # pulls in the oracle + `collatz_vm` factory via
    # `test/reference/collatz.jl` (re-include-guarded).
    include("test_collatz_roundtrip.jl")
    # M13.4 / `bennettvm-vw8` — the user-approved capstone: the public-API
    # one-liner `Bennett.reversible_compile(collatz, Int64; target=:reversible_vm)`
    # routed through the registration hook (ADR 0003 / a5j), run forward to the
    # oracle and reversed (P0.6). The integration proof end-to-end, no hand-built
    # ParsedIR. Sits after test_collatz_roundtrip.jl (shares the Case D shape).
    include("test_e2e_collatz.jl")
    # ADR 0012 R1 RESOLVED — width-aware `_apply_binop` (`bennettvm-bgc`).
    # The collatz slice (and the general ingest) now threads the source
    # `IRBinOp.width` / `IRICmp.width` into the `Define` it builds, and
    # `Define.forward` computes the op in i`width` semantics (extract low-`w`
    # bits, re-extend per the op's signedness, mask the result). This gate
    # pins the golden-master against a NATIVE i`w` oracle on inputs that
    # OVERFLOW their width (`(Int8(3)*x)÷Int8(2)` at x=50 → 203, pre-fix 75),
    # the signed-remainder and unsigned-udiv corroborations, the round-trip
    # on the overflow input (P0.6), and the verified width-64 no-op (existing
    # full-width behavior byte-identical). Sits right after the collatz
    # round-trip gate — its sibling R1 concern; depends only on
    # already-loaded symbols (Bennett.jl extraction + `lower_vm`).
    include("test_width_masking.jl")
    # SC9 Case C — matrix_sum (nested loops) round-trip acceptance gate
    # (`bennettvm-k7b`, ADR 0010). The nested-loop analogue of
    # test_collatz_roundtrip.jl: the definitive round-trip proof for the
    # doubly-nested counting loop the circuit backend cannot represent —
    # per-step inverse (L3) across six inputs at two K densities, aggregate
    # run!/unrun! anchored to the oracle (the nested run unwinds BOTH inner-
    # and outer-loop history under L3, bead `bennettvm-of5`), the SC9
    # headline assertion (n=3 → 9 → empty history), and the L2-raises
    # boundary. Sits AFTER test_per_step_inverse.jl (consumes the M8.2
    # `per_step_inverse_check` scaffold) and after the collatz round-trip
    # gate; pulls in the oracles + `matrix_sum_vm` factory via
    # `test/reference/matrix_sum.jl` (re-include-guarded).
    include("test_matrix_sum_roundtrip.jl")
    # matrix_tri (triangular nested loops) round-trip acceptance gate
    # (bead `bennettvm-e4l`, the IRCast end-to-end gate of `bennettvm-hek`;
    # ADR 0012 §D5 / ADR 0013). The NON-RECTANGULAR-nest analogue of
    # test_matrix_sum_roundtrip.jl: `matrix_tri_while(::Int8)` is a
    # doubly-nested `while` whose inner trip count varies with the outer
    # index (triangular sum `sum_{i=1}^n i(i+1)/2`). It is the program that
    # surfaced the within-edge synthetic-constant φ-name collision (e4l):
    # its `top → L7.preheader` edge sends the same constant into two φ-param
    # slots, which the pre-fix by-value-only dedup collapsed into a
    # duplicate `UnconditionalExit` arg. This gate is the end-to-end witness
    # that the cross-edge-share + within-edge-fresh-create fix
    # (`src/ir/ingest.jl`) lets the triangular nest lower, run forward
    # matching the oracle, and round-trip — and that the IRCast lowering
    # (`bennettvm-hek`) handles its sign-extended counters. Per-step inverse
    # (L3) across eight inputs at two K densities, aggregate run!/unrun!
    # anchored to the oracle, the headline (n=3 → 10 → empty history), and
    # the L2-raises boundary. Sits AFTER test_per_step_inverse.jl (consumes
    # the M8.2 `per_step_inverse_check` scaffold) and after the matrix_sum
    # round-trip gate; pulls in the oracles + `matrix_tri_vm` factory via
    # `test/reference/matrix_tri.jl` (re-include-guarded).
    include("test_matrix_tri_roundtrip.jl")
    # Memory floor (scalar IRAlloca/IRStore/IRLoad) unit + lowering tests
    # (bead `bennettvm-x9j`, ADR 0014 §D1–D4; ADR 0013 §D-2). Pins the new
    # `MemoryStore` / `MemoryLoad` instructions (`src/ir/memory_floor.jl`):
    # forward semantics (store-then-load, zero-init absent read), the
    # non-injective L3 classification, the deferred per-instruction inverse,
    # the bump-allocator addressing (distinct base addresses per scalar
    # alloca), the v1 scope guard (array / dynamic-N raise), and a hand-built
    # scalar ParsedIR lowered + run + round-tripped under L3 via the
    # `per_step_inverse_check` scaffold. Sits after the matrix_tri gate
    # (consumes the same M8.2 scaffold).
    include("test_memory_floor.jl")
    # Memory floor — THE EMITTER-AGNOSTIC GATE (bead `bennettvm-x9j`, ADR
    # 0014 §D5; ADR 0013 §D-1). Proves BennettVM round-trips a **C** program:
    # `int through_mem(int n){int s; s=n+1; return s;}` compiled clang-18 -O0
    # to a committed `.ll` (clang-free at test time), extracted via Bennett's
    # language-agnostic `extract_parsed_ir_from_ll`, lowered via the real
    # `lower_vm`, run forward matching the C oracle (n+1), and round-tripped
    # to empty history under L3 (P0.6). The executable demonstration that
    # BennettVM is useful to ANY LLVM emitter, not just Julia.
    include("test_memory_floor_cll.jl")
    # SC9 Case A Unit 1 — static-size array floor (bead precursor to
    # `bennettvm-ekc`; ADR 0009 Decisions 2b & 4). The array analogue of
    # test_memory_floor.jl: pins the new `VarGEP` instruction
    # (`src/ir/array_index.jl`, `dest := base + index*stride`, stride in
    # CELLS) and the `_lower_alloca!` lift to `ConstOperand(N>=1)` (bump
    # allocator reserves N consecutive cells). A hand-built static-array
    # ParsedIR (alloca N=4; arr[0..3]=…; gep arr[idx]; load; ret) lowered via
    # the real `lower_vm`, run forward matching an irreversible oracle
    # bit-for-bit across all in-range indices, and round-tripped under L3 via
    # the `per_step_inverse_check` scaffold at K ∈ {1, 4}. Also pins the
    # VarGEP forward arithmetic (base=5,index=3,stride=1 → 8), the
    # non-injective L3 classification, the deferred per-instruction inverse,
    # and the dynamic-N (SSAOperand) v1→v2 guard (still deferred, bead 0zn).
    # Sits right after the scalar memory-floor gates (consumes the same M8.2
    # scaffold and the same MemoryStore/MemoryLoad floor).
    include("test_array_floor.jl")
    # OPCODE — IRPtrOffset cell-addressed STATIC GEP ingest (bead
    # `bennettvm-b5x`; Bennett.jl additive field `Bennett-xv0u`; ADR 0009
    # Decision 2b). The constant-offset analogue of IRVarGEP: a pointer is an
    # Int64 cell address, the bump allocator reserves one cell per ELEMENT, so
    # the cell offset is the element INDEX = `offset_bytes ÷ (elem_width ÷ 8)`
    # — recovered from Bennett.jl's byte-valued `offset_bytes` plus the new
    # `elem_width` field (the circuit backend ignores `elem_width`; without it
    # a non-i64 array's byte offset would be mis-divided — a latent silent
    # miscompile). Lowers to `Define(dest, base, :add, element_index)`. A
    # hand-built `alloca i32[4]; arr[2]=99 (off=8,ew=32); load; ret` (oracle
    # f(x)=99) lowers, runs bit-exact, round-trips to empty history (P0.6), and
    # per-step-inverts at K ∈ {1,4}; sub-element offsets (non-even division),
    # non-SSA bases, and sub-byte elem_widths fail loud (Rule 1). Moves
    # IRPtrOffset OUT of the GAP group → COVERED. Same hand-built ParsedIR +
    # `per_step_inverse_check` idiom as test_array_floor.jl.
    include("test_ptroffset.jl")
    # SC9 Case A Unit 2 — indexed lossy store + (addr, old_value) L2 delta
    # (bead `bennettvm-ekc`; ADR 0009 Decision 2b/4.4). The FIRST L2 delta
    # that needs PRE-`forward()` state: a `MemoryStore` reverses via the
    # cheap M7.4 delta fast-path (capturing the overwritten cell's value +
    # presence BEFORE forward()) instead of an L3 full-state checkpoint.
    # Lands the `step!` `predelta_payload` pre-state hook
    # (`src/interpreter/Interpreter.jl`, capturing O(1) per store — NO full
    # IState deepcopy), `MemoryStore`'s `predelta_payload` +
    # `inverse(::MemoryStore, s, ::NamedTuple)` (`src/ir/memory_floor.jl`),
    # and the absent-cell delete branch (the ADR 0008 Dict missing-sentinel
    # trap). Sits right after the Unit-1 array floor it builds on; reuses
    # the same hand-built array `ParsedIR` shape and the M8.2 scaffold.
    include("test_store_delta.jl")
    # SC9 Case A — dynamic-N alloca + (base, n) L2 delta (bead
    # `bennettvm-0zn`; ADR 0009 Decision 2a). The runtime-sized allocation
    # rung: an `IRAlloca` with an `SSAOperand` n_elems (a C VLA / Julia
    # `Vector(undef, n)`) lowers to a `DynAlloca` (`src/ir/alloca.jl`) whose
    # `forward` materialises the pointer at a FROZEN compile-time base (no
    # runtime bump state in IState) and whose L2 `(base, n)` delta retracts
    # the whole region on reverse — UNCONDITIONALLY deleting `base..base+n-1`,
    # sound under L2/L3 store interleave (the soundness lemma). Lands the
    # ingest dynamic-N dispatch + the single-dynamic-array fail-loud guard
    # (`src/ir/ingest.jl`) and the `is_injective(::Type{DynAlloca}) = false`
    # pin (`src/history/Injective.jl`). Sits right after the Unit-2 store
    # delta it composes with (the region's element stores) and reuses the same
    # hand-built array `ParsedIR` shape + the M8.2 `per_step_inverse_check`.
    include("test_alloca_delta.jl")
    # ≥2 dynamic-N allocas via the runtime bump pointer `IState.heap_top` (bead
    # `bennettvm-uil`; ADR 0009 Decision 2a multi-array refinement). THE gate
    # for Case B (a Dict = keys + vals = two dynamic GenericMemory backings,
    # exceeding the pre-`uil` single-dynamic-array frozen-base floor). Pins:
    # two DISTINCT dynamic allocas own DISJOINT offset windows (`base =
    # instr.base + s.heap_top`), writes do not clobber across arrays, the
    # `heap_top` accounting (n1+n2 forward; round-trips to 0 on reverse), the
    # per-step inverse under the L2 `(base,n)` deltas, the mutation-proof
    # (removing the `heap_top += n` advance ALIASES the regions — RED), and the
    # single-array no-churn guarantee (heap_top = 0 → base == instr.base).
    # Generalises the single-DynAlloca `test_alloca_delta.jl` it sits beside.
    include("test_multi_dynalloca.jl")
    # SC9 Case A — `frtN` END-TO-END round-trip (bead `bennettvm-xld`; ADR
    # 0009 Decision 3). THE Case A executable proof: a REAL clang-18 C VLA
    # program (`test/reference/frtN.c` -> committed, hand-trimmed/named `.ll`)
    # flows through Bennett's language-agnostic `extract_parsed_ir_from_ll`,
    # the real `lower_vm` (dynamic-N `DynAlloca` + single-index `IRVarGEP`),
    # runs forward matching `frtN_oracle(n) = sum(i^2 for i<n)` bit-for-bit
    # (incl. n=5 -> 30), and round-trips to empty history under a MIXED L2/L3
    # stack (the two heap-state loops reverse via L3 checkpoint-replay; the
    # array element writes push L2 `(addr, old_value)` deltas; the alloca
    # pushes an L2 `(base, n)` delta — Decision 4 rung 7). Clang-free at test
    # time (committed `.ll`, Rule 12). Composes every Case A rung beneath it
    # (the array floor, the store delta, the alloca delta) on a real emitter's
    # output rather than a hand-built ParsedIR. Sits right after the
    # `test_alloca_delta.jl` DynAlloca unit it builds on.
    include("test_dyn_roundtrip.jl")
    # CW-A2 — the reversible malloc-arena floor (bead `bennettvm-416r.3`; ADR
    # 0018). The THIRD address-space tier beside alloca-stack (`heap_top`) and
    # globals: a deterministic arena bump allocator over the new
    # `IState.arena_top` cursor. Hand-built IR drives the heap-intrinsic family
    # (`src/ir/intrinsics.jl`): malloc→store→load→free round-trip, realloc =
    # malloc + memcpy composite, calloc reads-as-0 (absent=0), memset runtime-n
    # over mixed present/absent cells (the missing-sentinel was_present branch),
    # memmove overlap-safe, per-step inverse at K∈{1,4} (the M8.2 scaffold), the
    # ==/hash arena_top sensitivity guard (ADR 0018 §H — else a malloc inverse
    # that forgot the cursor retract would round-trip spuriously), and the §E
    # fail-loud matrix (bad free, non-cell-divisible / negative size, overlapping
    # memcpy, out-of-whitelist callee). The arena allocs reverse via an L2
    # `(base, cells)` delta (the DynAlloca template); the bulk ops via a per-cell
    # `(addr, old, was_present)` dest-range delta (the MemoryStore schema); free
    # is L1 injective (no-op, leaked). Sits right after the Case A dynamic-N heap
    # e2e it sits beside; reuses the same hand-built-VMProgram + M8.2
    # `per_step_inverse_check` idiom as test_multi_dynalloca.jl.
    include("test_arena_roundtrip.jl")
    # CW-D3 Lever 3 (Bennett-iwo9 decision 5; ADR 0021 D3; bead
    # `bennettvm-416r.12` gc_alloc_obj PART). Ingests Bennett.jl's
    # `IRCall(:gc_alloc_obj, [size, tag])` as an arena bump-alloc mirroring
    # `IntrinsicMalloc`, with the Julia type TAG carried as metadata but
    # STRUCTURALLY UNREAD by any state transition (no JIT type-tag address can
    # leak into VM state). Pins ingest shape, forward/inverse arena round-trip,
    # and the tag-invariance soundness witness (vary tag → bit-identical IState).
    # Sits right after the arena floor it mirrors.
    include("test_gc_alloc_obj_ingest.jl")
    # bennettvm-416r.12 (CW-D2) — julia `Memory{T}` backing-alloc ingest. Ingests
    # Bennett.jl's bare Symbol-callee `IRCall(:jl_alloc_genericmemory_unchecked,
    # [ptls, nbytes, typ])` as an arena bump-alloc mirroring `IntrinsicGCAlloc`:
    # ptls DROPPED, size carried, type tag STRUCTURALLY UNREAD (ADR 0021 D3).
    # Pins ingest shape, single-function lower_vm routing (no allowlist reject),
    # forward/inverse arena round-trip, and the durable coupling invariant
    # `Bennett._D1B_MODELED_HEAP_INTRINSICS == _HEAP_DISPATCH`.
    include("test_416r12_jl_alloc_genericmemory.jl")
    # Bennett-igr3 — julia.gc_loaded data-ptr launder ingest (downstream of
    # Bennett-qmv7). Ingests Bennett.jl's `IRCall(Symbol("julia.gc_loaded"),
    # [mem, data])` — the GC-rooting launder that returns the data pointer — as
    # the pointer-identity create `Define(dest, data, :add, 0)` (the laundered
    # data ptr IS the cell-addressed heap-Memory virtual base; `mem` is
    # STRUCTURALLY UNREAD). Pins ingest shape, the forward binding, the
    # mem-invariance soundness witness, and the fail-loud arity guard. Sits
    # beside its gc_alloc_obj sibling.
    include("test_igr3_gc_loaded_ingest.jl")
    # SC9 Case A — THE Julia-`Vector` round-trip gate (bead `Bennett-jfw6`, ADR
    # 0016). Drives a REAL Julia `Vector{T}(undef,n)` write/read/reduce loop
    # (`fvec` Int64 + `vsum` Int8) from SOURCE through Bennett.jl's `mem=:vm`
    # Case-A Memory recogniser (`src/extract/vector_vm*.jl`) — which strips the
    # GC/GenericMemory skeleton (the GC frame, the
    # `jl_alloc_genericmemory_unchecked` Memory backing, the Array wrapper, the
    # `julia.gc_loaded` data-ptr launder, the size/inexact/bounds throw
    # diamonds) and emits the loop-PRESERVING `IRAlloca(dyn)+IRVarGEP+IRStore/
    # IRLoad` multi-block ParsedIR — into `lower_vm` → forward (== oracle
    # bit-exact, golden master) → `unrun!` to empty history. Complements the C
    # `frtN.ll` gate above (`test_dyn_roundtrip.jl`): same VM shape, now from
    # Julia source. Also asserts the ADR-0016 fail-loud matrix (optimize=true /
    # O2-SIMD reject (D1); two dynamic Vectors → multi-array reject) and exer-
    # cises the mixed L2/L3 history (DynAlloca (base,n) delta) + per-step
    # inverse. The vsum Int8 case is the D6 stride witness (`mul %off,1`).
    include("test_vec_vm_roundtrip.jl")
    # SC9 Case B — RevMap reversible-map ADT + IRMap* ops unit gate (bead
    # `bennettvm-jrc`, ADR 0008). The Dict analogue of the memory-floor op
    # units: pins the `RevMap` (`IState.revmap`, a `Dict{Int64,Int64}`
    # mirroring `memory`) + the three `IRMap*` ops (`src/ir/revmap.jl`) at the
    # OP level — forward semantics, the L2 `(key, prior)` delta round-trip via
    # `predelta_payload` → `inverse(::NamedTuple)` (incl. the absent-key /
    # missing-sentinel cases for IRMapInsert AND IRMapDelete), the raising
    # `prev::Any` catch-all for all three, the `is_injective == false` pins,
    # and the load-bearing IState integration (ADR 0008 Finding 3: `==`/`hash`
    # SEE the revmap; deepcopy copies it independently). Does NOT build a
    # hand-built VMProgram round-trip through run!/unrun! — that is the
    # separate bead `bennettvm-l49`. Self-contained: depends only on
    # already-loaded BennettVM symbols. Sits right after the Case A heap family.
    include("test_revmap.jl")
    # SC9 Case B — hand-built IRMap* round-trip unit gate (bead
    # `bennettvm-l49`, ADR 0008 Decision 4a/6, Consequences bead 2). The
    # EXECUTABLE PROOF of the `RevMap` ADT: a hand-built `VMProgram` (no
    # Bennett.jl ingest — the `Dict`→`IRMap*` recognition arm is BLOCKED on
    # `Bennett-800b`) driven through the FULL interpreter loop. Part A is the
    # straight-line `fdict` gate (forward vs the `fdict_ref` oracle +
    # round-trip BOTH via L3 fallback and via the L2 `(key, prior)` inverse,
    # the M8.2 blind-spot discipline); Part B is a GENUINE back-edge loop CFG
    # (ConditionalEntry/Exit + back-edge, `Define`-built like collatz) whose
    # body does an IRMapInsert AND an IRMapGet into a RE-DEFINED dest each
    # iteration — the cross-iteration crux — asserting a MIXED L2-insert /
    # L3-control-flow round-trip to empty history (ADR 0008 Finding 3 makes
    # `IState.==` SEE the revmap). Complements the OP-level `test_revmap.jl`
    # (does NOT duplicate it). Sits right after its op-unit sibling.
    include("test_revmap_roundtrip.jl")
    # SC9 Case B — THE Dict round-trip gate (bead `bennettvm-7xa`). Part A
    # drives the EXACT fdict ParsedIR (IRMapInsert+IRMapGet) through the REAL
    # lower_vm ingest → VMProgram → forward (fdict(3,7)==7 vs oracle) → unrun!
    # to empty history under L2+L3 + per-step-inverse. Part B asserts the
    # Bennett.jl mem=:vm recogniser rewrites setindex!(dict,v,k) →
    # IRMapInsert(key=k,value=v) (value-before-key un-permuted) + drops the GC
    # skeleton. Part C asserts the bare-fdict inlined-getindex blocker fails
    # LOUD (Rule 1) — the documented gap, in Bennett.jl front-end inlining, not
    # the VM/ingest half (Part A proves that complete). Sits right after its
    # hand-built-VMProgram sibling.
    include("test_dict_roundtrip.jl")
    # SC10 — Float64 round-trip gate, hand-built (bead `bennettvm-8ox`, ADR
    # 0011 §D1). THE M_FP.2 executable proof: a hand-built back-edge-loop
    # `VMProgram` computing `x*x + 3x + 1` for a Float64 input (carried as a
    # UInt64 bit-pattern) via `SoftCall` nodes (soft_fmul/soft_fadd) driven
    # through the FULL interpreter loop — `run!` forward asserting the result
    # bit-pattern EQUALS the native Julia oracle `reinterpret(UInt64,
    # x*x+3x+1)` bit-for-bit (Rule 4 golden master; SoftFloat is bit-exact
    # against hardware f64, ADR 0011 D1), then `unrun!` to empty history
    # (P0.6). The four SoftCall dests are RE-DEFINED every iteration (the
    # cross-iteration crux), forcing the L3 checkpoint-replay path that
    # SoftCall reverses through (it is NOT l2-capable); the `per_step_
    # inverse_check` scaffold catches a broken intermediate reverse the
    # aggregate round-trip would mask. Sits after `test_revmap_roundtrip.jl`
    # and consumes the M8.2 `per_step_inverse_check` scaffold (re-include-
    # guarded), so it follows `test_per_step_inverse.jl`.
    include("test_fp_roundtrip.jl")
    # M8.3 — mutation-proof harness for per-instruction inverse
    # (`bennettvm-2kl`). Sits AFTER test_per_step_inverse.jl because
    # the harness depends on the `per_step_inverse_check` scaffold
    # exposed by M8.2 for its non-injective L2 cycles
    # (ArithmeticAssignment, MemoryAssignment). The three injective
    # kinds (SwapInstruction, MemoryInterchange, MemorySwap) use a
    # direct forward+inverse round-trip (the M6.3 pattern) because
    # the M7.6 L1 short-circuit makes `inverse()` unreachable for
    # them via `unstep!`'s L2 fast-path.
    include("test_mutation_proof.jl")
    # M8.4 — seeded random control-flow program generator
    # (`bennettvm-bii`). Sits AFTER test_mutation_proof.jl because the
    # generator's "scaffold compatibility" testset drives every shape
    # (linear/conditional/looping) through the M8.2 scaffold
    # (`per_step_inverse_check`) in both L3 and L2 regimes — those
    # primitives must already be exercised. Produces (VMProgram, inputs)
    # pairs the M8.5 (`bennettvm-tnp`) 100-program property test will
    # consume from a single seeded MersenneTwister(0xBE171973).
    include(joinpath("generators", "random_program.jl"))
    # M8.5 — 100-random-program property test (`bennettvm-tnp`), the M8
    # capstone. Sits LAST in the M8 family because it composes M8.2's
    # `per_step_inverse_check` scaffold, M8.4's seeded generator
    # (`default_rng`, `random_program`, `_structural_eq`,
    # `_classify_shape`), and M8.3's eval+delete_method+invokelatest
    # mutation discipline — all three must already be in scope. Walks a
    # single seeded RNG 100× asserting full round-trip + per-step
    # inverse at both L3 and L2 regimes, determinism, and a mutation-
    # proof RED-then-GREEN on `inverse(::ArithmeticAssignment)`.
    include("test_property_roundtrip.jl")
    # M_OPCODE.3 — the executable coverage matrix (bead `bennettvm-d7t`).
    # Turns every row of `docs/coverage-matrix.md` into an `@test`: for each
    # of the 16 concrete Bennett.jl `IRInst` subtypes, asserts the matrix's
    # DONE (11) / GAP (4) / N/A (1) status holds against the REAL `lower_vm`
    # ingest (`src/ir/ingest.jl`). DONE rows lower to the documented VM
    # instruction type (and two end-to-end witnesses run all 11 through
    # run!/unrun! against a hand-computed oracle); GAP rows raise a Rule-1
    # fail-loud error naming the unsupported op; IRSwitch (N/A) is documented
    # as frontend-pre-expanded with a belt-and-suspenders fail-loud assertion.
    # A future ingest change that silently starts/stops handling a subtype
    # trips a RED test here cross-referenced to the matrix row it contradicts
    # (prose rots; this file does not). Sits LAST as the coverage capstone —
    # it builds only hand-built ParsedIR fragments via the same idiom as
    # test_memory_floor.jl, so it depends only on already-loaded symbols.
    include("test_opcode_coverage.jl")
    # OPCODE F1/F2 — the clean-fail-loud completeness gate (bead
    # `bennettvm-0kl`, epic `bennettvm-x49`). The "fail loud cleanly" half of
    # the maximum-opcode-coverage north-star: the genuinely-impossible /
    # nondeterministic set must reach a CLEAR Rule-1 error whose message names
    # the cause, never a silent gap or a misleadingly-generic one. F1 adds the
    # `_NONDETERMINISTIC_CALLEES` guard in `ingest.jl`'s IRCall arm (rand /
    # objectid / time / getpid … → a SPECIFIC "nondeterministic — no
    # deterministic forward, no replay" error, distinct from the generic
    # SoftCall allowlist message); F2 pins the impossible-CFG/memory defensive
    # mirror (the shared `_lower_body_inst` `else` named for an unhandled
    # subtype, the deferred aggregate-RETURN IRRet guard, the IRSwitch
    # `_successors` reject, the non-SSA-ptr memory-floor reject) and documents
    # that
    # atomic/volatile/indirectbr/inline-asm/opaque-call are rejected UPSTREAM in
    # Bennett.jl (U14/U15/U4eu) and so are unrepresentable at the ParsedIR
    # interface. Sits right after the coverage capstone (same hand-built
    # ParsedIR idiom; depends only on already-loaded symbols).
    include("test_fail_loud_completeness.jl")
    # OPCODE G2 — aggregate IRExtractValue / IRInsertValue ingest for
    # homogeneous ArrayType `[N x iW]` aggregates (bead `bennettvm-acq`, epic
    # `bennettvm-x49`). An aggregate SSA value is modelled as a FAMILY of N
    # synthetic per-slot keys (`_agg_<name>_slot<k>`), since `IState.locals` is
    # a flat `Dict{Symbol,Int64}`: `insertvalue` rebuilds the family via N
    # non-destructive `Define` copies/creates (slot k := inserted val; the rest
    # copied from the prior aggregate or zero-created for the ZERO_AGG base);
    # `extractvalue` reads ONE slot into a scalar. Reuses the scalar `Define`
    # copy machinery so the IState type / equality / L3 checkpoint-replay all
    # carry over unchanged. A hand-built `[2 x i32]` build/read/add chain
    # (oracle `f(x)=x+7`) lowers, runs bit-exact, round-trips to empty history
    # (P0.6), and per-step-inverts at K ∈ {1,4}; a RETURNED aggregate fails loud
    # (the multi-key return is the follow-on bead). Same hand-built ParsedIR +
    # `per_step_inverse_check` idiom; depends only on already-loaded symbols.
    include("test_aggregate_extract_insert.jl")
    # Bennett-6bu3 — StructType aggregate IRInsertValue / IRExtractValue ingest
    # (the `{ptr,ptr}` GenericMemoryRef-body shape and fixed-width-integer
    # tuples). Bennett.jl's 6bu3 adds an additive `field_widths::Vector{Int}` so
    # a StructType aggregate lowers via per-field layout; BVM's index-keyed,
    # WIDTH-AGNOSTIC slot loop (`n_elems == length(field_widths)`) handles it with
    # NO code change. A hand-built {ptr,ptr} build/read chain (oracle
    # `f(data,mem)=data`) lowers, runs bit-exact on cell-sized inputs, round-trips
    # to empty history (P0.6), and per-step-inverts at K ∈ {1,4}. Same hand-built
    # ParsedIR + `per_step_inverse_check` idiom; depends only on loaded symbols.
    include("test_6bu3_struct_agg_ingest.jl")
    # M_FP.5 — Float32-rejection enforcement at the ingest boundary
    # (`bennettvm-h0t`; ADR 0011 §D2, Bennett-3rph). The witness half proves
    # the SC10 pure-Float64 lowering contains ZERO f32-touching SoftCalls; the
    # defensive half drives a hand-built f32 `IRCall` (soft_fptrunc ret-32 /
    # soft_fpext arg-32) through `lower_vm` and asserts the ingest guard
    # rejects each with a cause-naming ErrorException. Same hand-built ParsedIR
    # idiom as test_fail_loud_completeness.jl; depends on already-loaded
    # symbols + the SC10 fixture from test_fp_roundtrip.jl (re-built locally).
    include("test_fp_f32_reject.jl")
    # CW-B2/B3 — the reversible call/return machinery (ADR 0019; beads
    # `bennettvm-416r.6` / `416r.7`). The `CallEnter` / `ReturnExit`
    # transition pair over the `IState.frames` stack (chunk 1), the
    # multi-function lowering (`lower_vm(::Vector{Pair{Symbol,ParsedIR}})`
    # with `#`-qualified labels), and the interpreter's End-at-depth>1
    # routing. Covers the ADR §8 list: nested two-level call (golden master),
    # recursive factorial(5)==120 (frame depth 5, SSA collision), per-step
    # inverse ON CallEnter and ON ReturnExit, zero-history CallEnter step,
    # L3-checkpoint-inside-callee, malloc-in-callee pointer survival + arena
    # monotone, void-return callee, the §6 fail-loud suite, and frames
    # ==/hash sensitivity. Mutation-proof (M1–M4) is recorded in the file
    # header and performed against these tests. Pulls in
    # `per_step_inverse_check` via `test/test_per_step_inverse.jl`
    # (re-include-guarded); depends only on already-loaded symbols.
    include("test_call_roundtrip.jl")
    # Bennett-utzc / CW-D (ADR 0017 §4): the reversible `:__unreachable__` halt
    # sink. A dead throw arm branches to the dangling `:__unreachable__`
    # sentinel; ingest materialises a synthetic per-function sink block whose
    # sole body instruction `UnreachableHalt()` halts ON ENTRY with
    # `status = :error`. Covers not-taken round-trip (RED without the fix:
    # KeyError :__unreachable__), taken loud-halt, and the multi-function
    # `#`-qualified no-collision case. Sits after `test_call_roundtrip.jl`
    # (shares the multi-function lowering + `run!`-loop surface); pulls in
    # `per_step_inverse_check` via a plain `include` of test_per_step_inverse.jl
    # (the same idiom as test_dict_roundtrip.jl / test_call_roundtrip.jl).
    include("test_utzc_unreachable_sink.jl")
    # CW-C2 chunk C (BVM ADR 0020 D5; Bennett-nd45): a C-track `.ll`-sourced
    # IRCall has a bare `Symbol` callee. The IRCall arm now dispatches via
    # `_callee_sym(inst.callee)` (nameof for Function, identity for Symbol), so
    # a Symbol callee resolves through `_HEAP_DISPATCH` (:malloc → IntrinsicMalloc)
    # and the guard-5 function table (in-module → CallEnter), and the
    # nondeterminism/Float32 guards still fire.
    include("test_symbol_callee_ingest.jl")
    # CW-C3 (bead `bennettvm-416r.10`): THE STORY DEMO — a normal C hash-table
    # program (clang -O0 .ll) executes and REVERSES on the VM, bit-for-bit
    # against its native golden master (`test/reference/c/GOLDEN.txt`). The first
    # full proof of the language-agnostic claim (ADR 0017 §Sequencing CW-C).
    # Exercises the multi-function lowering, the frame-disjoint stack
    # (`stack_top` / `StackAlloca`), the COPY-arg / OVERWRITE-target call ABI,
    # the heap arena, and the IRPtrOffset struct GEP — end to end. Uses
    # `per_step_inverse_check` (re-include-guarded include inside the file).
    include("test_c_hashtable_e2e.jl")
    # bead `bennettvm-416r.4`: const globals as initialized read-only VM memory
    # segments. The acceptance gate `gtest(i)=rom[i&7]` (a `static const
    # uint8_t rom[8]` read at a runtime index) runs forward == native clang AND
    # reverses to its exact initial state; the 16 KB NES-ROM-scale case proves
    # the read-only design (shared `GlobalROM`, NOT per-checkpoint-copied). The
    # SAME front-end arm (Bennett.jl Case C) closes Bennett-dzd for local stack
    # arrays. clang-gated: emits fresh `.ll` + native golden in a tempdir,
    # self-skips if clang is absent (T5-corpus convention).
    include("test_global_array_vm.jl")
    # B1 (bd `bennettvm-zr7x`): `run!(...; record=false)` forward-only fast
    # mode — the Track-B framerate baseline
    # (`docs/design/emulator-on-bennettvm.md` §9.2). Fast == normal forward
    # result on the collatz one-liner (the E0 MVP sub-testset is opt-in via
    # `BENNETTVM_MVP_TESTS=1` — see the file header for the cost rationale),
    # `isempty(history)` after fast mode, `unrun!`/`unstep!` fail loud
    # (without mutating state) on a fast-mode RState, and the normal
    # recording round-trip is unregressed.
    include("test_fast_mode.jl")
end
