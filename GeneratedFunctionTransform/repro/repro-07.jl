# repro-07.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-07.jl
#   own_ci.owner = OwnedInterp, invoke ptr = Ptr{Nothing}(0x0000000000000000)
#   inferred exception type of own_caller(::Int): Union{}
#   inferred effects of own_caller(::Int):        (+c,+e,+n,+t,+s,!m,+u,!o,+r)
#   optimized drop(::Int) keeps the invoke? false   code = Any[:(return 1)]
#   runtime: invoke(target, own_ci, 2) -> threw: Failed to invoke or compile external codeinst
#   runtime: drop(2) -> 1
#   FAIL: inference says invoke(target, own_ci, x) cannot throw, but the runtime throws
#
# $ <fixes-build>/julia repro-07.jl
#   own_ci.owner = OwnedInterp, invoke ptr = Ptr{Nothing}(0x0000000000000000)
#   inferred exception type of own_caller(::Int): ErrorException
#   inferred effects of own_caller(::Int):        (+c,+e,+re,!n,+t,+s,!m,+u,!o,+r)
#   optimized drop(::Int) keeps the invoke? true   code = Any[:($(Expr(:invoke, CodeInstance for MethodInstance for target(::Int64) (foreign), BindingPartition(for Main.target: 43045:∞ - constant binding), Core.Argument(2)))), :(retur
#   runtime: invoke(target, own_ci, 2) -> threw: Failed to invoke or compile external codeinst
#   runtime: drop(2) -> 1
#   PASS: inference accounts for the runtime error (ErrorException)
#
# Bug 7: `abstract_invoke` (Compiler/src/abstractinterpretation.jl) tests
# `method_or_ci.owner === Nothing` -- the *type* -- so the branch that adds `ErrorException`
# to the exception type of `invoke(f, ci, args...)` is dead. `jl_f_invoke` (src/builtins.c)
# throws "Failed to invoke or compile external codeinst" for a foreign-owned CodeInstance
# that has no code, so inference claims nothrow for a call that throws.
#
# Usage: julia repro-07.jl
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

target(2)
const mi = Base.method_instance(target, (Int,))
const own_ci = CC.typeinf_ext_toplevel(OwnedInterp(), mi, CC.SOURCE_MODE_NOT_REQUIRED)::CodeInstance
@atomic own_ci.inferred = nothing      # a foreign CI whose source is gone (e.g. dropped after an image load)
empty!(OWN_CODEGEN)
println("own_ci.owner = ", own_ci.owner, ", invoke ptr = ", own_ci.invoke)

own_caller(x::Int) = invoke(target, own_ci, x)
drop(x::Int) = (invoke(target, own_ci, x); 1)

exct = Base.infer_exception_type(own_caller, (Int,))
println("inferred exception type of own_caller(::Int): ", exct)
println("inferred effects of own_caller(::Int):        ", Base.infer_effects(own_caller, (Int,)))
src = only(code_typed(drop, (Int,)))[1]
keeps = any(s -> Meta.isexpr(s, :invoke) || (Meta.isexpr(s, :call) && s.args[1] === GlobalRef(Core, :invoke)), src.code)
println("optimized drop(::Int) keeps the invoke? ", keeps, "   code = ", src.code)
direct = try invoke(target, own_ci, 2); "returned" catch e; "threw: " * showerr(e) end
println("runtime: invoke(target, own_ci, 2) -> ", direct)
println("runtime: drop(2) -> ", try drop(2) catch e; "threw: " * showerr(e) end)
if exct === Union{}
    println("FAIL: inference says invoke(target, own_ci, x) cannot throw, but the runtime throws")
else
    println("PASS: inference accounts for the runtime error (", exct, ")")
end
