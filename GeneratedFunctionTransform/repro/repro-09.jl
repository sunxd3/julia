# repro-09.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-09.jl
#   native target(2) = 30
#   own_ci: owner=OwnedInterp onchain=true inferred=nothing invoke=Ptr{Nothing}(0x0000000000000000)
#   optimized own_caller IR: Any[:(Base.add_int(_2, 1)), :(Base.mul_int(%1, 10)), :(return %2)]
#   compiled own_caller(2) = 30   (10 = foreign body, 30 = native body)
#   own_ci.invoke after the call = Ptr{Nothing}(0x0000000000000000)   (C_NULL: the caller never went through own_ci)
#   direct invoke(target, own_ci, 2) = threw: Failed to invoke or compile external codeinst
#   FAIL: compiled caller ran the native body for a foreign CodeInstance the runtime refuses to invoke
#
# $ <fixes-build>/julia repro-09.jl   (NOT fixed there)
#   native target(2) = 30
#   own_ci: owner=OwnedInterp onchain=true inferred=nothing invoke=Ptr{Nothing}(0x0000000000000000)
#   optimized own_caller IR: Any[:($(Expr(:invoke, CodeInstance for MethodInstance for target(::Int64) (foreign), BindingPartition(for Main.target: 43045:∞ - constant binding), Core.Argument(2)))), :(return %1)]
#   compiled own_caller(2) = 30   (10 = foreign body, 30 = native body)
#   own_ci.invoke after the call = Ptr{Nothing}(0x0000000000000000)   (C_NULL: the caller never went through own_ci)
#   direct invoke(target, own_ci, 2) = threw: Failed to invoke or compile external codeinst
#   FAIL: compiled caller ran the native body for a foreign CodeInstance the runtime refuses to invoke
#
# Bug 9: `add_codeinsts_to_jit!` (Compiler/src/typeinfer.jl) finds no source for a foreign-owned
# `:invoke` target and re-infers the MethodInstance *natively*; the JIT then resolves the
# `:invoke ci` through `emit_tojlinvoke(ci, "")` (src/jitlayers.cpp -> src/codegen.cpp), which
# dispatches by MethodInstance. The compiled caller runs the native body while a direct
# `invoke(f, ci, x)` on the very same CodeInstance throws.
#
# Usage: julia repro-09.jl
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

println("native target(2) = ", target(2))
const mi = Base.method_instance(target, (Int,))
const own_ci = CC.typeinf_ext_toplevel(OwnedInterp(), mi, CC.SOURCE_MODE_NOT_REQUIRED)::CodeInstance
@atomic own_ci.inferred = nothing      # source no longer retrievable by the native side
empty!(OWN_CODEGEN)
println("own_ci: owner=", own_ci.owner, " onchain=", onchain(mi, own_ci), " inferred=", own_ci.inferred, " invoke=", own_ci.invoke)

own_caller(x::Int) = invoke(target, own_ci, x)
src = only(code_typed(own_caller, (Int,)))[1]
println("optimized own_caller IR: ", src.code)
r = try own_caller(2) catch e; "threw: " * showerr(e) end
println("compiled own_caller(2) = ", r, "   (10 = foreign body, 30 = native body)")
println("own_ci.invoke after the call = ", own_ci.invoke, "   (C_NULL: the caller never went through own_ci)")
d = try invoke(target, own_ci, 2) catch e; "threw: " * showerr(e) end
println("direct invoke(target, own_ci, 2) = ", d)
if r == 30
    println("FAIL: compiled caller ran the native body for a foreign CodeInstance the runtime refuses to invoke")
elseif r == 10
    println("PASS: foreign body ran")
else
    println("PASS (loud): caller failed the same way the direct invoke does")
end
