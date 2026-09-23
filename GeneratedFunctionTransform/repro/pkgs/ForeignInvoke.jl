module ForeignInvoke
const Compiler = Base.Compiler
# newinterp.jl unchanged except for dropping its setup_Compiler.jl include (which is
# incompatible with precompilation); Compiler is pinned to the sysimage one above.
let path = normpath(Sys.BINDIR, "..", "..", "Compiler", "test", "newinterp.jl")  # run from a source build (usr/bin/julia)
    src = replace(read(path, String), "include(\"setup_Compiler.jl\")" => "")
    isdefined(Compiler, :InferenceCache) || (src = replace(src, "\$Compiler.InferenceCache" => "Vector{\$Compiler.InferenceResult}"))
    include_string(@__MODULE__, src, path)
end
@newinterp FIInterp
Base.Experimental.@MethodTable MT
Compiler.method_table(interp::FIInterp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), MT)
const CODEGEN = IdDict{Core.CodeInstance,Core.CodeInfo}()
Compiler.codegen_cache(::FIInterp) = CODEGEN
leaf(x::Int) = x + 1
Base.Experimental.@overlay MT leaf(x::Int) = x - 1
target(x::Int) = leaf(x) * 10
const mi = Compiler.specialize_method(Base._which(Tuple{typeof(target),Int}))
const fci = Compiler.typeinf_ext_toplevel(FIInterp(), mi, Compiler.SOURCE_MODE_ABI)
caller(x::Int) = invoke(target, fci, x) + 1
precompile(caller, (Int,))
end
