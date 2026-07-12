# Scout report — `jl_global#NNN` global census (fdict closed-world set)

Machine: WSL2 / Julia 1.12.x. Date: 2026-07-12. All evidence below was produced
live this session (probe scripts in `scratchpad/probe.jl`, `probe2.jl`; raw LLVM
in `scratchpad/root.ll`, `callee_*.ll`). No claim is paraphrased from docs.

Repro recipe (matches test_x3t0_multikey_return.jl testset (f)):
```julia
fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
set = Bennett.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8}; ptr_cells=true)
prog = BennettVM.lower_vm(set; entry = first(set).first)   # COMPLETES
rs = BennettVM.initial_state(prog, Dict(:a=>3, :b=>7)); BennettVM.run!(rs, prog)  # THROWS
```

---

## Q1 — REPRODUCE the wall

**VERDICT: Reproduced exactly. `run!` throws `KeyError: key Symbol("jl_global#23405")
not found` inside `Define.forward` → `_resolve` (arithmetic_assignment.jl:153),
driven from Interpreter `step!`. The offending instruction is the root
`fdict_d1b` PIR's `IRPtrOffset(dest=.ptr_ptr, base=jl_global#23405, offset_bytes=8)`,
which BennettVM lowers to `Define(:.ptr_ptr, :jl_global#23405, :add, 1)` — and
`jl_global#23405` is never bound in `active_locals`. The wall is hit at DICT
CONSTRUCTION, before setindex!/rehash! ever run.**

Evidence — captured error (probe.jl):
```
lower_vm COMPLETED: prog isa VMProgram = true
haskey ht_keyindex2_shorthash! = true
inputs = Dict(Symbol("a::Int8") => 3, Symbol("b::Int8") => 7)

RUN THREW: KeyError: key Symbol("jl_global#23405") not found
  [1] getindex(h::Dict{Symbol, Int64}, key::Symbol)      @ Base ./dict.jl:477
  [2] _resolve                @ src/ir/arithmetic_assignment.jl:153 [inlined]
  [3] forward(instr::Define, s::IState)  @ src/ir/define_instruction.jl:184
  [4] step!(...)              @ src/interpreter/Interpreter.jl:1056
```

The producing IR instruction (probe.jl census of the root PIR):
```
[fdict_d1b#4a8d3eda] Bennett.IRPtrOffset dest=.ptr_ptr  globalrefs=[jl_global#23405]
[fdict_d1b#4a8d3eda] Bennett.IRStore    dest=-          globalrefs=[jl_global#23405]
```
`ingest_body.jl:534` lowers `IRPtrOffset` to `Define(dest, base.name, :add, offset÷ew)`,
so the base `jl_global#23405` is *read* (`_resolve`) at forward time → KeyError.

The `.ptr_ptr` offset-8 GEP in the source LLVM (root.ll:49-54), inside the
`Dict()` constructor's inlined `fill!`:
```
%.ptr_ptr = getelementptr inbounds i8, ptr addrspace(11) %3, i32 8      ; %3 = singleton
%.ptr_ptr.unbox = load ptr, ptr addrspace(11) %.ptr_ptr
call void @llvm.memset.p0.i64(ptr align 1 %.ptr_ptr.unbox, i8 0, i64 0, i1 false)  ; LEN 0
```

---

## Q2 — GLOBAL CENSUS (all 4 ParsedIRs)

**VERDICT: The 4 PIRs reference two *disjoint* classes of Julia JIT global, both
of the SAME LLVM shape (`private constant ptr @X.jit`, `@X.jit = private alias
ptr, inttoptr (i64 <JIT-addr> to ptr)`): (1) `+Type#NNN` name-encoded TYPE-TAGS,
which extraction RECOGNISES and lowers to a constant identity; (2) `jl_global#NNN`
(no `+` prefix) interned globals — the empty `GenericMemory` singletons and misc
runtime objects — which extraction does NOT recognise: their defining `load` is
DROPPED, leaving a dangling SSA name. Only class (2) walls. Only the scalar
`_j_const#N` literals land in `ParsedIR.globals`.**

Per-PIR `.globals` field contents (probe.jl):
```
fdict_d1b#...        globals(keys) = [_j_const#2, _j_const#1]           (i64 1, i64 0)
setindex!#...        globals(keys) = []
rehash!#...          globals(keys) = [_j_const#3, _j_str_invalid GenericMemory siz...#2, _j_const#1]
ht_keyindex2_...     globals(keys) = []
```

Distinct global-like symbols referenced in the instruction STREAM (probe.jl):
```
jl_global#23405, jl_global#23406, jl_global#234061     (root fdict)
+Main.Base.Dict#23407                                   (root fdict)
+Core.GenericMemory#8415/#8417/#841717/#841530/#841743/#841755  (rehash!)
```
(Numbering drifts per code_llvm call — root.ll's own dump numbers them #71/#72/#77
/#73; structurally identical.)

**(a) Which instructions reference each, and role:**

| symbol | class | referencing instrs / role |
|---|---|---|
| `jl_global#23405` (=root.ll `#71`) | empty `Memory{UInt8}` singleton (keys) | `IRPtrOffset(.ptr_ptr, base=…, +8)` (GEP into singleton data-ptr field) **and** `IRStore` value (stored into Dict field). **NEVER DEFINED** → wall |
| `jl_global#23406` / `#234061` (=`#72` loaded twice) | empty `Memory{Int8}` singleton (vals/slots) | two `IRStore` values (Dict keys_ptr / vals_ptr fields). Never defined |
| `+Main.Base.Dict#23407` (=`#73`) | `Dict` TYPE-TAG | `IRBinOp(dest=+Main.Base.Dict#23407, :or, iconst(id),0,64)` (minted identity) → consumed as the IGNORED tag arg of `IRCall(:gc_alloc_obj)` (dest=`Dict`) |
| `+Core.GenericMemory#NNNN` (rehash!) | `GenericMemory` TYPE-TAGs | `IRBinOp` minted identity → tag arg of the `Memory{…}[]` allocation `IRCall`s |
| `jl_global#77` (root, L84) | AssertionError ctor arg | loaded + passed to `@j_AssertionError_76`; on the dead assert path, not reached by fdict(3,7) |
| `_j_const#1/#2/#3` | scalar `i64` literals | memcpy field-init sources; captured into `.globals` but NOT `IRVarGEP` bases (see Q5) |

**(b) Raw LLVM definitions (root.ll — verbatim):**

Class (2) — the interned `jl_global#NNN` (the wall culprits):
```
@"jl_global#71" = private unnamed_addr constant ptr @"jl_global#71.jit", !julia.constgv !0
@"jl_global#72" = private unnamed_addr constant ptr @"jl_global#72.jit", !julia.constgv !0
@"jl_global#77" = private unnamed_addr constant ptr @"jl_global#77.jit", !julia.constgv !0
@"jl_global#71.jit" = private alias ptr, inttoptr (i64 127817901295920 to ptr)
@"jl_global#72.jit" = private alias ptr, inttoptr (i64 127817871644880 to ptr)
@"jl_global#77.jit" = private alias ptr, inttoptr (i64 127818024795600 to ptr)
```

Class (1) — the `+Type#NNN` type-tags (RECOGNISED, handled):
```
@"+Main.Base.Dict#73"     = private unnamed_addr constant ptr @"+Main.Base.Dict#73.jit", !julia.constgv !0
@"+Core.AssertionError#78"= private unnamed_addr constant ptr @"+Core.AssertionError#78.jit", !julia.constgv !0
@"+Main.Base.Dict#73.jit"      = private alias ptr, inttoptr (i64 127817769866384 to ptr)
@"+Core.AssertionError#78.jit" = private alias ptr, inttoptr (i64 127817868798992 to ptr)
```
Scalar literals:
```
@"_j_const#1" = private unnamed_addr constant i64 0, align 8
@"_j_const#2" = private unnamed_addr constant i64 1, align 8
```

Note: class (1) and class (2) are BYTE-IDENTICAL in shape — `constant ptr`
pointing at a `.jit` alias that is `inttoptr (i64 <nondeterministic-JIT-addr>)`.
The ONLY difference is the NAME (`+dotted.Type#N` vs `jl_global#N`).

**(c) Read as data on the fdict(3,7) path?** The `jl_global#71/#72` singletons
are BOTH stored as opaque pointers into Dict fields AND read as data:
```
; root.ll — the defining loads (which extraction DROPS, see Q4):
%"jl_global#71" = load ptr, ptr @"jl_global#71"    ; load the singleton pointer VALUE
%1 = addrspacecast ptr %"jl_global#71" to ptr addrspace(10)
; then (fill!):  GEP +8 into the singleton, load its data-ptr, memset LEN 0 (inert)
; then stored into the fresh Dict object:
store atomic ptr addrspace(10) %1, ptr addrspace(11) %12 release
store atomic ptr addrspace(10) %4, ptr addrspace(11) %"new::Dict.keys_ptr" release
store atomic ptr addrspace(10) %5, ptr addrspace(11) %"new::Dict.vals_ptr" release
```
So: read as data = YES (GEP+8, and later rehash! reads the length field), but the
only construction-time data read feeds a **zero-length memset** (semantically no-op).

---

## Q3 — THE EMPTY-DICT SINGLETON specifically

**VERDICT: The `jl_global#71/#72` are the empty `GenericMemory` SINGLETONS (the
`Memory{UInt8}`/`Memory{Int8}` empty instances for keys/slots/vals), NOT type-tags.
`Dict{Int8,Int8}()` does NOT allocate them fresh — they are loaded from the interned
constant globals and STORED into the new Dict's keys/slots/vals fields as opaque
pointers. They ARE read as data on the full path: (a) at construction a GEP at
offset +8 (the Memory data-ptr field) is loaded but only feeds a `memset(len=0)`
(inert); (b) `rehash!` (reached by `d[a]=b`) reads a Memory LENGTH field
(`%memory_len = load i64, {i64,ptr}* , i32 0, i32 0`) to bound its rebuild/copy
loop — for the empty singleton this must read 0. `rehash!` DOES allocate the fresh
backing via the whitelisted `jl_alloc_genericmemory_unchecked` intrinsic (it emits
`Memory{…}[]` IRCalls). CONCLUSION: we need only a DETERMINISTIC opaque pointer for
each singleton plus a zeroed 16-byte header (length@0 = 0, data-ptr@8 = anything,
consumed only by the 0-length memset) — a default-0 GlobalROM cell satisfies the
length==0 read for free. No real Memory *contents* are required for fdict(3,7).**

Evidence — construction reads the singleton at offset +8 then does a 0-length
memset (root.ll:49-54), verbatim:
```
%.ptr_ptr = getelementptr inbounds i8, ptr addrspace(11) %3, i32 8   ; %3 = singleton@as11
%.ptr_ptr.unbox = load ptr, ptr addrspace(11) %.ptr_ptr             ; read data-ptr field
call void @llvm.memset.p0.i64(ptr align 1 %.ptr_ptr.unbox, i8 0, i64 0, i1 false)
```
The memset length is a COMPILE-TIME `i64 0` — not read from the singleton — so the
loaded data-ptr is never consumed meaningfully.

Evidence — `rehash!` reads Memory length fields (callee_rehash!.ll):
```
%36 = getelementptr inbounds { i64, ptr }, ptr addrspace(11) %35, i32 0, i32 0
%memory_len = load i64, ptr addrspace(11) %36, align 8, !range !129
```
(Several such `%memory_len*` reads; the copy loop over old slots bounds on
`length(old)` = 0 for the empty singleton.) `rehash!` allocates the NEW backing
fresh — census shows `IRCall` dests `Memory{UInt8}[]`, `Memory{Int8}[]` (the
`jl_alloc_genericmemory_unchecked` intrinsic path), so the fresh memory is a
whitelisted alloc, not read off a singleton.

---

## Q4 — FRONT-END STATE

**VERDICT: `_extract_const_globals` captures ONLY the scalar `_j_const#N` literals
(i64 0/1/…) for these PIRs; it DROPS every `jl_global#NNN` and `+Type#NNN` global
because their initializer is a `ptr` (a `constant ptr @…jit`), which matches none
of its dispatch arms (ConstantDataArray / ConstantStruct / ConstantAggregateZero /
ConstantInt) → final `else: continue`. The Julia set-path DOES run
`_extract_const_globals` (it is inside `_module_to_parsed_ir_on_func`, called per
callee). The `jl_global#NNN` NAME enters the instruction stream NOT as the global
itself but as the SSA NAME OF THE LOAD RESULT: Julia names `%"jl_global#71" = load
ptr, ptr @"jl_global#71"`, so the naming pass sets `names[load.ref] =
:jl_global#71` (module_walk.jl:308-313). The load is then DROPPED at
instructions.jl:3549-3565 (`load ptr @GlobalVariable`, not name-recognised as a
`+`-type-tag, and the GlobalVariable ptr operand is not in `names` → `return
nothing`). Result: the name is bound in `names` but no IRInst DEFINES it; every
later use (`IRPtrOffset` base, `IRStore` value) resolves to `ssa(:jl_global#71)`
via `_operand` (helpers.jl:204-208), producing the dangling reference.**

`.globals` contents per PIR (probe.jl, repeated from Q2):
```
fdict_d1b     : [_j_const#2 => (UInt64[1],64), _j_const#1 => (UInt64[0],64)]
setindex!     : []
rehash!       : [_j_const#3, _j_str_invalid GenericMemory siz...#2, _j_const#1]
ht_keyindex2  : []
```
No `jl_global#NNN` in ANY `.globals` — confirmed the load-drop leaves them
name-only.

Where the name is emitted (file:line):
- `src/extract/module_walk.jl:310-311` — naming pass: `names[inst.ref] =
  Symbol(LLVM.name(inst))` binds `:jl_global#71` to the (about-to-be-dropped) load.
- `src/extract/instructions.jl:3537-3547` — the `+Type#N` type-tag load arm
  (`_is_type_tag_global_name`, `+`-prefix ONLY) — does NOT match `jl_global#N`.
- `src/extract/instructions.jl:3549-3565` — fall-through: `haskey(names,
  ptr.ref)` is false for a GlobalVariable operand → `return nothing` (load dropped).
- `src/extract/helpers.jl:204-208` — `_operand` on later uses: `haskey(names, r)`
  true → `ssa(names[r])` = `ssa(:jl_global#71)` — the dangling operand.
- `src/extract/module_walk.jl:918-1033` — `_extract_const_globals`: the `ptr`
  initializer matches no arm → dropped.

---

## Q5 — VM SEEDING STATE

**VERDICT: `Define.forward` KeyErrors at `src/ir/define_instruction.jl:184` (via
`_resolve` at `src/ir/arithmetic_assignment.jl:153`). C-path globals are seeded by
`_global_segment` (`src/ir/ingest.jl:226`): it walks `parsed.globals`, materialises
ONLY globals used as an `IRVarGEP` base into a `GlobalROM` based at `GLOBAL_BASE =
2^48`, and `_lower_parsed_ir` PREPENDS a `Define(gname, base, :add, 0)` to the entry
block (ingest.jl:584-588) to bind each ROM pointer name. The fdict set NEVER reaches
this machinery for the jl_global names: they are not in `parsed.globals` at all, so
`_global_segment` produces nothing for them and no Define-prepend is emitted → the
name is unbound at runtime. The multi-function fail-loud guard (ingest_multi.jl:204)
does NOT fire, because `prog.globals.cells` is empty (the `_j_const` literals are
memcpy sources, never `IRVarGEP` bases, so `_global_segment` seeds zero cells) —
which is exactly why `lower_vm` COMPLETES and the wall is deferred to run time.**

The multi-function guard, verbatim (ingest_multi.jl:195-211):
```julia
# Const-global segment in a MULTI-function module is deferred (bead
# `bennettvm-416r.4` lands single-function only). Per-function
# `_lower_parsed_ir` assigns each referenced global a base from
# `GLOBAL_BASE + 0`, so two functions referencing globals would COLLIDE;
# correct handling needs a module-wide single assignment (a follow-up
# bead). The merged `VMProgram` (§3) also drops per-function globals, so
# a referenced global would silently read 0. Fail loud rather than
# miscompile (Rule 1). Existing fixtures (collatz / hashtable) GEP no
# const globals, so `global_rom.cells` is empty and this never fires.
isempty(prog.globals.cells) ||
    error("lower_vm(multi): function :", name, " references a const ",
          "global array, but module-wide const-global support is not ",
          "yet implemented (per-function bases would collide at ",
          "GLOBAL_BASE; the merged VMProgram drops per-function ",
          "globals). Single-function const globals work today (bead ",
          "`bennettvm-416r.4`); the multi-function module-wide segment ",
          "is a follow-up. Rule 1 fail-loud.")
```
This guard would fire IF `_j_const#N` (or the jl_globals, if they were captured)
were `IRVarGEP` bases. They are not, so `cells` is empty and lower_vm completes.

`IntrinsicGCAlloc.type_tag` is structurally unread (intrinsics.jl:194-210): the
`+Type#N` tags flow into its metadata-only third field and never touch VM state.

---

## Q6 — SCALE OF THE FIX

**VERDICT: AT the wall: exactly 1 distinct global (`jl_global#23405`, the keys
singleton). IN TOTAL on the fdict(3,7) path the root touches 2 distinct empty-
singleton globals (`#71` keys, `#72` vals+slots, loaded 3× total) plus (on dead
paths) `#77`. NOT all of them are type-tags. The `+Type#NNN` globals (Dict,
GenericMemory×6, KeyError, AssertionError) ARE type-tags and their ONLY consumer is
the ignored `gc_alloc_obj` / `jl_alloc_genericmemory_unchecked` tag arg (plus, for
KeyError/AssertionError, a `ptrtoint` on the throw path). The `jl_global#NNN`
globals are NOT type-tags: `#71/#72` are real empty-Memory SINGLETON data pointers,
stored into Dict fields AND read as data (offset +8 → 0-length memset; offset 0
length read by rehash!). So the fix is NOT "materialise a data segment for all of
them": it needs (a) a deterministic opaque pointer VALUE for each `jl_global#NNN`,
seeded + Define-prepended like the C GlobalROM path, and (b) a zeroed 16-byte
Memory header behind each singleton so the length@0 read returns 0 and the data-ptr@8
read (consumed only by memset(len=0)) is harmless. A default-0 GlobalROM already
provides (b) once (a) assigns a base.**

Counting evidence (probe.jl distinct list + root.ll): jl_global class in root =
`#23405`, `#23406`, `#234061` (i.e. singleton keys, singleton vals, second load of
vals→slots) = 2 unique underlying singletons; plus `#77` on the L84 assert path.
`+Type` class = `Dict#73`, `KeyError#75`, `AssertionError#78` (root) and 6×
`GenericMemory#NNNN` (rehash!) — all type-tags, consumed only as ignored alloc tags.

---

## Surprises / contradictions vs ADR 0021 D3

1. **ADR 0021 D3 is CORRECT about the LLVM shape, but its NAME-based recogniser
   is incomplete.** D3 says interned type-tag globals are `private alias ptr,
   inttoptr (i64 <JIT-addr> to ptr)` — verified verbatim for BOTH `+Type#NNN` AND
   `jl_global#NNN`. But the extractor only *recognises* the `+`-prefixed subset
   (`_is_type_tag_global_name` = `startswith("+") && occursin(r"#\d+$")`,
   constexpr.jl:135). The `jl_global#NNN` globals have the identical shape but a
   different name and fall through → their load is silently dropped → dangling SSA
   → the wall. The recogniser's `+`-only gate is the precise front-end gap.

2. **The `jl_global#NNN` are NOT (all) type-tags — the HANDOFF 2026-06-08 claim is
   the RIGHT intuition.** `#71/#72` are the empty `GenericMemory` SINGLETONS, real
   runtime objects, stored into Dict fields as opaque pointers and read as data.
   ADR 0021 D3's framing ("interned `jl_global#NNN` are runtime TYPE-TAG pointers …
   consumed by gc_alloc_obj which ignores the tag") is TOO NARROW: at least the
   Memory singletons are data pointers whose length field (0) is read by rehash!,
   not tags fed to gc_alloc_obj. Treating every `jl_global#NNN` as an ignorable tag
   would be wrong — the singleton pointer must be a stable value AND back a
   zeroed header.

3. **But the data that is read is INERT for fdict(3,7).** The offset+8 read feeds a
   compile-time-0 memset; the offset+0 length read needs only to be 0 (default-0
   ROM cell). So although the singleton is "real data", the *practical* fix
   collapses to "assign a deterministic pointer + zeroed 16-byte header" — much
   closer to D3's opaque-pointer philosophy than to a full singleton-object
   materialisation. The contradiction with D3 is real but the required fix is small.

4. **The wall is at CONSTRUCTION, not in setindex!/rehash!.** The doc context
   framed the singleton question around the rehash! probe loop, but fdict(3,7)
   aborts at the very first `IRPtrOffset` off the keys singleton during
   `Dict{Int8,Int8}()` — setindex!/rehash!/ht_keyindex2 are lowered but never
   executed. The rehash! length-read behaviour (Q3) is a *downstream* wall that the
   construction fix will expose next.

5. **The multi-function const-global guard never fires** for this set — a mild
   surprise given the doc's emphasis on it. Because the only captured globals
   (`_j_const#N`) are memcpy sources (never `IRVarGEP` bases), `_global_segment`
   seeds zero cells, `prog.globals.cells` is empty, the ingest_multi.jl:204 guard
   passes, and lower_vm completes. The jl_global names bypass the const-global
   pipeline entirely (they aren't in `.globals`), so the failure is a *dangling SSA
   operand at run time*, not a lower-time const-global collision.
```
