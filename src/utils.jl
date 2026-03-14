function gather_inputs!(inputs::SignalBuffer, io_states::Vector{IOState{IO,RAW}}) where {IO,RAW}
    for state in io_states
        is_read_enabled(state.config) || continue
        while true
            seq1 = state.input_seq[]
            isodd(seq1) && continue
            copy_by_pairs!(inputs.values, state.input_snapshot.values, state.gather_pairs)
            seq2 = state.input_seq[]
            seq1 == seq2 && break
        end
    end
    return inputs
end

function split_outputs!(outputs::SignalBuffer, io_states::Vector{IOState{IO,RAW}}) where {IO,RAW}
    for state in io_states
        is_write_enabled(state.config) || continue
        seq = state.output_seq[]
        state.output_seq[] = seq + UInt64(1)
        copy_by_pairs!(state.output_shared.values, outputs.values, state.split_pairs)
        state.output_seq[] = seq + UInt64(2)
        notify(state.outflag)
    end
    return nothing
end

function _write_logger_row!(runtime::SystemRuntime, row::AbstractVector{Float64})
    fill!(row, 0.0)
    copy_by_pairs!(row, runtime.inputs.values, runtime._logger_input_pairs)
    copy_by_pairs!(row, runtime.outputs.values, runtime._logger_output_pairs)
    copy_by_pairs!(row, runtime.params.values, runtime._logger_param_pairs)
    runtime._logger_time_idx > 0 && (@inbounds row[runtime._logger_time_idx] = runtime.timestamp)
    return nothing
end

function push_logger_snapshot!(runtime::SystemRuntime)
    push_logger_row!(runtime.logger, row -> _write_logger_row!(runtime, row))
    return nothing
end

function publish_monitor_snapshot!(runtime::SystemRuntime)
    mon = runtime.monitor
    mon === nothing && return nothing

    seq = mon.snapshot_seq[]
    mon.snapshot_seq[] = seq + UInt64(1)
    fill!(mon.snapshot, 0.0)
    copy_by_pairs!(mon.snapshot, runtime.inputs.values, runtime._monitor_input_pairs)
    copy_by_pairs!(mon.snapshot, runtime.outputs.values, runtime._monitor_output_pairs)
    copy_by_pairs!(mon.snapshot, runtime.params.values, runtime._monitor_param_pairs)
    runtime._monitor_time_idx > 0 && (@inbounds mon.snapshot[runtime._monitor_time_idx] = runtime.timestamp)
    mon.snapshot_seq[] = seq + UInt64(2)
    notify(mon.monitorflag)
    return nothing
end

function apply_monitor_params!(runtime::SystemRuntime)
    mon = runtime.monitor
    mon === nothing && return false

    lock(mon.param_lock)
    try
        seq = mon.param_seq[]
        seq == runtime._last_param_seq && return false

        @inbounds for pair in runtime._monitor_param_apply_pairs
            runtime.params.values[pair.dst] = mon.param_values[pair.src]
        end
        runtime._last_param_seq = seq
    finally
        unlock(mon.param_lock)
    end

    parameters_updated!(runtime.system, runtime.params)
    return true
end
