# test_cpu6502.jl — TDD harness for the E1 full-6502 core on BennettVM.
#
# For every (entry, seed) it asserts, per Rule 4:
#   (a) FORWARD  : the VM's returned int64 == the NATIVE clang binary (golden).
#   (b) ROUNDTRIP: after unrun!, current==initial, history empty, frames==1,
#                  arena_top==0, stack_top==0 (reversibility is a theorem here).
#   (c) SEMANTICS: known-answer programs additionally match a closed 6502
#                  formula of seed — catching an opcode-semantics bug that
#                  native==VM alone cannot (both run the SAME C).
#
# The native binary is compiled+run LIVE (no stale golden file). Prints a
# PASS/FAIL table per opcode group.
#
# Run:  julia --project emulator/test_cpu6502.jl        (from repo root)
#   env BENNETT_CPU_GROUPS="test_adc,test_sbc" runs only those entries
#   (comma-separated) — handy for iterating on one opcode group.

using BennettVM
import Bennett
const _BV = BennettVM
const _B  = Bennett

const HERE  = @__DIR__
const CSRC  = joinpath(HERE, "cpu6502.c")
const MSRC  = joinpath(HERE, "cpu6502_main.c")
const LL    = joinpath(HERE, "cpu6502.O0.ll")
const GOLD  = joinpath(HERE, "cpu6502_golden")
const K     = 32
# BENNETT_CPU_FWDONLY=1 → verify FORWARD correctness only (VM==native + known-
# answer semantics), skipping the ~5s/seed L3-replay reverse. Uses B1 fast mode
# (`run!(...; record=false)`) so the forward result is bit-for-bit identical to
# a recording run (see test_fast_mode.jl). Round-trip reversibility is a generic
# VM property proven on the representative sample + the hashtable/collatz e2e;
# this flag makes an all-151-opcode forward sweep practical (~3min vs ~28min).
const FWDONLY = get(ENV, "BENNETT_CPU_FWDONLY", "0") == "1"
const GREEN = "\e[32m"; const RED = "\e[31m"; const DIM = "\e[2m"; const RST = "\e[0m"

# --------------------------------------------------------------------------
# Build: LLVM IR (for the VM) + native golden binary (the oracle). Always
# rebuild so the two never drift from the C source.
# --------------------------------------------------------------------------
function build!()
    println("=== build: clang -O0 IR + native golden ===")
    run(`clang -O0 -S -emit-llvm -fno-discard-value-names -std=c11 $CSRC -o $LL`)
    run(`clang -O0 -std=c11 $CSRC $MSRC -o $GOLD`)
    println("  ok: $(basename(LL)) + $(basename(GOLD))")
end

# native golden: shell out to the compiled C binary; parse the printed int64.
native(entry::AbstractString, seed::Integer) =
    parse(Int64, strip(read(`$GOLD $entry $seed`, String)))

# The entry's single-i64 return SSA name (from the EndInstruction).
function _return_symbol(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BV.EndInstruction && b.exit.label === entry && !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

# --------------------------------------------------------------------------
# Test-group registry. Each entry: the C function name (== VM entry symbol ==
# initial-state param is always :seed), the seed sweep, and an optional
# known-answer oracle `f(seed)->Int64` for semantic validation.
# --------------------------------------------------------------------------
struct Group
    entry::Symbol
    desc::String
    seeds::Vector{Int64}
    oracle::Union{Nothing,Function}   # nothing => native-only; else known-answer
end

const _WIDE = Int64[0, 1, 2, 5, 0x0F, 0x10, 0x20, 0x7F, 0x80, 0x81, 0xFE, 0xFF]

const GROUPS = Group[
    Group(:test_loadstore,  "LDA #/zp/abs, LDX #/zp, LDY #, STA zp/abs", _WIDE, nothing),
    Group(:test_adc,        "ADC #/zp, CLC/SEC (carry+overflow)",        _WIDE, nothing),
    Group(:test_sbc,        "SBC #, SEC/CLC (borrow)",                   _WIDE, nothing),
    Group(:test_logic,      "AND #/ORA #/EOR #",                         _WIDE, nothing),
    Group(:test_cmp_branch, "CMP # + BEQ/BNE/BCC/BCS",                   _WIDE, nothing),
    Group(:test_transfers,  "TAX/TXA/TAY/TYA",                           _WIDE, nothing),
    Group(:test_incdec,     "INX/DEX/INY/DEY (+wrap)",                    _WIDE, nothing),
    Group(:test_jmp,        "JMP abs",                                   _WIDE, nothing),
    # STEP-3 opcode groups (indexed/indirect modes, RMW, stack, subroutines...)
    Group(:test_addr_modes, "zp,X/abs,X/abs,Y/zp,Y/(ind,X)/(ind),Y", _WIDE, nothing),
    Group(:test_memrmw,     "INC/DEC mem + STX/STY (all modes)",      _WIDE, nothing),
    Group(:test_shifts,     "ASL/LSR/ROL/ROR (A + memory)",           _WIDE, nothing),
    Group(:test_stack,      "PHA/PLA/PHP/PLP + TSX/TXS",              _WIDE, nothing),
    Group(:test_jsr_rts,    "JSR/RTS + hardware stack",               _WIDE, nothing),
    Group(:test_cpxy_bit,   "CPX/CPY + BIT (zp/abs)",                 _WIDE, nothing),
    Group(:test_flags,      "SEC/CLC/SEI/CLI/SED/CLD/CLV",            _WIDE, nothing),
    Group(:test_indirect,   "JMP (indirect)",                        _WIDE, nothing),
    Group(:test_branches2,  "BPL/BMI/BVC/BVS",                       _WIDE, nothing),
    # known-answer (semantic) programs
    Group(:test_adc_known,  "ADC known: A=(seed+5)&0xFF",  _WIDE, s -> Int64((s + 5)  & 0xFF)),
    Group(:test_sub_known,  "SBC known: A=(seed-0x10)&0xFF",_WIDE, s -> Int64((s - 16) & 0xFF)),
    Group(:test_countdown,  "loop known: A=(5*seed)&0xFF",
          Int64[0,1,2,3,5,10,20,50,51], s -> Int64((5 * s) & 0xFF)),
    Group(:test_asl_known,  "ASL known: A=(seed<<1)&0xFF",  _WIDE, s -> Int64((s << 1) & 0xFF)),
    Group(:test_lsr_known,  "LSR known: A=(seed&0xFF)>>1",  _WIDE, s -> Int64((s & 0xFF) >> 1)),
    Group(:test_jsr_known,  "JSR known: A=(seed+10)&0xFF",  _WIDE, s -> Int64((s + 10) & 0xFF)),
]

# --------------------------------------------------------------------------
# Run one group: lower_vm, then for each seed compare VM vs native (+oracle)
# and verify the round-trip. Returns (npass, nfail, tot_fwd, tot_rev).
# --------------------------------------------------------------------------
function run_group(SET, g::Group)
    prog = _BV.lower_vm(SET; entry = g.entry)
    mc   = _BV.compute_must_cache(prog)
    ret  = _return_symbol(prog, g.entry)
    npass = 0; nfail = 0; tf = 0.0; tr = 0.0
    fails = String[]
    for s in g.seeds
        rs   = _BV.initial_state(prog, Dict(:seed => Int64(s)))
        init = deepcopy(rs.current)
        t1 = @elapsed _BV.run!(rs, prog; max_steps = 200_000_000,
                               checkpoint_interval = K, must_cache_set = mc,
                               record = !FWDONLY)
        got  = _BV.result(rs)[ret]
        want = native(String(g.entry), s)
        if FWDONLY
            rt = true; t2 = 0.0                        # reverse skipped (B1 fast mode)
        else
            t2 = @elapsed _BV.unrun!(rs, prog; max_unsteps = 200_000_000)
            rt = isempty(rs.history) && length(rs.current.frames) == 1 &&
                 rs.current.arena_top == 0 && rs.current.stack_top == 0 && rs.current == init
        end
        tf += t1; tr += t2
        fwd = (got == want)
        sem = g.oracle === nothing ? true : (got == g.oracle(s))
        if fwd && rt && sem
            npass += 1
        else
            nfail += 1
            reason = !fwd ? "VM=$got≠native=$want" :
                     !sem ? "VM=$got≠oracle=$(g.oracle(s))" : "roundtrip broken"
            push!(fails, "seed=$s: $reason")
        end
    end
    return (npass, nfail, tf, tr, fails, _BV.n_instructions(prog))
end

# --------------------------------------------------------------------------
function main()
    build!()
    print("=== extract_parsed_ir_set_from_ll(ptr_cells=true) ... ")
    t_ext = @elapsed SET = _B.extract_parsed_ir_set_from_ll(LL; ptr_cells = true)
    println("$(length(SET)) fns in $(round(t_ext,digits=1))s ===")

    groups = GROUPS
    if haskey(ENV, "BENNETT_CPU_GROUPS")
        want = Set(Symbol.(split(ENV["BENNETT_CPU_GROUPS"], ",")))
        groups = filter(g -> g.entry in want, GROUPS)
    end

    println("\n", rpad("group", 16), rpad("what", 42), rpad("result", 10),
            rpad("instrs", 8), "fwd/rev(s)")
    println(DIM, "-"^96, RST)
    allpass = true; total_p = 0; total_f = 0
    for g in groups
        p, f, tf, tr, fails, ninst = run_group(SET, g)
        total_p += p; total_f += f
        mark = f == 0 ? "$(GREEN)PASS $p/$(p+f)$RST" : "$(RED)FAIL $p/$(p+f)$RST"
        println(rpad(String(g.entry), 16), rpad(g.desc, 42), rpad(mark, 19),
                rpad(ninst, 8), "$(round(tf,digits=2))/$(round(tr,digits=2))")
        for msg in fails
            println("    ", RED, msg, RST)
        end
        allpass &= (f == 0)
    end
    println(DIM, "-"^96, RST)
    n_sem = count(g -> g.oracle !== nothing, groups)
    println("groups=$(length(groups))  seeds/group≈$(length(_WIDE))  ",
            "known-answer(semantic) groups=$n_sem  cases: $(GREEN)$total_p pass$RST / ",
            total_f == 0 ? "0 fail" : "$(RED)$total_f fail$RST")
    rttext = FWDONLY ? "(round-trip SKIPPED — BENNETT_CPU_FWDONLY)" : "round-trips exactly, and"
    println(allpass ?
        "\n$(GREEN)=== ALL GREEN: every opcode group matches native C bit-for-bit, " *
        "$rttext known-answer programs match 6502 semantics ===$RST" :
        "\n$(RED)=== FAILURES ABOVE ===$RST")
    return allpass
end

ok = main()
exit(ok ? 0 : 1)
