# repro-04.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-04.jl
#   native target(2) = 30   (populates the native cache)
#   foreign ci.owner = OwnedInterp, direct invoke(target, ci, 2) = 10   (want 10)
#   optimized wrapper(::Int):
#       Base.add_int(_2, 1)
#       Base.mul_int(%1, 10)
#       return %2
#   wrapper(2) = 30   (10 = foreign body, 30 = native body)
#   FAIL: compiled wrapper ran the native body; foreign ci kept as :invoke target in IR? false
#
# $ <fixes-build>/julia repro-04.jl
#   native target(2) = 30   (populates the native cache)
#   foreign ci.owner = OwnedInterp, direct invoke(target, ci, 2) = 10   (want 10)
#   optimized wrapper(::Int):
#       $(Expr(:invoke, CodeInstance for MethodInstance for target(::Int64) (foreign), BindingPartition(for Main.target: 43045:∞ - constant binding), Core.Argument(2)))
#       return %1
#   wrapper(2) = 10   (10 = foreign body, 30 = native body)
#   PASS: the foreign CodeInstance stayed the invoke target
#
# Bug 4: `compileable_specialization` (Compiler/src/ssair/inlining.jl) prefers the CodeInstance
# in the *native* code cache over the foreign-owned CodeInstance it was handed for an
# `invoke(f, ci, args...)` call. The transformed body is silently replaced by the native one.
#
# Usage: julia repro-04.jl
# ---- minimal foreign AbstractInterpreters (no packages; works on 1.12, 1.13 and master) ----
const CC = Base.Compiler
using Core: MethodInstance, CodeInstance, CodeInfo
const _InfCache = isdefined(CC, :InferenceCache) ? CC.InferenceCache : Vector{CC.InferenceResult}

Base.Experimental.@MethodTable MT
leaf(x::Int) = x + 1
Base.Experimental.@overlay MT leaf(x::Int) = x - 1
target(x::Int) = leaf(x) * 10          # native: 30 for x=2; under the overlay: 10

# (1) foreign owner whose CodeInstances live on the MethodInstance's cache chain
struct OwnedInterp <: CC.AbstractInterpreter
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::_InfCache
end
OwnedInterp(; world::UInt = Base.get_world_counter()) =
    OwnedInterp(world, CC.InferenceParams(), CC.OptimizationParams(), _InfCache())
CC.InferenceParams(i::OwnedInterp) = i.inf_params
CC.OptimizationParams(i::OwnedInterp) = i.opt_params
CC.get_inference_world(i::OwnedInterp) = i.world
CC.get_inference_cache(i::OwnedInterp) = i.inf_cache
CC.cache_owner(::OwnedInterp) = OwnedInterp
CC.method_table(i::OwnedInterp) = CC.OverlayMethodTable(i.world, MT)
const OWN_CODEGEN = IdDict{CodeInstance,CodeInfo}()
CC.codegen_cache(::OwnedInterp) = OWN_CODEGEN

# (2) foreign owner with an ephemeral IdDict cache (not on the MethodInstance chain),
#     exactly as `Compiler/test/newinterp.jl`'s `@newinterp X true` defines one
struct EphCache
    dict::IdDict{MethodInstance,CodeInstance}
end
struct EphInterp <: CC.AbstractInterpreter
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::_InfCache
    global_cache::EphCache
end
EphInterp(; world::UInt = Base.get_world_counter()) =
    EphInterp(world, CC.InferenceParams(), CC.OptimizationParams(), _InfCache(),
              EphCache(IdDict{MethodInstance,CodeInstance}()))
CC.InferenceParams(i::EphInterp) = i.inf_params
CC.OptimizationParams(i::EphInterp) = i.opt_params
CC.get_inference_world(i::EphInterp) = i.world
CC.get_inference_cache(i::EphInterp) = i.inf_cache
CC.cache_owner(::EphInterp) = EphInterp
CC.method_table(i::EphInterp) = CC.OverlayMethodTable(i.world, MT)
CC.code_cache(i::EphInterp) = i.global_cache
CC.get(c::EphCache, mi::MethodInstance, default) = get(c.dict, mi, default)
CC.getindex(c::EphCache, mi::MethodInstance) = getindex(c.dict, mi)
CC.haskey(c::EphCache, mi::MethodInstance) = haskey(c.dict, mi)
CC.setindex!(c::EphCache, ci::CodeInstance, mi::MethodInstance) = setindex!(c.dict, ci, mi)
if isdefined(CC, :WorldView)   # <= 1.13 wraps `code_cache` in a WorldView
    CC.get(wv::CC.WorldView{EphCache}, mi::MethodInstance, default) = get(wv.cache.dict, mi, default)
    CC.getindex(wv::CC.WorldView{EphCache}, mi::MethodInstance) = getindex(wv.cache.dict, mi)
    CC.haskey(wv::CC.WorldView{EphCache}, mi::MethodInstance) = haskey(wv.cache.dict, mi)
    CC.setindex!(wv::CC.WorldView{EphCache}, ci::CodeInstance, mi::MethodInstance) = setindex!(wv.cache.dict, ci, mi)
end
const EPH_CODEGEN = IdDict{CodeInstance,CodeInfo}()
CC.codegen_cache(::EphInterp) = EPH_CODEGEN

onchain(mi, ci) = ccall(:jl_mi_cache_has_ci, Cint, (Any, Any), mi, ci) != 0
showerr(e) = sprint(showerror, e)
# ---- end preamble ----

println("native target(2) = ", target(2), "   (populates the native cache)")
const mi = Base.method_instance(target, (Int,))
const ci = CC.typeinf_ext_toplevel(OwnedInterp(), mi, CC.SOURCE_MODE_ABI)::CodeInstance
println("foreign ci.owner = ", ci.owner, ", direct invoke(target, ci, 2) = ", invoke(target, ci, 2), "   (want 10)")

wrapper(x::Int) = invoke(target, ci, x)
src = only(code_typed(wrapper, (Int,); optimize=true))[1]
println("optimized wrapper(::Int):")
foreach(s -> println("    ", s), src.code)
keeps = count(s -> Meta.isexpr(s, :invoke) && s.args[1] === ci, src.code)
r = wrapper(2)
println("wrapper(2) = ", r, "   (10 = foreign body, 30 = native body)")
if r == 10 && keeps == 1
    println("PASS: the foreign CodeInstance stayed the invoke target")
elseif r == 10
    println("PASS (weak): result is the foreign one, but the IR does not `:invoke` the foreign ci")
else
    println("FAIL: compiled wrapper ran the native body; foreign ci kept as :invoke target in IR? ", keeps == 1)
end
