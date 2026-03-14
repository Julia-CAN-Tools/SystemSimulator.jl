"""
    reader_loop(state, stop_signal)

Blocking task that reads raw payloads and enqueues them for parsing.
"""
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

            try
                put!(state.rx_queue, raw_payload)
            catch err
                if err isa InvalidStateException
                    break
                end
                rethrow(err)
            end
        end
    finally
        if isopen(state.rx_queue)
            close(state.rx_queue)
        end
    end
    @info "Reader loop exiting" io = state.config.name
    return nothing
end

"""
    parser_loop(state, stop_signal)

Consumes raw payloads, decodes signals, and publishes local snapshots.
"""
function parser_loop(state::IOState{IO,RAW}, stop_signal::StopSignal) where {IO,RAW}
    is_read_enabled(state.config) || return nothing
    @info "Parser loop started" io = state.config.name
    while !stop_requested(stop_signal)
        raw_payload = try
            take!(state.rx_queue)
        catch err
            if err isa InvalidStateException
                break
            end
            rethrow(err)
        end

        try
            matched = decode_raw!(state.config.io, raw_payload, state.input_local_rx)
            if matched
                # SeqLock write: odd seq = writing, even seq = done
                seq = state._snap_seq[]
                state._snap_seq[] = seq + UInt64(1)
                sync_dict!(state.input_local_snapshot, state.input_local_rx)
                state._snap_seq[] = seq + UInt64(2)
            end
        catch err
            @error "Parser loop error" io = state.config.name exception = (err, catch_backtrace())
        end
    end
    @info "Parser loop exiting" io = state.config.name
    return nothing
end

"""
    writer_loop(state, stop_signal)

Encodes local outputs and writes them to transport.
Uses Base.Event instead of Channel{Bool} for zero-alloc wakeup.
Uses encode_and_write! for zero-alloc inline encode+write.
"""
function writer_loop(state::IOState{IO,RAW}, stop_signal::StopSignal) where {IO,RAW}
    is_write_enabled(state.config) || return nothing
    @info "Writer loop started" io = state.config.name
    while !stop_requested(stop_signal)
        wait(state.outflag)
        Base.reset(state.outflag)
        stop_requested(stop_signal) && break

        try
            lock(state.outlock)
            try
                encode_and_write!(state.config.io, state.output_local)
            finally
                unlock(state.outlock)
            end
        catch err
            @error "Writer loop error" io = state.config.name exception = (err, catch_backtrace())
        end
    end
    @info "Writer loop exiting" io = state.config.name
    return nothing
end

"""
    system_loop(runtime, system_callback)

Single deterministic loop that gathers snapshots, invokes system callback,
and publishes outputs to IO writers.

Optimizations applied:
- dt_seconds cached before loop (1.3)
- Global inputlock/outputlock removed — only system loop touches these (2.2)
- Merged snapshot_to_sinks! replaces separate copy_to_logger!/copy_to_monitor! (2.1)
- Precision sleep with busy-wait tail for <10μs jitter (3.3)
- Base.Event for logger/monitor wakeup (3.4)
- Plain store for step_count (4.4)
"""
function system_loop(runtime::SystemRuntime{S,IO,RAW,MON}, system_callback::CF) where {S, IO<:AbstractIO, RAW, MON, CF<:Function}
    period_ns = convert(Dates.Nanosecond, Dates.Millisecond(runtime.config.dt_ms)).value
    dt_seconds = runtime.config.dt_ms / 1.0e3
    @info "System loop started" period_ms = runtime.config.dt_ms

    while !stop_requested(runtime.stop_signal)
        cycle_start = time_ns()

        try
            # Apply param updates from monitor (before gathering inputs)
            apply_monitor_params!(runtime)

            # No global inputlock — only system loop touches runtime.inputs
            gather_inputs!(runtime.inputs, runtime.io_states)

            # No global outputlock — only system loop touches runtime.outputs
            system_callback(
                runtime.system,
                runtime.inputs,
                runtime.outputs,
                dt_seconds,
            )

            split_outputs!(runtime.outputs, runtime.io_states)

            # Merged snapshot: copies to both logger and monitor in one pass
            snapshot_to_sinks!(runtime)
            notify(runtime.logger.loggerflag)
            if runtime.monitor !== nothing
                notify(runtime.monitor.monitorflag)
            end

            runtime.timestamp += dt_seconds
            runtime.step_count[] += 1
        catch err
            @error "System loop error" exception = (err, catch_backtrace())
        end

        # Precision sleep: OS sleep for most of the remaining time,
        # then busy-wait for the final ~1ms to achieve <10μs jitter
        elapsed_ns = Int64(time_ns() - cycle_start)
        remaining_ns = period_ns - elapsed_ns

        if remaining_ns > 2_000_000  # > 2ms remaining: sleep most of it
            sleep((remaining_ns - 1_000_000) / 1.0e9)  # sleep all but last 1ms
        end

        # Busy-wait for precise timing
        while Int64(time_ns() - cycle_start) < period_ns
            # spin
        end
    end

    @info "System loop exiting" total_steps = runtime.step_count[]
    return nothing
end

"""
    logger_loop(stop_signal, logger)

Background task that drains `logger.loggerflag` and calls `writeline` each cycle.
At shutdown: writes any remaining buffered rows via `writematrix`, then closes the file handle.
"""
function logger_loop(stop_signal::StopSignal, logger::Logger)
    @info "Logger loop started" filename = logger.filepath

    while !stop_requested(stop_signal)
        wait(logger.loggerflag)
        Base.reset(logger.loggerflag)
        stop_requested(stop_signal) && break
        writeline(logger)
    end

    if logger.counter > 0
        writematrix(logger, @view logger.buffer[1:logger.counter, :])
        logger.counter = 0
    end

    if isopen(logger.filehandle)
        close(logger.filehandle)
    end

    @info "Logger loop exiting" filename = logger.filepath
    return nothing
end

"""
    start!(runtime, system_callback)

Spawn all runtime tasks and return immediately (non-blocking).
"""
function start!(runtime::SystemRuntime{S,IO,RAW,MON}, system_callback::CF) where {S, IO<:AbstractIO, RAW, MON, CF<:Function}
    for state in runtime.io_states
        if is_read_enabled(state.config)
            state.reader_task = Threads.@spawn reader_loop(state, runtime.stop_signal)
            state.parser_task = Threads.@spawn parser_loop(state, runtime.stop_signal)
        end
        if is_write_enabled(state.config)
            state.writer_task = Threads.@spawn writer_loop(state, runtime.stop_signal)
        end
    end

    runtime.system_task = Threads.@spawn system_loop(runtime, system_callback)
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

"""
    stop!(runtime)

Coordinated shutdown sequence.

## Shutdown sequence

1. Sets the stop flag via `request_stop!`
2. Closes all IO backends so blocking `read_raw` calls return immediately
3. Notifies each writer's `outflag` event to wake blocked tasks
4. Notifies `logger.loggerflag` event
5. Closes monitor TCP server sockets and notifies `monitorflag`
6. Sleeps 200 ms to let in-flight work drain
7. Closes rx_queue channels
"""
function stop!(runtime::SystemRuntime)
    request_stop!(runtime.stop_signal)

    # Close IO backends first so blocking reads can unwind.
    for state in runtime.io_states
        try
            close(state.config.io)
        catch err
            @warn "Error closing IO" io = state.config.name exception = (err, catch_backtrace())
        end
    end

    # Wake writer tasks so they can observe stop_requested
    for state in runtime.io_states
        if is_write_enabled(state.config)
            notify(state.outflag)
        end
    end

    # Wake logger task
    notify(runtime.logger.loggerflag)

    # Close monitor TCP resources and wake its writer
    if runtime.monitor !== nothing
        close_monitor!(runtime.monitor)
        notify(runtime.monitor.monitorflag)
    end

    sleep(0.2)

    for state in runtime.io_states
        isopen(state.rx_queue) && close(state.rx_queue)
    end

    return nothing
end
