# repro-01.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-01.jl
#   FAIL [mt-cached]: died with signal 11; top frames:
#       ijl_array_grow_end at src/array.c:194
#       ijl_array_ptr_1d_push at src/array.c:260
#       push_edge at src/method.c:1140
#       ijl_method_instance_add_backedge at src/gf.c:2400
#       ijl_code_for_staged at src/method.c:881
#       call_get_staged at ./../usr/share/julia/Compiler/src/utilities.jl:0 [inlined]
#   FAIL [int-cached]: hung (terminated after 60s); where it was stuck:
#       jl_mutex_lock at src/julia_locks.h:75 [inlined]
#       ijl_method_instance_add_backedge at src/gf.c:2390
#       ijl_code_for_staged at src/method.c:881
#       call_get_staged at ./../usr/share/julia/Compiler/src/utilities.jl:0 [inlined]
#   FAIL [ci-cached]: died with signal 11; top frames:
#       ijl_method_instance_add_backedge at src/gf.c:2390
#       ijl_code_for_staged at src/method.c:881
#       call_get_staged at ./../usr/share/julia/Compiler/src/utilities.jl:0 [inlined]
#   FAIL [mt-plain-min]: died with signal 11; top frames:
#       ijl_array_grow_end at src/array.c:194
#       ijl_array_ptr_1d_push at src/array.c:260
#       push_edge at src/method.c:1140
#       ijl_method_instance_add_backedge at src/gf.c:2400
#       ijl_code_for_staged at src/method.c:881
#       jl_code_or_ci_for_interpreter at src/interpreter.c:726 [inlined]
#       jl_code_for_interpreter at src/interpreter.c:747
#
# $ <fixes-build>/julia repro-01.jl
#   PASS [mt-cached]: ran, survived GC and invalidation
#   PASS [int-cached]: ran, survived GC and invalidation
#   PASS [ci-cached]: ran, survived GC and invalidation
#   PASS [mt-plain-min]: ran, survived GC and invalidation
#
# Bug 1: `jl_code_for_staged`'s C backedge decoder (src/method.c) only understands three of the
# five edge shapes `store_backedges` emits. A generator that returns inference-derived edges
# on its CodeInfo -- `(sig, Core.methodtable)` for abstract dispatch, `(nmatches::Int, sig, mi...)`
# lookup markers, or a bare `CodeInstance` -- makes the decoder cast the wrong object to
# `jl_method_instance_t*` and call `jl_method_instance_add_backedge` on it.
#
# The decoder runs when a cache slot is passed: always for a `Core.CachedGenerator`, and for
# ANY generator when the body is fetched through the interpreter (`--compile=min`,
# src/interpreter.c `jl_code_or_ci_for_interpreter`).
#
# Usage:  julia repro-01.jl            # driver: runs each variant in a child process
#         julia repro-01.jl <variant>  # variants: mt-cached int-cached ci-cached mt-plain-min
const VARIANTS = ["mt-cached", "int-cached", "ci-cached", "mt-plain-min"]

if isempty(ARGS)
    for v in VARIANTS
        flags = v == "mt-plain-min" ? ["--compile=min"] : String[]
        cmd = `$(Base.julia_cmd()) --startup-file=no $flags $(@__FILE__) $v`
        out = IOBuffer()
        p = run(pipeline(ignorestatus(cmd); stdout=out, stderr=out); wait=false)
        finished = timedwait(() -> process_exited(p), 60.0) === :ok
        if !finished
            kill(p, Base.SIGTERM)                       # julia prints a backtrace on SIGTERM
            timedwait(() -> process_exited(p), 15.0) === :ok || kill(p, Base.SIGKILL)
        end
        wait(p)
        s = String(take!(out))
        if !finished
            println("FAIL [$v]: hung (terminated after 60s); where it was stuck:")
        elseif p.termsignal != 0 && finished
            println("FAIL [$v]: died with signal $(p.termsignal); top frames:")
        elseif p.exitcode != 0
            println("FAIL [$v]: exit code $(p.exitcode)")
        elseif occursin("survived invalidation", s)
            println("PASS [$v]: ran, survived GC and invalidation")
            continue
        else
            println("FAIL [$v]: unexpected output")
        end
        frames = filter(l -> occursin(r"^(ijl_method|ijl_code|ijl_array|jl_mutex|jl_code|push_edge|call_get_staged)", l), split(s, '\n'))
        foreach(l -> println("    ", l), first(frames, 7))
    end
    exit()
end

const variant = ARGS[1]
callee(x) = x + 1
callee(1)
const CALLEE_MI = Base.method_instance(callee, (Int,))
const CALLEE_CI = Base.Compiler.typeinf_ext_toplevel(Base.Compiler.NativeInterpreter(Base.get_world_counter()),
                                                    CALLEE_MI, Base.Compiler.SOURCE_MODE_ABI)::Core.CodeInstance
const GLOBAL_MT = isdefined(Core, :methodtable) ? Core.methodtable : Core.GlobalMethods

# the three edge shapes, encoded exactly as Compiler/src/stmtinfo.jl writes them
function edges_for(v)
    startswith(v, "mt")  && return Core.svec(Tuple{typeof(callee),Any}, GLOBAL_MT)   # abstract dispatch: sig first, table second
    startswith(v, "int") && return Core.svec(1, Tuple{typeof(callee),Int}, CALLEE_MI) # `nmatches, atype` lookup marker + matches
    startswith(v, "ci")  && return Core.svec(CALLEE_CI)                              # bare CodeInstance (an `invoke`/inlining edge)
    error("unknown variant")
end

function build_src()
    ci = ccall(:jl_new_code_info_uninit, Ref{Core.CodeInfo}, ())
    ci.code = Any[Core.ReturnNode(Core.SlotNumber(2))]     # `return x`
    ci.ssavaluetypes = 1
    ci.ssaflags = UInt32[0]
    ci.slotnames = Symbol[Symbol("#self#"), :x]
    ci.slotflags = UInt8[0x00, 0x00]
    ci.nargs = 2
    ci.isva = false
    ci.debuginfo = Core.DebugInfo(:none)
    ci.min_world = 1
    ci.max_world = typemax(UInt)
    ci.edges = edges_for(variant)
    return ci
end

struct CachedGen <: Core.CachedGenerator end
(::CachedGen)(world::UInt, source, argtypes...) = build_src()
struct PlainGen end
(::PlainGen)(world::UInt, source, argtypes...) = build_src()

const gen = endswith(variant, "plain-min") ? PlainGen() : CachedGen()
@eval function g(x)
    $(Expr(:meta, :generated, gen))
    $(Expr(:meta, :generated_only))
end

println("[$variant] g(1) = ", g(1))
GC.gc(); GC.gc()
println("[$variant] survived gc")
callee(x::Float64) = x - 1     # walk the backedges we just wrote
GC.gc(); GC.gc()
println("[$variant] survived invalidation")
