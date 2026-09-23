# repro-02.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-02.jl
#   Internal error: during type inference of
#   shared(Float64)
#   Encountered unexpected error in runtime:
#   TypeError(func=:typeassert, context="", expected=Int64, got=Array{Any, 1}(dims=(1,), ...)
#   ijl_type_error_rt at src/rtutils.c:121
#   ijl_type_error at src/rtutils.c:140
#   InferenceState at ./../usr/share/julia/Compiler/src/inferencestate.jl:339
#   InferenceState at ./../usr/share/julia/Compiler/src/inferencestate.jl:606 [inlined]
#   InferenceState at ./../usr/share/julia/Compiler/src/inferencestate.jl:608 [inlined]
#   typeinf_ext at ./../usr/share/julia/Compiler/src/typeinfer.jl:1398
#   typeinf_ext_toplevel at ./../usr/share/julia/Compiler/src/typeinfer.jl:1601 [inlined]
#   typeinf_ext_toplevel at ./../usr/share/julia/Compiler/src/typeinfer.jl:1610
#     [... backtrace truncated ...]
#   top-level scope at work/body-02.jl:35
#   jl_toplevel_eval_flex at src/toplevel.c:742
#   jl_eval_toplevel_stmts at src/toplevel.c:585
#   jl_toplevel_eval_flex at src/toplevel.c:683
#   ijl_toplevel_eval at src/toplevel.c:754
#   ijl_toplevel_eval_in at src/toplevel.c:799
#   eval at ./boot.jl:489
#   include_string at ./loading.jl:3016
#   _include at ./loading.jl:3076
#     [... backtrace truncated ...]
#   ssavaluetypes before first call: 1
#   shared(1)   = 1
#   ssavaluetypes after first call:  Any[Any]
#   shared(1.0) = 1.0   (look for 'Internal error: during type inference of shared(Float64)' above)
#   FAIL: the generator's CodeInfo was mutated in place (ssavaluetypes is now a Vector{Any})
#
# $ <fixes-build>/julia repro-02.jl
#   ssavaluetypes before first call: 1
#   shared(1)   = 1
#   ssavaluetypes after first call:  1
#   shared(1.0) = 1.0   (look for 'Internal error: during type inference of shared(Float64)' above)
#   PASS: the generator's CodeInfo was not mutated
#
# Bug 2: `jl_code_for_staged` (src/method.c) hands the generator's own CodeInfo object to
# `jl_resolve_definition_effects_in_ir` and then to inference without copying it. A generator
# that returns an object it keeps (e.g. prepared IR stored in a table) gets that object mutated
# by the first specialization; the second specialization then receives a half-inferred body
# and inference fails with an internal TypeError (recovered by falling back to dynamic dispatch).
#
# Usage: julia repro-02.jl
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
    ci.min_world = 1
    ci.max_world = typemax(UInt)
    return ci
end

const STORE = Dict{Symbol,Core.CodeInfo}(:shared => build_src())
sharedgen(world::UInt, source, argtypes...) = STORE[:shared]   # returns the stored object itself
@eval function shared(x)
    $(Expr(:meta, :generated, sharedgen))
    $(Expr(:meta, :generated_only))
end

before = STORE[:shared].ssavaluetypes
println("ssavaluetypes before first call: ", repr(before))
println("shared(1)   = ", shared(1))
after = STORE[:shared].ssavaluetypes
println("ssavaluetypes after first call:  ", repr(after))
r = try shared(1.0) catch e; sprint(showerror, e) end
println("shared(1.0) = ", r, "   (look for 'Internal error: during type inference of shared(Float64)' above)")
if after isa Int
    println("PASS: the generator's CodeInfo was not mutated")
else
    println("FAIL: the generator's CodeInfo was mutated in place (ssavaluetypes is now a $(typeof(after)))")
end
