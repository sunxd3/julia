# repro-06.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-06.jl
#   [1] precompiling ...
#   [2] loading and calling caller(2) ...
#       fci.invoke==C_NULL before: true
#       caller(2) = 31
#       fci.invoke==C_NULL after:  true
#   CONSISTENT WITH BUG: caller(2) == 31 while nothing was ever invoked through fci -> the image call site dispatched by MethodInstance
#   NOTE: this cannot separate the link-time fallback from bug 5 (native re-inference in `compile!`); the issue text is written from code reading.
#
# $ <fixes-build>/julia repro-06.jl   (NOT fixed there)
#   [1] precompiling ...
#   [2] loading and calling caller(2) ...
#       fci.invoke==C_NULL before: true
#       caller(2) = 31
#       fci.invoke==C_NULL after:  true
#   CONSISTENT WITH BUG: caller(2) == 31 while nothing was ever invoked through fci -> the image call site dispatched by MethodInstance
#   NOTE: this cannot separate the link-time fallback from bug 5 (native re-inference in `compile!`); the issue text is written from code reading.
#
# Bug 6 (from code reading; NO direct reproducer): `aot_link_output` (src/aotcompile.cpp) resolves
# each `:invoke` call target by (a) an equivalent CodeInstance compiled in the same output,
# (b) an equivalent one in the global cache, (c) a `pkg_plt` thunk for image instances, and
# otherwise falls back to `emit_tojlinvoke(ci, "")`, whose empty-name branch (src/codegen.cpp)
# drops the CodeInstance and emits `jl_invoke(args, nargs, mi)` -- dispatch by MethodInstance.
# (a) and (b) compare `owner`, so a foreign-owned target that was not emitted always reaches (d).
#
# This script only shows the *symptoms consistent with* that fallback, riding on the bug-5
# round trip: the caller's IR still `:invoke`s the foreign CodeInstance, that CodeInstance is not
# in the emitted set, and after the image is loaded `caller(2)` returns the native result while
# `fci.invoke` stays C_NULL (nothing ever called through `fci`).
#
# Usage: julia repro-06.jl
# ---- self-contained package-image round trip ----
# Writes a one-file package into a temp directory, precompiles it in a child julia with a fresh
# depot, then loads it in a second child. `ephemeral` selects the interpreter's cache flavour.
function write_pkg(dir, name; ephemeral::Bool, compiled::Bool = true)
    interp = ephemeral ? """
    struct EphCache; dict::IdDict{MethodInstance,CodeInstance}; end
    struct FIInterp <: CC.AbstractInterpreter
        world::UInt; inf_params::CC.InferenceParams; opt_params::CC.OptimizationParams
        inf_cache::_InfCache; global_cache::EphCache
    end
    FIInterp(; world::UInt = Base.get_world_counter()) =
        FIInterp(world, CC.InferenceParams(), CC.OptimizationParams(), _InfCache(), EphCache(IdDict{MethodInstance,CodeInstance}()))
    CC.code_cache(i::FIInterp) = i.global_cache
    CC.get(c::EphCache, mi::MethodInstance, default) = get(c.dict, mi, default)
    CC.getindex(c::EphCache, mi::MethodInstance) = getindex(c.dict, mi)
    CC.haskey(c::EphCache, mi::MethodInstance) = haskey(c.dict, mi)
    CC.setindex!(c::EphCache, ci::CodeInstance, mi::MethodInstance) = setindex!(c.dict, ci, mi)
    if isdefined(CC, :WorldView)
        CC.get(wv::CC.WorldView{EphCache}, mi::MethodInstance, default) = get(wv.cache.dict, mi, default)
        CC.getindex(wv::CC.WorldView{EphCache}, mi::MethodInstance) = getindex(wv.cache.dict, mi)
        CC.haskey(wv::CC.WorldView{EphCache}, mi::MethodInstance) = haskey(wv.cache.dict, mi)
        CC.setindex!(wv::CC.WorldView{EphCache}, ci::CodeInstance, mi::MethodInstance) = setindex!(wv.cache.dict, ci, mi)
    end
    """ : """
    struct FIInterp <: CC.AbstractInterpreter
        world::UInt; inf_params::CC.InferenceParams; opt_params::CC.OptimizationParams; inf_cache::_InfCache
    end
    FIInterp(; world::UInt = Base.get_world_counter()) =
        FIInterp(world, CC.InferenceParams(), CC.OptimizationParams(), _InfCache())
    """
    src = """
    module $name
    const CC = Base.Compiler
    using Core: MethodInstance, CodeInstance, CodeInfo
    const _InfCache = isdefined(CC, :InferenceCache) ? CC.InferenceCache : Vector{CC.InferenceResult}
    $interp
    CC.InferenceParams(i::FIInterp) = i.inf_params
    CC.OptimizationParams(i::FIInterp) = i.opt_params
    CC.get_inference_world(i::FIInterp) = i.world
    CC.get_inference_cache(i::FIInterp) = i.inf_cache
    CC.cache_owner(::FIInterp) = FIInterp
    Base.Experimental.@MethodTable MT
    CC.method_table(i::FIInterp) = CC.OverlayMethodTable(i.world, MT)
    const CODEGEN = IdDict{CodeInstance,CodeInfo}()
    CC.codegen_cache(::FIInterp) = CODEGEN

    leaf(x::Int) = x + 1
    Base.Experimental.@overlay MT leaf(x::Int) = x - 1
    target(x::Int) = leaf(x) * 10                 # native 30, under the overlay 10 (for x = 2)
    const mi = Base.method_instance(target, (Int,))
    const fci = $(compiled ? "CC.typeinf_ext_toplevel(FIInterp(), mi, CC.SOURCE_MODE_ABI)" : "CC.typeinf_ext(FIInterp(), mi, CC.SOURCE_MODE_GET_SOURCE)")::CodeInstance
    caller(x::Int) = invoke(target, fci, x) + 1   # 11 with the foreign body, 31 with the native one
    precompile(caller, (Int,))
    end
    """
    write(joinpath(dir, "$name.jl"), src)
end

function child(cmdstr, pkgdir, depot; timeout = 600.0)
    cmd = setenv(`$(Base.julia_cmd()) --startup-file=no -e $cmdstr`,
                 "JULIA_LOAD_PATH" => pkgdir, "JULIA_DEPOT_PATH" => depot, "JULIA_PKG_PRECOMPILE_AUTO" => "0")
    out = IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout=out, stderr=out); wait=false)
    finished = timedwait(() -> process_exited(p), timeout) === :ok
    finished || kill(p, Base.SIGKILL)
    wait(p)
    return (finished ? p.exitcode : -1, String(take!(out)))
end
# ---- end helpers ----

const pkgdir = mktempdir(); const depot = mktempdir()
write_pkg(pkgdir, "ForeignInvoke"; ephemeral=false)
println("[1] precompiling ...")
code, out = child("using ForeignInvoke", pkgdir, depot)
code == 0 || (println("FAIL: precompilation failed\n", out); exit(1))
println("[2] loading and calling caller(2) ...")
probe = """
using ForeignInvoke; const M = ForeignInvoke
println("    fci.invoke==C_NULL before: ", M.fci.invoke == C_NULL)
println("    caller(2) = ", M.caller(2))
println("    fci.invoke==C_NULL after:  ", M.fci.invoke == C_NULL)
"""
code, out = child(probe, pkgdir, depot)
print(out)
r = match(r"caller\(2\) = (\d+)", out); after = match(r"after:  (true|false)", out)
if r !== nothing && parse(Int, r.captures[1]) == 31 && after !== nothing && after.captures[1] == "true"
    println("CONSISTENT WITH BUG: caller(2) == 31 while nothing was ever invoked through fci -> the image call site dispatched by MethodInstance")
elseif r !== nothing && parse(Int, r.captures[1]) == 11
    println("PASS: caller(2) == 11")
else
    println("INCONCLUSIVE: see output above")
end
println("NOTE: this cannot separate the link-time fallback from bug 5 (native re-inference in `compile!`); the issue text is written from code reading.")
