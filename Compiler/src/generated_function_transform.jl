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
                                           @nospecialize(genargs::Tuple), @nospecialize(transform=nothing))
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
        transformed_body(interp, world, source, genargs, mi, transform)
    finally
        engine_reject(interp, reservation)
    end
    if !(src isa CodeInfo)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `generate_transformed_body` for `",
            typeof(interp), "` must return a `CodeInfo`, or an `IRCode` and its edges")))
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

# The names of the arguments of `source`, for the body of one of its specializations. The
# generated method's own argument names are forwarded; an anonymous argument has none to
# reuse.
function generated_argnames(source::Method)
    argnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), source.slot_syms)[1:Int(source.nargs)]
    for i in 1:length(argnames)
        argnames[i] === Symbol("#unused#") || continue
        name = Symbol("#unused", i - 1)
        name in argnames && throw(ArgumentError(LazyString("GeneratedFunctionTransform: the argument name ", name, " is reserved")))
        argnames[i] = name
    end
    return argnames
end

# The body `invoke(f, ci, args...)` of a specialization of `source`, where `f, args...` are
# its arguments from the one at `from` on, with `ci` as its edge.
function invoke_body(world::UInt, source::Method, @nospecialize(genargs::Tuple), ci::CodeInstance,
                     valid_worlds::WorldRange, from::Int)
    argnames = generated_argnames(source)
    # the number of varargs is known, so each is spread out with `getfield`
    args = Any[argnames[from:end]...]
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
    src.min_world = max(ci.min_world, valid_worlds.min_world)
    src.max_world = min(ci.max_world, valid_worlds.max_world)
    return src
end

# Whether a package image being generated could not carry `ci`: it can only carry it with
# its code.
discarded_for_output(ci::CodeInstance) = ccall(:jl_generating_output, Cint, ()) != 0 && !use_const_api(ci) &&
    (@atomic :monotonic ci.inferred) === nothing

# What `generated_function_transform_body` returns, before it is checked, for the
# specialization `mi` of `source`.
#
# Code that the cache of `interp` already holds for `mi` and that is valid in `world` is
# invoked as it is, and `generate_transformed_body` is not called. That is code published
# from IR in an earlier run of the generator, when the body made then is gone or was never
# kept (as after loading a package image), or the code `interp` inferred for the generated
# method when it met a call of it, which is the body an earlier run returned with what it
# invokes: the same function either way.
function transformed_body(interp::AbstractInterpreter, world::UInt, source::Method, @nospecialize(genargs::Tuple),
                          mi::MethodInstance, @nospecialize(transform))
    valid_worlds = WorldRange(world, typemax(UInt))
    ci = find_typeinf_cached_ci(interp, mi, WorldRange(world), SOURCE_MODE_ABI)
    if ci === nothing || discarded_for_output(ci)
        validation_world = get_world_counter()
        if transform === nothing
            result = generate_transformed_body(interp, world, source, genargs)
            result isa Tuple{IRCode,Union{SimpleVector,Vector{Any}}} || return result
            ir, edges = result
        else
            ir, edges = derive_transformed_ir(interp, world, mi, transform)
        end
        valid_worlds = ir.valid_worlds
        ci = publish_transformed_ir!(interp, mi, ir, edges, validation_world)
    end
    ci = add_codeinsts_to_jit!(interp, ci, SOURCE_MODE_ABI)::CodeInstance
    if discarded_for_output(ci)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `", typeof(interp), "` discarded the code of ",
            mi.specTypes, ", which a package image needs to carry it (see `Compiler.may_discard_trees`)")))
    end
    return invoke_body(world, source, genargs, ci, valid_worlds, 1)
end

# The IR of the specialization `mi` of a generated method whose generator has a
# `transform`, and the edges for what it was derived from. The compiler makes the lookup
# and infers the code the IR is derived from, so it knows these dependencies itself: the
# tool only maps IR to IR.
function derive_transformed_ir(interp::AbstractInterpreter, world::UInt, mi::MethodInstance, @nospecialize(transform))
    lookup = transform(mi.specTypes)
    valid_worlds = WorldRange(world, typemax(UInt))
    edges = Any[]
    source = nothing
    if lookup !== nothing
        if !(lookup isa Type && lookup <: Tuple)
            throw(ArgumentError(LazyString("GeneratedFunctionTransform: `transform` must return a signature or `nothing`, not ",
                lookup)))
        end
        match, valid_worlds = findsup(lookup, method_table(interp))
        if match === nothing
            throw(ArgumentError(LazyString("GeneratedFunctionTransform: no unique method of the interpreter's method table matches ",
                lookup)))
        end
        source_mi = specialize_method(match)
        dep = typeinf_ext(interp, source_mi, SOURCE_MODE_NOT_REQUIRED)
        source = typeinf_ircode(interp, source_mi, nothing)[1]
        if !(dep isa CodeInstance && source isa IRCode)
            throw(ArgumentError(LazyString("GeneratedFunctionTransform: inference of ", lookup, " with `",
                typeof(interp), "` produced no code")))
        end
        valid_worlds = intersect(valid_worlds, WorldRange(dep.min_world, dep.max_world))
        if !(world in valid_worlds)
            throw(ArgumentError(LazyString("GeneratedFunctionTransform: the code for ", lookup,
                " is not valid in world ", world)))
        end
        # As for a call that inference resolves by dispatch to its only match: the edge
        # stands for the code and for the lookup that found its method.
        push!(edges, dep)
    end
    ir = transform_ir(interp, mi, source)
    if !(ir isa IRCode)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `transform_ir` for `", typeof(interp),
            "` must return an `IRCode`")))
    end
    return IRCode(ir, valid_worlds), edges
end

"""
    transform_ir(interp::AbstractInterpreter, mi::MethodInstance, source::Union{IRCode,Nothing}) -> IRCode

Produce the typed IR of `mi`, a specialization of a method whose generator is
`Core.GeneratedFunctionTransform(transform, gen)`, for `interp = gen(world)`. `source` is
the optimized IR `interp` inferred for the signature `transform(mi.specTypes)`, or
`nothing` if `transform` returned `nothing`. The compiler looked that signature up and
inferred it, so it records the dependency on it itself; the IR returned is typed,
optimized and published as for `generate_transformed_body`.
"""
function transform_ir(interp::AbstractInterpreter, mi::MethodInstance, source::Union{IRCode,Nothing})
    throw(ArgumentError(LazyString("GeneratedFunctionTransform: `", typeof(interp),
        "` has no method of `Compiler.transform_ir`, which a generator with a `transform` needs")))
end

# Finish `ir`, typed IR that `generate_transformed_body` returned for the specialization
# `mi`, and publish it as the code of `mi` in the cache of `interp`, as inference
# publishes a result. `declared` are the edges only the tool knows.
function publish_transformed_ir!(interp::AbstractInterpreter, mi::MethodInstance, ir::IRCode,
                                 declared::Union{SimpleVector,Vector{Any}}, validation_world::UInt)
    world = get_inference_world(interp)
    def = mi.def::Method
    nargs = Int(def.nargs)
    if length(ir.argtypes) != nargs
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the IR for ", mi, " takes ", length(ir.argtypes),
            " arguments, but its method takes ", nargs)))
    end
    spec = unwrap_unionall(mi.specTypes)::DataType
    if def.isva
        # the method receives its trailing arguments packed in a tuple
        spec = rewrap_unionall(Tuple{spec.parameters[1:nargs-1]..., Tuple{spec.parameters[nargs:end]...}}, mi.specTypes)
    else
        spec = mi.specTypes
    end
    if !(spec <: Tuple{Any[widenconst(t) for t in ir.argtypes]...})
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the IR for ", mi, " does not accept its arguments")))
    end
    if !(world in ir.valid_worlds)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the IR for ", mi, " is not valid in world ", world)))
    end
    isempty(ir.new_nodes) || (ir = compact!(ir))

    # Type the statements flagged `IR_FLAG_REFINED`, as for IR that is interpreted with
    # more precise argument types. This records the edges of every call it resolves.
    spec_info = SpecInfo(nargs, def.isva, #=propagate_inbounds=#false, nothing)
    irsv = IRInterpretationState(interp, spec_info, ir, mi, copy(ir.argtypes), world, world)
    ir_abstract_constant_propagation(interp, irsv)
    if !(world in irsv.valid_worlds)
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: the IR for ", mi, " is not valid in world ", world)))
    end
    # The passes the optimizer runs on IR, so that calls are inlined or resolved to the
    # code they invoke.
    inlining = InliningState(irsv.edges, interp, IdDict{MethodInstance,CodeInstance}())
    ir = compact!(ssa_inlining_pass!(ir, inlining, spec_info.propagate_inbounds))
    ir = sroa_pass!(ir, inlining)
    ir, made_changes = adce_pass!(ir, inlining)
    made_changes && (ir = compact!(ir, true))
    verify_ir(ir, true, false, optimizer_lattice(interp), mi)
    slotnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), def.slot_syms)[1:nargs]
    for i = 1:length(ir.stmts)
        stmt = ir[SSAValue(i)][:stmt]
        for use in (stmt isa Argument ? (stmt,) : (u[] for u in userefs(stmt)))
            if use isa Argument && slotnames[use.n] === Symbol("#unused#")
                # codegen keeps no value for an anonymous argument
                throw(ArgumentError(LazyString("GeneratedFunctionTransform: the IR for ", mi, " reads argument ",
                    use.n, ", which has no name")))
            end
        end
    end
    # What callers may assume of the code: the return type, and the effects that the flags
    # of its statements establish, as after optimization of inferred code. Effects that
    # inference only accumulates while it infers source (`terminates`, `notaskstate`,
    # `inaccessiblememonly`) are left unknown.
    rettype = compute_ir_rettype(ir)
    result = InferenceResult(mi, typeinf_lattice(interp))
    ipo_dataflow_analysis!(interp, nargs, ir, result)
    effects = result.ipo_effects
    exctype = is_nothrow(effects) ? Union{} : Any
    edges = Core.svec(declared..., materialize_inference_edges(irsv.edges)...)

    src = ccall(:jl_new_code_info_uninit, Ref{CodeInfo}, ())
    src.slotnames = slotnames
    src.slotflags = fill(zero(UInt8), nargs)
    src.slottypes = copy(ir.argtypes)
    src.isva = def.isva
    src.nargs = UInt(nargs)
    if ir.debuginfo.def === nothing
        # IR that was not inferred from a method names nothing, as for `Core.OpaqueClosure(ir)`
        ir.debuginfo.def = mi
    end
    src = ir_to_codeinf!(src, ir)
    src.rettype = rettype
    src.edges = edges
    # the lookups behind the IR were made in `world`: the result starts there, and
    # `publish_codeinst!` decides whether it outlives it
    src.min_world = src.max_world = world
    inferred = maybe_compress_codeinfo(interp, mi, src)

    # everything that can throw comes before the reservation
    ci = engine_reserve(interp, mi)
    code = find_typeinf_cached_ci(interp, mi, WorldRange(world), SOURCE_MODE_ABI)
    if code !== nothing
        # another thread published first
        engine_reject(interp, ci)
        return code
    end
    publish_codeinst!(interp, mi, ci, src, rettype, exctype, inferred, encode_effects(effects),
        result.analysis_results, edges, validation_world)
    return ci
end

"""
    generate_transformed_body(interp::AbstractInterpreter, world::UInt, method::Method, genargs::Tuple)

Produce the body of a specialization of `method`, whose generator is
`Core.GeneratedFunctionTransform(gen)`, for `interp = gen(world)`: either the body itself, a
`CodeInfo`, or typed IR of the specialization with its edges, `(ir::IRCode, edges)`, which
the compiler publishes as code of `interp` and invokes.

This is called when inference or the runtime needs that body in a world in which none is
cached, which includes each time the code the previous body depended on has been
invalidated, unless the cache of `interp` holds code of the specialization that is valid
in `world`: that code is invoked without calling this. `genargs` is what the runtime
passes to a generator: the values of the method's static parameters, then the types of
its arguments, the types of trailing varargs as one tuple. When this is called, `interp`
is known to infer in exactly `world`, to have a `cache_owner` other than the native
compiler's and a `codegen_cache`, and `method` to have no keyword arguments.

The default method takes the first argument as a function `f` and the rest as its
arguments, looks the call `f(args...)` up in `method_table(interp)`, infers and compiles
the matching method with `interp`, and returns the body `invoke(f, ci, args...)` of the
resulting `CodeInstance` `ci`.

An interpreter that needs other code, for example code derived from `f` that takes other
arguments, adds a method for its own type.

# Returning IR

`(ir, edges)` is the code of the specialization itself: `ir.argtypes` are the arguments
as `method` receives them, the function first and trailing varargs packed in a tuple, and
`edges`, a `SimpleVector` or `Vector{Any}` in the format of `CodeInstance.edges`, hold
what the IR depends on in the world that the compiler cannot see in it: the
`CodeInstance`s it was derived from, and every method lookup that decided what it was
derived from, as `(signature, Core.methodtable)`. `ir.valid_worlds` is the range in which
those lookups hold (see `findsup`) and must contain `world`. The IR is consumed.

The compiler then does what it does for inferred code:
- It types every statement flagged `IR_FLAG_REFINED`, with `interp`, as for IR that is
  interpreted with more precise argument types (`ir_abstract_constant_propagation`), and
  records the edges of the calls it resolves. A call of a generated method of `interp` is
  resolved to the code `interp` has, or derives, for it.
- It runs the optimizer's passes on the IR: inlining, which resolves the calls that are
  not inlined to an `:invoke` of their code, SROA and dead code elimination. Passes that
  need the result of this typing therefore need not, and cannot, be run by the tool; it
  may run any pass it likes on the IR before returning it.
- It computes the return type from the IR, and from the flags of its statements the
  effects `consistent`, `effect_free`, `nothrow`, `noub` and `nortcall`, as after the
  optimization of inferred code (`ipo_dataflow_analysis!`). The exception type is
  `Union{}` if the code is `nothrow` and `Any` otherwise. `terminates`, `notaskstate` and
  `inaccessiblememonly` are left unknown: inference accumulates them only while it infers
  source, and the flags of a statement do not record the last two.
- It publishes the code as a `CodeInstance` of the specialization owned by
  `cache_owner(interp)`, with `edges` and the recorded edges, as inference publishes a
  result: reserved in the engine, valid in later worlds only once its backedges are
  stored and no method was defined since before this was called, entered in
  `codegen_cache(interp)` and compiled. If another thread published code for the
  specialization meanwhile, that is used.
- It returns the body `invoke(self, ci, args...)` with that `CodeInstance` as its edge.

What the tool must ensure, and nothing checks beyond the number and types of the
arguments and the well-formedness of the IR (`verify_ir`):
- The type and flags of a statement that is not flagged `IR_FLAG_REFINED` are right, and
  the type given to one that is flagged is right too: it is kept unless typing finds one
  that is more precise. Callers and the code itself are compiled against these types and
  against the return type and effects that follow from them, so a wrong one is
  memory-unsafe. Leave a type as `Any` and set the flag to have it computed.
- `edges` are complete, as described.
- The result depends on nothing but `cache_owner(interp)`, the specialization and `world`.

# Returning a body

A method may instead build the `CodeInstance` itself and return the body, or return a
body that invokes nothing. Of what follows, the generator checks only that the result is
a `CodeInfo` with a world range as described whose `edges` hold every `CodeInstance` it
refers to. Such a method must:

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
  `ci` with its source in `inferred`.
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

# Notes

The code of a specialization that is found in the cache of `interp` and invoked without
calling this is code published from IR by an earlier call, whose body is gone or was not
kept (as for a new caller after a package image was loaded), or code `interp` inferred
for the generated method when it met a call of it: the body an earlier call returned,
with what it invokes. Either is the function this would produce again, which is why all
code stored for the specialization and `cache_owner(interp)` must be that function.

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
    generated_argnames(source) # refuses a reserved argument name before anything is inferred
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
    if discarded_for_output(ci)
        # a caller compiled without this body dispatches to the generated method at run
        # time and regenerates it then
        throw(ArgumentError(LazyString("GeneratedFunctionTransform: `", typeof(interp), "` discarded the code of ",
            callsig, ", which a package image needs to carry it (see `Compiler.may_discard_trees`)")))
    end
    # also bounded by the lookup: a replaced method's own instances are never capped, so a
    # body generated in an old world must not be valid for the current one
    return invoke_body(world, source, genargs, ci, valid_worlds, 2)
end
