module RefOnly
import Base.Compiler: Compiler
include(normpath(Sys.BINDIR, "..", "..", "Compiler", "test", "newinterp.jl"))  # run from a source build (usr/bin/julia)
@newinterp FI false
Base.Experimental.@MethodTable MT
Compiler.method_table(interp::FI) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), MT)
const CODEGEN = IdDict{Core.CodeInstance,Core.CodeInfo}()
Compiler.codegen_cache(::FI) = CODEGEN
leaf(x::Int) = x + 1
Base.Experimental.@overlay MT leaf(x::Int) = x - 1
@noinline helper(x) = sum(sin(x+i) for i in 1:10)
function target(x::Int)
    s = 0.0
    for i in 1:100; s += helper(x*i)^2 + cos(s); end
    io = IOBuffer(); print(io, s > 3 ? string(s) : repr(s));
    return leaf(x) * 10
end
const fci = Compiler.typeinf_ext_toplevel(FI(), Base.method_instance(target, (Int,)), Compiler.SOURCE_MODE_NOT_REQUIRED)
caller(x::Int) = invoke(target, fci, x) + 1
# caller never precompiled
end
