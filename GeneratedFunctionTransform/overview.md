# Running compiler-generated code as ordinary Julia functions

## 1. The problem

An advanced use pattern is to be functionally equivalent to eval-ing functions at runtime. This is for metaprogramming packages: they build programs out of other programs, usually at the level of typed IR, and need the result to run as an ordinary function.

Some examples. Mooncake translates a Julia function into a function that takes the tangent-type mapping of the original input types, and replaces the original functions with rules; this requires doing the transform at the IR level and then registering the derived function as a new function to run.

## 2. The opaque closure

An existing mechanism to support this kind of pattern is the opaque closure. `Core.OpaqueClosure(ir, env...)` takes IR you produced and returns a callable with a declared argument tuple and return type. No method enters any method table.

The constructor (`Compiler/src/opaque_closure.jl:30-57`, `src/opaque_closure.c:153-179`):

1. converts the `IRCode` back to a `CodeInfo`, marked as already inferred;
2. creates a `Method` in no method table, and a `MethodInstance` for it;
3. creates a `CodeInstance` valid in exactly one world, the current one, with the IR's edges stored but never registered;
4. compiles it and copies the function pointers into the closure object.

The environment is a tuple; its type is the IR's first argument type and the body reads it with `getfield(Argument(1), i)`. A call jumps to the stored pointers (`src/opaque_closure.c:233`). Steps 2 to 4 are never consulted again.

## 3. How Julia keeps compiled code correct

To see the challenges the opaque closure needs to solve, let's recap Julia's world age and method table. A user writes methods; methods get specialized; because methods call other methods, all the compiled code needs to be compatible to be correct. The key data structures are `Method`, `MethodInstance` and `CodeInstance`.

A `Method` is a definition. A `MethodInstance` is a method specialized to concrete argument types, `g(::Int64)`; there is one per method and argument tuple, shared by everyone who compiles it. A `CodeInstance` is one compiled result for a `MethodInstance`: return type, effects, world range, forward edges, native code. Several can hang on one `MethodInstance`, each with an `owner` saying which compiler produced it.

Every definition increments the world counter. Every `CodeInstance` records the range of worlds in which its assumptions hold. When inference of `caller` relies on `callee`, the caller's instance gets a forward edge to the callee's and the callee's `MethodInstance` gets a backedge. Redefining `callee` walks the backedges and caps `max_world` on every dependent instance. Nothing is recompiled then; the next call from a newer world finds no valid instance and compiles again. A fresh instance is valid from its world into every future world until an edge caps it.

`IRCode` is the optimizer's working form: the `CodeInfo` is converted to SSA form, the passes run, and it is converted back into a `CodeInfo` for the `CodeInstance`. It carries a copy of the world range it was created with, which nothing updates. The packages call `typeinf_ircode` to get it and have no supported way to turn a modified copy back into a `CodeInstance`.

## 4. What opaque closure exposes

The whole interface of an opaque closure is its type, `OpaqueClosure{Args, R}`; the world age is stored in the object and not checked.

```julia
h(x::Int) = x + 1
const box = Any[h]
oc_static  = @opaque (x::Int) -> h(x)          # h resolved when the closure is compiled
oc_dynamic = @opaque (x::Int) -> box[1](x)     # h looked up at call time
h(x::Int) = x + 100
oc_static(1), oc_dynamic(1), h(1)              # 2, 2, 101
```

The dynamic case shows the stored world is applied: dispatch inside the closure body happens in the closure's world and finds the old `h`. No error, because to the runtime nothing is wrong.

## 5. Compiler optimization can be obstructed with OC

When creation and call are in the same function, inference tracks the closure as a `PartialOpaque`, infers the body itself, and the optimizer inlines the call and removes the closure: `oc = @opaque (x::Int) -> h(x) * a; oc(b)` compiles to two intrinsics. Nothing was trusted; the compiler re-derived everything in the caller's world.

When the closure arrives as a value, inference has the type only: an indirect call through the stored pointer, result `R`, unknown effects. `R` is checked only on this path: `@opaque Tuple{Int}->Int (x)->x+1.5` throws a `TypeError` when called through the closure and returns `2.5` when inlined.

Inlining a callee is sound because the callee's instance has edges: the caller's range is intersected with it and both can be capped later. The closure's instance has a range of one past world and no registered edges. Intersecting would make the caller valid only in a world that has passed; skipping it would leave the caller claiming validity for code nothing can retract. The same holds for effects and for a narrower return type (julia#62101): the compiler believes a callee's facts only because they can be withdrawn.

So: outside every method table, hence no registered edges, hence pinned to one world, hence nothing trusted across a boundary.

The packages pay for this in code. Mooncake's `optimise_ir!` (`Mooncake.jl/src/interpreter/ir_utils.jl:275`) runs inference, inlining, SROA and DCE by hand on its rule IR before freezing it; its `ClosureCacheKey` is `(world_age, key)`; `build_rrule` refuses to run if the world has moved. Reactant's pre-removal code says "`jl_new_opaque_closure` forcibly executes in the current world" and "to work around this we sadly create/compile the opaque closure" at first call, keeps every closure alive in a global vector against a GC-rooting crash, and purges them all after its precompile workload because they "capture the worldage of their compilation and thus are not relocatable". Reactant removed closures in January 2026.

## 6. The proposal

`Core.GeneratedFunctionTransform(gen)` is a second kind of generator for `@generated` methods. `gen` returns your `Compiler.AbstractInterpreter` for a given world; the call to compile is the generated method's own arguments. The struct, rather than a plain generator function, is what lets the compiler recognise this kind later and infer through it.

```julia
@eval function overdub(f, args...)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated,
        Core.GeneratedFunctionTransform(world -> MyInterp(; world))))
end
```

Nothing happens at definition. On the first call `overdub(g, 2)` with concrete types, the generator:

1. looks `g(::Int)` up in your interpreter's method table, in the caller's world;
2. runs your interpreter on it, producing a `CodeInstance` on `g(::Int)`'s own `MethodInstance`, next to Julia's, with your owner;
3. returns the body `invoke(g, ci, x)`, with that instance as the body's first edge and the body's world range intersected with the instance's.

The result is inside the method-table bookkeeping, it can be capped, and its range is open-ended. Inference already knows what to do with `invoke` of a named instance (`abstract_invoke`, `Compiler/src/abstractinterpretation.jl:2540-2568`): check the argument types against the instance's signature, check the caller's world is in its range, intersect the ranges, take its return type and effects as facts. The native compiler never sees your IR.

Lazy means: the work happens at the first call, in the caller's world, once per concrete argument tuple. After a redefinition the instance is capped and the next call regenerates. `gen` and your interpreter's own methods (its `method_table` overload, any trait it consults) run in the world where the generated method was defined; only lookups that take the world explicitly, overlay tables and the inner inference, see the caller's world. A result inferred under that frozen view is cached under your owner and reused by later users, so a tool whose interpreter can change within a session should put a version in `cache_owner`.

| | opaque closure | transform |
|---|---|---|
| return type | declared, checked only on the opaque path | inferred per specialization |
| effects | unknown | from the instance |
| call | indirect through a pointer | direct to a known symbol |
| world range | one past world | open range, capped by edges |
| caching | per creation | per specialization, shared by all callers |
| calls between transformed bodies | a boundary each | one inference |
| package image | segfault on load (julia#55073) | works |

## 7. What it allows and what it costs

A call compiled by another compiler that is still an ordinary call: it dispatches, specializes and infers like any method. The result lives in Julia's cache under the tool's owner, is invalidated automatically, passes return type, effects and constants to native callers, and serializes into a package image. Several tools can hold instances for the same function. Calls between transformed bodies are direct calls with edges.

The body of the generated method has only its arguments, so state a closure would have captured must be passed in. For these packages that is mechanical: Mooncake's captures are already a tuple of stacks, Libtask's a tuple of `Ref`s. Ordinary Julia closures work the same way: a struct holding the captured values and a method reading them from its first argument.

A generator runs only for concrete argument types, so a caller that does not know the types infers `Any`. The transformed IR is never inlined into native code, because it was derived under a different method table or lattice. Keyword arguments are not supported, an interpreter without a `codegen_cache` fails under `--compile=min`, and `cache_owner` must not be `nothing`.

## 8. Soundness

Getting here needed six fixes to Julia, each a separate commit before the feature: the C backedge decoder in `jl_code_for_staged` (segfaults on 1.12 and 1.13), the inliner's owner swap, `abstract_invoke` inferring a foreign `invoke` nothrow, a runtime bound on re-entrant generation, codegen's trampoline, and the compile drivers. Two more, copying a generator's `CodeInfo` and checking its world range, are upstream-only.

The inliner's `compileable_specialization` replaced a given `CodeInstance` with whatever the current compiler's cache held for the same `MethodInstance`. With two owners on one chain that substituted Julia's code for the tool's, silently. It now keeps the given instance when the owner differs.

Both compile drivers, the JIT's and the package image's, re-inferred a foreign `invoke` target natively when they found no source, and codegen's trampoline dispatched it by `MethodInstance`. A caller loaded from an image returned the native answer. The drivers now emit the foreign instance from the IR it carries or skip it, and the trampoline runs the instance itself or raises the same error as `invoke`; only `--trim` fails the build.

A transformed body may call the generated method for a callee whose transformed body reaches the first. Each level started a fresh top-level inference, so cycle detection, which works within one inference, never saw it, and the generator recursed until the stack overflowed (880 generator runs). The runtime now keeps a per-thread stack of the method instances being generated and refuses the second re-entry of one; that call site is compiled as an `invoke` of the method instance with an unknown result, and at run time finds the body finished by the outer level. Ping/pong now runs the generator 4 times. A callee calling itself inside a transformed body is an ordinary inference cycle.

The remaining rules: the instance is an edge of the body, so whatever caps it caps every caller. `gen` and the interpreter's own methods are fixed by the definition, and a result derived under them is reused by the owner; only the lookup and inner inference use the caller's world. The instance's return type and effects are believed, so anything the tool reads without recording an edge is invisible to invalidation. Methods added to an overlay table after a body was generated do not invalidate it (method-table backedges exist only for the global table); replacing an existing overlay method does.

## 9. Worked example: from `IRCode` to a function

The tool is an interpreter with an overlay table in which `leaf(x) = x - 1`; Julia's `leaf` is `x + 1`. It takes the typed IR of `g(x) = leaf(x) * 10` before inlining, so `leaf` is still a call, and edits the constant:

```julia
g(x::Int) = leaf(x) * 10
ir = Base.code_ircode(g, (Int,); optimize_until="CC: COMPACT_1")[1][1]
for i in 1:length(ir.stmts)
    st = ir.stmts[i][:stmt]
    st isa Expr && st.head === :call && st.args[end] === 10 && (st.args[end] = 1000)
end
```

The IR is converted to a `CodeInfo` and stored under a tag that appears in a type; a raw generator returns it as the body:

```julia
function ir_to_body(ir)
    src = ccall(:jl_new_code_info_uninit, Ref{Core.CodeInfo}, ())
    n = length(ir.argtypes)
    src.slotnames = [Symbol("#self#"), :x]; src.slotflags = zeros(UInt8, n)
    src.slottypes = copy(ir.argtypes); src.nargs = n; src.isva = false
    src = Compiler.ir_to_codeinf!(src, ir)
    src.ssavaluetypes = length(src.code)     # hand it over uninferred
    return src
end
struct IRFn{tag} end
const IRS = Dict{Symbol,Core.CodeInfo}(:g => ir_to_body(ir))
ir_generator(world::UInt, source::Method, tag, self, x) = copy(IRS[tag])
@eval function (::IRFn{tag})(x::Int) where {tag}
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, ir_generator))
end
```

With `overdub` from section 6 and `gen = world -> ToolInterp(; world)`:

```
native g(2)             = 30        (2+1)*10
IRFn natively           = 3000      (2+1)*1000: the tool's IR, Julia's leaf
overdub(IRFn{:g}(), 2)  = 1000      (2-1)*1000: the tool's IR, the tool's leaf
```

The objects behind the third line:

```
MethodInstance for (::IRFn{:g})(::Int64) carries two instances:
   owner=nothing     worlds=[42931, ∞]  rettype=Int64
   owner=ToolInterp  worlds=[42932, ∞]  rettype=Int64

the body generated for overdub(::IRFn{:g}, ::Int):
   Core.getfield(_3, 1)
   Core.invoke(_2, CodeInstance for (::IRFn{:g})(::Int64) (foreign), %1)
   return %2
   worlds=[42944, ∞]   edges: CodeInstance(owner=ToolInterp)

a native caller, caller(x) = overdub(IRFn{:g}(), x) + 1, compiles to:
   invoke(CodeInstance (foreign), IRFn{:g}(), x)
   Base.add_int(%1, 1)
```

Replacing the tool's `leaf` with `x - 100`:

```
overdub(IRFn{:g}(), 2) = -98000
   owner=nothing     worlds=[42931, ∞]
   owner=ToolInterp  worlds=[42959, ∞]
   owner=ToolInterp  worlds=[42932, 42958]
```

The old instance is capped and left on the chain, a new one is derived on the next call, Julia's own is untouched.
