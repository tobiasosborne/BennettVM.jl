# mvp_c_runner.jl — run the C 6502 core on BennettVM via the proven C path,
# anchored to the NATIVE golden master (Rule 4 / Law 1).
using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B  = Bennett

const HERE = @__DIR__
const LL   = joinpath(HERE, "mos6502.O0.ll")
const K    = 32

# golden master captured from the native clang -O0 binary
const GOLDEN = Dict(0=>0, 1=>5, 2=>10, 3=>15, 5=>25, 10=>50, 20=>100, 51=>255)

function _return_symbol(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BV.EndInstruction && b.exit.label === entry && !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

println("=== ingest mos6502.O0.ll (ptr_cells=true) ===")
t_ext = @elapsed SET = _B.extract_parsed_ir_set_from_ll(LL; ptr_cells = true)
println("  extracted $(length(SET)) function(s) in $(round(t_ext,digits=1))s")

println("=== lower_vm(entry=:mos6502) ===")
t_low = @elapsed prog = _BV.lower_vm(SET; entry = :mos6502)
mc  = _BV.compute_must_cache(prog)
ret = _return_symbol(prog, :mos6502)
println("  lowered in $(round(t_low,digits=1))s → $(_BV.n_instructions(prog)) instrs; ret=$ret")

allgood = true
for n in (0, 1, 2, 3, 5, 10, 20, 51)
    rs   = _BV.initial_state(prog, Dict(:n => Int64(n)))
    init = deepcopy(rs.current)
    tf = @elapsed _BV.run!(rs, prog; max_steps = 200_000_000,
                           checkpoint_interval = K, must_cache_set = mc)
    got  = _BV.result(rs)[ret]
    want = GOLDEN[n]
    tr = @elapsed _BV.unrun!(rs, prog; max_unsteps = 200_000_000)
    rt = isempty(rs.history) && length(rs.current.frames) == 1 &&
         rs.current.arena_top == 0 && rs.current.stack_top == 0 && rs.current == init
    fwd = got == want
    mark = (fwd && rt) ? "\e[32mPASS\e[0m" : "\e[31mFAIL\e[0m"
    println("  n=$n  VM→$got  native→$want  $(fwd ? "✓" : "✗")   " *
            "roundtrip=$(rt ? "✓" : "✗")   [fwd $(round(tf,digits=2))s / rev $(round(tr,digits=2))s]  $mark")
    global allgood &= (fwd && rt)
end

println(allgood ?
    "\n\e[32m=== MVP GREEN: a reversible 6502 executed hand-assembled machine code, matched native C bit-for-bit, and un-ran to its exact initial state ===\e[0m" :
    "\n\e[31m=== MVP FAILURES ===\e[0m")
