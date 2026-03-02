"""
    sync_dict!(dest, src)

Overwrite destination dictionary with source values.
"""
function sync_dict!(dest::Dict{String,Float64}, src::Dict{String,Float64})
    for (key, value) in src
        dest[key] = value
    end
    return dest
end

"""
    gather_inputs!(inputs, io_states)

Collect per-IO snapshots into namespaced global inputs.
"""
function gather_inputs!(inputs::Dict{String,Float64}, io_states::Vector{IOState})
    for state in io_states
        is_read_enabled(state.config) || continue
        lock(state.inputlock)
        try
            for (local_name, global_name) in state.input_keymap
                inputs[global_name] = state.input_local_snapshot[local_name]
            end
        finally
            unlock(state.inputlock)
        end
    end
    return inputs
end

"""
    split_outputs!(outputs, io_states)

Project namespaced global outputs into each IO local output dictionary.
"""
function split_outputs!(outputs::Dict{String,Float64}, io_states::Vector{IOState})
    for state in io_states
        is_write_enabled(state.config) || continue
        lock(state.outlock) do
            for (local_name, global_name) in state.output_keymap
                state.output_local[local_name] = get(outputs, global_name, state.output_local[local_name])
            end
        end
        isready(state.outflag) || put!(state.outflag, true)
    end
    return nothing
end

"""
    copy_to_logger!(runtime)

Copy runtime snapshots into logger dictionary for buffered write.
"""
function copy_to_logger!(runtime::SystemRuntime)
    lock(runtime.logger.loggerlock) do
        lock(runtime.inputlock) do
            for (key, value) in runtime.inputs
                runtime.logger.loggerdict[key] = value
            end
        end
        lock(runtime.outputlock) do
            for (key, value) in runtime.outputs
                runtime.logger.loggerdict[key] = value
            end
        end
        lock(runtime.paramlock) do
            for (key, value) in runtime.params
                runtime.logger.loggerdict[key] = value
            end
        end
        runtime.logger.loggerdict["Time"] = runtime.timestamp
    end
    return nothing
end
