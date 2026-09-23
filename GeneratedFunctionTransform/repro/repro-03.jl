# repro-03.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-03.jl
#   Internal error: during type inference of
#   stale(Int64)
#   Encountered unexpected error in runtime:
#   ErrorException("invalid age range update")
#   error at ./error.jl:44
#   WorldWithRange at ./../usr/share/julia/Compiler/src/inferencestate.jl:253 [inlined]
#   intersect at ./../usr/share/julia/Compiler/src/inferencestate.jl:259 [inlined]
#   update_valid_age! at ./../usr/share/julia/Compiler/src/inferencestate.jl:990 [inlined]
#   InferenceState at ./../usr/share/julia/Compiler/src/inferencestate.jl:415
#   InferenceState at ./../usr/share/julia/Compiler/src/inferencestate.jl:606 [inlined]
#   InferenceState at ./../usr/share/julia/Compiler/src/inferencestate.jl:608 [inlined]
#   typeinf_ext at ./../usr/share/julia/Compiler/src/typeinfer.jl:1398
#     [... backtrace truncated ...]
#   top-level scope at work/body-03.jl:36
#   jl_toplevel_eval_flex at src/toplevel.c:742
#   jl_eval_toplevel_stmts at src/toplevel.c:585
#   jl_toplevel_eval_flex at src/toplevel.c:683
#   ijl_toplevel_eval at src/toplevel.c:754
#   ijl_toplevel_eval_in at src/toplevel.c:799
#   eval at ./boot.jl:489
#   include_string at ./loading.jl:3016
#   _include at ./loading.jl:3076
#     [... backtrace truncated ...]
#   compile mode: default
#   stale(1) returned: 1
#   FAIL: the stale body was accepted (any 'Internal error ... invalid age range update' above was printed by inference and recovered from)
#
# $ julia +1.13 --compile=min repro-03.jl
#   compile mode: --compile=min
#   stale(1) returned: 1
#   FAIL: the stale body was accepted (any 'Internal error ... invalid age range update' above was printed by inference and recovered from)
#
# $ <fixes-build>/julia repro-03.jl
#   compile mode: default
#   stale(1) threw: Generated function stale returned code valid for worlds [1, 2], which does not include the requested world 43042
#   PASS: generator's out-of-range world was rejected with a descriptive error
#
# $ <fixes-build>/julia --compile=min repro-03.jl
#   compile mode: --compile=min
#   stale(1) threw: Generated function stale returned code valid for worlds [1, 2], which does not include the requested world 43042
#   PASS: generator's out-of-range world was rejected with a descriptive error
#
# Bug 3: a generator may restrict the world range of the CodeInfo it returns, but
# `jl_code_for_staged` (src/method.c) never checks that the range contains the requested world.
# On the compiled path this surfaces much later as `Internal error: ... invalid age range update`
# from `InferenceState` (Compiler/src/inferencestate.jl), naming neither the generator nor the
# range; under `--compile=min` no check runs at all and the stale body executes silently.
#
# Usage: julia repro-03.jl
#        julia --compile=min repro-03.jl
function build_src()
    ci = ccall(:jl_new_code_info_uninit, Ref{Core.CodeInfo}, ())
    ci.code = Any[Core.ReturnNode(Core.SlotNumber(2))]     # `return x`
    ci.ssavaluetypes = 1
    ci.ssaflags = UInt32[0]
    ci.slotnames = Symbol[Symbol("#self#"), :x]
    ci.slotflags = UInt8[0x00, 0x00]
    ci.nargs = 2
    ci.isva = false
    ci.debuginfo = Core.DebugInfo(:none)
    return ci
end

function stalegen(world::UInt, source, argtypes...)
    ci = build_src()
    ci.min_world = 1
    ci.max_world = UInt(2)      # a stale snapshot; `world` is far beyond 2
    ci.edges = Core.svec()
    return ci
end
@eval function stale(x)
    $(Expr(:meta, :generated, stalegen))
    $(Expr(:meta, :generated_only))
end

println("compile mode: ", Base.JLOptions().compile_enabled == 3 ? "--compile=min" : "default")
r = try
    ("returned", stale(1))
catch e
    ("threw", sprint(showerror, e))
end
println("stale(1) ", r[1], ": ", r[2])
if r[1] == "threw" && occursin("world", r[2])
    println("PASS: generator's out-of-range world was rejected with a descriptive error")
else
    println("FAIL: the stale body was accepted (any 'Internal error ... invalid age range update' above was printed by inference and recovered from)")
end
