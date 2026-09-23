# repro-08.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-08.jl
#   [a] in-process `compile!` with a foreign ephemeral-cache CodeInstance that has source:
#       fci.owner=EphInterp onchain=false ci_has_source(native, fci)=true
#       compile! ok -> PASS [a]
#   [b] JIT path: compiling a caller that `invoke`s an uncompiled foreign ephemeral-cache CodeInstance:
#       eph_ci.owner=EphInterp onchain=false invoke=Ptr{Nothing}(0x0000000000000000)
#       typeinf_ext_toplevel(native, eph_caller mi, SOURCE_MODE_ABI) ok -> PASS [b]
#       eph_caller(2) = 30   (10 foreign, 30 native; an 'Internal error' above means the assertion fired inside jl_type_infer)
#   [c] package image: precompiling a module whose `caller` invokes such a CodeInstance:
#       caller(2) = 31
#   PASS [c]: precompile + load succeeded
#
# $ <fixes-build>/julia repro-08.jl   (NOT fixed there)
#   Internal error: during type inference of
#   eph_caller(Int64)
#   Encountered unexpected error in runtime:
#   MethodError(f=Base.string, args=(Expr(:call, :var"===", Expr(:., :ci, :(:owner)), Expr(:., :cache, :(:owner))),), world=0x0000000000002ecb)
#   jl_method_error_bare at src/gf.c:3492:9
#   jl_method_error at src/gf.c:3510:5
#   jl_f_throw_methoderror at src/builtins.c:725:5 [inlined]
#   jl_f_throw_methoderror at src/builtins.c:721:1
#   __assert_tostring at ./error.jl:250:0 (pc: 2)
#   unknown function (ip: 0x75963ab7c752) at (unknown file)
#   _assert_tostring at ./error.jl:249:0 (pc: 2)
#   setindex! at ./../usr/share/julia/Compiler/src/cicache.jl:45:0 (pc: 13)
#     [... backtrace truncated ...]
#   top-level scope at work/body-08.jl:176:0 (pc: 77)
#   ijl_eval_thunk at src/toplevel.c:773:18
#   jl_toplevel_eval_flex at src/toplevel.c:717:26
#   jl_eval_toplevel_stmts at src/toplevel.c:602:15
#   jl_toplevel_eval_flex at src/toplevel.c:689:27
#   ijl_toplevel_eval at src/toplevel.c:787:12
#   ijl_toplevel_eval_in at src/toplevel.c:832:13
#   eval at ./boot.jl:618:0 (pc: 1)
#   include_string at ./loading.jl:3324:0 (pc: 140)
#     [... backtrace truncated ...]
#   [a] in-process `compile!` with a foreign ephemeral-cache CodeInstance that has source:
#       fci.owner=EphInterp onchain=false ci_has_source(native, fci)=true
#       compile! threw: AssertionError: ci.owner === cache.owner -> FAIL [a]
#           setindex!(cache::Compiler.InternalCodeCache, ci::CodeInstance, mi::MethodInstance) at cicache.jl:45
#           compile!(codeinfos::Vector{Any}, workqueue::Compiler.CompilationQueue; invokelatest_queue::Nothing, enqueue_unprepared_invokes::Bool, external_linkage::Bool) at typeinfer.jl:2157
#   [b] JIT path: compiling a caller that `invoke`s an uncompiled foreign ephemeral-cache CodeInstance:
#       eph_ci.owner=EphInterp onchain=false invoke=Ptr{Nothing}(0x0000000000000000)
#       threw: AssertionError: ci.owner === cache.owner -> FAIL [b]
#           setindex!(cache::Compiler.InternalCodeCache, ci::CodeInstance, mi::MethodInstance) at cicache.jl:45
#           add_codeinsts_to_jit!(interp::Compiler.NativeInterpreter, ci::CodeInstance, source_mode::UInt8) at typeinfer.jl:2056
#           typeinf_ext_toplevel(interp::Compiler.NativeInterpreter, mi::MethodInstance, source_mode::UInt8) at typeinfer.jl:2077
#       eph_caller(2) = 30   (10 foreign, 30 native; an 'Internal error' above means the assertion fired inside jl_type_infer)
#   [c] package image: precompiling a module whose `caller` invokes such a CodeInstance:
#       fatal: error thrown and no exception handler available.
#       MethodError(f=Base.string, args=(Expr(:call, :var"===", Expr(:., :ci, :(:owner)), Expr(:., :cache, :(:owner))),), world=0x0000000000002ecb)
#       setindex! at ./../usr/share/julia/Compiler/src/cicache.jl:45:0 (pc: 13)
#       #compile!#223 at ./../usr/share/julia/Compiler/src/typeinfer.jl:2157:0 (pc: 577)
#       compile! at ./../usr/share/julia/Compiler/src/typeinfer.jl:2088:0 [inlined]
#       Failed to precompile ForeignInvokeEph [top-level] to "/tmp/jl_3waAZT/compiled/v1.14/jl_F7lrsC" (ProcessExited(1)).
#   FAIL [c]: precompilation died with the wrong-owner cache insert assertion (exit=1)
#
# Bug 8: `compile!` and `add_codeinsts_to_jit!` (Compiler/src/typeinfer.jl) insert an `:invoke`
# target into the *native* code cache with `code_cache(interp)[mi] = callee` when it is not on the
# MethodInstance's cache chain. For a foreign-owned CodeInstance from an interpreter with an
# ephemeral (IdDict) cache this trips `@assert ci.owner === cache.owner` in
# `InternalCodeCache` `setindex!` (Compiler/src/cicache.jl) -- an internal error on the JIT path
# and a hard failure when building a package image.
#
# Usage: julia repro-08.jl
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

target(2)
const mi = Base.method_instance(target, (Int,))

println("[a] in-process `compile!` with a foreign ephemeral-cache CodeInstance that has source:")
let fci = CC.typeinf_ext(EphInterp(), mi, CC.SOURCE_MODE_GET_SOURCE)::CodeInstance
    native = CC.NativeInterpreter(Base.get_world_counter())
    println("    fci.owner=", fci.owner, " onchain=", onchain(mi, fci), " ci_has_source(native, fci)=", CC.ci_has_source(native, fci))
    q = CC.CompilationQueue(; interp = native); push!(q, fci)
    try
        CC.compile!(Any[], q; external_linkage=false)
        println("    compile! ok -> PASS [a]")
    catch e
        println("    compile! threw: ", showerr(e), " -> FAIL [a]")
        st = stacktrace(catch_backtrace())
        foreach(f -> println("        ", f), first(st, 2))
    end
end

println("[b] JIT path: compiling a caller that `invoke`s an uncompiled foreign ephemeral-cache CodeInstance:")
const eph_ci = CC.typeinf_ext_toplevel(EphInterp(), mi, CC.SOURCE_MODE_NOT_REQUIRED)::CodeInstance
eph_caller(x::Int) = invoke(target, eph_ci, x)
let cmi = Base.method_instance(eph_caller, (Int,))
    println("    eph_ci.owner=", eph_ci.owner, " onchain=", onchain(mi, eph_ci), " invoke=", eph_ci.invoke)
    try
        CC.typeinf_ext_toplevel(CC.NativeInterpreter(Base.get_world_counter()), cmi, CC.SOURCE_MODE_ABI)
        println("    typeinf_ext_toplevel(native, eph_caller mi, SOURCE_MODE_ABI) ok -> PASS [b]")
    catch e
        println("    threw: ", showerr(e), " -> FAIL [b]")
        st = stacktrace(catch_backtrace())
        foreach(f -> println("        ", f), first(filter(f -> occursin("typeinfer", string(f.file)) || occursin("cicache", string(f.file)), st), 3))
    end
    println("    eph_caller(2) = ", try eph_caller(2) catch e; "threw: " * showerr(e) end, "   (10 foreign, 30 native; an 'Internal error' above means the assertion fired inside jl_type_infer)")
end

println("[c] package image: precompiling a module whose `caller` invokes such a CodeInstance:")
const pkgdir = mktempdir(); const depot = mktempdir()
write_pkg(pkgdir, "ForeignInvokeEph"; ephemeral=true, compiled=false)   # fci: inferred, source kept, not compiled
code, out = child("using ForeignInvokeEph; println(\"    caller(2) = \", ForeignInvokeEph.caller(2))", pkgdir, depot)
lines = filter(!isempty, split(strip(out), '\n'))
keep = filter(l -> occursin(r"fatal|MethodError|AssertionError|cicache|compile!|add_codeinsts|caller\(2\)|Failed to precompile", l), lines)
foreach(l -> println("    ", first(l, 200)), first(keep, 8))
if code == 0
    println("PASS [c]: precompile + load succeeded")
elseif occursin("ci.owner === cache.owner", out) || occursin("cicache.jl:45", out)
    println("FAIL [c]: precompilation died with the wrong-owner cache insert assertion (exit=$code)")
else
    println("FAIL [c]: precompilation failed for another reason (exit=$code)")
end
