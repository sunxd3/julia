# Bugs in Julia found while building `Core.GeneratedFunctionTransform`

Ten bugs in the runtime and compiler, none caused by the feature. They came up while building `Core.GeneratedFunctionTransform`, an interpreter-backed generator. Bugs 1-6 were found while building the branch (reproduced 2026-09-17). Bugs 7-10 came out of the audit rounds on 2026-09-21. The current release is Julia 1.13.0. Every self-contained reproducer in [`repro/`](repro/) was run against 1.13.0 and against a build carrying the fixes, and its real output was captured in its header (2026-09-21/22). On 1.13.0: all four decoder variants crash or hang (bug 1); the no-copy and stale-world cases raise internal errors (bugs 2 and 3); the ping/pong generator recursion overflows the stack and then hangs, or sometimes recovers (bug 10). The fix for bugs 5, 6, 8 and 9 was verified on 2026-09-22. Line numbers are against `ca626376c0` unless stated. Where the text says "master", it means `55312b3c97` (2026-09-21), which is also the base of the rebuilt feature branch.

There are two themes. Bugs 1-3 and 10 are in the generated-function protocol, and plain user code on released Julia can reach them. Bugs 4-9 all come from assuming that a `MethodInstance` has only one compiler. You reach them through `invoke(f, ci, args...)` (JuliaLang/julia#56660) with a `CodeInstance` from an external `AbstractInterpreter`. Bug 4 gives a silent wrong answer on the 1.13.0 release. Bugs 5, 8 and 9 need master: on 1.13.0, bug 4 inlines the native body before a foreign `:invoke` can reach them.

**Where the fixes are.** The feature branch `xs/generated-function-transform` is being rebuilt on master `55312b3c97`. Six fixes come first, as separate commits, followed by the feature commit:

1. `method: Fix the backedge decoder in jl_code_for_staged` (bug 1)
2. `inlining: Keep a foreign-owned CodeInstance as the invoke target` (bug 4, master route)
3. `inference: Do not infer invoke of a foreign CodeInstance as nothrow` (bug 7)
4. `method: Bound re-entrant generation of a MethodInstance` (bug 10)
5. `codegen: Never dispatch a foreign-owned CodeInstance by MethodInstance` (bug 6, plus the `needsparams` arm of `emit_invoke`, and the JIT-trampoline half of bug 9)
6. `Compiler: Do not re-infer a foreign-owned invoke target natively` (bugs 5 and 8, and the driver half of bug 9)

Commit hashes are not final, so this document refers to commits by title. The feature does not need bugs 2 (copy) and 3 (world range), so their fixes are not on the branch. They are kept as patches in [Appendix A](#appendix-a-the-two-fixes-not-on-the-branch), to be proposed as standalone PRs. Two problems are not fixed anywhere: bug 4 on the 1.13 release, and overlay-table additions that never invalidate (see the end of the table). Nothing has been filed upstream and nothing has been pushed.

| # | Bug | Reproduces on | Where fixed |
|---|---|---|---|
| 1 | C backedge decoder segfault | 1.12.7, 1.13.0 | (1) `method: Fix the backedge decoder in jl_code_for_staged` |
| 2 | generator `CodeInfo` not copied | 1.12.7, 1.13.0 | patch in Appendix A |
| 3 | generator world range not validated | 1.12.7, 1.13.0 | patch in Appendix A |
| 4 | inliner swaps a foreign `CodeInstance` | **1.13.0** (native body inlined) and master; not 1.12.7 | master: (2) `inlining: Keep a foreign-owned CodeInstance as the invoke target`; 1.13: unfixed |
| 5 | `compile!` re-infers a foreign target | master | (6) `Compiler: Do not re-infer a foreign-owned invoke target natively` |
| 6 | `emit_tojlinvoke` fallback dispatches by `MethodInstance` (AOT) | master (via `repro/review-pkgs/BigEphNR.jl`) | (5) `codegen: Never dispatch a foreign-owned CodeInstance by MethodInstance`, plus the `needsparams` arm |
| 7 | `owner === Nothing` typo in `abstract_invoke` | 1.13.0, master | (3) `inference: Do not infer invoke of a foreign CodeInstance as nothrow` |
| 8 | wrong-owner cache insert asserts | master | (6) `Compiler: Do not re-infer a foreign-owned invoke target natively` |
| 9 | `add_codeinsts_to_jit!` + JIT trampoline swap | master | trampoline: (5) `codegen: ...`; driver: (6) `Compiler: ...` |
| 10 | generator re-entry recurses without bound | 1.12.7, 1.13.0 | (4) `method: Bound re-entrant generation of a MethodInstance` |
| - | overlay-table additions never invalidate | (design limitation) | unfixed (design-scale) |

The last row is not a bug in the same sense. If you add an overlay method *after* generation, the body goes stale, both for the inner inference and for the generator's own `findsup` lookup. Shadowing in the global table does invalidate correctly. The missing facility is method-table backedges for non-global tables: `jl_method_table_add_backedge` and `jl_method_table_activate` in `src/gf.c` only handle `jl_method_table`. Fixing that is a redesign, so it is out of scope and is documented in the feature's docstring.

## 1. The C backedge decoder in `jl_code_for_staged` is type-confused and segfaults

Status: fixed by commit (1) `method: Fix the backedge decoder in jl_code_for_staged`. Independent of the feature; reproduces on 1.12.7 and 1.13.0, and master has the identical decoder. Reproducer: `repro/repro-01.jl` (variants `mt-cached`, `int-cached`, `ci-cached`, `mt-plain-min`).

`store_backedges` encodes a forward-edge list in five shapes:

- a bare `MethodInstance` or `CodeInstance`;
- a `Core.Binding`;
- an `(invokesig, callee)` pair, where the callee is a `MethodInstance`, `CodeInstance`, `Method` or `MethodTable`;
- a bare `Method`, which is ignored;
- an `(nmatches::Int, atype)` lookup marker, followed by that many edges.

The reference decoder is `ForwardToBackedgeIterator` (`Compiler/src/typeinfer.jl:822-861`). `jl_code_for_staged` has a second copy in C, for the edges a generator puts on the `CodeInfo` it returns. That copy understood only three of the shapes; its comment (master `src/method.c:863`) says it "needs to match `store_backedges`".

Its `MethodTable` branch tested `jl_is_mtable(kind)` on the *first* element of the pair. The encoding puts the signature first and the table second (`Compiler/src/stmtinfo.jl:247-248`), so that branch was dead. A `MethodTable` callee and an `Int` lookup marker therefore both fell into the catch-all pair branch. That branch casts the second element to `jl_method_instance_t*` and calls `jl_method_instance_add_backedge` on it:

- For a `MethodTable`, this writes a `Vector` push through the `backedges` field offset of a different struct.
- For an `Int` marker (`stmtinfo.jl:274`), it locks a `Type` as if it were a `MethodInstance`, and the process hangs.
- For a bare `CodeInstance` or `Method`, it reads past the end of the svec, because `assert(i < l)` is compiled out.

```julia
struct MyGen <: Core.CachedGenerator end
callee(x) = x + 1
function (::MyGen)(world::UInt, source, argtypes...)
    ci = ccall(:jl_new_code_info_uninit, Ref{Core.CodeInfo}, ())
    # ... minimal `return x` body ...
    ci.edges = Core.svec(Tuple{typeof(callee),Any}, Core.methodtable)
    return ci
end
@eval function g(x)
    $(Expr(:meta, :generated, MyGen()))
    $(Expr(:meta, :generated_only))
end
g(1)
```

- **1.12.7:** `signal 11 (1): Segmentation fault` in `ijl_array_grow_end` <- `push_edge` (`src/method.c:1071`) <- `ijl_method_instance_add_backedge` <- `ijl_code_for_staged`.
- **1.13.0:** the same crash with `push_edge` at `src/method.c:1140` and `ijl_code_for_staged` at `:881` (`repro-01.jl`, variant `mt-cached`). A bare `CodeInstance` edge (`ci-cached`) also segfaults.
- **`Int` lookup-marker variant (`int-cached`):** it hangs instead of crashing. It was killed after 180s on 1.12.7 and terminated after 60s on 1.13.0, stuck in `jl_mutex_lock` <- `ijl_method_instance_add_backedge`.
- **Fixed build:** all four variants run and survive GC and an invalidation.

The decoder runs only under `if (cache || needs_cache_for_correctness)` (master `:852`). On the compiled path, `cache` is non-null only for a `Core.CachedGenerator` (`Compiler/src/utilities.jl:88-92`). That is not the whole gate, though. `jl_code_or_ci_for_interpreter` passes a non-null cache for *any* generator with no cached uninferred source (`src/interpreter.c:891`; master `:909`). So an ordinary `@generated` function reaches the decoder on any interpreted path. I verified this: the same script with a plain, non-`CachedGenerator` generator segfaults under `--compile=min` on 1.12.7 and 1.13.0 (`mt-plain-min`), and runs clean on the fixed build. This is a live crash for ordinary generated functions that report inference-derived edges, not a latent one. `GeneratedFunctionTransform` is not a `CachedGenerator`, and its bodies are inferred rather than interpreted, so the feature does not strictly depend on this fix. The fix still comes first on the branch.

Expected: the decoder accepts all five edge shapes that `store_backedges` understands, with no memory corruption.

The fix makes the C decoder mirror the Julia one case for case:

- skip an `Int` marker and its `atype`;
- skip a `Method`;
- map a `CodeInstance` to its `MethodInstance`;
- test the *second* element of a pair for `MethodTable`, `Method` or `CodeInstance`.

A better long-term fix is to not have two decoders. `jl_code_for_staged` would return whether it won the cache race, and `call_get_staged` would call `store_backedges` on the Julia side.

## 2. A generator's `CodeInfo` is handed to inference without being copied

Status: not on the feature branch (the feature does not need it). The fix, a copy on entry, is preserved in Appendix A. Reproduces on 1.12.7 and 1.13.0, and master has the same code. Reproducer: `repro/repro-02.jl`.

`jl_code_for_staged` returns `func`, the object the generator returned, to its caller (`src/method.c:927`; master `:910`). Along the way, `jl_resolve_definition_effects_in_ir` (`:821`) rewrites its statement array in place. Afterwards, inference overwrites `ssavaluetypes`, changing it from an `Int` to a `Vector`. Only the already-cached path really protects the caller: `:784` returns a copy of the cached body. The caching path's copy at `:855` goes *into* the cache. When the cache race is won, the object handed back is still the generator's own, so a `Core.CachedGenerator` returning a stored `CodeInfo` sees it mutated too.

The natural way to paste prepared IR into a method is a generator that returns a `CodeInfo` it holds elsewhere, such as a registry keyed by a tag. That object gets mutated, and the second specialization is given a half-inferred body.

```julia
const STORE = Dict{Symbol,Core.CodeInfo}()
STORE[:shared] = build_src()          # a plain `return x` CodeInfo, ssavaluetypes = 1
sharedgen(world::UInt, source, argtypes...) = STORE[:shared]
@eval function shared(x)
    $(Expr(:meta, :generated, sharedgen))
    $(Expr(:meta, :generated_only))
end
shared(1)                              # ok; STORE[:shared].ssavaluetypes is now Any[Any]
shared(1.0)                            # Internal error: during type inference of shared(Float64)
```

The second call prints `Internal error: during type inference of shared(Float64)` with `TypeError(func=:typeassert, expected=Int64, got=Array{Any,1})` from `InferenceState`. That is `Compiler/src/inferencestate.jl:374` on master and `:339` on 1.13.0. It then recovers and returns the right answer through runtime dispatch. The result is a silent performance loss plus stderr noise. With the fix, `ssavaluetypes` is still `1` after the first call, and no internal error occurs.

No documented rule says a generator must return a fresh object, and `GeneratedFunctionStub` always builds one, so nobody has hit this. I first called it a policy choice between copying and documenting the rule. It is not:

- Documenting the rule would not fix the in-place rewrite at `:821`.
- The function's own header comment already says "Return a newly allocated CodeInfo".
- Two independent measurements put `jl_copy_ast` at 0.1-1% of one generator expansion: 0.14 us against 102 us for a one-statement body, and 85 us against 13 ms at 3000 statements.

Expected: the runtime copies what a generator returns. (The alternative would be to document the rule and report violations as a generator error.)

Fix: `func = (jl_code_info_t*)jl_copy_ast(ex)` at master `:819`, before the first mutation.

## 3. A generator's world range is validated too late and reported as an internal error

Status: not on the feature branch (the feature does not need it). The fix is preserved in Appendix A. Reproduces on 1.12.7 and 1.13.0, and master has the same code. Reproducer: `repro/repro-03.jl` (run it both with and without `--compile=min`).

A generator may restrict the world range of its result by setting `min_world`/`max_world` on the returned `CodeInfo`. `jl_code_for_staged` validates one thing about that range (`src/method.c:846-850`): if `edges == nothing` and `max_world == typemax`, then `min_world` must be `1`. It does not check that the range contains the world the body was requested for. That is checked much later, when `InferenceState` applies the generated-function restriction (`Compiler/src/inferencestate.jl:446-449`) and calls `update_valid_age!`. That call throws `error("invalid age range update")` (`:1336`).

```julia
function stalegen(world::UInt, source, argtypes...)
    ci = build_src()
    ci.min_world = 1
    ci.max_world = UInt(2)      # a stale snapshot
    ci.edges = Core.svec()
    return ci
end
```

Calling the method prints `Internal error: during type inference of stale(Int64)` / `ErrorException("invalid age range update")`, with an `update_valid_age!` <- `InferenceState` <- `typeinf_ext` backtrace, and then recovers. The message names neither the generator nor the range. The same string is used at two other sites (master `inferencestate.jl:264` and `:498`), so the error alone is not enough to diagnose the problem.

The interpreted path is worse. Under `--compile=min` nothing checks the range at all. The uninferred instance takes the generator's bounds, `jl_cached_uninferred` then never matches, and the stale body simply runs and returns. So the check has to live in `jl_code_for_staged`, the one place all three callers pass through (`src/interpreter.c:891`, `Compiler/src/utilities.jl:103/108`, `base/reflection.jl:34`). A better message on the Julia side would miss the interpreted path. With the fix, both paths raise `Generated function stale returned code valid for worlds [1, 2], which does not include the requested world 43046`. The world number differs between runs; the captured output in `repro-03.jl` shows 43042.

This is easy to hit by accident. `IRCode.valid_worlds` is a snapshot: its `max_world` is the world counter at the time the IR was produced, not `typemax`. A tool pasting IR it already inferred will naturally copy that range onto the body, which gives exactly this error.

Expected: a generator error naming the method and the range, in every execution mode.

Fix: next to the existing check in `jl_code_for_staged`, check `min_world <= world <= max_world`, and throw a `jl_errorf` naming the generator and both worlds.

## 4. `compileable_specialization` replaces a foreign `CodeInstance` with the native cache's

Status: fixed on master by commit (2) `inlining: Keep a foreign-owned CodeInstance as the invoke target` (`Compiler/src/ssair/inlining.jl:810-814`). **This is also a silent wrong answer on the 1.13.0 release, by a different route that commit (2) does not cover. That route is unfixed.** 1.12.7 is unaffected. Reproducer: `repro/repro-04.jl`.

Both routes come from JuliaLang/julia#60442 (`e1dda38c51`, 2026-01-24), which made the optimizer rewrite `invoke(f, ci, args...)` into `Expr(:invoke, ci, ...)`. I measured all four builds with one script (`repro-04.jl`). It uses the overlay `leaf(x) = x - 1` against the native `x + 1`, so 10 is the right answer and 30 means the body was swapped:

| Build | Result | What happens |
|---|---|---|
| 1.12.7 | 10 | The call stays dynamic and `jl_invoke` runs the right instance. |
| 1.13.0 | 30 | The native body is inlined. |
| pristine master | 30 | The `:invoke` target is swapped for the native instance. |
| fixed build | 10 | The foreign instance stays the `:invoke` target. |

**On 1.13.0, the native body is *inlined*.** `handle_invoke_expr!` drops the `CodeInstance` at once (`mi = get_ci_mi(edge)`) and calls `resolve_todo(mi, info, flag, state)` (1.13 `inlining.jl:1617-1620`). That call looks the `MethodInstance` up in the native cache (`get_cached_result(state, mi)`) and inlines whatever source it finds (1.13.0's `Compiler/src/ssair/inlining.jl:881-904`). The typed IR of the wrapper is `add_int(_2, 1); mul_int(%1, 10)`, and 1.13's `compileable_specialization` (`:795`) also takes the cache entry unconditionally. When the native cache has no source, `resolve_todo` returns `nothing`, the `:invoke` of the foreign instance survives, and the call is correct. So the bug appears only once the same method has also been compiled natively.

Master restructured this path: there, an `InvokeCICallInfo` is never inlined and goes to `compileable_specialization`, which is the swap described below. A 1.13 backport therefore needs its own small patch. In `handle_invoke_expr!`, skip the `MethodInstance`-keyed `resolve_todo` when `edge isa CodeInstance && edge.owner !== cache_owner(state.interp)`. This patch has not been written or tested.

Because of this, bugs 8 and 9 cannot be shown on 1.13.0: no foreign `:invoke` survives inlining to reach `compile!` or the JIT there. When the bug 5 and bug 9 reproducers print 31 and 30 on 1.13.0, that is this bug.

**On master, the `:invoke` target is swapped.** When the inliner keeps a call as an `:invoke` rather than inlining it, `compileable_specialization` looks in `code_cache(state)` for the callee's `MethodInstance`, and prefers the `CodeInstance` it finds there over the one it was handed (`inlining.jl:805-822`; `keep_direct_edge` at `:810` only covered the TypeEgal-ABI case, and `:812-814` replace `code`). The preference is right within the native cache, where any instance for that `MethodInstance` is interchangeable. It is wrong across owners. A `CodeInstance` produced by another `AbstractInterpreter` is a different compilation of the same method, and substituting the native one silently runs untransformed code.

Expected: a `CodeInstance` whose `owner` differs from `cache_owner(interp)` stays the call target (or the call is left unoptimized).

With commit (2), `keep_direct_edge` also holds when `code.owner !== cache_owner(state.interp)`. Without this, the transformed body is discarded whenever the same `MethodInstance` also has a native instance on its chain, which is the common case. You can reach this without the feature by writing `invoke(f, ci, args...)` with a foreign `ci` in a function that then gets compiled. The commit adds a test in `Compiler/test/AbstractInterpreter.jl`. Commits (5) and (6) were developed on top of it.

## 5. The package-image driver re-infers a foreign `invoke` target natively

Status: fixed by commit (6) `Compiler: Do not re-infer a foreign-owned invoke target natively`, together with bug 8 and the driver half of bug 9. The fix depends on commit (5) for what happens at run time. Reproduces on master; on 1.13.0 the same symptom appears, but through bug 4. Reproducers: `repro/repro-05.jl` (package-image round trip) and the five packages in `repro/review-pkgs/`.

`compile!` looked an `:invoke` target up in `interp.codegen`, which is the **native** interpreter's codegen cache. On a miss, it called `typeinf_ext(interp, mi, SOURCE_MODE_GET_SOURCE)` (master `typeinfer.jl:2134-2144`). That re-infers the callee under the native owner and queues *that* instance in its place, while the foreign callee is only marked as inspected. The symptom: after the image is loaded, a precompiled `caller(2)` returns 31 (the native callee) instead of 11. `repro-05.jl` shows the same result on 1.13.0 and on master plus the bug 4 fix: after loading, `caller(2) = 31` and `fci.invoke == C_NULL`, while `invoke(target, fci, 2)` directly raises `Failed to invoke or compile external codeinst`. Run in-process, the driver emits `[(:caller2, nothing), (:target, nothing)]`: a native `target`, and `fci` is not in the emitted set.

The source is available. The serializer keeps `ci.inferred` for foreign owners (`src/staticdata_utils.c:148`).

This bug does not depend on the generator. It affects any precompiled `invoke(f, ci, args...)` with a foreign `ci`.

Expected: `caller(2) == 11` after loading, or an error. It must never run the native body.

**How the fix got here.** The feature commit first carried a partial fix (`typeinfer.jl:2133-2139` at `af78494c04`): when the owner differs, use `ci_get_source(interp, callee)`. That was not sufficient on its own. When `ci_get_source` returned `nothing`, the code still fell through to native re-inference, so the bug became rarer but was not closed. The partial fix also led into bug 8.

The first complete fix made the image driver *error* on a foreign instance without source. It was reviewed on 2026-09-22 and sent back with two blockers, both verified:

- `inferred === nothing` is the normal state of any non-inlineable foreign instance, so realistic packages stopped precompiling.
- The error could not even print. `Base.string` has no methods in the driver's frozen world, so the worker died the same way as with the assert it replaced.

The revised version is what commits (5) and (6) contain:

- A foreign instance is emitted from its own source when `ci_get_source` finds it.
- Otherwise, both drivers skip it, as the JIT does, and leave the edge to the runtime. There, the trampoline from commit (5) runs the instance or raises `Failed to invoke or compile external codeinst`.
- Only under `--trim`, where there is no runtime fallback, does the driver hard-fail, using `Core.println` and `Core.TrimFailure` as the trim verifier does.

The owner test is `is_foreign_owned`, which treats the `:trim` owner as the native compiler's own namespace, as `aotcompile.cpp` does. The comment in `collectinvokes!` that described the native re-inference as deliberate (`typeinfer.jl:1916-1927`, from `e7fe47b022`, JuliaLang/julia#62001) is rewritten in commit (6). All five reviewer packages now precompile. The non-inlineable ones raise the deferred error at call time instead of silently returning the native result. The inlineable ones return the foreign result, 11. Commit (6) adds tests to `test/precompile.jl` and `Compiler/test/AbstractInterpreter.jl`. The feature's own test is `test/precompile.jl`, "GeneratedFunctionTransform invoke edge".

## 6. `aot_link_output` falls back to dispatching a foreign `CodeInstance` by `MethodInstance`

Status: fixed by commit (5) `codegen: Never dispatch a foreign-owned CodeInstance by MethodInstance`. The fix is in the shared `emit_tojlinvoke` funnel, not in `aot_link_output` alone, so it also covers the JIT (bug 9). Review found a third site, the `needsparams` arm of `emit_invoke` (`src/codegen.cpp:6331`), and commit (5) fixes it the same way.

Reproducers:

- `repro/review-pkgs/BigEphNR.jl` reproduces this on pristine master. It uses a non-inlineable foreign instance kept off the `mi.cache` chain. The driver never enqueues that instance, so the image's caller links to the `!theFunc` branch of `emit_tojlinvoke` (`src/codegen.cpp:7779-7783`) and runs the native body (31).
- `repro/repro-06.jl` shows only consistent symptoms. The bug 5 round trip leaves `fci.invoke == C_NULL` before and after `caller(2) = 31`, but that script cannot separate this fallback from bug 5.
- `repro/sp.jl` exercises the `needsparams` arm.

`aot_link_output` (`src/aotcompile.cpp:878-920`) resolves each call target in three steps:

1. an equivalent `CodeInstance` being compiled in the same output;
2. an equivalent one in the global cache;
3. a `pkg_plt` thunk for an image instance.

Both equivalence tests check `owner` (`jl_is_ci_equiv`, `src/gf.c:641-664`; `jl_get_ci_equiv_range`, `aotcompile.cpp:852-873`), so they are safe. The final fallback is not. `emit_tojlinvoke(ci, StringRef(), out)` with an empty name takes the branch at `src/codegen.cpp:7779-7783` (master `:7952-7957`), which discards the `CodeInstance` and emits `jl_invoke(args, nargs, mi)`. For a foreign-owned instance, that re-dispatches into whatever the native cache holds: the same ownership swap as bugs 4 and 5, now at link time. Because both equivalence tests are owner-aware, a foreign-owned target that was not itself emitted *always* lands in this fallback.

`jl_f_invoke` in the interpreter already handles this correctly. A foreign-owned `CodeInstance` with no compiled code raises `"Failed to invoke or compile external codeinst"` (`src/builtins.c:1948`) rather than falling back to the `MethodInstance`.

Expected: a call target with `ci->owner != jl_nothing` is never re-dispatched into the native cache. It either runs the instance or raises the same error as `jl_f_invoke`.

These notes originally argued that the AOT path should fail at build time. Because a source-less foreign instance is normal (see §5), commit (5) instead makes the error deferred and identical to the builtin's. It adds `jl_invoke_codeinst`, shared with `jl_f_invoke`, which runs the `CodeInstance` itself (trying to compile it first) or raises that error. Both `emit_tojlinvoke` and the `needsparams` arm route a foreign instance to it. `jl_is_native_ci_owner` names the owner test.

## 7. `abstract_invoke` compares a `CodeInstance`'s owner against the type `Nothing`

Status: fixed by commit (3) `inference: Do not infer invoke of a foreign CodeInstance as nothrow`. The line arrived with JuliaLang/julia#56660 (`efa917e877`), and `repro-07.jl` shows the bug on 1.13.0 as well as master. Reproducer: `repro/repro-07.jl`.

```julia
# TODO: When we add curing, we may want to assume this is nothrow
if (method_or_ci.owner === Nothing && method_or_ci.def.def isa Method)
    exct_ci = Union{exct_ci, ErrorException}
end
```

This is `Compiler/src/abstractinterpretation.jl:2559` (master `:2555-2558`). A native instance's owner is the value `nothing`, never the type, so the branch is dead. The polarity is reversed as well. `jl_f_invoke` throws `"Failed to invoke or compile external codeinst"` exactly when the owner is *not* `nothing` and the instance cannot be compiled (`src/builtins.c:1947`; master `:2133-2142`), and it never consults `def.def isa Method`. So `invoke(f, foreign_ci, args...)` is inferred nothrow.

Measured on 1.13.0 with a foreign instance that has no code:

- `infer_exception_type` is `Union{}`.
- The effects are `(+c,+e,+n,+t,+s,!m,+u,!o,+r)`.
- `drop(x) = (invoke(target, ci, x); 1)` optimizes to `return 1`, while the direct call throws.

With the fix, the exception type is `ErrorException`, the effects include `!n`, and `drop` keeps the `:invoke`. `drop(2)` still returns 1 there, but for a different reason: the JIT-trampoline half of bug 9, which was unfixed in that build.

The line was last touched by `ea7dbfc6a1` (JuliaLang/julia#60414, "Fix typo in `abstract_invoke`"). That commit fixed an undefined variable `method_ir_ci` on the same line. That typo could never have fired either, because the dead first operand short-circuits the condition. That is how both survived.

Expected: `ErrorException` in the inferred exception type for a foreign-owned `CodeInstance`, as the comment above the branch intends.

The fix is `method_or_ci.owner !== nothing`. It is conservative rather than exact. With no `codegen_cache`, the builtin `invoke` throws, while a compiled `Expr(:invoke, foreign_ci)` links from `ci->inferred` and runs. Inference has to assume the throwing case.

## 8. The compile drivers insert a foreign `CodeInstance` into the native cache and assert

Status: fixed by commit (6) `Compiler: Do not re-infer a foreign-owned invoke target natively`. With it, a foreign instance is never inserted into `code_cache(interp)`, and an off-chain one is rooted through `jit_cache_root!(nothing, ci)`. Reproduces on master only. Reproducer: `repro/repro-08.jl` ([a] `compile!` in-process, [b] the JIT path, [c] a precompiled package).

Both drain loops end with `code_cache(interp)[mi] = callee` when `jl_mi_cache_has_ci(mi, callee) == 0` and `find_equivalent_cached_ci` finds nothing:

- `compile!` (package images) at `Compiler/src/typeinfer.jl:2162`, which is master `:2157`;
- `add_codeinsts_to_jit!` (the JIT) at `:2054`, which is master `:2056`.

`setindex!` asserts `ci.owner === cache.owner` (`Compiler/src/cicache.jl:45`), and `@assert` is always live in Julia. Take an interpreter whose cache is not on the `MethodInstance` chain, such as `@newinterp X true`, an ephemeral `IdDict`. The instance is not found on the chain, so the insert is reached, and it raises an `AssertionError`. During precompilation, that error is fatal to the package. On master, `repro-08.jl` gives:

- [a] `AssertionError` from `compile!`;
- [b] an `AssertionError` from `add_codeinsts_to_jit!`. When reached through `jl_type_infer`, it shows up as `Internal error: during type inference of eph_caller(Int64)`, followed by `eph_caller(2) = 30`, the native body.
- [c] `fatal: error thrown and no exception handler available`, then `Failed to precompile ForeignInvokeEph`.

In [c], a secondary problem hides the assertion text. In the sysimage `Compiler`, the message construction in `@assert` calls `Base.string` in a world where it has no method for `Expr`, so the worker dies with a `MethodError` instead.

On 1.13.0 all three cases pass. That is not because the insert is guarded: the 1.13 inliner never leaves a foreign `:invoke` in the IR (bug 4).

Whether the feature's partial `compile!` fix (§5) opened this depends on the configuration. Both earlier statements of it in these notes were half right.

- **Uncompiled ephemeral instance: pre-existing.** When `collectinvokes!` probes the edge (`:1913`), `ci_has_source` writes the foreign source into the native codegen cache (`typeinfer.jl:1563`). So the old `get(interp.codegen, callee, nothing)` already finds source and reaches the insert. `repro-08.jl` reproduces this through the real driver.
- **Already compiled instance: opened by the partial fix.** Here `ci_has_invoke(edge)` short-circuits that probe, and the native codegen cache stays empty. Before the feature's partial fix, the code fell into native re-inference, the silent swap of bug 5. The partial fix's `ci_get_source` supplied source instead, reached the insert, and turned the silent wrong answer into a hard precompile error. I reproduced this with a bare `invoke(f, ci, x)` package and no generator: `repro/pkgs/ForeignInvokeEph.jl`, built with the feature's partial fix. On pristine master, that package takes the native re-inference path instead.

On-chain foreign caches (`InternalCodeCache(owner)`) skip the insert, which is why only ephemeral caches show the assertion.

Expected: another owner's `CodeInstance` is never inserted into `InternalCodeCache(nothing)`.

Fix: insert only when `callee.owner === cache_owner(interp)`, and root a foreign instance another way (`jit_cache_root!`, `typeinfer.jl:2000-2007`). `find_equivalent_cached_ci` cannot rescue it, because it already requires equal owners (`:1686`).

## 9. The JIT re-infers a foreign target natively, and its trampoline dispatches by `MethodInstance`

Status: fixed in two halves. Commit (6) `Compiler: Do not re-infer a foreign-owned invoke target natively` makes `add_codeinsts_to_jit!` emit a foreign instance from its own source, or skip it. Commit (5) `codegen: Never dispatch a foreign-owned CodeInstance by MethodInstance` makes the trampoline hand the instance to `jl_invoke_codeinst`. Reproduces on master only. Reproducers: `repro/repro-09.jl`; `repro/owner_repro.jl`, case C (cases A-D cover the JIT and driver paths for ephemeral and on-chain foreign instances); and `repro/nocodegen.jl`, the builtin-only variant.

`add_codeinsts_to_jit!` (`Compiler/src/typeinfer.jl:2032-2043`; master `:2034-2044`) is the run-time twin of bug 5. On a `ci_get_source` miss, it calls `typeinf_ext(workqueue.interp, callee.def, source_mode)` with no owner test. The caller's IR still `:invoke`s the foreign instance, which the JIT never compiled. So `JuliaOJIT::linkCallTarget` falls through to `JLTrampolineMaterializationUnit`, then to `emit_tojlinvoke(CI, "", Out)` (`src/jitlayers.cpp:1194`), and finally to the same `jl_invoke(args, nargs, mi)` branch as bug 6.

`repro-09.jl` puts a foreign instance on the chain and clears its source, as happens after an image load or cache trimming. The compiled caller returns 30, the native body, while `invoke(target, own_ci, 2)` on the *same* instance throws `Failed to invoke or compile external codeinst`, and `own_ci.invoke` stays `C_NULL`. The compiled and interpreted paths disagree about one object. 1.13.0 also prints 30, but by bug 4's route. The feature's own instances escaped this only because they already have `invoke` set when they reach the loop (`ci_has_invoke` at `:2020`).

Expected: the compiled caller behaves like the builtin. It either throws or runs the foreign body, never the native one.

## 10. A generator that infers code can re-enter its own generation without bound

Status: fixed by commit (4) `method: Bound re-entrant generation of a MethodInstance`. Reproduces on 1.12.7 and 1.13.0 with nothing but `Base.Compiler.NativeInterpreter`; master has no guard either. Reproducer: `repro/repro-10.jl` (variants `capped` and `uncapped`).

Consider a `Core.CachedGenerator` that runs `typeinf_ext_toplevel` on its callee, over `ping(n) = od(pong, n-1) + 1; pong(n) = od(ping, n-1) + 1`. The chain goes like this:

1. Generating `od(ping, ::Int)` infers `ping`.
2. `ping` needs the body of `od(pong, ::Int)`, whose generation infers `pong`.
3. `pong` needs `od(ping, ::Int)` again, whose body does not exist yet, so the chain starts over.

Each level is a new top-level inference, so inference's own cycle detection never sees it. `jl_engine_reserve` keys on `(mi, owner)` and just hands a same-thread re-entry a placeholder (`src/engine.c:94-129`). The `CachedGenerator` cache is written only after the generator returns.

On 1.13.0:

- With a depth cap of 25, the generator is entered 26 times for `od(ping, 4)`.
- Uncapped, the recursion runs to about 730 nested generator frames (732 in the recorded run) and prints stack-overflow warnings. Then it either recovers or deadlocks on the JIT lock (`jl_compile_codeinst_now` <- `jl_fptr_wait_for_compiled`). It recovers when `get_staged` swallows the `StackOverflowError`, which happened in 2 of 7 runs, with 737 generator entries and `result = 4`.
- This script produced no segfault. The segfault first recorded for this bug was actually bug 1, reached because the original reproducer recorded a `CodeInstance` edge. `repro-10.jl` uses `edges = svec(mi)` to stay clear of that crash.

This is Differ.jl issue #84. It is also what the feature's first version worked around, for its own generator only, with a task-local `generating_stack`. The same script on that build recursed until its depth cap.

Expected: two specializations need two generations. Re-entry for a `MethodInstance` already being generated on the same thread should be refused.

Commit (4) keeps a per-thread stack of the `MethodInstance`s being generated in `jl_code_for_staged`, threaded through the C frames. Task switches are forbidden inside a generator (`in_pure_callback`, `src/task.c:680`), so a per-thread record is exact. The guard allows one re-entry and errors on the next. `get_staged` treats the error as "no body", so the refused call site compiles without knowledge of its result and resolves at run time. For ping/pong, the generator runs 4 times: each of the two specializations once, and each re-entered once. The result is 4. Generating a *different* `MethodInstance` from inside a generator is unaffected, including a generated function recursing into itself under another signature.

The guard's first version refused the *first* re-entry, and that was a regression. `Compiler/test/inference.jl:116` caught it: the `wrapper62338_gencache` test from JuliaLang/julia#62359, whose generator calls `precompile` on a caller of itself. On master, that nests to depth exactly 2 and stops by itself. Inference entered through `jl_type_infer` refuses to recur on a `MethodInstance` the thread has reserved (`jl_engine_hasreserved`, `src/gf.c:442`). Refusing at depth 1 made the nested session publish the cycle with an uninferred edge to the generated method, which is a degraded cached result. Only a generator that calls the compiler directly (`typeinf_ext_toplevel`) bypasses the engine check, so the guard only has to stop what the engine does not. I measured the self-`precompile` case on a pristine-master build and on the fixed build: both give 2 generator entries at depth 2.

A lesson about testing here. `test/runtests.jl Compiler/...` runs against the sysimage `Compiler`, not `Compiler/src` loaded from source; that needs `--project=Compiler`. Also, `make` does not rebuild the sysimage if a `Compiler` file was edited while the previous build was still reading it. Both of these bit once. Before trusting a result, check that the running method's IR contains the change.

## Verification record

Two trees were verified. Both were based on master `55312b3c97`, and both held their fixes as uncommitted changes. The rebuilt branch as a whole (the six commits plus the feature) was then run on 2026-09-23: `staged`, `Compiler/AbstractInterpreter`, `precompile`, `Compiler/inference` and `reflection` gave 3618 pass, 13 broken, 0 fail, and the clang analysis of `method.c`, `gf.c`, `codegen.cpp` and `builtins.c` was clean on the six-fix tree.

**Generated-function and inference fixes (bugs 1, 2, 3, 4, 7, 10), 2026-09-21.** This tree had one prepared commit per fix, in this order: 1, 4, 7, 3, 2, 10. It passed:

- `test/staged.jl`, also under `--compile=min`;
- all of `Compiler/test`;
- a 41-suite regression sweep;
- `test/trim.jl`;
- the clang analysis of `src/method.c`.

An independent review judged all six fixes ready. The sweep's one real failure, `Compiler/test/inference.jl:116`, was a regression from the first version of the re-entry guard, and it is fixed (see bug 10). Bugs 2 and 3 were part of this tree; the rebuilt branch drops them (Appendix A).

**Foreign-owner compile fixes (bugs 5, 6, 8, 9), 2026-09-22.** This tree was built on top of the bug 4 `keep_direct_edge` change, and split into a runtime part (`src/`, now commit (5)) and a driver-and-tests part (now commit (6)). The first version was sent back in review (§5). The revised version was verified in a separate session on seven packages:

- the five reviewer packages in `repro/review-pkgs/`, all with a non-inlineable `target`:

  | Package | Foreign instance |
  |---|---|
  | `BigOwnedABI` | on-chain, ABI-compiled |
  | `BigOwnedNR` | on-chain, inference only |
  | `BigEphNR` | ephemeral cache, inference only |
  | `RefOnly` | `caller` never precompiled |
  | `RefOuter` | `caller` reached only through a precompiled `outer` |

- the two inlineable packages in `repro/pkgs/` (`ForeignInvoke`, `ForeignInvokeEph`).

Run them with `JULIA_DEPOT_PATH=<fresh> JULIA_LOAD_PATH="review-pkgs:@stdlib" julia review-pkgs/runpkg.jl BigOwnedABI`, from `repro/`; use `pkgs:@stdlib` for the other two. They include `Compiler/test/newinterp.jl` from the running source build. On pristine master, every package's `caller(2)` returns 31, the native body. With the fix, the non-inlineable packages throw `Failed to invoke or compile external codeinst`, and the inlineable ones return 11. The suites `precompile`, `Compiler/AbstractInterpreter`, `Compiler/inference`, `Compiler/inline`, `staged` and `trim` gave 3277 pass, 16 broken, 0 fail. The clang analysis of `gf.c`, `codegen.cpp` and `builtins.c` is clean. The author's own reproducers, `repro/owner_repro.jl` (cases A-D), `repro/nocodegen.jl` (builtin only) and `repro/sp.jl` (`needsparams`), were used alongside the packages.

**Reproducers.** Each `repro/repro-NN.jl` is self-contained: an inline interpreter, no includes, no packages. Each carries its captured output in its header, from Julia 1.13.0 (`d1c37793dd2`) and from a local build ("fixes-build", 1.14.0-DEV.3318, master `55312b3c97` plus the uncommitted fixes for bugs 1-4, 7 and 10). For bugs 5, 6, 8 and 9, that build *is* master behaviour. Bug 4's pristine-master result (30) and the bug 10 depth-2 comparison were measured on a pristine-master build.

**Where the fixes belong.** A layering audit of the feature's first version settled two placement questions, and the current commits follow them. The recursion guard belongs in the runtime, around `jl_call_staged` in `jl_code_for_staged`. That function already has the `MethodInstance`, which the generator ABI hides from the generator. A guard there covers every generator kind, including hand-rolled `CachedGenerator`s and the Differ.jl #84 class. The engine cannot take this over: `jl_engine_reserve` keys on `(mi, owner)`, and "being generated" is a different fact from "reserved for inference". The `compile!` fix belonged in both compile drivers and in codegen's shared `tojlinvoke` funnel, not in the feature. Patching one driver left the silent swap reachable through the other driver and through the link-time and JIT fallbacks (bugs 6, 8, 9).

## Filing upstream

Nothing has been filed. The per-bug sections above are the issue texts. Each section already carries the cause, a minimal reproducer, the observed and expected behaviour, and a proposed fix. Each issue should link its `repro/repro-NN.jl` and quote the relevant part of its header. For bug 6, use `repro/review-pkgs/BigEphNR.jl`; `repro-06.jl` cannot isolate that bug. Use this environment block:

```
Julia Version 1.13.0, Commit d1c37793dd2 (2026-09-09 19:00 UTC), official release
Linux x86_64 (AMD EPYC 9555), LLVM 20.1.8, stock GC
master: 1.14.0-DEV.3318, 55312b3c97 (2026-09-21)
```

When filing:

- **Quote master line numbers.** The sections mostly cite `ca626376c0`; the master (`55312b3c97`) equivalents are given in parentheses where the issue drafts had them.
- **Bugs 5, 6, 8 and 9 share one control flow and one fix pair,** commits (5) and (6). They can be filed separately, but each should point to the others. The fix for 5 must land with the fix for 8, because the same control flow reaches the insert.
- **Bug 4 has two filings in one.** One is the master regression, fixed by commit (2). The other is the 1.13.0 inlining route, which needs the `handle_invoke_expr!` guard described in §4 if a backport is wanted.
- **Bugs 2 and 3** go with their patches from Appendix A as standalone PRs.
- **When a fix is proposed as a PR,** use its commit message as the PR body. Note that it was independently reviewed, and state how carefully the human author has read it.

## Appendix A: the two fixes not on the branch

The feature does not need these fixes, so they are kept here to be proposed as standalone PRs. Each has a `src/method.c` patch and a `test/staged.jl` patch. All four apply to master `55312b3c97` and to the current rebuilt-branch tip, but **the copy test patch applies only after the world-range test patch**: its context includes the world-range test. So apply the world-range fix first, as the original commit order did. The method patches are independent of each other.

### A.1 World range (bug 3)

```
method: Reject a generator result that excludes the requested world

A generator may restrict the world range of the `CodeInfo` it returns,
but nothing checked that the range contained the world the body was
requested for.  On the compiled path the mismatch surfaced later as
an internal error from `InferenceState`, `invalid age range update`,
a message shared with other sites that names neither the generator nor
the range; on the interpreted path nothing checked at all and the stale
body ran. This is easy to hit by copying `IRCode.valid_worlds`, whose
upper bound is a snapshot of the world counter, onto the returned body.

Validate the range where the result is received and name the generator
and both worlds in the error.
```

`fix-world-range.method.patch`:

```diff
--- a/src/method.c
+++ b/src/method.c
@@ -848,6 +848,10 @@
                 jl_error("Generated function result with `edges == nothing` and `max_world == typemax(UInt)` must have `min_world == 1`");
             }
         }
+        if (func->min_world > world || func->max_world < world) {
+            jl_errorf("Generated function %s returned code valid for worlds [%zu, %zu], which does not include the requested world %zu",
+                      jl_symbol_name(def->name), func->min_world, func->max_world, world);
+        }

         if (cache || needs_cache_for_correctness) {
             // TODO: this should poison the runtime, so that attempts to call save in staticdata afterwards will abort,
```

`fix-world-range.test.patch`:

```diff
--- a/test/staged.jl
+++ b/test/staged.jl
@@ -490,6 +490,22 @@
 @test doit_mixed(1) == 3
 @test mixed_edges_runs[] == 3

+# A generator's result must be valid for the world it was requested for; a stale range
+# (e.g. copied from `IRCode.valid_worlds`) is rejected up front instead of surfacing as an
+# internal error from inference
+function stale_world_gen(world::UInt, source::Method, self, x)
+    src = generate_lambda_ex(world, source, (:doit_stale, :x), (), :(x))
+    src.edges = Core.svec()
+    src.min_world = UInt(1)
+    src.max_world = UInt(2)
+    return src
+end
+@eval function doit_stale(x)
+    $(Expr(:meta, :generated, stale_world_gen))
+    $(Expr(:meta, :generated_only))
+end
+@test_throws "does not include the requested world" doit_stale(1)
+
 # Test that writing a bad cassette-style pass gives the expected error (#49715)
 function generator49715(world, source, self, f, tt)
     tt = Base.type_parameter(tt)
```

### A.2 Copy (bug 2)

```
method: Copy a generator's result before using it

`jl_code_for_staged` rewrote the statements of the `CodeInfo` a generator
returned in place and then handed the same object to inference, which
mutates it further. The two paths that serve a cached body already copy;
the ordinary path did not. A generator returning an object it keeps,
such as a prepared body stored in a table, therefore saw it corrupted;
inference of the next specialization started from a half-inferred body,
failed with an internal error and fell back to the interpreter.

Copy the result on entry, as the function's own contract ("Return a newly
allocated CodeInfo") states.
```

`fix-copy.method.patch`:

```diff
--- a/src/method.c
+++ b/src/method.c
@@ -816,10 +816,13 @@
         if (!jl_is_code_info(ex)) {
             jl_error("As of Julia 1.12, generated functions must return `CodeInfo`. See `Base.generated_body_to_codeinfo`.");
         }
-        func = (jl_code_info_t*)ex;
+        // The generator may return an object it keeps (a prepared body stored in a
+        // table, say); the statements are rewritten in place below and the caller
+        // mutates the result while inferring it, so work on a copy.
+        func = (jl_code_info_t*)jl_copy_ast(ex);
+        ex = NULL;
         jl_array_t *stmts = (jl_array_t*)func->code;
         jl_resolve_definition_effects_in_ir(stmts, def->module, mi->sparam_vals, NULL, 1);
-        ex = NULL;

         // If this generated function has an opaque closure, cache it for
         // correctness of method identity. In particular, other methods that call
```

`fix-copy.test.patch` (apply after `fix-world-range.test.patch`):

```diff
--- a/test/staged.jl
+++ b/test/staged.jl
@@ -490,6 +490,23 @@
 @test doit_mixed(1) == 3
 @test mixed_edges_runs[] == 3

+# A generator's result is copied before it is used: returning an object the generator
+# keeps must not hand a half-inferred body to the next specialization
+const shared_body_store = Dict{Symbol,Core.CodeInfo}()
+function shared_body_gen(world::UInt, source::Method, self, x)
+    get!(shared_body_store, :body) do
+        generate_lambda_ex(world, source, (:doit_shared, :x), (), :(x))
+    end
+end
+@eval function doit_shared(x)
+    $(Expr(:meta, :generated, shared_body_gen))
+    $(Expr(:meta, :generated_only))
+end
+@test doit_shared(1) === 1
+@test shared_body_store[:body].ssavaluetypes isa Int
+@test doit_shared(1.0) === 1.0
+@test doit_shared("a") === "a"
+
 # A generator's result must be valid for the world it was requested for; a stale range
 # (e.g. copied from `IRCode.valid_worlds`) is rejected up front instead of surfacing as an
 # internal error from inference
```

## Appendix B: notes for the PR texts

These are open points and remarks from the notes that a PR description or reviewer will need. They are not new findings.

1. **Exports (commit 5).** `jl_invoke_codeinst` and `jl_is_native_ci_owner` are `JL_DLLEXPORT` but not listed in `src/jl_exported_funcs.inc`. The precedent is `jl_invoke_oc`. Codegen references `jl_invoke_codeinst`, so Windows and macOS linking needs CI to confirm.
2. **The `:trim` owner (commits 5 and 6).** `jl_is_native_ci_owner` and `is_native_owner` treat `:trim` as the native compiler's own namespace, because it is re-stamped to `nothing` on serialization (cf. `aotcompile.cpp`). The PR text should say this explicitly.
3. **Deferred error rather than build-time error (commits 5 and 6).** A source-less foreign instance is the normal state of a non-inlineable one. So the drivers skip it, and the trampoline raises the builtin's error at call time. Only `--trim` hard-fails. It uses `Core.println` and `Core.TrimFailure`, because `Base.string` has no methods in the driver's frozen world. §5 records why the erroring first version was rejected.
4. **The `collectinvokes!` comment (commit 6).** The comment from `e7fe47b022` (JuliaLang/julia#62001) described native re-inference of foreign edges as intended. Commit (6) rewrites it; the PR should call this out, since it reverses a stated intent.
5. **Conservative rather than exact (commit 3).** Inference now assumes `invoke` of a foreign instance may throw, even though a compiled `Expr(:invoke, foreign_ci)` can link from `ci->inferred` and run.
6. **Exactly one re-entry (commit 4).** Refusing the first re-entry regressed `Compiler/test/inference.jl:116` (JuliaLang/julia#62359); §10 explains why depth 2 is the bound the engine already enforces.
7. **Follow-up for commit 1.** The duplicate C decoder could be removed by returning "won the cache race" to Julia and calling `store_backedges` there.
8. **1.13 backport.** Commit (2) does not fix 1.13.0, which needs the `handle_invoke_expr!` guard from §4. That patch has not been written.
9. **`@assert` in the sysimage `Compiler`.** The assertion message is built with `Base.string`, which can have no method in the compiler's world, so the assertion text is lost (§8 [c]). This is a separate problem and is not filed.
10. **Cost of the copy (Appendix A.2).** Quote the measurement from §2 in the PR: `jl_copy_ast` is 0.1-1% of a generator expansion.
