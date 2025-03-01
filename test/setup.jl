using Distributed, Test, oneAPI

oneAPI.functional() || error("oneAPI.jl is not functional on this system")

# GPUArrays has a testsuite that isn't part of the main package.
# Include it directly.
import GPUArrays
gpuarrays = pathof(GPUArrays)
gpuarrays_root = dirname(dirname(gpuarrays))
include(joinpath(gpuarrays_root, "test", "testsuite.jl"))
testf(f, xs...; kwargs...) = TestSuite.compare(f, oneArray, xs...; kwargs...)

const eltypes = [Int16, Int32, Int64,
                 Complex{Int16}, Complex{Int32}, Complex{Int64},
                 Float16, Float32,
                 ComplexF32]
const float16_supported = oneL0.module_properties(device()).fp64flags & oneL0.ZE_DEVICE_MODULE_FLAG_FP16 == oneL0.ZE_DEVICE_MODULE_FLAG_FP16
if float16_supported
    append!(eltypes, [#=Float16,=# ComplexF16])
end
const float64_supported = oneL0.module_properties(device()).fp64flags & oneL0.ZE_DEVICE_MODULE_FLAG_FP64 == oneL0.ZE_DEVICE_MODULE_FLAG_FP64
if float64_supported
    append!(eltypes, [Float64, ComplexF64])
end
TestSuite.supported_eltypes(::Type{<:oneArray}) = eltypes

using Random


## entry point

function runtests(f, name)
    old_print_setting = Test.TESTSET_PRINT_ENABLE[]
    Test.TESTSET_PRINT_ENABLE[] = false

    try
        # generate a temporary module to execute the tests in
        mod_name = Symbol("Test", rand(1:100), "Main_", replace(name, '/' => '_'))
        mod = @eval(Main, module $mod_name end)
        @eval(mod, using Test, Random, oneAPI)

        let id = myid()
            wait(@spawnat 1 print_testworker_started(name, id))
        end

        ex = quote
            GC.gc(true)
            Random.seed!(1)
            oneAPI.allowscalar(false)

            @timed @testset $"$name" begin
                $f()
            end
        end
        data = Core.eval(mod, ex)
        #data[1] is the testset

        # process results
        cpu_rss = Sys.maxrss()
        passes,fails,error,broken,c_passes,c_fails,c_errors,c_broken =
            Test.get_test_counts(data[1])
        if data[1].anynonpass == false
            data = ((passes+c_passes,broken+c_broken),
                    data[2],
                    data[3],
                    data[4],
                    data[5])
        end
        res = vcat(collect(data), cpu_rss)

        GC.gc(true)
        res
    finally
        Test.TESTSET_PRINT_ENABLE[] = old_print_setting
    end
end


## auxiliary stuff

# NOTE: based on test/pkg.jl::capture_stdout, but doesn't discard exceptions
macro grab_output(ex)
    quote
        mktemp() do fname, fout
            ret = nothing
            open(fname, "w") do fout
                redirect_stdout(fout) do
                    ret = $(esc(ex))
                end
            end
            ret, read(fname, String)
        end
    end
end

# @test_throw, peeking into the load error for testing macro errors
macro test_throws_macro(ty, ex)
    return quote
        Test.@test_throws $(esc(ty)) try
            $(esc(ex))
        catch err
            if VERSION < v"1.7-"
                @test err isa LoadError
                @test err.file === $(string(__source__.file))
                @test err.line === $(__source__.line + 1)
                rethrow(err.error)
            else
                rethrow(err)
            end
        end
    end
end

# Run some code on-device
macro on_device(ex...)
    code = ex[end]
    kwargs = ex[1:end-1]

    @gensym kernel
    esc(quote
        let
            function $kernel()
                $code
                return
            end

            oneAPI.@sync @oneapi $(kwargs...) $kernel()
        end
    end)
end

# helper function for sinking a value to prevent the callee from getting optimized away
@inline sink(i::Int32) =
    Base.llvmcall("""%slot = alloca i32
                     store volatile i32 %0, i32* %slot
                     %value = load volatile i32, i32* %slot
                     ret i32 %value""", Int32, Tuple{Int32}, i)
@inline sink(i::Int64) =
    Base.llvmcall("""%slot = alloca i64
                     store volatile i64 %0, i64* %slot
                     %value = load volatile i64, i64* %slot
                     ret i64 %value""", Int64, Tuple{Int64}, i)

nothing # File is loaded via a remotecall to "include". Ensure it returns "nothing".
