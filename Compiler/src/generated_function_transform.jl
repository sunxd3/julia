# This file is a part of Julia. License is MIT: https://julialang.org/license

# Implementation of `Core.GeneratedFunctionTransform`, reached from its call method in
# Base through the `Compiler` module the interpreter belongs to.

# The signature of the generated method's specialization, `Tuple{typeof(self), argtypes...}`,
# from what the runtime hands a generator: the values of the static parameters, then the
# argument types, a trailing varargs packed in a tuple.
function generated_signature(source::Method, @nospecialize(genargs::Tuple))
    argtypes = genargs[end-Int(source.nargs)+1:end]
    source.isva && (argtypes = (argtypes[1:end-1]..., argtypes[end]...))
    return Tuple{argtypes...}
end

# The key under which a thread reserves a specialization of a generated method in the
# engine while its body is generated for `owner`. It is not a cache owner: holding it marks
# the thread as generating that body, and makes other threads that need the body wait.
struct GeneratingBody
    owner
    GeneratingBody(@nospecialize(owner)) = new(owner)
end

# Whether `x`, a statement of untyped code or a part of one, refers to a CodeInstance that
# is not among `edges`.
function has_unlisted_codeinstance(@nospecialize(x), @nospecialize(edges))
    if x isa CodeInstance
        if edges isa Union{SimpleVector,Vector{Any}}
            for i in 1:length(edges)
                edges[i] === x && return false
            end
        end
        return true
    elseif x isa Expr
        for arg in x.args
            has_unlisted_codeinstance(arg, edges) && return true
        end
    elseif x isa QuoteNode
        return has_unlisted_codeinstance(x.value, edges)
    end
    return false
end

# The generator proper: check what every interpreter and every generated method must
# satisfy, then ask `generate_transformed_body` for the body, and check that. The checks
# are made here, around the call of the function an interpreter may add a method to, so
# that they hold for such a method as well.
function generated_function_transform_body(interp::AbstractInterpreter, world::UInt, source::Method,
                                           @nospecialize(genargs::Tuple))
    owner = cache_owner(interp)
    if codegen_cache(interp) === nothing
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the interpreter `", typeof(interp),
            "` must define a `Compiler.codegen_cache`, so that the code it produces can be invoked")))
    end
    if is_native_owner(owner)
        # its code would be cached as the native compiler's, and ordinary calls would run it
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the interpreter `", typeof(interp),
            "` must define a `Compiler.cache_owner` other than the native compiler's")))
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
    # Generating the body may request the same body again, for example when the code an
    # interpreter derives for a recursive function calls the generated method for that
    # function. Such a request gets no body: the call that makes it is inferred as `Any`
    # and dispatched at run time, when the body exists.
    mi = specialize_method(source, generated_signature(source, genargs),
        Core.svec(genargs[1:end-Int(source.nargs)]...))
    key = GeneratingBody(owner)
    if engine_hasreserved(mi, key)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the body of ", mi,
            " is requested while this thread is generating it")))
    end
    reservation = engine_reserve(mi, key)
    src = try
        generate_transformed_body(interp, world, source, genargs)
    finally
        engine_reject(interp, reservation)
    end
    if !(src isa CodeInfo)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `generate_transformed_body` for `",
            typeof(interp), "` must return a `CodeInfo`")))
    end
    if !(src.min_world <= world <= src.max_world)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the body generated for ", source,
            " is not valid in world ", world)))
    end
    # Only its edges invalidate the body: it may not outlive code among them, and code it
    # invokes that is not among them would be invoked when no longer valid.
    edges = src.edges
    if edges isa Union{SimpleVector,Vector{Any}}
        for i in 1:length(edges)
            edge = edges[i]
            edge isa CodeInstance || continue
            if !(edge.min_world <= src.min_world && src.max_world <= edge.max_world)
                throw(ArgumentError(LazyString("GeneratedFunctionTransform: the body generated for ", source,
                    " is valid in worlds in which the code for ", get_ci_mi(edge).specTypes, ", an edge of it, is not")))
            end
        end
    end
    for stmt in src.code
        if has_unlisted_codeinstance(stmt, edges)
            throw(ArgumentError(LazyString("GeneratedFunctionTransform: the body generated for ", source,
                " refers to a `CodeInstance` that is not in its `edges`")))
        end
    end
    return src
end

"""
    generate_transformed_body(interp::AbstractInterpreter, world::UInt, method::Method, genargs::Tuple)::CodeInfo

Produce the body of a specialization of `method`, whose generator is
`Core.GeneratedFunctionTransform(gen)`, for `interp = gen(world)`. This is called each time
the generator runs: whenever inference or the runtime needs that body in a world in which
none is cached, which includes each time the code the previous body depended on has been
invalidated. `genargs` is what the runtime passes to a generator: the values of the
method's static parameters, then the types of its arguments, the types of trailing varargs
as one tuple. When this is called, `interp` is known to infer in exactly `world`, to have a
`cache_owner` other than the native compiler's and a `codegen_cache`, and `method` to have
no keyword arguments.

The default method takes the first argument as a function `f` and the rest as its
arguments, looks the call `f(args...)` up in `method_table(interp)`, infers and compiles
the matching method with `interp`, and returns the body `invoke(f, ci, args...)` of the
resulting `CodeInstance` `ci`.

An interpreter that needs other code, for example code derived from `f` that takes other
arguments, adds a method for its own type. That method builds a `CodeInstance` `ci` of the
specialization of `method` itself, owned by `cache_owner(interp)`, and returns a body that
invokes it with the method's own arguments. It must do the following. Of this, the
generator checks only that the result is a `CodeInfo` with a world range as described
whose `edges` hold every `CodeInstance` it refers to.

- Store the code on the `MethodInstance` of the specialization being generated, and on no
  other. Inference uses whatever code it finds for a `MethodInstance` and an owner in place
  of any other code for them, so all code stored for one such pair must be the same
  function with the same calling convention. The body, which `interp` infers when it
  meets a call of the generated method, and the code that body invokes are the same
  function; code stored for `cache_owner(interp)` on the `MethodInstance` of another
  method, such as the one the code was derived from, is taken for that method's code
  as soon as `interp` infers a call of it.
- Return a `CodeInfo` for `method` (see `Core.GeneratedFunctionStub`) whose body calls
  `invoke(self, ci, args...)` with the arguments of the specialization.
- Set `edges` of the `CodeInfo` to hold `ci`, and its `min_world` and `max_world` to a
  range that contains `world` and lies within the range of `ci` and of every other
  `CodeInstance` in `edges`, and within the range in which any method lookup it made holds
  (as returned by `findsup`).
- Publish `ci` so that it can be invoked: `ci` must be in the cache of its `MethodInstance`
  (`code_cache(interp)`), valid in `world`, and compiled or compilable from
  `codegen_cache(interp)` (see `add_codeinsts_to_jit!`). A package image can only carry
  `ci` with its source in `inferred`. If the cache already holds such code that is valid in
  `world`, use that instead of publishing more: the generator can run again while the code
  an earlier run published is valid, for example for a new caller after a package image
  was loaded, and of two equivalent `CodeInstance`s in a cache only one is compiled.
- Give `ci` a return type, an exception type and effects that hold for its code. Callers
  are compiled against them without checking them: a return type the code does not keep
  to makes callers read a value as something it is not, which is memory-unsafe.
- Record in the `edges` of `ci` everything in the world that `ci` depends on: the
  `CodeInstance`s it was derived from or invokes, and every method lookup that decided
  what it was derived from. Nothing else invalidates `ci`, and so the body. Inference does
  this for the code it produces; a method that builds `ci` by other means must do it
  itself, and must register the backedges (`store_backedges`) before `ci` is made valid
  for later worlds (`jl_promote_ci_to_current`, with the world counter read before the
  dependencies were), as `finish!` does.
- Depend on nothing but `cache_owner(interp)`, the specialization and `world`: within the
  range of the `CodeInfo`, another call with these must be free to use the same body.

While this runs, the thread holds a reservation of the specialization for
`cache_owner(interp)`. A request for the same body on that thread meanwhile throws instead
of running this again, as when the derived code of a recursive function calls the
generated method for that function: inference, which makes that request, then infers the
call as `Any` and leaves it to be dispatched at run time, when the body exists. Another
thread that needs the body waits for it, unless the two threads wait for each other's,
in which case one proceeds and both may generate it. A reservation belongs to a thread,
not to a task: if this switches tasks, another task on the thread that requests the same
body meanwhile gets that error too.

Each specialization is generated on its own, in the world of the request that finds no
valid body for it. When several generated specializations are derived from the same code,
such as a forward pass and the reverse pass that consumes what it returns, one of them may
be regenerated from a later definition while a value made by the other, as derived from
an earlier one, is still in use. What they must agree on therefore has to be part of the
types of the values passed between them, so that a value made by an earlier derivation
selects a specialization derived to match it, never code derived from a later world.

This method, like `gen` and the other methods of `interp`, is part of the compiler:
redefining it does not invalidate bodies generated before (see
`Core.GeneratedFunctionTransform`). An error it throws is thrown by the call; a caller
that is being inferred infers `Any` for the call instead, and the failure is not cached.
"""
function generate_transformed_body(interp::AbstractInterpreter, world::UInt, source::Method,
                                   @nospecialize(genargs::Tuple))
    # the generated method's own argument names are forwarded; an anonymous argument has
    # none to reuse
    argnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), source.slot_syms)[1:Int(source.nargs)]
    for i in 1:length(argnames)
        argnames[i] === Symbol("#unused#") || continue
        name = Symbol("#unused", i - 1)
        name in argnames && throw(ArgumentError(LazyString("GeneratedFunctionTransform: the argument name ", name, " is reserved")))
        argnames[i] = name
    end
    sig = generated_signature(source, genargs)
    callsig = Tuple{sig.parameters[2:end]...}
    if callsig === Tuple{}
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: ", source,
            " must be called with the function to call as its first argument")))
    end
    match, valid_worlds = findsup(callsig, method_table(interp))
    if match === nothing
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: no unique method of the interpreter's method table matches ",
            callsig)))
    end
    ci = typeinf_ext_toplevel(interp, specialize_method(match), SOURCE_MODE_ABI)
    if !(ci isa CodeInstance)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: inference of ", callsig, " with `",
            typeof(interp), "` produced no code")))
    end
    if !(world in valid_worlds && ci.min_world <= world <= ci.max_world)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the code for ", callsig,
            " is not valid in world ", world)))
    end
    if ccall(:jl_generating_output, Cint, ()) != 0 && !use_const_api(ci) &&
            (@atomic :monotonic ci.inferred) === nothing
        # an image can only carry `ci` with its code; a caller compiled without this body
        # dispatches to the generated method at run time and regenerates it then
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `", typeof(interp), "` discarded the code of ",
            callsig, ", which a package image needs to carry it (see `Compiler.may_discard_trees`)")))
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
