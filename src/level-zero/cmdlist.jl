# list

export ZeCommandList, execute!

mutable struct ZeCommandList
    handle::ze_command_list_handle_t

    function ZeCommandList(dev::ZeDevice; flags=ZE_COMMAND_LIST_FLAG_NONE)
        desc_ref = Ref(ze_command_list_desc_t(
            ZE_COMMAND_LIST_DESC_VERSION_CURRENT,
            flags,
        ))
        handle_ref = Ref{ze_command_list_handle_t}()
        zeCommandListCreate(dev, desc_ref, handle_ref)
        obj = new(handle_ref[])
        finalizer(obj) do obj
            zeCommandListDestroy(obj)
        end
        obj
    end
end

Base.unsafe_convert(::Type{ze_command_list_handle_t}, list::ZeCommandList) = list.handle

Base.close(list::ZeCommandList) = zeCommandListClose(list)

Base.reset(list::ZeCommandList) = zeCommandListReset(list)

"""
    ZeCommandList(dev::ZeDevice, ...) do list
        append_...!(list)
    end

Create a command list for device `dev`, passing in a do block that appends operations.
The list is then closed and can be used immediately, e.g. for execution.

"""
function ZeCommandList(f::Base.Callable, args...; kwargs...)
    list = ZeCommandList(args...; kwargs...)
    f(list)
    close(list)
    return list
end

execute!(queue::ZeCommandQueue, lists::Vector{ZeCommandList}, fence=nothing) =
    zeCommandQueueExecuteCommandLists(queue, length(lists), lists, something(fence, C_NULL))

"""
    execute!(queue::ZeCommandQueue, ...) do list
        append_...!(list)
    end

Create a command list for the device that owns `queue`, passing in a do block that appends
operations. The list is then closed and executed on the queue.
"""
function execute!(f::Base.Callable, queue::ZeCommandQueue, fence=nothing; kwargs...)
    list = ZeCommandList(f, queue.device; kwargs...)
    execute!(queue, [list])
end
