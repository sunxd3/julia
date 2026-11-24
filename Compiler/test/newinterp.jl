# This file is a part of Julia. License is MIT: https://julialang.org/license

# TODO set up a version who defines new interpreter with persistent cache?

include("setup_Compiler.jl")

"""
    @newinterp NewInterpreter [ephemeral_cache::Bool=false]

Defines new `NewInterpreter <: AbstractInterpreter` whose cache is separated
from the native code cache, satisfying the minimum interface requirements.

When the `ephemeral_cache=true` option is specified, `NewInterpreter` will hold
`CodeInstance` in an ephemeral non-integrated cache, rather than in the integrated
`Compiler.InternalCodeCache`.
Keep in mind that ephemeral cache lacks support for invalidation and doesn't persist across
sessions. However it is a usual Julia object of the type `global_cache::IdDict{MethodInstance,CodeInstance}`,
making it easier for debugging and inspecting the compiler behavior.
"""
macro newinterp(InterpName, ephemeral_cache::Bool=false)
    InterpCacheName = esc(Symbol(string(InterpName, "Cache")))
    InterpName = esc(InterpName)
    C = Core
    quote
        $(ephemeral_cache && quote
        struct $InterpCacheName
            dict::IdDict{$C.MethodInstance,$C.CodeInstance}
        end
        $InterpCacheName() = $InterpCacheName(IdDict{$C.MethodInstance,$C.CodeInstance}())
        end)
        struct $InterpName <: $Compiler.AbstractInterpreter
            meta # additional information
            world::UInt
            inf_params::$Compiler.InferenceParams
            opt_params::$Compiler.OptimizationParams
            inf_cache::$Compiler.InferenceCache
            $(ephemeral_cache && :(global_cache::$InterpCacheName))
            function $InterpName(meta = nothing;
                                 world::UInt = Base.get_world_counter(),
                                 inf_params::$Compiler.InferenceParams = $Compiler.InferenceParams(),
                                 opt_params::$Compiler.OptimizationParams = $Compiler.OptimizationParams(),
                                 inf_cache::$Compiler.InferenceCache = $Compiler.InferenceCache(),
                                 $(ephemeral_cache ?
                                    Expr(:kw, :(global_cache::$InterpCacheName), :($InterpCacheName())) :
                                    Expr(:kw, :_, :nothing)))
                return $(ephemeral_cache ?
                    :(new(meta, world, inf_params, opt_params, inf_cache, global_cache)) :
                    :(new(meta, world, inf_params, opt_params, inf_cache)))
            end
        end
        $Compiler.InferenceParams(interp::$InterpName) = interp.inf_params
        $Compiler.OptimizationParams(interp::$InterpName) = interp.opt_params
        $Compiler.get_inference_world(interp::$InterpName) = interp.world
        $Compiler.get_inference_cache(interp::$InterpName) = interp.inf_cache
        $Compiler.cache_owner(::$InterpName) = $InterpName
        $(ephemeral_cache && quote
        $Compiler.code_cache(interp::$InterpName) = interp.global_cache
        $Compiler.get(cache::$InterpCacheName, mi::$C.MethodInstance, default) = get(cache.dict, mi, default)
        $Compiler.getindex(cache::$InterpCacheName, mi::$C.MethodInstance) = getindex(cache.dict, mi)
        $Compiler.haskey(cache::$InterpCacheName, mi::$C.MethodInstance) = haskey(cache.dict, mi)
        $Compiler.setindex!(cache::$InterpCacheName, ci::$C.CodeInstance, mi::$C.MethodInstance) = setindex!(cache.dict, ci, mi)
        end)
    end
end

"""
    publish_generated_code!(derive, interp, mi::MethodInstance) -> CodeInstance

A reference for how a method of `Compiler.generate_transformed_body` publishes the code
it built itself for `mi`, the specialization of the generated method, in the cache of
`interp`, and makes it ready to `invoke`.

Code of `mi` that the cache already holds and that is valid in the world of `interp` is
used as it is. Otherwise `derive()` is called for `(src, edges)`: optimized code for the
arguments of `mi`, with its return type in `src.rettype`, and everything in the world it
depends on. As `finish!` does for an inferred result, the code is published as valid in
the interpreter's world only, and for later worlds once its backedges are stored and the
world counter is known not to have moved since before `derive` was called.

This does not reserve `mi` in the inference engine, so two threads may publish at once.
"""
function publish_generated_code!(derive, interp::Compiler.AbstractInterpreter, mi::Core.MethodInstance)
    world = Compiler.get_inference_world(interp)
    validation_world = Base.get_world_counter()
    ci = Compiler.find_typeinf_cached_ci(interp, mi, Compiler.WorldRange(world), Compiler.SOURCE_MODE_ABI)
    if ci === nothing
        src, edges = derive()
        src::Core.CodeInfo
        edges::Core.SimpleVector
        src.edges = edges
        src.min_world = src.max_world = world
        inferred = Compiler.maybe_compress_codeinfo(interp, mi, src)
        ci = Core.CodeInstance(mi, Compiler.cache_owner(interp), src.rettype, Any, nothing, inferred, Int32(0),
            world, world, Compiler.encode_effects(Compiler.EFFECTS_UNKNOWN), nothing, src.debuginfo, edges)
        if world == validation_world && Compiler.store_backedges(ci, edges)
            @atomic :monotonic ci.flags |= Compiler.CI_FLAGS_UNIQUE_BACKEDGES
        end
        Compiler.codegen_cache(interp)[ci] = src
        Compiler.code_cache(interp)[mi] = ci
        ccall(:jl_promote_ci_to_current, Cvoid, (Any, UInt), ci, validation_world)
    end
    return Compiler.add_codeinsts_to_jit!(interp, ci, Compiler.SOURCE_MODE_ABI)::Core.CodeInstance
end
