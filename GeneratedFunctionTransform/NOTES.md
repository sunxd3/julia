# Background notes: `Core.GeneratedFunctionTransform`

## The machinery the feature touches

**The four objects.** Method (`src/julia.h:413`) -> MethodInstance (`:491`) -> CodeInstance (`:540`), CodeInfo (`:363`). `owner` is on CodeInstance, not MethodInstance, so two interpreters share one MethodInstance and hang separate instances on its `next` chain.

**World age and invalidation.** One narrowing function, `update_valid_age!` (`Compiler/src/inferencestate.jl:1333`). Forward edges on the CI, backedges on the callee MI, written by `store_backedges` (`Compiler/src/typeinfer.jl:871`). `max_world` is provisional until `jl_promote_cis_to_current` (`src/gf.c:2181`) sets it to infinity under the world lock. Trigger is `jl_method_table_insert` (`src/gf.c:3455`) -> `jl_method_table_activate` (`:3193`), two branches (exact replacement `:3250`, shadowing `:3290`), both ending in `invalidate_code_instance` (`:2425`). Replaced method's own instances are never capped, only callers. Regeneration is lazy: old CI stays on the chain behind the new one.

**Opaque closures.** Struct `src/julia.h:518`; world stamped at creation `src/opaque_closure.c:135`; edges kept but never registered, instance world range [world, world] `:171`; body is a Method outside every table (`src/method.c:1203`). Inference: `PartialOpaque` (`base/boot.jl:680`) from `opaque_closure_tfunc` (`Compiler/src/tfuncs.jl:2434`); eager body inference at creation (`abstractinterpretation.jl:3618`); calls via `abstract_call_opaque_closure` (`:3133`); no-source escape hatch `:3143`. Optimizer: inline via `handle_opaque_closure_call!` (`inlining.jl:1601`), captures via `getfield(oc, :captures)` (`:346`), SROA lifts captures (`passes.jl:457`), creation removable (`optimize.jl:448`), return bound narrowed (`narrow_opaque_closure!`, `inlining.jl:1255`). Codegen: creation inline with `get_oc_function` (`codegen.cpp:7434`), calls via `emit_specsig_oc_call` (`:6242`, indirect through `specptr`). Across the type boundary: declared RetT only, `Effects()`, no specialization, no inlining. This is structural (frozen world), not laziness.

**Mooncake's use.** `opaque_closure` at `Mooncake.jl/src/utils.jl:447` (forces return type); `optimise_ir!` at `Mooncake.jl/src/interpreter/ir_utils.jl:275` is a hand-driven copy of the optimizer pipeline on synthetic IR (fabricated toplevel MI, manual inlining/SROA/ADCE, version-gated, `BugPatchInterpreter` workaround). Inlining is intra-rule only; rule-to-rule calls are OC boundaries. `src_inlining_policy` override (`abstract_interpretation.jl:312`) is the legitimate part. Its per-(world, signature) `oc_cache` is at `Mooncake.jl/src/interpreter/abstract_interpretation.jl:13`.

**tfuncs.** Type transfer functions for builtins/intrinsics; table at `Compiler/src/tfuncs.jl:55` and `:57`, registered by `add_tfunc`, dispatched from `builtin_tfunction` (`:3115`) via `abstract_call_builtin` (`abstractinterpretation.jl:2242`).

**The diff itself.** Generator at `Compiler/src/generators.jl:69`; recursion guard `:84`; edges + world range `:115`. `abstract_invoke` CI branch `abstractinterpretation.jl:2549` (trusts rettype/exct/effects, narrows world, negative narrowing when out of range). Ownership fix `inlining.jl:781`. C decoder `src/method.c:875`. Two worlds: generator runs pinned to `primary_world` (`src/method.c:807`), lookup + inner inference use requesting `world`.

## Conclusions reached

- The feature is best framed as the less-opaque alternative to OpaqueClosure: same "trust the object, don't inspect it" shape at the boundary, but on the world clock, on the real MI, with edges.
- What crosses the boundary now: effects, exact per-signature return type, constant-return folding at codegen, direct call to a known symbol, world range, shared cache. What stays opaque: inlining the transformed body into native code (policy, could be relaxed per owner).
- Where OC is still better: abstract callers (generator only fires on dispatch tuples, so caller infers `Any`); a declared type is a contract, but only on the opaque path. Verified on the in-tree 1.14-dev build 2026-09-15: `@opaque Tuple{Int}->Int (x)->x+y` with `y=1.5` throws `TypeError` when called opaquely but returns 2.5 when creation and call are inlined together.

## Fact checks (measured on the in-tree build, 2026-09-15)

- Dynamic OC call cost: 19 ns vs 17 ns for a dynamic generic call (`callany(g::Any, x)` loop). A "~450 ns per dynamic OC call on 1.12+" claim from an external report is not the plain dynamic call path and is not cited in the RFC.
- Both `@cfunction($oc, Int, (Int,))` and `@cfunction(oc, Int, (Int,))` work on the in-tree build (both return 3 for input 2; the `$` form needs `.ptr` in a `ccall`). A "closures cannot go through `@cfunction`" claim is wrong here.
- OC "edges are dropped" is imprecise: `src/opaque_closure.c:171-176` keeps the svec edges but creates the instance with `min_world == max_world == world` and never registers backedges.

## Package images (tested 2026-09-15; was broken before the fix that day)

Symptom: `caller(2)` returned 31 (native `target`) instead of 11 after loading the image. Cause: `compile!` (`Compiler/src/typeinfer.jl:2132`) looked a foreign-owned `:invoke` edge up only in the native interpreter's `codegen_cache`, missed, re-inferred the MI natively, and never emitted the foreign CI; `aot_link_output` (`src/aotcompile.cpp:908`) then emitted a `tojlinvoke` thunk that re-dispatches by MI, i.e. the ownership swap at link time. Fix: `compile!` now uses `ci_get_source(interp, callee)` (decompresses `ci.inferred`, which the serializer keeps for foreign owners, `src/staticdata_utils.c:148`) when `callee.owner !== cache_owner(interp)`. Test: `test/precompile.jl` "GeneratedFunctionTransform invoke edge". Edge verification lives in `Compiler/src/reinfer.jl` (`verify_method`).

Note that this bug is independent of the generator: it affects plain `invoke(f, ci, ...)` (julia#56660) in package images.

Still open: the C fallback in `aot_link_output` should error (like `src/builtins.c:1948` "Failed to invoke or compile external codeinst") rather than re-dispatch by MI for a foreign-owned CI with no code; it is now unreachable for this feature but is a latent hazard for any precompiled user-level `invoke(f, ci, ...)`.

Contrast with OC: instances in pkgimages segfault by design (julia#55073, #62180).

## Recursion through the generated method (found and fixed 2026-09-15)

Reproduction: `ping(n) = overdub(pong, n-1)+1; pong(n) = overdub(ping, n-1)+1; overdub(ping, 4)`. Inference of `overdub(ping,::Int)` runs the generator -> fresh interp -> `typeinf_ext_toplevel(ping(::Int))` -> needs the body of `overdub(pong,::Int)` -> generator -> fresh interp -> `pong(::Int)` -> needs `overdub(ping,::Int)` whose body does not exist yet (first generator has not returned) -> generator again -> ... Observed: 880 generator runs, two "detected a stack overflow; program state may be corrupted" warnings, then `get_staged` swallows the error, the call infers `Any`, runtime dispatch regenerates at top level and the answer (4) is right. Plain recursion inside a transformed body (`fact`) is fine: 1 generator run, ordinary inference cycle in the tool's domain. Why not caught: inference cycle detection walks `sv.parent` within one inference; each nested `typeinf_ext_toplevel` is a new root with a new interpreter. `jl_engine_reserve` (`src/engine.c:84-130`) detects a thread waiting on itself but on same-thread re-entry just proceeds with a new placeholder (`cond` path). This is Differ's issue #84 / its `dualized_impl_in_progress` guard, in our setting.

Fix: a per-task stack of `(source, fullsig)` in progress in `generate_transformed_body` (`generating_stack` in `generators.jl`); on re-entry throw (matches RFC §4.4 semantics). Verified after the fix: the refused call site is compiled as `Expr(:invoke, MethodInstance for overdub(::typeof(ping), ::Int64), ...)` (dispatch resolved statically, no CI, result `Any`); at run time it finds the body cached by the outer level. ping/pong: 2 generator runs, no stack overflow. Cost per cycle edge: one code lookup plus an untyped result. For the AD use case (rules calling `overdub` on every callee) recursive primals make this the common case, so this matters. Tests `gft_overdub5` ping/pong, self, fact in `Compiler/test/AbstractInterpreter.jl`; RFC §4.2 covers it; docstring paragraph added.

## `--trim` (tested by hand 2026-09-15, works)

The RFC Appendix A program with an inline interpreter struct (since `Compiler/test/newinterp.jl` pulls in InteractiveUtils), built with the pinned JuliaC (`deps/jlutilities/juliac`) via `-m JuliaC --output-exe gfttrim --trim=safe --experimental <proj> --bundle <out>`: binary prints `caller(2) = 11`, empty build log (no verifier warnings), 1.68 MB. Not yet a `test/trim/` project; adding one would be cheap (copy the `test/trim/Hello` layout).

## Differ.jl (prior art; clone inspected at HEAD e61b6b1, 2026-09-15)

A hand-rolled GFT: `@generated frule!!/rrule!!` -> `ContextualInterpreter` built at the generator world -> `typeinf_ext_toplevel(..., SOURCE_MODE_ABI)` on a carrier method whose body the interpreter swaps in `finishinfer!`/`optimize` (`Contextual/src/Contextual.jl:198-236`) -> body `return invoke(dualized_impl, $cinst, dualargs...)` (`DifferForwards/src/forward_interp.jl:1970`, verified). `cache_owner = Forward()`/`Reverse(...)`; edges folded into the carrier CI; world range `[interp.world, typemax]`; tests `test_backedges.jl`, `test_world_ranges.jl`. No OC in the engine (verified by grep). Descends from Mooncake PRs #593/#900 (both closed unmerged). README (verified): "Differ's code-generation phase happens at compile-time inside a `@generated function`", 1.13-only, "made for fun". Reverse header: "Unlike Mooncake (two OpaqueClosures sharing captured state), the two passes here are ordinary CodeInstances and the shared state is an explicit Tape value."

Pain points it documents, which GFT addresses or must address: `get_world_counter()` returns a `typemax` sentinel inside generators and dispatch is pinned to `primary_world` (they use `Core._call_in_world_total` + mandatory mt-edges); re-entrant `typeinf_ext_toplevel` inside a generator "fragile", crashes at 3 nesting levels (their issue
#84); recursion across generator boundaries needs cycle guards; `src_inlining_policy` to block inlining of hand-ruled callees; a transform that bails compiles a throwing stub. Not independently verified: the `finishinfer!` swap and the nesting crash; both from a report.

Why the owner swaps (RFC §5.1, §5.3) never bit Differ: it never puts a native and a foreign instance on the same chain in one session (inferred, not checked).

## Reactant automatic control flow (issue #3265), looked into 2026-09-15

Issue "Tracking issue for automatic control flow 1.12" (glou-nes, 2026-09-10). Public code is on the fork `glou-nes/Reactant.jl`, branches `auto_cf` (2025-10-15) and `acf_jitless` (2025-11-24); the 1.12 branch with the substitute is not pushed anywhere public. Mechanism (`src/auto_cf/ir_control_flow_transform.jl`): at compile time, under the Reactant interpreter, each if-branch / loop body is extracted into its own `IRCode` (`extract_multiple_block_ir`) and the outer IR gets `Expr(:invoke, mi, jit_if_controlflow, cond, r1, r2, n, args...)` with the region IRs baked in as constants (`:181-188`). At trace time `jit_if_controlflow` (`:252`) opens a `stablehlo.if` region, deep-copies the traced args, and runs the region via `juliair_to_mlir(ir, args...)` = `Core.OpaqueClosure(ir)(args...)` (`:62-73`) inside the activated MLIR block, so calls in the region emit ops there. A new OC per trace. The region IR is already inferred under the overlay table, so it must run as written (ownership problem again). Issue TODO: "replaced it with a generated macro (like `call_with_reactant` without the GPUCompiler part). Need to determine how to properly handle these synthetic method instances created during compilation regarding caching." That open question is exactly what GFT + the tag composition answers: `@generated region_body(::Val{tag}, args...)` pasting the region IR (tag = content hash of parent MI + region), reached through a GFT method with the Reactant interpreter -> cached on the synthetic MI with owner Reactant, once per argument types instead of once per trace, world-clocked, precompilable. Not immediate for them: they target 1.12, GFT is 1.14+.

## Worked example: IRCode -> function through the branch (2026-09-15)

Tool = `ToolInterp` with overlay `leaf(x) = x - 1` (native `leaf(x) = x + 1`). Tool takes typed IR of `g(x) = leaf(x) * 10` before inlining (`Base.code_ircode(g, (Int,); optimize_until="CC: COMPACT_1")`), edits `*10` -> `*1000`, converts to `CodeInfo` (`jl_new_code_info_uninit` + slotnames/slottypes/nargs + `ir_to_codeinf!`), stores it in a registry keyed by a tag, defines `struct IRFn{tag} end` with a generated call method whose *raw* generator returns `copy(IRS[tag])`, then `overdub(IRFn{:g}(), 2)` through GFT. Results: native `g(2)` 30; `IRFn{:g}()(2)` natively 3000 (tool IR, Julia's `leaf`); `overdub(...)` 1000 (tool IR, tool's `leaf`). MI `(::IRFn{:g})(::Int64)` carries two instances (owner nothing [42931,∞], owner ToolInterp [42932,∞]); the stub is `Core.invoke(_2, CodeInstance(foreign), getfield(_3,1))`, worlds [42944,∞], edges = that CI; a native caller compiles to `:invoke CI(foreign)` + `add_int`. Replacing the overlay `leaf` caps the tool instance to [42932,42958], new one [42959,∞], answer -98000. (Consistent with RFC §4.5: *replacing* an overlay method invalidates through MI backedges; only *adding* one does not.)

Three pitfalls hit, all worth exposing in a write-up:
1. `@generated` cannot return a `CodeInfo`: `GeneratedFunctionStub` wraps the value in `Expr(:return, Expr(:toplevel_pure, body))` (`base/expr.jl:1883-1900`), so the CodeInfo became a literal and the method returned it as a value. Use the raw protocol `gen(world, source, spvals..., argtypes...)` via `Expr(:meta, :generated, gen)`.
2. `ir.valid_worlds` is a snapshot (provisional max_world from the `code_ircode` run); copying it onto the body gives "invalid age range update" in `InferenceState` (`inferencestate.jl:446`). Leave the body's range at the default; the derivation recomputes it.
3. Inference mutates the `CodeInfo` it is given (`ssavaluetypes` Int -> Vector); a generator must return a fresh `copy` per request or the second compiler gets a half-inferred object. Also: hand the body over uninferred (`src.ssavaluetypes = length(src.code)`) so types are re-derived under whichever compiler infers it.

## Open items (carry forward)

1. `aot_link_output` foreign-owner fallback should error instead of re-dispatching by MI (see "Package images" above).
2. Inference-time constant folding: `abstract_invoke` could return `Const` when `rettype_const` set (RFC §8.1).
3. Opt-in inlining per owner (RFC §8.2).
4. Test gaps: interpreter from a separately loaded `Compiler` package; `--trim` as a `test/trim/` project.
5. Name: is `GeneratedFunctionTransform` right? (RFC §8.5)
6. The three supporting fixes (`src/method.c` decoder, `compileable_specialization`, `compile!`) are independently landable and could be split out as their own commits/PRs (RFC §5).
