# This file is a part of Julia. License is MIT: https://julialang.org/license

using Test

include("setup_Compiler.jl")
include("irutils.jl")
include("newinterp.jl")

# interpreter that performs abstract interpretation only
# (semi-concrete interpretation should be disabled automatically)
@newinterp AbsIntOnlyInterp1
Compiler.may_optimize(::AbsIntOnlyInterp1) = false
@test Base.infer_return_type(Base.init_stdio, (Ptr{Cvoid},); interp=AbsIntOnlyInterp1()) >: IO

# it should work even if the interpreter discards inferred source entirely
@newinterp AbsIntOnlyInterp2
Compiler.may_optimize(::AbsIntOnlyInterp2) = false
Compiler.transform_result_for_cache(::AbsIntOnlyInterp2, ::Compiler.InferenceResult, edges::Core.SimpleVector) = nothing
@test Base.infer_return_type(Base.init_stdio, (Ptr{Cvoid},); interp=AbsIntOnlyInterp2()) >: IO

# OverlayMethodTable
# ==================

using Base.Experimental: @MethodTable, @overlay, @consistent_overlay

# @overlay method with return type annotation
@MethodTable RT_METHOD_DEF
@overlay RT_METHOD_DEF Base.sin(x::Float64)::Float64 = cos(x)
@overlay RT_METHOD_DEF function Base.sin(x::T)::T where T<:AbstractFloat
    cos(x)
end

@newinterp MTOverlayInterp
@MethodTable OVERLAY_MT
Compiler.method_table(interp::MTOverlayInterp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), OVERLAY_MT)

# `include_ambiguous` preserves ambiguous matches across method-table views and cache modes.
ambiguous_lookup(x::Integer, y) = 1
ambiguous_lookup(x, y::Integer) = 2
ambiguous_overlay(x, y) = 0
@overlay OVERLAY_MT ambiguous_overlay(x::Integer, y) = 1
@overlay OVERLAY_MT ambiguous_overlay(x, y::Integer) = 2

@testset "ambiguous method lookup" begin
    world = Base.get_world_counter()
    sig = Tuple{typeof(ambiguous_lookup),Integer,Integer}
    internal = Compiler.InternalMethodTable(world)
    filtered = Compiler.findall(sig, internal)
    inclusive = Compiler.findall(sig, internal; include_ambiguous=true)
    @test filtered !== nothing
    @test Compiler.length(filtered) == 0
    @test inclusive !== nothing
    @test inclusive.ambig
    @test Compiler.length(inclusive) == 2
    @test Set(match.method for match in inclusive) == Set(methods(ambiguous_lookup))

    cached = Compiler.CachedMethodTable(internal)
    @test Compiler.length(Compiler.findall(sig, cached)) == 0
    @test Compiler.length(Compiler.findall(sig, cached; include_ambiguous=true)) == 2
    @test length(cached.cache) == 2

    overlay_sig = Tuple{typeof(ambiguous_overlay),Integer,Integer}
    overlay = Compiler.OverlayMethodTable(world, OVERLAY_MT)
    overlay_matches = Compiler.findall(overlay_sig, overlay; include_ambiguous=true)
    @test overlay_matches !== nothing
    @test overlay_matches.ambig
    @test Compiler.length(overlay_matches) == 2
    base_method = only(methods(ambiguous_overlay))
    @test all(match -> match.method !== base_method, overlay_matches)
end

function Compiler.add_remark!(interp::MTOverlayInterp, ::Compiler.InferenceState, remark)
    if interp.meta !== nothing
        # Core.println(remark)
        push!(interp.meta, remark)
    end
    return nothing
end

struct StrangeSinError end
strangesin(x) = sin(x)
@overlay OVERLAY_MT strangesin(x::Float64) =
    iszero(x) ? throw(StrangeSinError()) : x < 0 ? nothing : cos(x)

# inference should use the overlayed method table
@test Base.return_types((Float64,); interp=MTOverlayInterp()) do x
    strangesin(x)
end |> only === Union{Float64,Nothing}
@test Base.return_types((Any,); interp=MTOverlayInterp()) do x
    @invoke strangesin(x::Float64)
end |> only === Union{Float64,Nothing}
@test only(Base.return_types(strangesin, (Float64,); interp=MTOverlayInterp())) === Union{Float64,Nothing}
@test Base.infer_exception_type(strangesin, (Float64,); interp=MTOverlayInterp()) === Union{StrangeSinError,DomainError}
@test only(Base.infer_exception_types(strangesin, (Float64,); interp=MTOverlayInterp())) === Union{StrangeSinError,DomainError}
@test last(only(code_typed(strangesin, (Float64,); interp=MTOverlayInterp()))) === Union{Float64,Nothing}
@test last(only(Base.code_ircode(strangesin, (Float64,); interp=MTOverlayInterp()))) === Union{Float64,Nothing}

# effect analysis should figure out that the overlayed method is used
@test Base.infer_effects((Float64,); interp=MTOverlayInterp()) do x
    strangesin(x)
end |> !Compiler.is_nonoverlayed
@test Base.infer_effects((Any,); interp=MTOverlayInterp()) do x
    @invoke strangesin(x::Float64)
end |> !Compiler.is_nonoverlayed

# account for overlay possibility in unanalyzed matching method
callstrange(::Float64) = strangesin(x)
callstrange(::Number) = Core.compilerbarrier(:type, nothing) # trigger inference bail out
callstrange(::Any) = 1.0
callstrange_entry(x) = callstrange(x) # needs to be defined here because of world age
let interp = MTOverlayInterp(Set{Any}())
    matches = Compiler.findall(Tuple{typeof(callstrange),Any}, Compiler.method_table(interp))
    @test matches !== nothing
    @test Compiler.length(matches) == 3
    @test Base.infer_effects(callstrange_entry, (Any,); interp) |> !Compiler.is_nonoverlayed
    @test "Call inference reached maximally imprecise information: bailing on doing more abstract inference." in interp.meta
end

# but it should never apply for the native compilation
@test Base.infer_effects((Float64,)) do x
    strangesin(x)
end |> Compiler.is_nonoverlayed
@test Base.infer_effects((Any,)) do x
    @invoke strangesin(x::Float64)
end |> Compiler.is_nonoverlayed

# fallback to the internal method table
@test Base.return_types((Int,); interp=MTOverlayInterp()) do x
    cos(x)
end |> only === Float64
@test Base.return_types((Any,); interp=MTOverlayInterp()) do x
    @invoke cos(x::Float64)
end |> only === Float64

# not fully covered overlay method match
overlay_match(::Any) = nothing
@overlay OVERLAY_MT overlay_match(::Int) = missing
@test Base.return_types((Any,); interp=MTOverlayInterp()) do x
    overlay_match(x)
end |> only === Union{Nothing,Missing}

# overlay method should shadow the base method with the same signature,
# filtering it out from method match results
overlay_shadow_zero() = Any[]
overlay_shadow_zero(xs::Vector{Int}...) = Int[xs[i][j] for i=eachindex(xs) for j=eachindex(xs[i])]
@overlay OVERLAY_MT overlay_shadow_zero() = error()
@test Base.infer_return_type((Vector{Vector{Int}},); interp=MTOverlayInterp()) do x
    overlay_shadow_zero(x...)
end == Vector{Int}

# partial concrete evaluation
@test Base.return_types(; interp=MTOverlayInterp()) do
    isbitstype(Int) ? nothing : missing
end |> only === Nothing
Base.@assume_effects :terminates_locally function issue41694(x)
    res = 1
    0 ≤ x < 20 || error("bad fact")
    while x > 1
        res *= x
        x -= 1
    end
    return res
end
@test Base.return_types(; interp=MTOverlayInterp()) do
    issue41694(3) == 6 ? nothing : missing
end |> only === Nothing

# disable partial concrete evaluation when tainted by any overlayed call
Base.@assume_effects :total totalcall(f, args...) = f(args...)
@test Base.return_types(; interp=MTOverlayInterp()) do
    if totalcall(strangesin, 1.0) == cos(1.0)
        return nothing
    else
        return missing
    end
end |> only === Nothing

# override `:native_executable` to allow concrete-eval for overlay-ed methods
function myfactorial(x::Int, raise)
    res = 1
    0 ≤ x < 20 || raise("x is too big")
    Base.@assume_effects :terminates_locally while x > 1
        res *= x
        x -= 1
    end
    return res
end
raise_on_gpu1(x) = error(x)
@overlay OVERLAY_MT @noinline raise_on_gpu1(x) = #=do something with GPU=# error(x)
raise_on_gpu2(x) = error(x)
@consistent_overlay OVERLAY_MT @noinline raise_on_gpu2(x) = #=do something with GPU=# error(x)
raise_on_gpu3(x) = error(x)
@consistent_overlay OVERLAY_MT @noinline Base.@assume_effects :foldable raise_on_gpu3(x) = #=do something with GPU=# error_on_gpu(x)
cpu_factorial(x::Int) = myfactorial(x, error)
gpu_factorial1(x::Int) = myfactorial(x, raise_on_gpu1)
gpu_factorial2(x::Int) = myfactorial(x, raise_on_gpu2)
gpu_factorial3(x::Int) = myfactorial(x, raise_on_gpu3)

@test Base.infer_effects(cpu_factorial, (Int,); interp=MTOverlayInterp()) |> Compiler.is_nonoverlayed
@test Base.infer_effects(gpu_factorial1, (Int,); interp=MTOverlayInterp()) |> !Compiler.is_nonoverlayed
@test Base.infer_effects(gpu_factorial2, (Int,); interp=MTOverlayInterp()) |> Compiler.is_consistent_overlay
let effects = Base.infer_effects(gpu_factorial3, (Int,); interp=MTOverlayInterp())
    # check if `@consistent_overlay` together works with `@assume_effects`
    # N.B. the overlaid `raise_on_gpu3` is not :foldable otherwise since `error_on_gpu` is (intentionally) undefined.
    @test Compiler.is_consistent_overlay(effects)
    @test Compiler.is_foldable(effects)
end
@test Base.infer_return_type(; interp=MTOverlayInterp()) do
    Val(gpu_factorial2(3))
end == Val{6}
@test Base.infer_return_type(; interp=MTOverlayInterp()) do
    Val(gpu_factorial3(3))
end == Val{6}

# GPUCompiler needs accurate inference through kwfunc with the overlay of `Core.throw_inexacterror`
# https://github.com/JuliaLang/julia/issues/48097
@newinterp Issue48097Interp
@MethodTable ISSUE_48097_MT
Compiler.method_table(interp::Issue48097Interp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), ISSUE_48097_MT)
function Compiler.concrete_eval_eligible(interp::Issue48097Interp,
    @nospecialize(f), result::Compiler.MethodCallResult, arginfo::Compiler.ArgInfo, sv::Compiler.AbsIntState)
    ret = @invoke Compiler.concrete_eval_eligible(interp::Compiler.AbstractInterpreter,
        f::Any, result::Compiler.MethodCallResult, arginfo::Compiler.ArgInfo, sv::Compiler.AbsIntState)
    if ret === :semi_concrete_eval
        # disable semi-concrete interpretation
        return :none
    end
    return ret
end
@overlay ISSUE_48097_MT @noinline Core.throw_inexacterror(f::Symbol, ::Type{T}, val) where {T} = return
issue48097(; kwargs...) = return 42
@test fully_eliminated(; interp=Issue48097Interp(), retval=42) do
    issue48097(; a=1f0, b=1.0)
end

# https://github.com/JuliaLang/julia/issues/52938
@newinterp Issue52938Interp
@MethodTable ISSUE_52938_MT
Compiler.method_table(interp::Issue52938Interp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), ISSUE_52938_MT)
inner52938(x, types::Type, args...; kwargs...) = x
outer52938(x) = @inline inner52938(x, Tuple{}; foo=Ref(42), bar=1)
@test fully_eliminated(outer52938, (Any,); interp=Issue52938Interp(), retval=Argument(2))

# https://github.com/JuliaGPU/CUDA.jl/issues/2241
@newinterp Cuda2241Interp
@MethodTable CUDA_2241_MT
Compiler.method_table(interp::Cuda2241Interp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), CUDA_2241_MT)
inner2241(f, types::Type, args...; kwargs...) = nothing
function outer2241(f)
    @inline inner2241(f, Tuple{}; foo=Ref(42), bar=1)
    return nothing
end
# NOTE CUDA.jl overlays `throw_boundserror` in a way that causes effects, but these effects
#      are ignored for this call graph at the `@assume_effects` annotation on `typejoin`.
#      Here it's important to use `@consistent_overlay` to avoid tainting the `:nonoverlayed` bit.
const cuda_kernel_state = Ref{Any}()
@consistent_overlay CUDA_2241_MT @inline Base.throw_boundserror(A, I) =
    (cuda_kernel_state[] = (A, I); error())
@test fully_eliminated(outer2241, (Nothing,); interp=Cuda2241Interp(), retval=nothing)

# Should not concrete-eval overlayed methods in semi-concrete interpretation
@newinterp OverlaySinInterp
@MethodTable OVERLAY_SIN_MT
Compiler.method_table(interp::OverlaySinInterp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), OVERLAY_SIN_MT)
overlay_sin1(x) = error("Not supposed to be called.")
@overlay OVERLAY_SIN_MT overlay_sin1(x) = cos(x)
@overlay OVERLAY_SIN_MT Base.sin(x::Union{Float32,Float64}) = overlay_sin1(x)
let ir = Base.code_ircode(; interp=OverlaySinInterp()) do
        sin(0.)
    end |> only |> first
    ir.argtypes[1] = Tuple{}
    oc = Core.OpaqueClosure(ir)
    @test oc() == cos(0.)
end
@overlay OVERLAY_SIN_MT Base.sin(x::Union{Float32,Float64}) = @noinline overlay_sin1(x)
let ir = Base.code_ircode(; interp=OverlaySinInterp()) do
        sin(0.)
    end |> only |> first
    ir.argtypes[1] = Tuple{}
    oc = Core.OpaqueClosure(ir)
    @test oc() == cos(0.)
end
_overlay_sin2(x) = error("Not supposed to be called.")
@overlay OVERLAY_SIN_MT _overlay_sin2(x) = cos(x)
overlay_sin2(x) = _overlay_sin2(x)
@overlay OVERLAY_SIN_MT Base.sin(x::Union{Float32,Float64}) = @noinline overlay_sin2(x)
let ir = Base.code_ircode(; interp=OverlaySinInterp()) do
        sin(0.)
    end |> only |> first
    ir.argtypes[1] = Tuple{}
    oc = Core.OpaqueClosure(ir)
    @test oc() == cos(0.)
end

# AbstractLattice
# ===============

using Core: SlotNumber, Argument
using .Compiler: slot_id, tmerge_fast_path
import .Compiler:
    AbstractLattice, BaseInferenceLattice, IPOResultLattice, InferenceLattice,
    widenlattice, is_valid_lattice_norec, typeinf_lattice, ipo_lattice, optimizer_lattice,
    widenconst, tmeet, tmerge, ⊑, abstract_eval_special_value, widenreturn

@newinterp TaintInterpreter
struct TaintLattice{PL<:AbstractLattice} <: Compiler.AbstractLattice
    parent::PL
end
Compiler.widenlattice(𝕃::TaintLattice) = 𝕃.parent
Compiler.is_valid_lattice_norec(::TaintLattice, @nospecialize(elm)) = isa(elm, Taint)

struct InterTaintLattice{PL<:AbstractLattice} <: Compiler.AbstractLattice
    parent::PL
end
Compiler.widenlattice(𝕃::InterTaintLattice) = 𝕃.parent
Compiler.is_valid_lattice_norec(::InterTaintLattice, @nospecialize(elm)) = isa(elm, InterTaint)

const AnyTaintLattice{L} = Union{TaintLattice{L},InterTaintLattice{L}}

Compiler.typeinf_lattice(::TaintInterpreter) = InferenceLattice(TaintLattice(BaseInferenceLattice.instance))
Compiler.ipo_lattice(::TaintInterpreter) = InferenceLattice(InterTaintLattice(IPOResultLattice.instance))
Compiler.optimizer_lattice(::TaintInterpreter) = InterTaintLattice(SimpleInferenceLattice.instance)

struct Taint
    typ
    slots::BitSet
    function Taint(@nospecialize(typ), slots::BitSet)
        if typ isa Taint
            slots = typ.slots ∪ slots
            typ = typ.typ
        end
        return new(typ, slots)
    end
end
Taint(@nospecialize(typ), id::Int) = Taint(typ, push!(BitSet(), id))
function Base.:(==)(a::Taint, b::Taint)
    return a.typ == b.typ && a.slots == b.slots
end

struct InterTaint
    typ
    slots::BitSet
    function InterTaint(@nospecialize(typ), slots::BitSet)
        if typ isa InterTaint
            slots = typ.slots ∪ slots
            typ = typ.typ
        end
        return new(typ, slots)
    end
end
InterTaint(@nospecialize(typ), id::Int) = InterTaint(typ, push!(BitSet(), id))
function Base.:(==)(a::InterTaint, b::InterTaint)
    return a.typ == b.typ && a.slots == b.slots
end

const AnyTaint = Union{Taint, InterTaint}

function Compiler.tmeet(𝕃::AnyTaintLattice, @nospecialize(v), @nospecialize(t::Type))
    T = isa(𝕃, TaintLattice) ? Taint : InterTaint
    if isa(v, T)
        v = v.typ
    end
    return tmeet(widenlattice(𝕃), v, t)
end
function Compiler.tmerge(𝕃::AnyTaintLattice, @nospecialize(typea), @nospecialize(typeb))
    r = tmerge_fast_path(𝕃, typea, typeb)
    r !== nothing && return r
    # type-lattice for Taint
    T = isa(𝕃, TaintLattice) ? Taint : InterTaint
    if isa(typea, T)
        if isa(typeb, T)
            return T(
                tmerge(widenlattice(𝕃), typea.typ, typeb.typ),
                typea.slots ∪ typeb.slots)
        else
            typea = typea.typ
        end
    elseif isa(typeb, T)
        typeb = typeb.typ
    end
    return tmerge(widenlattice(𝕃), typea, typeb)
end
function Compiler.:⊑(𝕃::AnyTaintLattice, @nospecialize(typea), @nospecialize(typeb))
    T = isa(𝕃, TaintLattice) ? Taint : InterTaint
    if isa(typea, T)
        if isa(typeb, T)
            typea.slots ⊆ typeb.slots || return false
            return ⊑(widenlattice(𝕃), typea.typ, typeb.typ)
        end
        typea = typea.typ
    elseif isa(typeb, T)
        return false
    end
    return ⊑(widenlattice(𝕃), typea, typeb)
end
Compiler.widenconst(taint::AnyTaint) = widenconst(taint.typ)

function Compiler.abstract_eval_special_value(interp::TaintInterpreter,
    @nospecialize(e), sstate::Compiler.StatementState, sv::Compiler.InferenceState)
    ret = @invoke Compiler.abstract_eval_special_value(interp::Compiler.AbstractInterpreter,
        e::Any, sstate::Compiler.StatementState, sv::Compiler.InferenceState)
    if isa(e, SlotNumber) || isa(e, Argument)
        return Taint(ret, slot_id(e))
    end
    return ret
end

function Compiler.widenreturn(𝕃::InferenceLattice{<:InterTaintLattice}, @nospecialize(rt), @nospecialize(bestguess), nargs::Int, slottypes::Vector{Any}, changes::Compiler.VarTable)
    if isa(rt, Taint)
        return InterTaint(rt.typ, BitSet((id for id in rt.slots if id ≤ nargs)))
    end
    return Compiler.widenreturn(widenlattice(𝕃), rt, bestguess, nargs, slottypes, changes)
end

@test Compiler.tmerge(typeinf_lattice(TaintInterpreter()), Taint(Int, 1), Taint(Int, 2)) == Taint(Int, BitSet(1:2))

# code_typed(ifelse, (Bool, Int, Int); interp=TaintInterpreter())

# External lattice without `Conditional`

import .Compiler:
    AbstractLattice, ConstsLattice, PartialsLattice, InferenceLattice,
    typeinf_lattice, ipo_lattice, optimizer_lattice

@newinterp NonconditionalInterpreter
Compiler.typeinf_lattice(::NonconditionalInterpreter) = InferenceLattice(PartialsLattice(ConstsLattice()))
Compiler.ipo_lattice(::NonconditionalInterpreter) = InferenceLattice(PartialsLattice(ConstsLattice()))
Compiler.optimizer_lattice(::NonconditionalInterpreter) = PartialsLattice(ConstsLattice())

@test Base.return_types((Any,); interp=NonconditionalInterpreter()) do x
    c = isa(x, Int) || isa(x, Float64)
    if c
        return x
    else
        return nothing
    end
end |> only === Any

# CallInfo × inlining
# ===================

@newinterp NoinlineInterpreter
noinline_modules(interp::NoinlineInterpreter) = interp.meta::Set{Module}

import .Compiler: CallInfo

struct NoinlineCallInfo <: CallInfo
    info::CallInfo # wrapped call
end
Compiler.add_edges_impl(edges::Vector{Any}, info::NoinlineCallInfo) = Compiler.add_edges!(edges, info.info)
Compiler.nsplit_impl(info::NoinlineCallInfo) = Compiler.nsplit(info.info)
Compiler.getsplit_impl(info::NoinlineCallInfo, idx::Int) = Compiler.getsplit(info.info, idx)
Compiler.getresult_impl(info::NoinlineCallInfo, idx::Int) = Compiler.getresult(info.info, idx)

function Compiler.abstract_call(interp::NoinlineInterpreter, arginfo::Compiler.ArgInfo, si::Compiler.StmtInfo,
    vtypes::Union{Compiler.VarTable,Nothing}, sv::Compiler.InferenceState, max_methods::Int)
    ret = @invoke Compiler.abstract_call(interp::Compiler.AbstractInterpreter,
        arginfo::Compiler.ArgInfo, si::Compiler.StmtInfo, vtypes::Union{Compiler.VarTable,Nothing}, sv::Compiler.InferenceState, max_methods::Int)
    return Compiler.Future{Compiler.CallMeta}(ret, interp, sv) do ret, interp, sv
        if sv.mod in noinline_modules(interp)
            (;rt, exct, effects, info) = ret
            return Compiler.CallMeta(rt, exct, effects, NoinlineCallInfo(info))
        end
        return ret
    end
end
function Compiler.src_inlining_policy(interp::NoinlineInterpreter,
    @nospecialize(src), @nospecialize(info::CallInfo), stmt_flag::UInt32)
    if isa(info, NoinlineCallInfo)
        return false
    end
    return @invoke Compiler.src_inlining_policy(interp::Compiler.AbstractInterpreter,
        src::Any, info::CallInfo, stmt_flag::UInt32)
end

@inline function inlined_usually(x, y, z)
    return x * y + z
end
foo_split(x::Float64) = 1
foo_split(x::Int) = 2

# check if the inlining algorithm works as expected
let src = code_typed1((Float64,Float64,Float64)) do x, y, z
        inlined_usually(x, y, z)
    end
    @test count(isinvoke(:inlined_usually), src.code) == 0
    @test count(iscall((src, inlined_usually)), src.code) == 0
end
let NoinlineModule = Module()
    OtherModule = Module()
    main_func(x, y, z) = inlined_usually(x, y, z)
    @eval NoinlineModule noinline_func(x, y, z) = $inlined_usually(x, y, z)
    @eval OtherModule other_func(x, y, z) = $inlined_usually(x, y, z)
    @eval NoinlineModule bar_split_error() = $foo_split(Core.compilerbarrier(:type, nothing))

    interp = NoinlineInterpreter(Set((NoinlineModule,)))

    # this anonymous function's context is Main -- it should be inlined as usual
    let src = code_typed1(main_func, (Float64,Float64,Float64); interp)
        @test count(isinvoke(:inlined_usually), src.code) == 0
        @test count(iscall((src, inlined_usually)), src.code) == 0
    end

    # it should work for cached results
    method = only(methods(inlined_usually, (Float64,Float64,Float64,)))
    mi = Compiler.specialize_method(method, Tuple{typeof(inlined_usually),Float64,Float64,Float64}, Core.svec())
    @test Compiler.haskey(Compiler.code_cache(interp), mi)
    let src = code_typed1(main_func, (Float64,Float64,Float64); interp)
        @test count(isinvoke(:inlined_usually), src.code) == 0
        @test count(iscall((src, inlined_usually)), src.code) == 0
    end

    # now the context module is `NoinlineModule` -- it should not be inlined
    let src = code_typed1(NoinlineModule.noinline_func, (Float64,Float64,Float64); interp)
        @test count(isinvoke(:inlined_usually), src.code) == 1
        @test count(iscall((src, inlined_usually)), src.code) == 0
    end

    # the context module is totally irrelevant -- it should be inlined as usual
    let src = code_typed1(OtherModule.other_func, (Float64,Float64,Float64); interp)
        @test count(isinvoke(:inlined_usually), src.code) == 0
        @test count(iscall((src, inlined_usually)), src.code) == 0
    end

    let src = code_typed1(NoinlineModule.bar_split_error)
        @test count(iscall((src, foo_split)), src.code) == 0
        @test count(iscall((src, Core.throw_methoderror)), src.code) > 0
    end
end

# custom inferred data
# ====================

@newinterp CustomDataInterp
struct CustomDataInterpToken end
Compiler.cache_owner(::CustomDataInterp) = CustomDataInterpToken()
struct CustomData
    inferred
    CustomData(@nospecialize inferred) = new(inferred)
end
function Compiler.transform_result_for_cache(
    interp::CustomDataInterp, result::Compiler.InferenceResult, edges::Core.SimpleVector)
    inferred_result = @invoke Compiler.transform_result_for_cache(
        interp::Compiler.AbstractInterpreter, result::Compiler.InferenceResult, edges::Core.SimpleVector)
    return CustomData(inferred_result)
end
function Compiler.src_inlining_policy(
    interp::CustomDataInterp, @nospecialize(src), @nospecialize(info::Compiler.CallInfo),
    stmt_flag::UInt32)
    if src isa CustomData
        src = src.inferred
    end
    return @invoke Compiler.src_inlining_policy(
        interp::Compiler.AbstractInterpreter, src::Any, info::Compiler.CallInfo,
        stmt_flag::UInt32)
end
Compiler.retrieve_ir_for_inlining(cached_result::CodeInstance, src::CustomData) =
    Compiler.retrieve_ir_for_inlining(cached_result, src.inferred)
Compiler.retrieve_ir_for_inlining(mi::MethodInstance, src::CustomData, preserve_local_sources::Bool) =
    Compiler.retrieve_ir_for_inlining(mi, src.inferred, preserve_local_sources)
let src = code_typed((Int,); interp=CustomDataInterp()) do x
        return (@noinline sin(x)) + (@noinline cos(x))
    end |> only |> first
    @test count(isinvoke(:sin), src.code) == 1
    @test count(isinvoke(:cos), src.code) == 1
    @test_broken count(isinvoke(:+), src.code) == 0
end

# ephemeral cache mode
@newinterp DebugInterp #=ephemeral_cache=#true
func_ext_cache1(a) = func_ext_cache2(a) * cos(a)
func_ext_cache2(a) = sin(a)
let interp = DebugInterp()
    @test Base.infer_return_type(func_ext_cache1, (Float64,); interp) === Float64
    @test isdefined(interp, :global_cache)
    found = false
    for (mi, codeinst) in interp.global_cache.dict
        if mi.def.name === :func_ext_cache2
            found = true
            break
        end
    end
    @test found
end

@newinterp InvokeInterp
struct InvokeOwner end
global codegen::IdDict{CodeInstance, CodeInfo} = IdDict{CodeInstance, CodeInfo}()
Compiler.cache_owner(::InvokeInterp) = InvokeOwner()
Compiler.codegen_cache(::InvokeInterp) = codegen
let interp = InvokeInterp()
    source_mode = Compiler.SOURCE_MODE_ABI
    f = (+)
    args = (1, 1)
    mi = @ccall jl_method_lookup(Any[f, args...]::Ptr{Any}, (1+length(args))::Csize_t, Base.tls_world_age()::Csize_t)::Ref{Core.MethodInstance}
    ci = Compiler.typeinf_ext_toplevel(interp, mi, source_mode)
    @test invoke(f, ci, args...) == 2

    f = error
    args = "test"
    mi = @ccall jl_method_lookup(Any[f, args...]::Ptr{Any}, (1+length(args))::Csize_t, Base.tls_world_age()::Csize_t)::Ref{Core.MethodInstance}
    ci = Compiler.typeinf_ext_toplevel(interp, mi, source_mode)
    result = nothing
    try
        invoke(f, ci, args...)
    catch e
        result = sprint(Base.show_backtrace, catch_backtrace())
    end
    @test isa(result, String)
    @test contains(result, "[1] error(::Char, ::Char, ::Char, ::Char)")
end

# Global publication and per-interpreter source/ABI capability are selected separately,
# including when a winner appears while inference is running.
@newinterp SourceModeWinnerInterp
global source_mode_codegen::IdDict{CodeInstance,CodeInfo} = IdDict{CodeInstance,CodeInfo}()
Compiler.codegen_cache(::SourceModeWinnerInterp) = source_mode_codegen

source_mode_inadequate_winner(x::Int) = x + 1
let interp = SourceModeWinnerInterp()
    mi = Base.method_instance(source_mode_inadequate_winner, (Int,))
    inadequate = Core.CodeInstance(mi, Compiler.cache_owner(interp), Int, Any,
        nothing, nothing, zero(Int32), UInt(1), typemax(UInt), zero(UInt32),
        nothing, nothing, Core.svec())
    Compiler.code_cache(interp)[mi] = inadequate
    @test !Compiler.ci_has_source(interp, inadequate)

    ci = Compiler.typeinf_ext(interp, mi, Compiler.SOURCE_MODE_ABI)
    @test ci !== inadequate
    @test Compiler.ci_has_source(interp, ci)
    @test iszero(@ccall jl_mi_cache_has_ci(mi::Any, ci::Any)::Cint)
    # The capability-blind global winner remains unique. The source-capable result
    # is session-local and can be reused by this interpreter without allowing it to
    # escape into the global executable cache.
    @test get(Compiler.code_cache(interp), mi, nothing) === inadequate
    @test Compiler.typeinf_ext(interp, mi, Compiler.SOURCE_MODE_ABI) === ci
    overlay = Compiler.OverlayCodeCache(
        Compiler.code_cache(interp), Compiler.InferenceCache())
    valid_worlds = Compiler.WorldRange(interp.world)
    @test Compiler.find_cached_ci(interp, overlay, mi,
        valid_worlds, Compiler.SOURCE_MODE_ABI) === nothing
    @test Compiler.find_local_cached_ci(interp, mi,
        valid_worlds, Compiler.SOURCE_MODE_ABI) === ci

    # JIT compilation uses the local source to compile the ABI-equivalent global
    # winner; the local CI itself remains outside the executable cache.
    @test Compiler.typeinf_ext_toplevel(
        interp, mi, Compiler.SOURCE_MODE_ABI) === inadequate
    @test Compiler.ci_has_invoke(inadequate)
    @test iszero(@ccall jl_mi_cache_has_ci(mi::Any, ci::Any)::Cint)
    # `inadequate` lives in the native `mi.cache` chain (an `InternalCodeCache`
    # with a custom owner), which already roots it for the process lifetime, so
    # the JIT handoff must not have leaked a redundant global root for it.
    @test (@ccall jl_as_global_root(inadequate::Any, 0::Cint)::Ptr{Cvoid}) == C_NULL
end

# A source-inadequate winner with a different return ABI cannot suppress normal
# publication. The completed CI is globally inserted and promoted before JIT use.
source_mode_nonequivalent_winner(x::Int) = x + 1
let interp = SourceModeWinnerInterp()
    mi = Base.method_instance(source_mode_nonequivalent_winner, (Int,))
    inadequate = Core.CodeInstance(mi, Compiler.cache_owner(interp), Any, Any,
        nothing, nothing, zero(Int32), UInt(1), typemax(UInt), zero(UInt32),
        nothing, nothing, Core.svec())
    Compiler.code_cache(interp)[mi] = inadequate

    ci = Compiler.typeinf_ext_toplevel(interp, mi, Compiler.SOURCE_MODE_ABI)
    @test ci !== inadequate
    @test ci.rettype === Int
    @test !iszero(@ccall jl_mi_cache_has_ci(mi::Any, ci::Any)::Cint)
    @test ci.max_world == typemax(UInt)

    @eval source_mode_world_bump_62338() = nothing
    newer = SourceModeWinnerInterp(; world=Base.get_world_counter())
    @test Compiler.typeinf_ext_toplevel(
        newer, mi, Compiler.SOURCE_MODE_ABI) === ci
end

# Equivalent-winner selection also goes through the cache abstraction rather than
# assuming that every executable cache is the native MethodInstance chain.
@newinterp SourceModeEphemeralInterp true
global source_mode_ephemeral_codegen::IdDict{CodeInstance,CodeInfo} =
    IdDict{CodeInstance,CodeInfo}()
Compiler.codegen_cache(::SourceModeEphemeralInterp) = source_mode_ephemeral_codegen
source_mode_ephemeral_winner(x::Int) = x + 1
let interp = SourceModeEphemeralInterp()
    mi = Base.method_instance(source_mode_ephemeral_winner, (Int,))
    winner = Core.CodeInstance(mi, Compiler.cache_owner(interp), Int, Any,
        nothing, nothing, zero(Int32), UInt(1), typemax(UInt), zero(UInt32),
        nothing, nothing, Core.svec())
    Compiler.code_cache(interp)[mi] = winner

    @test Compiler.typeinf_ext_toplevel(
        interp, mi, Compiler.SOURCE_MODE_ABI) === winner
    @test Compiler.code_cache(interp)[mi] === winner
    @test Compiler.ci_has_invoke(winner)
    # The JIT retains raw pointers to the emitted `winner` for the lifetime of
    # the process, and this ephemeral cache dies with `interp`, so the JIT
    # handoff must have promoted `winner` to a global root (`jit_cache_root!`).
    @test (@ccall jl_as_global_root(winner::Any, 0::Cint)::Ptr{Cvoid}) != C_NULL
    empty!(source_mode_ephemeral_codegen)
end

const source_mode_interp_ref = Ref{Any}()
const source_mode_winner_ref = Ref{Any}()
@generated function source_mode_publish_winner()
    interp = source_mode_interp_ref[]::SourceModeWinnerInterp
    winner = source_mode_winner_ref[]::Core.CodeInstance
    Compiler.code_cache(interp)[winner.def] = winner
    return :(nothing)
end
source_mode_qualifying_winner(x::Int) = (source_mode_publish_winner(); x + 1)
let interp = SourceModeWinnerInterp()
    mi = Base.method_instance(source_mode_qualifying_winner, (Int,))
    winner = Core.CodeInstance(mi, Compiler.cache_owner(interp), Int, Any,
        nothing, nothing, zero(Int32), UInt(1), typemax(UInt), zero(UInt32),
        nothing, nothing, Core.svec())
    source_mode_codegen[winner] = Compiler.retrieve_code_info(mi, interp.world)
    source_mode_interp_ref[] = interp
    source_mode_winner_ref[] = winner

    ci = Compiler.typeinf_ext(interp, mi, Compiler.SOURCE_MODE_ABI)
    @test ci === winner
    local_results = [
        entry for entry in Compiler.get_inference_cache(interp).results
        if entry isa Compiler.LocalInferenceResult && entry.result.linfo === mi
    ]
    @test length(local_results) == 1
    local_result = only(local_results)
    @test local_result.result.replacement_ci === winner
    @test iszero(@ccall jl_mi_cache_has_ci(mi::Any, local_result.result.ci::Any)::Cint)
    source_mode_interp_ref[] = nothing
    source_mode_winner_ref[] = nothing
    empty!(source_mode_codegen)
end

# The executable cache for a custom interpreter remains CodeInstance-only even when
# inference also retains completed local source/proof entries.
using REPL.REPLCompletions: completions
@newinterp OverlayCacheInterp true
@test let
    interp = OverlayCacheInterp()
    # `completions` has a call graph deep enough to exercise repeated global and local
    # cache lookups for the same MethodInstances.
    f = completions
    args = ("", 0)
    mi = @ccall jl_method_lookup(Any[f, args...]::Ptr{Any}, (1+length(args))::Csize_t,
        Base.tls_world_age()::Csize_t)::Ref{Core.MethodInstance}
    Compiler.typeinf_ext_toplevel(interp, mi, Compiler.SOURCE_MODE_NOT_REQUIRED)
    true
end


# `invoke(f, ci, args...)` with a `CodeInstance` from another `cache_owner` must keep
# invoking exactly that `CodeInstance`, even once the native cache holds code for the
# same `MethodInstance` (which the inlining pass otherwise prefers as invoke target).
@newinterp OwnerSwapInterp
@MethodTable OWNER_SWAP_MT
Compiler.method_table(interp::OwnerSwapInterp) = Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), OWNER_SWAP_MT)
global owner_swap_codegen::IdDict{CodeInstance,CodeInfo} = IdDict{CodeInstance,CodeInfo}()
Compiler.codegen_cache(::OwnerSwapInterp) = owner_swap_codegen
owner_swap_leaf(x::Int) = x + 1
@overlay OWNER_SWAP_MT owner_swap_leaf(x::Int) = x - 1
owner_swap_target(x::Int) = owner_swap_leaf(x) * 10
const owner_swap_ci = let interp = OwnerSwapInterp()
    @test owner_swap_target(2) == 30 # populate the native cache first
    mi = Base.method_instance(owner_swap_target, (Int,))
    Compiler.typeinf_ext_toplevel(interp, mi, Compiler.SOURCE_MODE_ABI)
end
@test owner_swap_ci.owner === OwnerSwapInterp
@test invoke(owner_swap_target, owner_swap_ci, 2) == 10
owner_swap_wrapper(x::Int) = invoke(owner_swap_target, owner_swap_ci, x)
@test Base.return_types(owner_swap_wrapper, (Int,)) == Any[Int]
let src = code_typed1(owner_swap_wrapper, (Int,))
    @test count(src.code) do @nospecialize stmt
        isexpr(stmt, :invoke) && stmt.args[1] === owner_swap_ci
    end == 1
end
@test owner_swap_wrapper(2) == 10
# `invoke` refuses to compile a foreign-owned `CodeInstance` through the native method and
# throws instead, so unlike a native one the call is not nothrow
@test Base.infer_exception_type(owner_swap_wrapper, (Int,)) === ErrorException
@test !Compiler.is_nothrow(Base.infer_effects(owner_swap_wrapper, (Int,)))

# A CodeInstance owned by another interpreter that is `invoke`d from natively compiled
# code must be emitted from its own source, not replaced by a native inference of its
# MethodInstance (the two bodies differ here through an overlay method table), even when
# its owner keeps it in an ephemeral cache that is not on the `mi.cache` chain.
@MethodTable FOREIGN_INVOKE_MT
foreign_invoke_leaf(x::Int) = x + 1
@overlay FOREIGN_INVOKE_MT foreign_invoke_leaf(x::Int) = x - 1
foreign_invoke_target(x::Int) = foreign_invoke_leaf(x) * 10
@newinterp ForeignInvokeEphInterp true
Compiler.method_table(interp::ForeignInvokeEphInterp) =
    Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), FOREIGN_INVOKE_MT)
const foreign_invoke_eph_codegen = IdDict{CodeInstance,CodeInfo}()
Compiler.codegen_cache(::ForeignInvokeEphInterp) = foreign_invoke_eph_codegen
const foreign_invoke_eph_ci = let interp = ForeignInvokeEphInterp()
    mi = Base.method_instance(foreign_invoke_target, (Int,))
    # inferred but not compiled: the native JIT has to emit it when compiling the caller
    Compiler.typeinf_ext_toplevel(interp, mi, Compiler.SOURCE_MODE_NOT_REQUIRED)
end
foreign_invoke_eph_caller(x::Int) = invoke(foreign_invoke_target, foreign_invoke_eph_ci, x)
@test iszero(@ccall jl_mi_cache_has_ci(Compiler.get_ci_mi(foreign_invoke_eph_ci)::Any,
                                       foreign_invoke_eph_ci::Any)::Cint)
@test foreign_invoke_eph_caller(2) == 10
@test foreign_invoke_eph_ci.invoke != C_NULL
@test foreign_invoke_target(2) == 30

# When the foreign CodeInstance has no retrievable source, the caller must not run the
# native body in its place either: the call fails as `invoke(f, ci, args...)` does.
@newinterp ForeignInvokeOwnedInterp
Compiler.method_table(interp::ForeignInvokeOwnedInterp) =
    Compiler.OverlayMethodTable(Compiler.get_inference_world(interp), FOREIGN_INVOKE_MT)
const foreign_invoke_owned_codegen = IdDict{CodeInstance,CodeInfo}()
Compiler.codegen_cache(::ForeignInvokeOwnedInterp) = foreign_invoke_owned_codegen
const foreign_invoke_owned_ci = let interp = ForeignInvokeOwnedInterp()
    mi = Base.method_instance(foreign_invoke_target, (Int,))
    Compiler.typeinf_ext_toplevel(interp, mi, Compiler.SOURCE_MODE_NOT_REQUIRED)
end
@test !iszero(@ccall jl_mi_cache_has_ci(Compiler.get_ci_mi(foreign_invoke_owned_ci)::Any,
                                        foreign_invoke_owned_ci::Any)::Cint)
@atomic foreign_invoke_owned_ci.inferred = nothing
empty!(foreign_invoke_owned_codegen)
foreign_invoke_owned_caller(x::Int) = invoke(foreign_invoke_target, foreign_invoke_owned_ci, x)
@test_throws "Failed to invoke or compile external codeinst" foreign_invoke_owned_caller(2)
@test_throws "Failed to invoke or compile external codeinst" invoke(foreign_invoke_target, foreign_invoke_owned_ci, 2)
@test foreign_invoke_target(2) == 30

# A foreign target whose MethodInstance needs its static parameters at run time takes
# the `needsparams` path of `emit_invoke`, which used to dispatch on the MethodInstance
# (running the native body). Such a CodeInstance has no valid ABI for the drain loops
# (`has_valid_abi_sparams`), so it cannot be given code and the call must fail instead.
foreign_invoke_sp_target(x::Vector{T}) where {T} = foreign_invoke_leaf(length(x)) * 10
const foreign_invoke_sp_ci = let interp = ForeignInvokeEphInterp()
    mi = Base.method_instance(foreign_invoke_sp_target, (Vector,))
    @test !Compiler.has_valid_abi_sparams(mi)
    Compiler.typeinf_ext_toplevel(interp, mi, Compiler.SOURCE_MODE_ABI)
end
foreign_invoke_sp_caller(x::Vector) = invoke(foreign_invoke_sp_target, foreign_invoke_sp_ci, x)
let src = only(Base.code_typed(foreign_invoke_sp_caller, (Vector{Int},)))[1]
    # the edge is the foreign CodeInstance itself
    @test any(s -> Meta.isexpr(s, :invoke) && s.args[1] === foreign_invoke_sp_ci, src.code)
end
@test foreign_invoke_sp_ci.invoke == C_NULL
@test_throws "Failed to invoke or compile external codeinst" foreign_invoke_sp_caller([1, 2])
@test foreign_invoke_sp_target([1, 2]) == 30

# `Core.GeneratedFunctionTransform` infers the call with the interpreter returned by its
# factory and invokes the resulting `CodeInstance`; the inner `CodeInstance` is an edge of
# the generated body, so redefinitions regenerate it.
@eval function gft_overdub(f, args...)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform((world::UInt) -> OwnerSwapInterp(; world))))
end
@test fieldnames(Core.GeneratedFunctionTransform) === (:gen,)
gft_target(x::Int) = owner_swap_leaf(x) * 10
@test gft_target(2) == 30
@test gft_overdub(gft_target, 2) == 10
gft_caller(x::Int) = gft_overdub(gft_target, x) + 1
@test Base.return_types(gft_caller, (Int,)) == Any[Int]
let src = code_typed1(gft_caller, (Int,))
    @test count(src.code) do @nospecialize stmt
        isexpr(stmt, :invoke) && stmt.args[1] isa CodeInstance && stmt.args[1].owner === OwnerSwapInterp
    end == 1
end
@test gft_caller(2) == 11
gft_target(x::Int) = owner_swap_leaf(x) * 100
@test gft_overdub(gft_target, 2) == 100
@test gft_caller(2) == 101
@test_throws "no unique method" gft_overdub(gft_target, "not an Int")
# varargs are splatted back out: zero, one and several trailing arguments
const gft_va_zero = Ref(0)  # keeps the zero-argument call from being constant folded
gft_va() = owner_swap_leaf(gft_va_zero[])
gft_va(x::Int) = owner_swap_leaf(x)
gft_va(x::Int, y::Int, z::Int) = owner_swap_leaf(x) + y * z
@test gft_overdub(gft_va) == -1
@test gft_overdub(gft_va, 5) == 4
@test gft_overdub(gft_va, 5, 2, 3) == 10
gft_va_caller(x::Int) = gft_overdub(gft_va) + gft_overdub(gft_va, x) + gft_overdub(gft_va, x, x, x)
@test gft_va_caller(2) == -1 + 1 + 5
let src = code_typed1(gft_va_caller, (Int,))
    @test count(src.code) do @nospecialize stmt
        isexpr(stmt, :invoke) && stmt.args[1] isa CodeInstance && stmt.args[1].owner === OwnerSwapInterp
    end == 3
    @test !any(src.code) do @nospecialize stmt
        isexpr(stmt, :call) && stmt.args[1] === GlobalRef(Core, :_apply_iterate)
    end
end
# a fixed-arity generated method works the same way
@eval function gft_overdub1(f, x)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform((world::UInt) -> OwnerSwapInterp(; world))))
end
@test gft_overdub1(gft_target, 2) == 100
# an anonymous argument has no slot name to reuse
@eval function gft_overdub4(f, ::Int)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform((world::UInt) -> OwnerSwapInterp(; world))))
end
@test gft_overdub4(gft_target, 2) == 100
# when the varargs are the only argument, the callee is the first of them
@eval function gft_va_only(args...)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform((world::UInt) -> OwnerSwapInterp(; world))))
end
@test gft_va_only(gft_target, 2) == 100
@test gft_va_only(gft_va) == -1
@test gft_va_only(gft_va, 5, 2, 3) == 10
gft_va_only_caller(x::Int) = gft_va_only(gft_target, x) + gft_va_only(gft_va) + gft_va_only(gft_va, x, x, x)
@test gft_va_only_caller(2) == 100 - 1 + 5
let src = code_typed1(gft_va_only_caller, (Int,))
    @test count(src.code) do @nospecialize stmt
        isexpr(stmt, :invoke) && stmt.args[1] isa CodeInstance && stmt.args[1].owner === OwnerSwapInterp
    end == 3
    @test !any(src.code) do @nospecialize stmt
        isexpr(stmt, :call) && stmt.args[1] === GlobalRef(Core, :_apply_iterate)
    end
end
# there must be a callee
@test_throws "must be called with the function to call" gft_va_only()
# `gen` must return an interpreter for the requesting world with its own cache
for (name, gen) in ((:gft_bad_type, (world::UInt) -> world),
                    (:gft_bad_owner, (world::UInt) -> Compiler.NativeInterpreter(world)),
                    (:gft_bad_world, (world::UInt) -> OwnerSwapInterp(; world = world - 1)))
    @eval function $name(f, args...)
        $(Expr(:meta, :generated_only))
        $(Expr(:meta, :generated, Core.GeneratedFunctionTransform(gen)))
    end
end
@test_throws "must return a `Compiler.AbstractInterpreter`, got UInt" gft_bad_type(gft_target, 2)
@test_throws "must define a `Compiler.cache_owner` other than `nothing`" gft_bad_owner(gft_target, 2)
@test_throws "it must infer in the world it is given" gft_bad_world(gft_target, 2)
# keyword arguments are refused: the method holding the body receives them first
@eval function gft_overdub_kw(f, args...; k = 1)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform((world::UInt) -> OwnerSwapInterp(; world))))
end
@test_throws "keyword arguments are not supported" gft_overdub_kw(gft_target, 2)
@test_throws "keyword arguments are not supported" gft_overdub_kw(gft_target, 2; k = 3)
# recursion through the generated method: the transformed body of one callee reaches the
# generated method for another, whose transformed body reaches the first. The runtime
# allows one re-entry of a specialization that is already being generated and refuses the
# second instead of recursing; that call site is compiled without knowledge of its result,
# and at run time it finds the finished body.
const gft_gen_count = Ref(0)
@eval function gft_overdub5(f, args...)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform(
        (world::UInt) -> (gft_gen_count[] += 1; OwnerSwapInterp(; world)))))
end
# passing the generated function as its own callee is ordinary nested generation:
# `gft_overdub5(gft_overdub5, f, x)` transforms the call `gft_overdub5(f, x)`, a
# different specialization, which is generated in turn
@test gft_overdub5(gft_overdub5, gft_target, 2) == 100
@test gft_gen_count[] == 2
@test gft_overdub5(gft_overdub5, gft_target, 2) == 100
@test gft_gen_count[] == 2
gft_gen_count[] = 0
gft_ping(n::Int) = n <= 0 ? 0 : gft_overdub5(gft_pong, n - 1) + 1
gft_pong(n::Int) = n <= 0 ? 0 : gft_overdub5(gft_ping, n - 1) + 1
@test gft_overdub5(gft_ping, 4) == 4
@test gft_gen_count[] == 4       # `ping` and `pong`: each generated once and re-entered once
gft_self(n::Int) = n <= 0 ? 0 : gft_overdub5(gft_self, n - 1) + 1
gft_gen_count[] = 0
@test gft_overdub5(gft_self, 3) == 3
@test gft_gen_count[] == 2       # generated once and re-entered once
# a callee calling itself directly is an ordinary inference cycle, not a generator cycle
gft_fact(n::Int) = n <= 1 ? 1 : n * gft_fact(n - 1)
gft_gen_count[] = 0
@test gft_overdub5(gft_fact, 5) == 120
@test gft_gen_count[] == 1
