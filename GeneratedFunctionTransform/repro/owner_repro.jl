# Independent reproducer: one-compiler-per-MethodInstance assumptions, JIT and driver paths.
const __custom_compiler_active = true   # keep setup_Compiler.jl from @activate-ing stdlib Compiler
using Base.Compiler: Compiler
include(normpath(Sys.BINDIR, "..", "..", "Compiler", "test", "newinterp.jl"))  # run from a source build (usr/bin/julia)

Base.Experimental.@MethodTable MT
leaf(x::Int) = x + 1
Base.Experimental.@overlay MT leaf(x::Int) = x - 1
target(x::Int) = leaf(x) * 10
@assert target(2) == 30            # native cache populated first
const mi = Base.method_instance(target, (Int,))
const world = Base.get_world_counter()

# ---- Ephemeral (off-chain) foreign cache ----
@newinterp EphInterp true
Compiler.method_table(interp::EphInterp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), MT)
const EPH_CODEGEN = IdDict{Core.CodeInstance,Core.CodeInfo}()
Compiler.codegen_cache(::EphInterp) = EPH_CODEGEN

# uncompiled foreign CI (inference only), as a tool that only wants inference would produce
const eph_ci = Compiler.typeinf_ext_toplevel(EphInterp(; world), mi, Compiler.SOURCE_MODE_NOT_REQUIRED)
println("[eph] owner=", eph_ci.owner, " onchain=", ccall(:jl_mi_cache_has_ci, Cint, (Any,Any), mi, eph_ci),
        " invoke=", eph_ci.invoke, " inferred isa CodeInfo=", eph_ci.inferred isa Core.CodeInfo)

# A: JIT path (add_codeinsts_to_jit! under the native interpreter)
eph_caller(x::Int) = invoke(target, eph_ci, x)
println("[A] JIT path with ephemeral foreign invoke target:")
try
    r = eph_caller(2)
    println("[A] eph_caller(2) = ", r, "  (10 = foreign body, 30 = native swap)")
catch e
    println("[A] threw: ", sprint(showerror, e)[1:min(end,300)])
end
println("[A] eph_ci.invoke now = ", eph_ci.invoke)

# B: package-image driver (compile!) with the same CI, fresh method so nothing is cached
eph_caller2(x::Int) = invoke(target, eph_ci, x)
let cmi = Base.method_instance(eph_caller2, (Int,))
    println("[B] driver path (typeinf_ext_toplevel(methods, worlds, TRIM_NO, false)):")
    try
        res = Compiler.typeinf_ext_toplevel(Any[cmi], UInt[Base.get_world_counter()], 0x0, false)
        codeinfos = res[1]
        cis = [c for c in codeinfos if c isa Core.CodeInstance]
        println("[B] emitted CIs: ", [(Base.get_ci_mi(c).def.name, c.owner) for c in cis])
    catch e
        println("[B] threw: ", sprint(showerror, e)[1:min(end,400)])
    end
end

# ---- On-chain foreign owner (InternalCodeCache), source discarded ----
@newinterp OwnedInterp
Compiler.method_table(interp::OwnedInterp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), MT)
const OWN_CODEGEN = IdDict{Core.CodeInstance,Core.CodeInfo}()
Compiler.codegen_cache(::OwnedInterp) = OWN_CODEGEN

const own_ci = Compiler.typeinf_ext_toplevel(OwnedInterp(; world), mi, Compiler.SOURCE_MODE_NOT_REQUIRED)
println("[own] owner=", own_ci.owner, " onchain=", ccall(:jl_mi_cache_has_ci, Cint, (Any,Any), mi, own_ci),
        " invoke=", own_ci.invoke, " inferred isa CodeInfo=", own_ci.inferred isa Core.CodeInfo)
# simulate "activation cleared inferred" / image discarded IR for a CI the native side cannot see source for
@atomic own_ci.inferred = nothing
empty!(OWN_CODEGEN)
println("[own] inferred cleared -> ", own_ci.inferred)

# C: JIT path: ci_get_source returns nothing for the foreign target
own_caller(x::Int) = invoke(target, own_ci, x)
println("[C] JIT path, foreign target with no retrievable source:")
try
    r = own_caller(2)
    println("[C] own_caller(2) = ", r, "  (10 = foreign body, 30 = native swap)")
catch e
    println("[C] threw: ", sprint(showerror, e)[1:min(end,300)])
end
println("[C] own_ci.invoke now = ", own_ci.invoke)
println("[C] direct invoke(target, own_ci, 2): ")
try
    println("    -> ", invoke(target, own_ci, 2))
catch e
    println("    threw: ", sprint(showerror, e)[1:min(end,200)])
end

# D: driver path, same CI: does compile! fall through to native re-inference?
own_caller2(x::Int) = invoke(target, own_ci, x)
let cmi = Base.method_instance(own_caller2, (Int,))
    println("[D] driver path with source-less foreign target:")
    try
        res = Compiler.typeinf_ext_toplevel(Any[cmi], UInt[Base.get_world_counter()], 0x0, false)
        codeinfos = res[1]
        pairs = [(Base.get_ci_mi(codeinfos[i]).def.name, codeinfos[i].owner, codeinfos[i] === own_ci) for i in 1:2:length(codeinfos) if codeinfos[i] isa Core.CodeInstance]
        println("[D] emitted (name, owner, is_own_ci): ", pairs)
        # does the caller's emitted IR still :invoke own_ci?
        for i in 1:2:length(codeinfos)
            ci = codeinfos[i]; src = codeinfos[i+1]
            ci isa Core.CodeInstance && Base.get_ci_mi(ci).def.name === :own_caller2 || continue
            for st in src.code
                Meta.isexpr(st, :invoke) && println("[D] own_caller2 IR invokes: owner=", st.args[1].owner, " is_own_ci=", st.args[1] === own_ci)
            end
        end
    catch e
        println("[D] threw: ", sprint(showerror, e)[1:min(end,400)])
    end
end
