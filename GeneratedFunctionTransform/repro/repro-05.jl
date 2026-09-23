# repro-05.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-05.jl
#   [1] precompiling ForeignInvoke in a child process ...
#       exit=0
#   [2] loading the image in a fresh child and calling caller(2) ...
#       fci.owner=ForeignInvoke.FIInterp fci.invoke==C_NULL: true typeof(fci.inferred)=String
#       direct invoke(target, fci, 2) = Failed to invoke or compile external codeinst
#       caller(2) = 31
#       fci.invoke==C_NULL after caller(2): true
#       exit=0
#   FAIL: precompiled caller(2) == 31 (native body was emitted for a foreign-owned invoke target)
#   [3] in-process: Compiler.typeinf_ext_toplevel(methods, worlds, TRIM_NO, external_linkage=false)
#       emitted (name, owner): [(:caller2, nothing), (:target, nothing)]
#       caller2 IR invokes: owner=Main.ForeignInvokeInProc.FIInterp is fci=true
#       fci in emitted set? false   (false + a native `target` above = native re-inference)
#
# $ <fixes-build>/julia repro-05.jl   (NOT fixed there)
#   [1] precompiling ForeignInvoke in a child process ...
#       exit=0
#   [2] loading the image in a fresh child and calling caller(2) ...
#       fci.owner=ForeignInvoke.FIInterp fci.invoke==C_NULL: true typeof(fci.inferred)=String
#       direct invoke(target, fci, 2) = Failed to invoke or compile external codeinst
#       caller(2) = 31
#       fci.invoke==C_NULL after caller(2): true
#       exit=0
#   FAIL: precompiled caller(2) == 31 (native body was emitted for a foreign-owned invoke target)
#   [3] in-process: Compiler.typeinf_ext_toplevel(methods, worlds, TRIM_NO, external_linkage=false)
#       emitted (name, owner): [(:caller2, nothing), (:target, nothing)]
#       caller2 IR invokes: owner=Main.ForeignInvokeInProc.FIInterp is fci=true
#       fci in emitted set? false   (false + a native `target` above = native re-inference)
#
# Bug 5: `compile!` (Compiler/src/typeinfer.jl) looks an `:invoke` target up in the *native*
# interpreter's codegen cache and, on a miss, re-infers the MethodInstance natively with
# `typeinf_ext(interp, mi, SOURCE_MODE_GET_SOURCE)`. For a foreign-owned CodeInstance
# (one produced by another AbstractInterpreter, here with an overlay method table) the package
# image therefore contains the native body, and the precompiled caller returns the native result.
#
# Usage: julia repro-05.jl        (writes a temp package + depot, precompiles, reloads)
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
println("[1] precompiling ForeignInvoke in a child process ...")
code, out = child("using ForeignInvoke", pkgdir, depot)
println("    exit=", code, isempty(strip(out)) ? "" : "\n" * join("    " .* split(strip(out), '\n'), '\n'))
code == 0 || (println("FAIL: precompilation failed"); exit(1))

println("[2] loading the image in a fresh child and calling caller(2) ...")
probe = """
using ForeignInvoke; const M = ForeignInvoke
println("    fci.owner=", M.fci.owner, " fci.invoke==C_NULL: ", M.fci.invoke == C_NULL, " typeof(fci.inferred)=", typeof(M.fci.inferred))
println("    direct invoke(target, fci, 2) = ", try invoke(M.target, M.fci, 2) catch e; sprint(showerror, e) end)
println("    caller(2) = ", M.caller(2))
println("    fci.invoke==C_NULL after caller(2): ", M.fci.invoke == C_NULL)
"""
code, out = child(probe, pkgdir, depot)
print(out); println("    exit=", code)
m = match(r"caller\(2\) = (\d+)", out)
r = m === nothing ? nothing : parse(Int, m.captures[1])
if r == 11
    println("PASS: precompiled caller(2) == 11 (foreign body)")
elseif r == 31
    println("FAIL: precompiled caller(2) == 31 (native body was emitted for a foreign-owned invoke target)")
else
    println("FAIL: could not determine caller(2)")
end

# In-process view of the same driver: which CodeInstances does the image builder emit?
println("[3] in-process: Compiler.typeinf_ext_toplevel(methods, worlds, TRIM_NO, external_linkage=false)")
const CC = Base.Compiler
include_string(Main, replace(read(joinpath(pkgdir, "ForeignInvoke.jl"), String), "module ForeignInvoke" => "module ForeignInvokeInProc"))
M = ForeignInvokeInProc
@eval M caller2(x::Int) = invoke(target, fci, x) + 1      # fresh: `caller` itself is already compiled
cmi = Base.method_instance(M.caller2, (Int,))
res = CC.typeinf_ext_toplevel(Any[cmi], UInt[Base.get_world_counter()], 0x0, false)
cis = res isa Union{Tuple,Core.SimpleVector} ? res[1] : res   # master returns svec(codeinfos, cis)
emitted = [(Base.get_ci_mi(c).def.name, c.owner) for c in cis if c isa Core.CodeInstance]
println("    emitted (name, owner): ", emitted)
for i in eachindex(cis)
    c = cis[i]
    c isa Core.CodeInstance && Base.get_ci_mi(c).def.name === :caller2 || continue
    for st in cis[i+1].code
        Meta.isexpr(st, :invoke) && println("    caller2 IR invokes: owner=", st.args[1].owner, " is fci=", st.args[1] === M.fci)
    end
end
println("    fci in emitted set? ", any(c -> c === M.fci, cis), "   (false + a native `target` above = native re-inference)")
