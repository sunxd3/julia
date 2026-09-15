# This file is a part of Julia. License is MIT: https://julialang.org/license

# Implementation of `Core.GeneratedFunctionTransform`.
#
# A method whose generator is a `GeneratedFunctionTransform` has no source of its own.
# When the runtime asks for its body, the generator selects a call from the argument
# types (via `g.transform`), infers and compiles that call with the interpreter returned
# by `g.gen(world)`, and returns a stub that `invoke`s the resulting `CodeInstance`.
# That `CodeInstance` is recorded as a forward edge of the stub, so whatever invalidates
# the inner result also invalidates every caller of the generated method, and the
# runtime then simply re-runs this generator.

# Reassemble the signature of the specialization being generated from what the runtime
# hands to a generator: the static parameter values come first and are dropped, and the
# types of a trailing varargs arrive packed in a tuple. Returns the full signature and
# the one without the generated function itself.
function transform_signature(source::Method, argtypes::Tuple)
    nsparams = unionall_depth(source.sig)
    types = Any[argtypes[nsparams+1:end]...]
    if source.isva
        for t in pop!(types)::Tuple
            push!(types, t)
        end
    end
    return Tuple{types...}, Tuple{types[2:end]...}
end

# The `Compiler` module an interpreter belongs to, found through its `AbstractInterpreter`
# supertype: a `Compiler` loaded separately from the one in the system image has its own.
function interpreter_compiler(@nospecialize(interp))
    T = typeof(interp)
    while T !== Any
        if T.name.name === :AbstractInterpreter
            mod = T.name.module
            isdefined(mod, :generate_transformed_body) && return mod
        end
        T = supertype(T)
    end
    return nothing
end

# The runtime dispatches generators through `Core`, so this entry point belongs to the
# compiler baked into the system image; a separately loaded `Compiler` package must not
# overwrite it (and could not be reached by the runtime anyway).
#
# Like every generator, this runs in `source.primary_world` (the runtime pins the world
# for the duration of the callback): `transform` and `gen` are fixed by the definition
# of the generated method, and redefining them later affects only generated methods
# defined afterwards. Only the interpreter they produce works in the requesting `world`.
if !(isdefined(Base, :Compiler) && Compiler !== Base.Compiler)
function (g::Core.GeneratedFunctionTransform)(world::UInt, source::Method, @nospecialize(argtypes...))
    return generate_transformed_body(g, world, source, argtypes)
end
end

# The specializations whose body is being generated on the current task, innermost last.
# A transformed body may reach the generated method for another callee whose transformed
# body reaches the first (any recursive callee does this). Every level starts a fresh
# top-level inference that knows nothing of the one above, so the cycle detection inference
# applies within one frame graph never sees it, and the generator would recurse until the
# stack overflows. A request for a specialization that is already on this stack fails
# instead: `get_staged` treats a throwing generator as "no body", so that one call site is
# compiled as an `invoke` of the method instance with an unknown result, and at run time
# it finds the body finished by the outer level.
# Recursion inside a transformed body (a callee calling itself) never gets here; it is an
# ordinary inference cycle within the inner interpreter.
function generating_stack()
    tls = task_local_storage()
    return get!(() -> Any[], tls, :GeneratedFunctionTransform_generating)::Vector{Any}
end

function generate_transformed_body(g::Core.GeneratedFunctionTransform, world::UInt,
                                   source::Method, argtypes::Tuple)
    fullsig = transform_signature(source, argtypes)[1]
    stack = generating_stack()
    for entry in stack
        (s, sig) = entry::Tuple{Method,Any}
        if s === source && sig == fullsig
            error("GeneratedFunctionTransform: the body of ", fullsig, " is already being generated ",
                  "and a transformed body reaches it again; that call is resolved at run time")
        end
    end
    push!(stack, (source, fullsig))
    try
        interp = g.gen(world)
        # Inference has to run in the compiler the interpreter was written against
        compiler = interpreter_compiler(interp)
        if compiler === nothing
            error("GeneratedFunctionTransform: `gen` must return an `AbstractInterpreter`, got ", typeof(interp))
        elseif compiler !== @__MODULE__
            return compiler.generate_transformed_body(g, interp, world, source, argtypes)
        end
        return generate_transformed_body(g, interp, world, source, argtypes)
    finally
        pop!(stack)
    end
end

function generate_transformed_body(g::Core.GeneratedFunctionTransform, interp::AbstractInterpreter,
                                   world::UInt, source::Method, argtypes::Tuple)
    if get_inference_world(interp) != world
        error("GeneratedFunctionTransform: `gen` must construct its interpreter for world ", world)
    end
    fullsig, argsig = transform_signature(source, argtypes)
    lookup = g.transform(argsig)
    if !(lookup isa Type && lookup <: Tuple)
        error("GeneratedFunctionTransform: `transform` must return a tuple type, got ", lookup)
    end
    nargs = length((unwrap_unionall(argsig)::DataType).parameters)
    nargs ≥ 1 || error("GeneratedFunctionTransform: the generated method must take the callee as its first argument")
    match, valid_worlds = findsup(lookup, method_table(interp))
    match === nothing && error("GeneratedFunctionTransform: no unique method matching ", lookup)
    mi = specialize_method(match)
    if mi.def === source && mi.specTypes == fullsig
        # inferring this would call right back into this generator with the same arguments
        error("GeneratedFunctionTransform: `transform` selected the specialization being generated")
    end
    ci = typeinf_ext_toplevel(interp, mi, SOURCE_MODE_ABI)
    if !(ci isa CodeInstance)
        error("GeneratedFunctionTransform: inference of ", mi, " produced no code")
    end

    # Build `invoke(f, ci, args...)`, forwarding the generated method's own arguments
    # (minus the function itself) positionally. Any varargs are spread back out. The
    # method's own slot names are not reused, since an anonymous argument has none.
    nfixed = Int(source.nargs) - Int(source.isva)
    argnames = Any[Symbol("#self#")]
    for i in 2:Int(source.nargs)
        push!(argnames, Symbol("#arg#", i - 1))
    end
    args = Any[argnames[i] for i in 2:nfixed]
    if source.isva
        va = argnames[end]
        for i in 1:length(argtypes[end]::Tuple)
            push!(args, Expr(:call, GlobalRef(Core, :getfield), va, i))
        end
    end
    body = Expr(:call, GlobalRef(Core, :invoke), args[1], ci, args[2:end]...)
    stub = Core.GeneratedFunctionStub(identity, Core.svec(argnames...), Core.svec())
    src = stub(world, source, body)::CodeInfo

    # The inner `CodeInstance` is the edge that keeps this body honest: when it is
    # invalidated, so is everything that inlined or invoked this stub, and the generator
    # is re-run. Keep whatever binding edges lowering already recorded.
    edges = Any[ci]
    src.edges isa SimpleVector && append!(edges, src.edges)
    src.edges = Core.svec(edges...)
    src.min_world = max(ci.min_world, first(valid_worlds))
    src.max_world = min(ci.max_world, last(valid_worlds))
    return src
end
