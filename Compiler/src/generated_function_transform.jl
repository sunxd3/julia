# This file is a part of Julia. License is MIT: https://julialang.org/license

# Implementation of `Core.GeneratedFunctionTransform`, reached from its call method in
# Base through the `Compiler` module the interpreter belongs to.

# The signature of the call a generated method `overdub(f, args...)` is to transform,
# `Tuple{typeof(f), argtypes...}`, from what the runtime hands a generator: the values
# of the static parameters, then the argument types, a trailing varargs packed in a tuple.
function transformed_call_signature(source::Method, @nospecialize(genargs::Tuple))
    argtypes = genargs[end-Int(source.nargs)+2:end] # drops the generated function itself
    source.isva && (argtypes = (argtypes[1:end-1]..., argtypes[end]...))
    return Tuple{argtypes...}
end

# Infer and compile the call with `interp`, and return the body `invoke(f, ci, args...)`
# with the resulting CodeInstance as its edge, so that whatever invalidates that
# CodeInstance also invalidates the body and the generator is re-run.
function generate_transformed_body(interp::AbstractInterpreter, world::UInt, source::Method,
                                   @nospecialize(genargs::Tuple))
    if codegen_cache(interp) === nothing
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the interpreter `", typeof(interp),
            "` must define a `Compiler.codegen_cache`, so that the code it produces can be invoked")))
    end
    if get_inference_world(interp) != world
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `gen(", world,
            ")` returned an interpreter for world ", get_inference_world(interp))))
    end
    if source.nkw != 0
        # the method holding the body of a method with keyword arguments receives their
        # values before the callee
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: keyword arguments are not supported (in ",
            source, ")")))
    end
    # the generated method's own argument names are forwarded; an anonymous argument has
    # none to reuse
    argnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), source.slot_syms)[1:Int(source.nargs)]
    for i in 2:length(argnames)
        argnames[i] === Symbol("#unused#") || continue
        name = Symbol("#unused", i - 1)
        name in argnames && throw(ArgumentError(LazyString("GeneratedFunctionTransform: the argument name ", name, " is reserved")))
        argnames[i] = name
    end
    sig = transformed_call_signature(source, genargs)
    if sig === Tuple{}
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: ", source,
            " must be called with the function to call as its first argument")))
    end
    match, valid_worlds = findsup(sig, method_table(interp))
    if match === nothing
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: no unique method of the interpreter's method table matches ",
            sig)))
    end
    ci = typeinf_ext_toplevel(interp, specialize_method(match), SOURCE_MODE_ABI)
    if !(ci isa CodeInstance)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: inference of ", sig, " with `",
            typeof(interp), "` produced no code")))
    end
    if ccall(:jl_generating_output, Cint, ()) != 0 && !use_const_api(ci) &&
            (@atomic :monotonic ci.inferred) === nothing
        # an image can only carry `ci` with its code; a caller compiled without this body
        # dispatches to the generated method at run time and regenerates it then
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `", typeof(interp), "` discarded the code of ",
            sig, ", which a package image needs to carry it (see `Compiler.may_discard_trees`)")))
    end

    # the number of varargs is known, so each is spread out with `getfield`
    args = Any[argnames[2:end]...]
    if source.isva
        vaslot = pop!(args)
        for i in 1:length(genargs[end]::Tuple)
            push!(args, Expr(:call, GlobalRef(Core, :getfield), vaslot, i))
        end
    end
    body = Expr(:call, GlobalRef(Core, :invoke), args[1], ci, args[2:end]...)
    stub = Core.GeneratedFunctionStub(identity, Core.svec(argnames...), Core.svec())
    src = stub(world, source, body)::CodeInfo
    src.edges = Core.svec(ci)
    # also bounded by the lookup: a replaced method's own instances are never capped, so a
    # body generated in an old world must not be valid for the current one
    src.min_world = max(ci.min_world, first(valid_worlds))
    src.max_world = min(ci.max_world, last(valid_worlds))
    return src
end
