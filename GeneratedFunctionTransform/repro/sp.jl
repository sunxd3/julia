const __custom_compiler_active = true
using Base.Compiler: Compiler, CodeInstance, CodeInfo
include(normpath(Sys.BINDIR, "..", "..", "Compiler", "test", "newinterp.jl"))  # run from a source build (usr/bin/julia)
using Base.Experimental: @MethodTable, @overlay
@MethodTable MT
leaf(x::Int) = x + 1
@overlay MT leaf(x::Int) = x - 1
@newinterp EI true
Compiler.method_table(i::EI) = Compiler.OverlayMethodTable(Compiler.get_inference_world(i), MT)
const CG = IdDict{CodeInstance,CodeInfo}()
Compiler.codegen_cache(::EI) = CG
sp_target(x::Vector{T}) where {T} = leaf(length(x)) * 10
const mi = Base.method_instance(sp_target, (Vector,))
const fci = Compiler.typeinf_ext_toplevel(EI(), mi, Compiler.SOURCE_MODE_ABI)
println("sparams=", mi.sparam_vals, " invoke=", fci.invoke)
sp_caller(x::Vector) = invoke(sp_target, fci, x)
ct = only(Base.code_typed(sp_caller, (Vector{Int},)))[1]
foreach(s -> Meta.isexpr(s, :invoke) && println("typed IR: invoke ", typeof(s.args[1]), " owner=", s.args[1].owner), ct.code)
using InteractiveUtils; io = IOBuffer(); InteractiveUtils.code_llvm(io, sp_caller, (Vector{Int},); raw=true); llvm = String(take!(io))
println("LLVM calls jl_invoke_codeinst: ", occursin("jl_invoke_codeinst", llvm), "  jl_invoke: ", occursin("@ijl_invoke(", llvm) || occursin("@jl_invoke(", llvm))
try; println("sp_caller = ", sp_caller([1,2])); catch e; println("threw: ", sprint(showerror, e)); end
println("native = ", sp_target([1,2]))
