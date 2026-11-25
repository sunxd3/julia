# RFC: `Core.GeneratedFunctionTransform`

> **Status & feedback needed:** PRs 1–3 below are implemented: PRs 1–2 cover standalone bugfixes and foreign `CodeInstance` isolation, and PR 3 implements the default `Core.GeneratedFunctionTransform(gen)` from Jameson Nash's original proposal (running the generator in the requested world, which was an open TODO in the original note and remains open to review). The main design questions needing consensus are in **Mode 2 (derived IR)**, **Eager vs. lazy generation**, and **Open questions** (for PR 4).

## Summary

Some Julia packages compile code with a custom `Compiler.AbstractInterpreter` and need to run the result. Today, the only way to run compiler-produced typed IR is `Core.OpaqueClosure(ir)`, which forfeits what ordinary methods get: per-specialization caching, world-age invalidation, package image serialization, and visibility of return types and effects to callers.

This RFC proposes `Core.GeneratedFunctionTransform`, a new `CachedGenerator` for `@generated` methods that lets a package use code produced by its own `AbstractInterpreter` as the body of an ordinary method. Instead of returning typed code from the generator slot, the interpreter caches its compiled `CodeInstance` under its own `cache_owner`, and the generator emits an untyped stub (`invoke(..., ci, args...)`) with `ci` as its edge. Julia then infers, caches, invalidates, and serializes the call through the existing method-table machinery.

The design builds on [Jameson Nash's proposal](https://hackmd.io/@vtjnash/generatedowner) and extends it to cover tools like reverse-mode AD whose generated code is a different function from the primal it was derived from. A working prototype and a minimal Mooncake-style AD (`gft-examples/toyad.jl`) exist on branch `xs/gft`.

## Motivation

Compiler-extending packages either re-compile an existing function under custom rules (contextual dispatch, overlays, custom passes) or derive new functions from a primal's typed IR (forward and reverse passes in automatic differentiation). Neither of Julia's existing mechanisms fits:

| Mechanism | Input | Caching & invalidation | Package images | Caller visibility |
| :--- | :--- | :--- | :---: | :--- |
| `Core.OpaqueClosure(ir)` | Typed `IRCode` | Manual cache; frozen world (no invalidation) | No | Declared `rettype` only; `exctype = Any`, effects unknown |
| `@generated` (`GeneratedFunctionStub`) | Untyped AST / `CodeInfo` | Per-specialization; via `edges` | Yes | Full (re-inferred from scratch) |
| `Core.GeneratedFunctionTransform` | Custom `AbstractInterpreter` (or derived `IRCode`) | Per-specialization; automatic via `edges` | Yes (if owner keeps code) | `rettype`, `exctype`, and effects (except `nothrow`, `:consistent`) |

Ordinary `@generated` functions also run as pure callbacks pinned to their method's `primary_world`, so they cannot run the compiler in the current world to inspect or transform methods defined since.

The `@generated` slot is untyped on purpose: inference caches results under the native compiler's owner (`owner === nothing`), and Julia treats all native `CodeInstance`s of a `MethodInstance` as interchangeable. Code that Julia did not infer natively must never enter that slot.

In practice, tools like Mooncake.jl fall back to `OpaqueClosure`s and must work around every missing piece:
- maintaining a manual world-keyed rule cache that is flushed on any method definition;
- predicting each rule's return type before constructing the IR so it can be stamped onto the closure type;
- re-deriving every rule from scratch in every session because closures cannot live in package images;
- losing caller-side effect propagation because `OpaqueClosure` calls have unknown effects and exception types.

With `GeneratedFunctionTransform`, rules become ordinary methods backed by foreign-owned `CodeInstance`s: Julia handles caching, invalidation, caller inference, and package images.

## Goals and Constraints

**Goals**
- **Method semantics for foreign-compiled code:** Code produced by a custom `AbstractInterpreter` is cached per specialization, invalidated through its dependencies, saved in package images, and called directly with visible return types and effects.
- **Support derived functions, not just re-compilations:** Cover tools like AD where the transformed code takes different arguments, returns a different type, or has no source method of its own (e.g., a pullback).
- **Run in the current world:** The package's interpreter runs in the requested world so it sees current method definitions and bounds its results like ordinary inference.

**Constraints**
- **Minimal new API:** Connect `@generated` methods to foreign `CodeInstance`s using existing pieces (`AbstractInterpreter`, `cache_owner`, `codegen_cache`, `invoke(f, ci, args...)`).
- **Strict foreign/native isolation:** Foreign code must never be mistaken for native code, and native code must never silently execute in place of foreign code (in dispatch, folding, codegen, JIT/AOT drivers, or `--trim`).
- **No weakening of existing guarantees:** The generator slot stays untyped, and existing `@generated` methods are unchanged.
- **Graceful failure inside the compiler:** Errors, stale caches, deep nesting, or recursive cycles during generation must degrade cleanly rather than crashing or hanging the compiler.
- **No manual invalidation bookkeeping for tools:** For derived IR, the compiler should own the lookup, edge recording, world bounds, and publication rather than asking packages to hand-assemble `CodeInstance`s and backedges.

## Proposal

### Architecture Overview

A method opts in by setting its generator to `Core.GeneratedFunctionTransform`. In both modes, the generator produces a foreign-owned `CodeInstance` (`ci`, with `owner = cache_owner(interp)`) and returns an untyped `:uninferred` stub whose body is `invoke(..., ci, args...)` with `ci` in its `edges`.

```text
Mode 1 — Re-compile a call (overdub(f, args...)):

  native caller (owner = nothing)
    └─ :invoke ──▶ foreign_ci  [on f's MethodInstance, owner = MyInterp]
                      ▲
                      │ edge (backedge on f's MI)
           uninferred_ci  [on overdub's MI, owner = :uninferred]
             body: invoke(f, foreign_ci, args...)

Mode 2 — Derive a new function (rrule!!(f, args...)):

  native caller (owner = nothing)
    └─ :invoke ──▶ foreign_ci  [on rrule!!'s own MI, owner = ADInterp]
                      ▲            └─ edge ──▶ primal_ci [on f's MI]
                      │ edge
           uninferred_ci  [on rrule!!'s MI, owner = :uninferred]
             body: invoke(rrule!!, foreign_ci, f, args...)
```

Invalidation flows straight up the backedge chain: redefining a dependency of `f` invalidates `primal_ci` (Mode 2) → `foreign_ci` → `uninferred_ci` → native callers. The next call runs the generator again in the new world.

### The Generator

```julia
@eval function overdub(f, args...)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform(world -> MyInterp(; world))))
end
```

When a specialization is requested in `world`:
1. `jl_code_for_staged` invokes `gen(world)` in `world` with `in_pure_callback = 0` (unlike user generators, which run as pure callbacks in `def.primary_world`). This lets `gen`, the interpreter's methods, method lookup, and inner inference all see one world and read the live world counter to bound and promote results. (Running in the requested world as a non-pure callback was left open in Jameson's original proposal; this is the prototype's answer and is open to review.)
2. Base routes to `generated_function_transform_body` in the `Compiler` module `interp` belongs to (so interpreters built against a separately loaded `Compiler` work).
3. The compiler verifies that `interp` infers in exactly `world`, has a non-native `cache_owner` (neither `nothing` nor `:trim`), and defines a `codegen_cache`, and that the generated method has no keyword arguments.

### Mode 1: Compile the Call with the Interpreter (Implemented; Follows Original Proposal)

Without a `transform` argument, `overdub(f, args...)` takes `f` as its first argument and `args...` as the rest:
1. Looks up the call signature of `f(args...)` in `method_table(interp)` via `findsup`.
2. Infers, optimizes, and adds to the JIT via `typeinf_ext_toplevel(interp, target_mi, SOURCE_MODE_ABI)`, producing `ci` on `target_mi`.
3. Emits `invoke(f, ci, args...)` with `edges = svec(ci)`, bounded by both `ci`'s world range and the lookup's `valid_worlds`.

The interpreter's existing overloads (overlay `method_table`, inlining policy, optimization passes) determine what `ci` compiles to, and inference records all edges automatically.

### Mode 2: Code Derived from Another Function (Open)

Mode 1 only compiles `f` itself. Automatic differentiation needs something different:

- `f(x::Float64)::Float64` and `rrule!!(f, x::Float64)::Tuple{Float64, Pullback}` have different argument counts and return types.
- A pullback `(pb::Pullback)(ȳ)` has no corresponding source method at all.
- Crucially, `ADInterp` *still needs to infer `f` as `f`* to obtain the primal's typed IR, so `(mi_f, ADInterp)` cannot hold `rrule!!`'s code without colliding with `f` itself.

Therefore, derived code is stored on the **generated method's own `MethodInstance`** (under `cache_owner(interp)`), where the `:uninferred` stub and the derived code represent the exact same function.

In the prototype, this takes two pieces:

```julia
primal_sig(sig) = Tuple{sig.parameters[2:end]...}   # rrule!!(f, x...) is derived from f(x...)

@eval function rrule!!(f, x::Float64...)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta, :generated, Core.GeneratedFunctionTransform(primal_sig, world -> ADInterp(world))))
end

function Compiler.transform_ir(interp::ADInterp, mi::MethodInstance, primal::Union{IRCode,Nothing})
    ...  # return typed IRCode for `mi`
end
```

1. **`transform(sig) -> Union{Type{<:Tuple}, Nothing}`** (optional first argument): maps the generated method's specialization signature to the signature the code is derived from, or `nothing` if derived from nothing in the current world (e.g., a pullback derived from a saved past world).
2. **IR mapping** (currently `Compiler.transform_ir(interp, mi, source)`): receives the optimized typed `IRCode` of the looked-up signature (or `nothing`) and returns typed `IRCode` for `mi`.

The compiler handles everything around the IR mapping using the same machinery as ordinary inference:
- **Lookup & primal inference:** looks up `transform(mi.specTypes)` in `method_table(interp)`, infers it with `interp`, and records the resulting `CodeInstance` as a regular-dispatch edge (which invalidates both when the primal's dependencies change and when a more specific method is added) together with the lookup's `valid_worlds`.
- **Typing & optimization:** runs `ir_abstract_constant_propagation` on statements flagged `IR_FLAG_REFINED` (recording call edges, including calls to other generated methods of `interp`), followed by inlining, SROA, ADCE, and `verify_ir`.
- **Effects & publication:** computes `rettype` from the IR and refines `consistent`, `effect_free`, `nothrow`, `noub`, and `nortcall` from statement flags via `ipo_dataflow_analysis!`. Publishes the `CodeInstance` on `mi` through the same backedge-before-promotion path as `finish!`, adds it to `codegen_cache(interp)` and the JIT, and returns `invoke(self, ci, args...)`.

The tool never constructs a `CodeInstance`, never declares edges, and never touches world bounds or the JIT.

### Keeping Foreign Code Apart & What Callers See

Since JuliaLang/julia#64950, `invoke(f, ci, args...)` with a constant `CodeInstance` inlines to an `:invoke` of that exact `CodeInstance`. This work closes the remaining places where Julia treated all `CodeInstance`s of a `MethodInstance` as interchangeable:
- **Inference & folding:** `abstract_invoke` adds `ErrorException` to `exctype` and forces `:consistent = ALWAYS_FALSE` for foreign `CodeInstance`s (because an uncompiled foreign `CodeInstance` errors instead of falling back to native dispatch, and folding/concrete evaluation would dispatch natively). `irinterp`'s `concrete_eval_invoke` must likewise avoid folding or natively re-interpreting foreign `CodeInstance`s (tracked for PR 2; not yet committed on `xs/gft`). Callers still see `ci.rettype`, `exctype`, and the remaining effects (for derived IR, `:terminates`, `:notaskstate`, and `:inaccessiblememonly` remain unknown because inference only accumulates them from source).
- **JIT, AOT, & `--trim`:** `add_codeinsts_to_jit!` and `compile!` emit a foreign `CodeInstance` from its own source if present, never re-infer its `MethodInstance` natively, and never insert it into the native cache. Trim verification rejects `:trim` instances substituting for foreign edges.
- **Codegen & runtime:** Fallbacks (`tojlinvoke` trampolines, `needsparams`, `jl_f_invoke`, `jl_invoke_target`) route through `jl_invoke_codeinst`, which compiles/calls `ci` itself and errors rather than falling back to `jl_invoke(mi)` for foreign owners. Self-recursion in `emit_invoke` shortcuts only on exact `ci` identity for foreign owners.

In callers, the foreign body is not inlined and (with the `irinterp` fix in PR 2) not constant-folded, and compiles to a direct `:invoke` of `ci` with its specialized calling convention. Package images serialize `ci` whenever the interpreter retains its code (`inferred !== nothing`) or uses the constant-return ABI.

### Eager Generation, and a Lazy Path

Generation is eager by default: when the compiler types a derived body and meets a call to a generated method, it generates that callee's body immediately before finishing the caller. This keeps calls between derived functions typed and direct, and lets a single `precompile` of a top-level rule pull its whole call graph into a package image.

Eager generation has two costs:
- **Native-stack nesting:** Each callee is generated inside the typing of its caller via `jl_code_for_staged`, outside the stackless design native inference has had since JuliaLang/julia#55575. In the prototype, a chain of ~500 distinct, non-inlined functions overflows the stack inside the compiler. The overflow is caught like any generator failure and the remaining levels are generated on first call, so the result is still correct, but the runtime warns that state may be corrupted.
- **Cold-path work:** Callees on paths that may never run (such as error paths) are derived eagerly. A callee whose derivation fails does not fail its caller; that call is left unresolved at compile time.

A lazy path already works with the same mechanism used for cycles: a call whose body is not generated during inference is still resolved to its `MethodInstance`, with its dispatch edge recorded, and compiled as an `:invoke` of that specialization; the body is generated on first execution. A tool can opt into this today without compiler changes by having its `Compiler.abstract_call_method` return an unknown result for its own generated method while typing derived IR (tested up to 3000-deep chains, with invalidation intact).

The trade-offs of laziness:
- **Unknown return type:** The tool must supply the expected type (for example via a `typeassert`, or in the type parameter of a lazy rule object as Mooncake.jl does) if it can predict it without the callee's body.
- **Call overhead:** Each lazy call goes through the specialization and boxes its result (~7 ns more than a direct call).
- **Slower first call & partial precompilation:** Each body is generated by a separate runtime request on first execution, and a package image only captures specializations that were run or precompiled explicitly.

The intended fix (not yet in the prototype) is for the compiler to bound generation nesting depth and fall back to lazy calls past the limit, as it does for cycles, so no tool can overflow the stack.

### Failure Modes & Cycle Handling

- **Throwing generator:** If the generator or interpreter throws, inference infers `Any` for the call and leaves it as an unresolved call to the specialization; the failure is not cached.
- **Validation:** Pre-checks verify world, non-native `cache_owner`, `codegen_cache`, and `nkw == 0`. Post-checks verify argument count/types, `verify_ir`, world containment against every `CodeInstance` edge, and that no unlisted `CodeInstance` appears in the stub.
- **Cache reuse:** If `code_cache(interp)` already holds a valid `CodeInstance` for `mi` in `world` (for instance, loaded from a package image when the `:uninferred` stub was not retained), it is invoked directly without re-running the generator.
- **Cycle breaking:** While generating a body, the thread reserves `(mi, GeneratingBody(owner))` in the inference engine (`src/engine.c`), and `typeinf_ext` checks `engine_hasreserved(interp, mi)`. A same-thread re-entrant request throws instead of recursing; other threads wait for the completed body. The call that would close the cycle is compiled as an `:invoke` of its specialization (`MethodInstance`) with its result inferred as `Any` (unless the tool asserts a type): for self-recursion, codegen turns that into a direct self-call with no runtime overhead, while a cycle across two or more specializations pays for a call through the specialization and a boxed result at the closing edge.

## Package Obligations (Unchecked Invariants)

The compiler does not and cannot check the following; packages using `GeneratedFunctionTransform` must uphold them:

1. **Purity with respect to world state:** Generated IR must depend only on `cache_owner(interp)`, `mi`, `world`, and the `source` IR provided. Reading other world state (extra method lookups, globals, tables) will not be tracked for invalidation.
2. **Compiler code is not tracked:** `gen`, the interpreter's methods, and `transform` / `transform_ir` are part of the compiler, not the program being compiled. Redefining them does not invalidate previously generated bodies (redefine the generated method to force regeneration).
3. **Trusted IR types and flags:** Just like `Core.OpaqueClosure(ir)`, types and flags left unflagged (without `IR_FLAG_REFINED`) are trusted without re-checking; wrong types are memory-unsafe. Leave types as `Any` with `IR_FLAG_REFINED` to let the compiler infer them.
4. **Cross-specialization agreement (e.g., forward vs. reverse pass):** Each generated specialization is invalidated and regenerated independently in the world of its next request. If a tool splits one derivation across multiple generated methods (like a forward pass returning a `Pullback` and a reverse pass consuming it), values produced by an older derivation can be called after the primal is redefined. Whatever the two sides must agree on has to be encoded in the types flowing between them so an old value never dispatches to a newly re-derived specialization.

## Limitations & Non-Goals

**Limitations**
- Like all `@generated` functions, argument types must be concrete; abstract calls infer `Any` and dispatch at runtime.
- Keyword-argument methods are not supported.
- Adding a new method to an overlay `MethodTable` does not invalidate previously generated bodies (replacing an existing method does).
- Calls that close a cycle of generated methods get no body at compile time; they compile as `:invoke` of their specialization typed `Any` (direct for self-recursion, boxed through the specialization for multi-method cycles).
- Eager generation currently nests on the native stack and overflows at ~500 distinct generated levels (see *Eager Generation, and a Lazy Path*).
- Bodies are generated during caller inference, not on first execution.
- In the current prototype, `transform` maps to at most one looked-up signature.
- Encoding a world number in a type parameter (as `toyad.jl` does to keep a `Pullback` matched to its forward pass) only works within a single session and does not survive package images.

**Non-goals for the initial PRs**
- Inlining foreign `CodeInstance` bodies into native callers.
- Resolving recursive/mutually recursive cycles together at compile time so the closing call is typed.
- Computing `:terminates`, `:notaskstate`, and `:inaccessiblememonly` from derived IR.

## Relation to the Original Proposal

Compared to [Jameson Nash's proposal](https://hackmd.io/@vtjnash/generatedowner):
- **`transform` is optional and nullable:** Without it, Mode 1 compiles the first argument applied to the rest. With it, returning `nothing` supports generated methods not derived from a current-world lookup (e.g., pullbacks).
- **Derived code lives on the generated method's `MethodInstance`:** The original proposal assumed the stub forwards the generated method's arguments unchanged to the looked-up method's `CodeInstance`, which cannot represent AD rules whose signatures and return types differ from the primal.
- **Owner is `cache_owner(interp)`**, not `gen`.
- **Generator world:** The proposal left open which world the generator runs in; the prototype runs it in the requested `world` with `in_pure_callback = 0`.
- **Foreign fallback errors:** Foreign code is never re-inferred natively; where it has no code, the call errors (via `jl_invoke_codeinst`), matching `invoke(f, ci, args...)`.

## Prototype Status & PR Plan

- **Branch `xs/gft`:** Mode 1, foreign-CI isolation, runtime/staged-function fixes, and IR publication are committed with tests. Mode 2 (`transform` + `transform_ir`) is also committed on the branch and exercised by `gft-examples/toyad.jl` (~150 lines of straight-line `Float64` reverse-mode AD, 40 checks covering nested rules, inference, effects, caching, and invalidation).
- **Known prototype shortcuts / follow-ups:**
  - An earlier manual-edges extension point (`generate_transformed_body` returning `(ir, edges)`) is still on the branch and would be removed once Mode 2's API is agreed.
  - `derive_transformed_ir` currently obtains the primal's edge (`typeinf_ext`) and its `IRCode` (`typeinf_ircode`) from two separate inferences; the final implementation should take both from one.
- **Mooncake.jl experiment:** An earlier prototype adapting Mooncake.jl independently converged on the same two operations — producing IR for the generated method's own specialization, and letting the compiler finish and publish it.

**Staged PR plan:**
1. **Standalone generated-function & `CachedGenerator` fixes:** Fix the C backedge decoder in `jl_code_for_staged`, avoid the unbarriered GC store in `call_get_staged`, and fix two world-promotion races (provisional staged results and uninferred `finish!`).
2. **Foreign `CodeInstance` isolation:** `is_native_owner` / `is_foreign_owned`, blocking native folding (`abstract_invoke` and `irinterp`'s `concrete_eval_invoke`), re-inference, and fallback dispatch of foreign `CodeInstance`s across inference, JIT, AOT, codegen, and `--trim`.
3. **Default `Core.GeneratedFunctionTransform(gen)`:** Mode 1 + runtime support in `jl_code_for_staged` + engine cycle guards.
4. **Derived IR (Mode 2):** Factor `publish_codeinst!` out of `finish!` and add the agreed IR-derivation interface (plus depth-bounded eager generation).

## Open Questions

### Decisions needed for PR 4

1. **Where should the IR mapping live?**
   - **Option A — Existing `AbstractInterpreter` overload (e.g., `Compiler.optimize`):** No new `Compiler` hook, closest to the original proposal, *but* `optimize` produces code stored on the looked-up method's `MethodInstance` with the looked-up method's signature — it cannot produce a differently typed AD rule without colliding with inferring the primal itself.
   - **Option B — New `Compiler.transform_ir(interp, mi, source)` hook (current prototype):** Cleanly separates inferring `source` from deriving `mi`'s IR, dispatches on `interp` like the rest of `AbstractInterpreter`, and keeps `GeneratedFunctionTransform` small — *but* adds a new method to `Compiler`'s extension surface.
   - **Option C — Callable field on `GeneratedFunctionTransform` (next to `transform`):** Adds nothing to `Compiler` and lets one interpreter type back multiple distinct generated methods (e.g., `rrule!!` and `Pullback` without branching on `mi` inside `transform_ir`) — *but* moves a compiler hook onto a `Core` generator struct.

2. **Is the generated method's own `MethodInstance` the right home for derived code?**
   Storing `foreign_ci` on `mi` under `cache_owner(interp)` preserves the invariant that all code for `(mi, owner)` computes the same function. In the prototype, each generated specialization ends up with one tool-owned `CodeInstance` per world range (the wrapper is not cached next to the derived code). However, `jl_is_ci_equiv` and `jl_get_ci_equiv_range` still treat two foreign `CodeInstance`s with the same `(mi, owner, rettype)` as interchangeable — should equivalence linking be restricted to native owners (matching `emit_invoke`), or is `(mi, owner)` meant to guarantee interchangeability?

3. **Is a single looked-up signature from `transform` enough?**
   Some transformations read more than one method (e.g., combining a primal with an auxiliary rule or custom tangent definition). Should `transform` be allowed to return multiple signatures, or should the compiler pass a lookup/recording context to the IR mapping so the tool can request additional primal IRs on demand with automatic edge tracking?

4. **How should nested generation be bounded (and should laziness be opt-in)?**
   A compiler-enforced depth limit that falls back to lazy calls is the smallest fix for the native-stack overflow. Beyond that, should a tool have a declared way to request laziness (instead of overriding `abstract_call_method`), and should a lazy call be able to carry a return type declared by the tool?

### Follow-up / deferred questions

5. **Matching forward and reverse passes across package images:** Without world numbers (which are session-local), what is the cleanest way for a `Pullback` type to stay pinned to the forward pass that created it across precompilation? (For example, a content hash of the primal IR, or a compiler-provided generation/revision token.)
6. **Recursive / mutually recursive cycles:** Should a future extension resolve cycles of generated methods together so the closing call is typed?
7. **Remaining IR effects:** Is it worth computing `:terminates`, `:notaskstate`, and `:inaccessiblememonly` from derived IR so callers can propagate stronger effects?
