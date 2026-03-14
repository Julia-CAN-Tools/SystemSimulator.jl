"""
    sync_dict!(dest, src)

Overwrite destination dictionary with source values.
"""
function sync_dict!(dest::AbstractDict{String,Float64}, src::AbstractDict{String,Float64})
    for (key, value) in src
        dest[key] = value
    end
    return dest
end

"""
    gather_inputs!(inputs, io_states)

Collect per-IO snapshots into namespaced global inputs using pre-computed index pairs.
Uses SeqLock (3.2): retries if the parser is mid-write (odd seq) or if seq changed
during the copy (torn read).
"""
function gather_inputs!(inputs::SignalBuffer, io_states::Vector{IOState{IO,RAW}}) where {IO,RAW}
    for state in io_states
        is_read_enabled(state.config) || continue
        while true
            seq1 = state._snap_seq[]
            isodd(seq1) && continue
            copy_by_pairs!(inputs.values, state.input_local_snapshot.values, state._gather_pairs)
            seq2 = state._snap_seq[]
            seq1 == seq2 && break
        end
    end
    return inputs
end

"""
    split_outputs!(outputs, io_states)

Project namespaced global outputs into each IO local output dictionary
using pre-computed index pairs. Zero hash lookups.
"""
function split_outputs!(outputs::SignalBuffer, io_states::Vector{IOState{IO,RAW}}) where {IO,RAW}
    for state in io_states
        is_write_enabled(state.config) || continue
        lock(state.outlock)
        try
            copy_by_pairs!(state.output_local.values, outputs.values, state._split_pairs)
        finally
            unlock(state.outlock)
        end
        notify(state.outflag)
    end
    return nothing
end

"""
    snapshot_to_sinks!(runtime)

Copy runtime signal snapshots to logger and monitor using pre-computed index pairs.
Zero hash lookups — uses `copy_by_pairs!` for inputs/outputs/params and direct
index write for timestamp.
"""
function snapshot_to_sinks!(runtime::SystemRuntime)
    logger = runtime.logger
    mon = runtime.monitor

    # Copy to logger using pre-computed pairs
    lock(logger.loggerlock)
    try
        copy_by_pairs!(logger.loggerdict.values, runtime.inputs.values, runtime._logger_input_pairs)
        copy_by_pairs!(logger.loggerdict.values, runtime.outputs.values, runtime._logger_output_pairs)
        lock(runtime.paramlock)
        try
            copy_by_pairs!(logger.loggerdict.values, runtime.params.values, runtime._logger_param_pairs)
        finally
            unlock(runtime.paramlock)
        end
        if runtime._logger_time_idx > 0
            @inbounds logger.loggerdict.values[runtime._logger_time_idx] = runtime.timestamp
        end
    finally
        unlock(logger.loggerlock)
    end

    # Copy to monitor using pre-computed pairs
    if mon !== nothing
        lock(mon.monitorlock)
        try
            copy_by_pairs!(mon.monitordict.values, runtime.inputs.values, runtime._monitor_input_pairs)
            copy_by_pairs!(mon.monitordict.values, runtime.outputs.values, runtime._monitor_output_pairs)
            lock(runtime.paramlock)
            try
                copy_by_pairs!(mon.monitordict.values, runtime.params.values, runtime._monitor_param_pairs)
            finally
                unlock(runtime.paramlock)
            end
            if runtime._monitor_time_idx > 0
                @inbounds mon.monitordict.values[runtime._monitor_time_idx] = runtime.timestamp
            end
        finally
            unlock(mon.monitorlock)
        end
    end

    return nothing
end

"""
    apply_monitor_params!(runtime)

Apply staged param updates from the TCP monitor into `runtime.params` and
`system.params`. Uses cached `_sys_params_ref` to avoid hasproperty reflection.
Sets `_params_dirty` on the system if it has that field.
"""
function apply_monitor_params!(runtime::SystemRuntime)
    mon = runtime.monitor
    mon === nothing && return nothing

    lock(mon.param_lock)
    try
        seq = mon.param_seq[]
        seq == runtime._last_param_seq && return nothing

        lock(runtime.paramlock)
        try
            for (name, value) in mon.param_updates
                runtime.params[name] = value
            end
        finally
            unlock(runtime.paramlock)
        end

        # Use cached reference instead of hasproperty reflection
        ctrl_params = runtime._sys_params_ref
        if ctrl_params !== nothing
            for (name, value) in mon.param_updates
                if haskey(ctrl_params, name)
                    ctrl_params[name] = value
                end
            end
            # Mark params dirty on the system if it supports it
            ctrl = runtime.system
            if hasproperty(ctrl, :_params_dirty)
                ctrl._params_dirty = true
            end
        end
        runtime._last_param_seq = seq
    finally
        unlock(mon.param_lock)
    end
    return nothing
end
