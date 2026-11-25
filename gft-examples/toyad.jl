# ToyAD: a minimal Mooncake-style reverse-mode AD built on `Core.GeneratedFunctionTransform`.
#
# `rrule!!(f, x...)` returns `(f(x...), pb)`, and `pb(ȳ)` returns the tangents of `(f, x...)`.
# Hand-written methods of `rrule!!` are the primitives. Its fallback method and the call of a
# `Pullback` are generated methods whose bodies `ADInterp` derives from the optimized typed
# IR of the primal: the forward pass and the reverse pass. As in Mooncake.jl, each is typed
# `IRCode` that the tool builds statement by statement from the primal's `IRCode`; no source
# is generated and nothing is lowered or inferred from source. The generator names the
# signature each is derived from; the compiler looks it up, infers it and records the
# dependency, and the tool only maps IR to IR in `transform_ir`. The compiler then types what is left
# untyped, optimizes it and publishes it as a CodeInstance owned by `ADInterp` on the
# generated method's own MethodInstance, as it publishes inferred code.
#
# Subset: straight-line code over `Float64`s. Anything else is an error at derivation time.
module ToyAD

const CC = Base.Compiler
using Core: CodeInfo, CodeInstance, MethodInstance, SSAValue, Argument, ReturnNode
using .CC: IRCode

# ---- tangents ----
struct NoTangent end
tangent_type(::Type{Float64}) = Float64
tangent_type(::Type) = NoTangent # functions, integers, ...
zero_tangent(::Type{T}) where {T} = tangent_type(T) === NoTangent ? NoTangent() : zero(tangent_type(T))
accum(a::Float64, b::Float64) = a + b
accum(::NoTangent, ::NoTangent) = NoTangent()

# ---- rules ----
# Optimized IR has `Float64` arithmetic inlined down to intrinsics. They all have one type,
# so their rules are looked up by value at derivation time rather than by dispatch.
const INTRINSIC_RULES = IdDict{Any,Any}(
    Base.add_float => (a, b) -> (Base.add_float(a, b), ȳ -> (NoTangent(), ȳ, ȳ)),
    Base.sub_float => (a, b) -> (Base.sub_float(a, b), ȳ -> (NoTangent(), ȳ, -ȳ)),
    Base.mul_float => (a, b) -> (Base.mul_float(a, b), ȳ -> (NoTangent(), ȳ * b, ȳ * a)),
    Base.div_float => (a, b) -> (y = Base.div_float(a, b); (y, ȳ -> (NoTangent(), ȳ / b, -ȳ * y / b))),
    Base.neg_float => a -> (Base.neg_float(a), ȳ -> (NoTangent(), -ȳ)),
)
# The fallback of `rrule!!` derives a rule; the pullback it returns holds the pullbacks of
# the calls of the primal `Sig`, and its call is derived from the same IR: the primal as it
# was in world `W`, where the forward pass was derived, so that a pullback made before the
# primal is redefined still matches its forward pass. (A world is only meaningful within one
# session, so a real tool would need a key that survives package images.)
struct Pullback{Sig,W,D<:Tuple}
    data::D
    Pullback{Sig,W}(data::D) where {Sig,W,D} = new{Sig,W,D}(data)
end
function interp end
# The first argument of the generator names what each is derived from: `rrule!!(f, x...)`
# from the code of `f(x...)` in the current world, which the compiler looks up, infers
# with `interp` and hands to `transform_ir`, recording the dependency itself; the call of
# a pullback from nothing in the current world.
primal_sig(@nospecialize(sig::Type)) = Tuple{sig.parameters[2:end]...}
@eval function rrule!!(f, x::Float64...)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform(primal_sig, (world::UInt) -> interp(world))))
end
@eval function (pb::Pullback)(ȳ::Float64)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform(Returns(nothing), (world::UInt) -> interp(world))))
end
rrule!!(::typeof(sin), x::Float64) = (sin(x), ȳ -> (NoTangent(), ȳ * cos(x)))
rrule!!(::typeof(cos), x::Float64) = (cos(x), ȳ -> (NoTangent(), -ȳ * sin(x)))
rrule!!(::typeof(exp), x::Float64) = (y = exp(x); (y, ȳ -> (NoTangent(), ȳ * y)))
rrule!!(::typeof(log), x::Float64) = (log(x), ȳ -> (NoTangent(), ȳ / x))

function value_and_gradient(f, x::Float64...)
    y, pb = rrule!!(f, x...)
    return y, Base.tail(pb(1.0))
end

# ---- the interpreter ----
struct ADInterp <: CC.AbstractInterpreter
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::CC.InferenceCache
end
interp(world::UInt) = ADInterp(world, CC.InferenceParams(), CC.OptimizationParams(), CC.InferenceCache())
CC.InferenceParams(interp::ADInterp) = interp.inf_params
CC.OptimizationParams(interp::ADInterp) = interp.opt_params
CC.get_inference_world(interp::ADInterp) = interp.world
CC.get_inference_cache(interp::ADInterp) = interp.inf_cache
CC.cache_owner(::ADInterp) = ADInterp
const CODEGEN = IdDict{CodeInstance,CodeInfo}()
CC.codegen_cache(::ADInterp) = CODEGEN

# ---- the primal as it was in world `W`, for the reverse pass ----
# A lookup in a past world never changes, so this depends on nothing.
function primal_ir(world::UInt, @nospecialize(sig::Type))
    ad = interp(world)
    match, _ = CC.findsup(sig, CC.method_table(ad))
    return CC.typeinf_ircode(ad, CC.specialize_method(match), nothing)[1]::IRCode
end

# The calls of straight-line `ir` as `(ssa index, rule call prefix, operands)`, and the
# returned value. Operands are `SSAValue`s, `Argument`s or `Float64` literals.
function tape(ir::IRCode, @nospecialize(sig::Type))
    unsupported(@nospecialize(x)) = error("ToyAD: unsupported in $sig: $x")
    isfloat(@nospecialize(a)) = CC.widenconst(CC.argextype(a, ir)) === Float64
    ops = Tuple{Int,Vector{Any},Vector{Any}}[]
    for i in 1:length(ir.stmts)
        stmt = ir[SSAValue(i)][:stmt]
        if stmt isa ReturnNode && isdefined(stmt, :val)
            isfloat(stmt.val) || unsupported(stmt)
            return ops, stmt.val
        elseif Meta.isexpr(stmt, :call) || Meta.isexpr(stmt, :invoke)
            f, operands... = stmt.args[(stmt.head === :invoke ? 2 : 1):end]
            f = CC.singleton_type(CC.argextype(f, ir)) # the callee, if it is a constant
            all(isfloat, operands) && isfloat(SSAValue(i)) || unsupported(stmt)
            if stmt.head === :invoke && f isa Function # a rule of its own, primitive or derived
                push!(ops, (i, Any[rrule!!, f], operands))
            elseif haskey(INTRINSIC_RULES, f)
                push!(ops, (i, Any[INTRINSIC_RULES[f]], operands))
            else
                unsupported(stmt)
            end
        elseif stmt !== nothing
            unsupported(stmt) # control flow, allocation, mutation, ...
        end
    end
    unsupported("no return")
end

# ---- building IR ----
# Statements and their types, appended one at a time; `emit!` returns the SSAValue of the
# statement it adds. Every type is left as `Any`, for the compiler to fill in.
# (Mooncake collects new statements per basic block in its `BBCode`; a toy without control
# flow needs one list.)
struct Builder
    stmts::Vector{Any}
    types::Vector{Any}
end
Builder() = Builder(Any[], Any[])
function emit!(b::Builder, @nospecialize(stmt))
    push!(b.stmts, stmt)
    push!(b.types, Any)
    return SSAValue(length(b.stmts))
end
call(@nospecialize(args...)) = Expr(:call, args...)
field(@nospecialize(x), i) = call(getfield, x, i)

# An `IRCode` of the statements in `b`, for a method called with `argtypes` (cf. Mooncake's
# `ircode`). Every statement is flagged `IR_FLAG_REFINED`, which is what makes the compiler
# type it; the line table is empty.
function ircode(b::Builder, argtypes::Vector{Any})
    n = length(b.stmts)
    stream = CC.InstructionStream(b.stmts, b.types, CC.CallInfo[CC.NoCallInfo() for _ in 1:n],
        zeros(Int32, 3n), fill(CC.IR_FLAG_REFINED, n))
    debuginfo = CC.DebugInfoStream(nothing, Core.DebugInfo(:ToyAD), n)
    return IRCode(stream, CC.compute_basic_blocks(b.stmts), debuginfo, argtypes, Expr[], CC.VarState[])
end

# The forward pass of the primal `ir`, as the IR of `rrule!!(f, x...)`, whose arguments are
# `argtypes = [typeof(rrule!!), F, Tuple{Float64...}]`. Each primal call
#     %i = f(a, b)::Float64
# becomes
#     %r = rule(a, b)
#     %v = getfield(%r, 1)   the value of %i
#     %p = getfield(%r, 2)   the pullback
# and uses of %i become uses of %v. The pullbacks are returned in a `Pullback{sig,world}`.
function forward_pass(ir::IRCode, @nospecialize(sig::Type), world::UInt, argtypes::Vector{Any})
    ops, ret = tape(ir, sig)
    b = Builder()
    # the primal's arguments: `f` is argument 2 here, and the `x`s are packed in argument 3
    x = [emit!(b, field(Argument(3), k)) for k in 1:length(ir.argtypes)-1]
    v = Dict{Int,SSAValue}() # primal SSA index => the statement here that holds its value
    value(@nospecialize(a)) = a isa SSAValue ? v[a.id] : a isa Argument ? (a.n == 1 ? Argument(2) : x[a.n-1]) : a
    pullbacks = SSAValue[]
    for (i, rule, operands) in ops
        r = emit!(b, call(rule..., map(value, operands)...))
        v[i] = emit!(b, field(r, 1))
        push!(pullbacks, emit!(b, field(r, 2)))
    end
    data = emit!(b, call(tuple, pullbacks...))
    pb = emit!(b, call(Pullback{sig,world}, data)) # inlined to a `:new` once `data` has a type
    emit!(b, ReturnNode(emit!(b, call(tuple, value(ret), pb))))
    return ircode(b, argtypes)
end

# The reverse pass of the primal `ir`, as the IR of `(pb::Pullback{sig,W,D})(ȳ)`, whose
# arguments are `argtypes = [Pullback{sig,W,D}, Float64]`. The primal's calls are visited
# in reverse; for the n-th, `%i = f(a, b)`:
#     %p = getfield(%data, n)   the pullback of the call
#     %d = (%p)(t_i)            t_i is the tangent of %i
#     t_a = accum(t_a, getfield(%d, 2)), and likewise for b
# `tangent` maps a primal value to the IR value that holds its tangent so far, which is
# what Mooncake keeps in a reverse-data `Ref` per SSA value.
function reverse_pass(ir::IRCode, @nospecialize(sig::Type), argtypes::Vector{Any})
    ops, ret = tape(ir, sig)
    b = Builder()
    tangent = Dict{Any,Any}(Argument(k) => zero_tangent(T) for (k, T) in enumerate(sig.parameters))
    for (i, _, _) in ops
        tangent[SSAValue(i)] = 0.0
    end
    # a `Float64` literal has no tangent to accumulate into
    accum!(@nospecialize(a), t) = haskey(tangent, a) && (tangent[a] = emit!(b, call(accum, tangent[a], t)))
    accum!(ret, Argument(2)) # the seed `ȳ`
    data = emit!(b, field(Argument(1), QuoteNode(:data)))
    for (n, (i, _, operands)) in Iterators.reverse(enumerate(ops))
        p = emit!(b, field(data, n))
        d = emit!(b, call(p, tangent[SSAValue(i)]))
        for (j, operand) in enumerate(operands)
            accum!(operand, emit!(b, field(d, j + 1))) # field 1 is the tangent of the callee
        end
    end
    out = emit!(b, call(tuple, (tangent[Argument(k)] for k in 1:length(sig.parameters))...))
    emit!(b, ReturnNode(out))
    return ircode(b, argtypes)
end

const DERIVATIONS = Ref(0)
# The derived code is the code of the generated method's own specialization. This maps the
# primal's IR, which the compiler looked up and inferred, to it. It handles no edges: the
# compiler knows what it handed over. The compiler types and optimizes the IR, with `ADInterp`, so that a call of `rrule!!` for a
# callee of the primal is resolved to the code `ADInterp` has for it, the callee's derived
# forward pass; records the edges of the calls it resolved; publishes the result; and
# builds the body that invokes it. It does not call this while code it published for the
# specialization is valid.
function CC.transform_ir(interp::ADInterp, mi::Core.MethodInstance, primal::Union{IRCode,Nothing})
    T = mi.specTypes.parameters # (typeof(rrule!!), F, Float64...) or (Pullback{Sig,W,D}, Float64)
    DERIVATIONS[] += 1
    if primal === nothing
        # the reverse pass is derived from the primal as of its forward pass's world `W`
        sig, W = T[1].parameters
        return reverse_pass(primal_ir(W, sig), sig, Any[T...])
    end
    # the arguments as the method receives them: its trailing arguments packed in a tuple
    return forward_pass(primal, primal_sig(mi.specTypes), CC.get_inference_world(interp),
        Any[T[1], T[2], Tuple{T[3:end]...}])
end

end # module

# ---- checks ----
using Test
using .ToyAD: ToyAD, value_and_gradient, rrule!!

fd(f, x...) = ntuple(length(x)) do i
    h = 1e-6
    (f(x[1:i-1]..., x[i] + h, x[i+1:end]...) - f(x[1:i-1]..., x[i] - h, x[i+1:end]...)) / 2h
end
isapproxtuple(a, b; kw...) = all(isapprox.(a, b; kw...))

f1(x, y) = sin(x) * y + exp(x * y)
@noinline g2(x, y) = x * y - cos(y) / x
f2(x, y) = g2(x, y) * g2(y, x) + log(x)
f3(x) = x * x * x + x # repeated use: tangents accumulate
leaf(x) = 2.0 * x
f4(x) = sin(leaf(x)) # `leaf` is inlined into the primal
f5(x, y) = x
@noinline k1(x, y) = x * sin(y)
k2(x, y) = k1(y, x)
m1(x::Real) = sin(x)

@testset "ToyAD" begin
    x, y = 0.7, -1.3
    @testset "gradients" begin
        v, g = value_and_gradient(f1, x, y)
        @test v === f1(x, y)
        @test isapproxtuple(g, (cos(x) * y + y * exp(x * y), sin(x) + x * exp(x * y)); rtol = 1e-12)
        @test isapproxtuple(g, fd(f1, x, y); rtol = 1e-7)
        v, g = value_and_gradient(f2, x, y)
        @test v === f2(x, y)
        @test isapproxtuple(g, fd(f2, x, y); rtol = 1e-7)
        @test value_and_gradient(f3, x) === (f3(x), (3x^2 + 1,))
        @test value_and_gradient(f5, x, y) === (x, (1.0, 0.0))
    end
    @testset "inference" begin
        caller(x, y) = value_and_gradient(f1, x, y)
        @test Base.return_types(caller, (Float64, Float64)) == Any[Tuple{Float64,Tuple{Float64,Float64}}]
        @test isconcretetype(only(Base.return_types(rrule!!, (typeof(f1), Float64, Float64))))
        code = only(code_typed(caller, (Float64, Float64)))[1].code
        @test count(code) do stmt
            Meta.isexpr(stmt, :invoke) && stmt.args[1] isa Core.CodeInstance && stmt.args[1].owner === ToyAD.ADInterp
        end == 2 # the forward pass and the reverse pass
    end
    @testset "the published code is the typed IR the tool built, finished by the compiler" begin
        caller(x, y) = value_and_gradient(f1, x, y)
        code = only(code_typed(caller, (Float64, Float64)))[1].code
        cis = [stmt.args[1] for stmt in code if Meta.isexpr(stmt, :invoke) && stmt.args[1].owner === ToyAD.ADInterp]
        @test length(cis) == 2
        for ci in cis # the forward pass, then the reverse pass
            src = ToyAD.CODEGEN[ci] # what is compiled
            @test all(isconcretetype, src.ssavaluetypes[1:end-1]) && src.code[end] isa Core.ReturnNode
            @test length(src.slotnames) == ci.def.def.nargs # no local variables: nothing was lowered
            @test isconcretetype(ci.rettype)
            callee(stmt) = Base.Compiler.singleton_type(Base.Compiler.argextype(stmt.args[1], src, Base.Compiler.VarState[]))
            @test all(stmt -> !Meta.isexpr(stmt, :call) || callee(stmt) isa Union{Core.Builtin,Core.IntrinsicFunction}, src.code) # no dispatch left
        end
        @test count(stmt -> Meta.isexpr(stmt, :new), ToyAD.CODEGEN[cis[1]].code) == 5 # 4 closures and the `Pullback`
    end
    @testset "callers see the effects of the derived code" begin
        caller(x, y) = value_and_gradient(f1, x, y)
        code = only(code_typed(caller, (Float64, Float64)))[1].code
        for stmt in code
            Meta.isexpr(stmt, :invoke) && stmt.args[1].owner === ToyAD.ADInterp || continue
            effects = Base.Compiler.decode_effects(stmt.args[1].ipo_purity_bits)
            @test effects != Base.Compiler.EFFECTS_UNKNOWN
            @test Base.Compiler.is_effect_free(effects)
        end
        @test Base.Compiler.is_effect_free(Base.infer_effects(caller, (Float64, Float64)))
    end
    @testset "caching and invalidation" begin
        compiled(x) = value_and_gradient(f4, x)[2][1]
        @test compiled(x) ≈ 2cos(2x)
        n = ToyAD.DERIVATIONS[]
        @test compiled(x) ≈ 2cos(2x)
        @test value_and_gradient(f4, x)[2][1] ≈ 2cos(2x)
        @test value_and_gradient(f2, x, y) isa Tuple
        @test ToyAD.DERIVATIONS[] == n # nothing is derived twice
        @eval leaf(x) = 3.0 * x # inlined callee: invalidates through the primal's CodeInstance
        @test Base.invokelatest(compiled, x) ≈ 3cos(3x)
        @test ToyAD.DERIVATIONS[] == n + 2 # the forward and the reverse pass of `f4`
        @eval @noinline g2(x, y) = x + y # callee with a derived rule of its own
        @test isapproxtuple(value_and_gradient(f2, x, y)[2], (2(x + y) + 1 / x, 2(x + y)); rtol = 1e-12)
        @eval f4(x) = cos(x) # the primal itself
        @test value_and_gradient(f4, x)[2][1] ≈ -sin(x)
    end
    @testset "a more specific method for the primal's signature" begin
        @test value_and_gradient(m1, x)[2][1] ≈ cos(x)
        @eval m1(x::Float64) = cos(x) # `m1(::Real)` is not redefined; dispatch to it is replaced
        @test value_and_gradient(m1, x)[2][1] ≈ -sin(x)
    end
    @testset "a pullback made before its primal is redefined" begin
        _, pb = rrule!!(k2, 0.3, 0.4)
        @eval k2(x, y) = k1(x, y) # swaps the arguments of the call
        @test Base.invokelatest(pb, 1.0)[2:3] === (0.4cos(0.3), sin(0.3)) # the old primal's gradient
        @test Base.invokelatest(value_and_gradient, k2, 0.3, 0.4)[2] === (sin(0.4), 0.3cos(0.4))
    end
    @testset "outside the subset" begin
        @test_throws "ToyAD: unsupported" value_and_gradient(x -> x > 0 ? x : -x, x)
        @test_throws "ToyAD: unsupported" value_and_gradient(x -> x * time(), x)
    end
end
