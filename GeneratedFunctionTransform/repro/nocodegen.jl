const __custom_compiler_active = true
using Base.Compiler: Compiler
include(normpath(Sys.BINDIR, "..", "..", "Compiler", "test", "newinterp.jl"))  # run from a source build (usr/bin/julia)
Base.Experimental.@MethodTable MT
leaf(x::Int) = x + 1
Base.Experimental.@overlay MT leaf(x::Int) = x - 1
target(x::Int) = leaf(x) * 10
target(2)
@newinterp NoCG
Compiler.method_table(i::NoCG) = Compiler.OverlayMethodTable(Compiler.get_inference_world(i), MT)
const mi = Base.method_instance(target, (Int,))
const fci = Compiler.typeinf_ext_toplevel(NoCG(), mi, Compiler.SOURCE_MODE_NOT_REQUIRED)
println("inferred: ", typeof(fci.inferred))
try; println("builtin: ", invoke(target, fci, 2)); catch e; println("builtin threw: ", sprint(showerror,e)); end
caller(x::Int) = invoke(target, fci, x)
println("compiled caller(2) = ", caller(2), " (10 foreign)")
