pkg = ARGS[1]
try
    Base.compilecache(Base.PkgId(pkg))
catch e
    println("COMPILECACHE THREW: ", sprint(showerror, e)[1:min(end,300)])
end
M = try Base.require(Main, Symbol(pkg)) catch e; println("REQUIRE THREW: ", sprint(showerror,e)[1:min(end,300)]); exit(0) end
invokelatest() do
    ci = M.fci
    println(pkg, ": inferred::", typeof(ci.inferred), " invoke=", ci.invoke != C_NULL, " onchain=", ccall(:jl_mi_cache_has_ci, Cint,(Any,Any),Base.get_ci_mi(ci),ci))
    for i in 1:5; GC.gc(); end
    r = try M.caller(2) catch e; "THREW " * sprint(showerror,e)[1:min(end,120)] end
    println(pkg, ": caller(2) = ", r, " (11 foreign / 31 native)")
    for i in 1:5; GC.gc(); end
    println(pkg, ": again ", try M.caller(3) catch e; "THREW" end)
end
