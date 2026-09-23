# repro-10.jl -- self-contained reproducer (no packages, no includes)
# Binaries: `julia +1.13` = Julia 1.13.0 (d1c37793dd2, official release, x86_64-linux-gnu);
#           fixes-build = 1.14.0-DEV.3318 (master 55312b3c97 + uncommitted fixes for bugs 1-4, 7, 10; a local build, not kept).
# Observed output, captured 2026-09-21/22 (backtraces truncated, build paths shortened):
#
# $ julia +1.13 repro-10.jl
#   FAIL [capped]: generator entered 26 times for od(ping, 4) (bounded only by the cap); result = 4
#   FAIL [uncapped]: hung after the overflow (terminated after 90s); stack-overflow warnings: 3; nested generator frames in the backtrace: 732; generator entries: ?; no result printed
#       jl_compile_codeinst_now at src/jitlayers.cpp:791
#       jl_compile_codeinst_impl at src/jitlayers.cpp:875
#       jl_fptr_wait_for_compiled at src/gf.c:3794
#
# $ <fixes-build>/julia repro-10.jl
#   PASS [capped]: generator entered 4 times; result = 4
#   PASS [uncapped]: generator entered 4 times; result = 4
#
# Bug 10: a `Core.CachedGenerator` that runs inference can re-enter its own generation.
# Inference of the callee reaches the generated method for another callee, whose body calls
# back into the first; every request starts a fresh generation. Nothing bounds this, so
# mutual recursion through the generated method overflows the stack.
#
# Usage:  julia repro-10.jl            # driver: runs both variants in child processes
#         julia repro-10.jl capped     # generator bails out at depth 25 (shows the re-entry count)
#         julia repro-10.jl uncapped   # crashes
if isempty(ARGS)
    for v in ["capped", "uncapped"]
        cmd = `$(Base.julia_cmd()) --startup-file=no $(@__FILE__) $v`
        out = IOBuffer()
        p = run(pipeline(ignorestatus(cmd); stdout=out, stderr=out); wait=false)
        finished = timedwait(() -> process_exited(p), 90.0) === :ok
        if !finished
            kill(p, Base.SIGTERM)                       # julia prints a backtrace on SIGTERM
            timedwait(() -> process_exited(p), 20.0) === :ok || kill(p, Base.SIGKILL)
        end
        wait(p)
        s = String(take!(out))
        m = match(r"generator entries: (\d+)", s)
        entries = m === nothing ? "?" : m.captures[1]
        overflows = count("detected a stack overflow", s)
        nested = count("RecGen at", s)
        res = something(match(r"(result = .*|THREW: .*)", s), (match = "no result printed",)).match
        if overflows > 0 || !finished || p.termsignal != 0
            println("FAIL [$v]: ", finished ? "exit=$(p.exitcode) signal=$(p.termsignal)" : "hung after the overflow (terminated after 90s)",
                    "; stack-overflow warnings: $overflows; nested generator frames in the backtrace: $nested; generator entries: $entries; $res")
            stuck = filter(l -> occursin(r"^(jl_compile_codeinst|jl_fptr_wait|Encountered stack overflow|Internal error)", l), split(s, '\n'))
            foreach(l -> println("    ", l), first(stuck, 4))
        elseif entries != "?" && parse(Int, entries) > 8
            println("FAIL [$v]: generator entered $entries times for od(ping, 4) (bounded only by the cap); $res")
        else
            println("PASS [$v]: generator entered $entries times; $res")
        end
    end
    exit()
end

const CC = Base.Compiler
const CAP = ARGS[1] == "capped" ? 25 : typemax(Int)
const DEPTH = Ref(0)

struct RecGen <: Core.CachedGenerator end
function (::RecGen)(world::UInt, source::Method, self, f, x)
    DEPTH[] += 1
    DEPTH[] > CAP && error("bailing out at depth $CAP -- unbounded generator re-entry")
    # what an "overdub"-style tool does: infer the callee, then invoke the result
    mi = Base.specialize_method(Base._which(Tuple{f, x}; world))
    ci = CC.typeinf_ext_toplevel(CC.NativeInterpreter(world), mi, CC.SOURCE_MODE_ABI)
    stub = Core.GeneratedFunctionStub(identity, Core.svec(:od, :f, :x), Core.svec())
    src = stub(world, source, :($(Core.invoke)(f, $ci, x)))
    src.edges = Core.svec(mi)      # MethodInstance edge: the one shape the C decoder handles (see bug 1)
    src.min_world = ci.min_world
    src.max_world = ci.max_world
    return src
end
@eval function od(f, x)
    $(Expr(:meta, :generated, RecGen()))
    $(Expr(:meta, :generated_only))
end

ping(n::Int) = n <= 0 ? 0 : od(pong, n - 1) + 1
pong(n::Int) = n <= 0 ? 0 : od(ping, n - 1) + 1

try
    println("result = ", od(ping, 4))
catch e
    println("THREW: ", sprint(showerror, e))
end
println("generator entries: ", DEPTH[])
