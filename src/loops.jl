function reader_loop(state::IOState{IO,RAW}, stop_signal::StopSignal) where {IO,RAW}
    is_read_enabled(state.config) || return nothing
    @info "Reader loop started" io = state.config.name
    try
        while !stop_requested(stop_signal)
            raw_payload = try
                read_raw(state.config.io)
            catch err
                stop_requested(stop_signal) && break
                @error "Reader loop error" io = state.config.name exception = (err, catch_backtrace())
                sleep(0.01)
                continue
            end

            raw_payload === nothing && continue
            try_push!(state.rx_queue, raw_payload)
        end
    finally
        close(state.rx_queue)
    end
    @info "Reader loop exiting" io = state.config.name
    return nothing
end

function parser_loop(state::IOState{IO,RAW}, stop_signal::StopSignal) where {IO,RAW}
    is_read_enabled(state.config) || return nothing
    @info "Parser loop started" io = state.config.name

    while !stop_requested(stop_signal)
        raw_payload = try_pop!(state.rx_queue)
        if raw_payload === nothing
            if !isopen(state.rx_queue)
                break
            end
            sleep(0.0005)
            continue
        end

        try
            matched = decode_raw!(state.config.io, raw_payload, state.input_view)
            if matched
                seq = state.input_seq[]
                state.input_seq[] = seq + UInt64(1)
                sync_values!(state.input_snapshot, state.input_work)
                state.input_seq[] = seq + UInt64(2)
            end
        catch err
            @error "Parser loop error" io = state.config.name exception = (err, catch_backtrace())
        end
    end
    @info "Parser loop exiting" io = state.config.name
    return nothing
end

function writer_loop(state::IOState{IO,RAW}, stop_signal::StopSignal) where {IO,RAW}
    is_write_enabled(state.config) || return nothing
    @info "Writer loop started" io = state.config.name
    while !stop_requested(stop_signal)
        wait(state.outflag)
        Base.reset(state.outflag)
        stop_requested(stop_signal) && break

        while true
            seq1 = state.output_seq[]
            isodd(seq1) && continue
            sync_values!(state.output_shadow, state.output_shared)
            seq2 = state.output_seq[]
            seq1 == seq2 && break
        end

        try
            encode_and_write!(state.config.io, state.output_shadow_view)
        catch err
            if err isa InvalidStateException
                break
            end
            @error "Writer loop error" io = state.config.name exception = (err, catch_backtrace())
        end
    end
    @info "Writer loop exiting" io = state.config.name
    return nothing
end

function system_loop(runtime::SystemRuntime)
    period_ns = convert(Dates.Nanosecond, Dates.Millisecond(runtime.config.dt_ms)).value
    @info "System loop started" period_ms = runtime.config.dt_ms

    while !stop_requested(runtime.stop_signal)
        cycle_start = time_ns()

        try
            apply_monitor_params!(runtime)
            gather_inputs!(runtime.inputs, runtime.io_states)
            control_step!(
                runtime.system,
                runtime.inputs,
                runtime.outputs,
                runtime.params,
                runtime.dt_seconds,
            )
            split_outputs!(runtime.outputs, runtime.io_states)
            push_logger_snapshot!(runtime)
            publish_monitor_snapshot!(runtime)
            runtime.timestamp += runtime.dt_seconds
            runtime.step_count[] += 1
        catch err
            @error "System loop error" exception = (err, catch_backtrace())
        end

        elapsed_ns = Int64(time_ns() - cycle_start)
        remaining_ns = period_ns - elapsed_ns

        if remaining_ns > 2_000_000
            sleep((remaining_ns - 1_000_000) / 1.0e9)
        end

        while Int64(time_ns() - cycle_start) < period_ns
        end
    end

    @info "System loop exiting" total_steps = runtime.step_count[]
    return nothing
end

function logger_loop(stop_signal::StopSignal, logger::Logger)
    @info "Logger loop started" filename = logger.filepath

    while !stop_requested(stop_signal)
        wait(logger.flushflag)
        Base.reset(logger.flushflag)
        if logger.flush_pending[]
            writematrix(logger, logger.flush_buffer, logger.flush_count)
            logger.flush_count = 0
            logger.flush_pending[] = false
        end
    end

    if logger.flush_pending[]
        writematrix(logger, logger.flush_buffer, logger.flush_count)
        logger.flush_count = 0
        logger.flush_pending[] = false
    end
    if logger.active_count > 0
        writematrix(logger, logger.active_buffer, logger.active_count)
        logger.active_count = 0
    end
    isopen(logger.filehandle) && close(logger.filehandle)

    @info "Logger loop exiting" filename = logger.filepath
    return nothing
end

function start!(runtime::SystemRuntime)
    for state in runtime.io_states
        if is_read_enabled(state.config)
            state.reader_task = Threads.@spawn reader_loop(state, runtime.stop_signal)
            state.parser_task = Threads.@spawn parser_loop(state, runtime.stop_signal)
        end
        if is_write_enabled(state.config)
            state.writer_task = Threads.@spawn writer_loop(state, runtime.stop_signal)
        end
    end

    runtime.system_task = Threads.@spawn system_loop(runtime)
    runtime.logger_task = Threads.@spawn logger_loop(runtime.stop_signal, runtime.logger)

    if runtime.monitor !== nothing
        mon = runtime.monitor
        if mon.in_server !== nothing
            Threads.@spawn _monitor_accept_loop!(mon, :in)
            runtime.monitor_reader_task = Threads.@spawn monitor_reader_loop(mon, runtime.stop_signal)
        end
        if mon.out_server !== nothing
            Threads.@spawn _monitor_accept_loop!(mon, :out)
            runtime.monitor_writer_task = Threads.@spawn monitor_writer_loop(mon, runtime.stop_signal)
        end
    end
    return nothing
end

function stop!(runtime::SystemRuntime)
    request_stop!(runtime.stop_signal)

    for state in runtime.io_states
        try
            close(state.config.io)
        catch err
            @warn "Error closing IO" io = state.config.name exception = (err, catch_backtrace())
        end
        close(state.rx_queue)
        notify(state.outflag)
    end

    notify(runtime.logger.flushflag)

    if runtime.monitor !== nothing
        close_monitor!(runtime.monitor)
        notify(runtime.monitor.monitorflag)
    end

    sleep(0.1)
    return nothing
end
