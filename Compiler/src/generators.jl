# This file is a part of Julia. License is MIT: https://julialang.org/license

# Implementation of `Core.GeneratedFunctionTransform`.
#
# A method whose generator is a `GeneratedFunctionTransform` has no source of its own.
# When the runtime asks for its body, it calls the generator's call method in Base
# (`base/reflection.jl`), which constructs the interpreter with `g.gen(world)` and routes
# to `generate_transformed_body` of the `Compiler` module that interpreter belongs to.
# That infers and compiles the call itself (the generated method's arguments minus the
# generated function) with the interpreter, and returns a stub that `invoke`s the
# resulting `CodeInstance`. That `CodeInstance` is recorded as a forward edge of the
# stub, so whatever invalidates the inner result also invalidates every caller of the
# generated method, and the runtime then simply re-runs the generator.

# Reassemble the signature of the specialization being generated from what the runtime
# hands to a generator: the static parameter values come first and are dropped, and the
# types of a trailing varargs arrive packed in a tuple. Returns the signature of the
# call itself, i.e. without the generated function.
function transform_signature(source::Method, argtypes::Tuple)
    nsparams = unionall_depth(source.sig)
    types = Any[argtypes[nsparams+1:end]...]
    if source.isva
        for t in pop!(types)::Tuple
            push!(types, t)
        end
    end
    return Tuple{types[2:end]...}
end

# Like every generator, this runs in `source.primary_world` (the runtime pins the world
# for the duration of the callback), so `g.gen` and the methods of the interpreter type
# are those visible when the generated method was defined. Only the lookup and the inner
# inference, which take `world` explicitly, see the requesting world.
function generate_transformed_body(g::Core.GeneratedFunctionTransform, interp::AbstractInterpreter,
                                   world::UInt, source::Method, argtypes::Tuple)
    if cache_owner(interp) === nothing
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the interpreter `", typeof(interp),
            "` returned by `gen` must define a `Compiler.cache_owner` other than `nothing`")))
    end
    if get_inference_world(interp) != world
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `gen(", world,
            ")` returned an interpreter for world ", get_inference_world(interp),
            "; it must infer in the world it is given")))
    end
    if source.nkw != 0
        # the method is the body of a method with keyword arguments; its leading
        # arguments are keyword values, not the callee
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: keyword arguments are not supported (in ",
            source, ")")))
    end
    argsig = transform_signature(source, argtypes)
    if isempty((argsig::DataType).parameters)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: ", source,
            " must be called with the function to call as its first argument")))
    end
    match, valid_worlds = findsup(argsig, method_table(interp))
    if match === nothing
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: no unique method of the interpreter's method table matches ",
            argsig)))
    end
    mi = specialize_method(match)
    ci = typeinf_ext_toplevel(interp, mi, SOURCE_MODE_ABI)
    if !(ci isa CodeInstance)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: inference of ", mi,
            " with `", typeof(interp), "` produced no code")))
    end

    # Build `invoke(f, ci, args...)`, forwarding the generated method's own arguments
    # (minus the function itself) positionally. The generator runs for concrete argument
    # types, so the number of varargs is known and each is spread out with `getfield`;
    # when the varargs are the only argument, the callee is the first of them. The
    # method's own slot names are not reused, since an anonymous argument has none.
    argnames = Any[Symbol("#self#")]
    for i in 2:Int(source.nargs)
        push!(argnames, Symbol("#arg#", i - 1))
    end
    args = Any[argnames[i] for i in 2:Int(source.nargs)]
    if source.isva
        vaslot = pop!(args)
        for i in 1:length(argtypes[end]::Tuple)
            push!(args, Expr(:call, GlobalRef(Core, :getfield), vaslot, i))
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
