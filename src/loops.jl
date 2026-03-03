"""
    reader_loop(state, stop_signal)

Blocking task that reads raw payloads and enqueues them for parsing.
"""
function reader_loop(state::IOState, stop_signal::StopSignal)
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
function parser_loop(state::IOState, stop_signal::StopSignal)
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
                lock(state.inputlock)
                try
                    sync_dict!(state.input_local_snapshot, state.input_local_rx)
                finally
                    unlock(state.inputlock)
                end
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
"""
function writer_loop(state::IOState, stop_signal::StopSignal)
    is_write_enabled(state.config) || return nothing
    @info "Writer loop started" io = state.config.name
    while !stop_requested(stop_signal)
        try
            take!(state.outflag)
        catch err
            if err isa InvalidStateException
                break
            end
            rethrow(err)
        end

        stop_requested(stop_signal) && break

        try
            lock(state.outlock) do
                payloads = encode_raw(state.config.io, state.output_local)
                for payload in payloads
                    write_raw(state.config.io, payload)
                end
            end
        catch err
            @error "Writer loop error" io = state.config.name exception = (err, catch_backtrace())
        end
    end
    @info "Writer loop exiting" io = state.config.name
    return nothing
end

"""
    control_loop(runtime, control_callback)

Single deterministic loop that gathers snapshots, invokes control callback,
and publishes outputs to IO writers.
"""
function control_loop(runtime::SystemRuntime, control_callback::CF) where {CF<:Function}
    period_ns = convert(Dates.Nanosecond, Dates.Millisecond(runtime.config.dt_ms)).value
    @info "Control loop started" period_ms = runtime.config.dt_ms

    while !stop_requested(runtime.stop_signal)
        cycle_start = time_ns()

        try
            lock(runtime.inputlock) do
                gather_inputs!(runtime.inputs, runtime.io_states)
            end

            lock(runtime.outputlock) do
                control_callback(
                    runtime.controller,
                    runtime.inputs,
                    runtime.outputs,
                    runtime.config.dt_ms / 1.0e3,
                )
            end

            split_outputs!(runtime.outputs, runtime.io_states)

            copy_to_logger!(runtime)
            isready(runtime.logger.loggerflag) || put!(runtime.logger.loggerflag, true)

            runtime.timestamp += runtime.config.dt_ms / 1.0e3
            Threads.atomic_add!(runtime.step_count, 1)
        catch err
            @error "Control loop error" exception = (err, catch_backtrace())
        end

        elapsed_ns = time_ns() - cycle_start
        remaining_ns = period_ns - elapsed_ns
        remaining_ns > 0 && sleep(remaining_ns / 1.0e9)
    end


    @info "Control loop exiting" total_steps = runtime.step_count[]
    return nothing
end

function logger_loop(stop_signal::StopSignal, logger::Logger)
    @info "Logger loop started" filename = logger.filepath

    while true
        if stop_requested(stop_signal) && !isready(logger.loggerflag)
            break
        end

        try
            take!(logger.loggerflag)
        catch err
            if err isa InvalidStateException
                break
            end
            rethrow(err)
        end

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

function start!(runtime::SystemRuntime, control_callback::Function)
    for state in runtime.io_states
        if is_read_enabled(state.config)
            state.reader_task = Threads.@spawn reader_loop(state, runtime.stop_signal)
            state.parser_task = Threads.@spawn parser_loop(state, runtime.stop_signal)
        end
        if is_write_enabled(state.config)
            state.writer_task = Threads.@spawn writer_loop(state, runtime.stop_signal)
        end
    end

    runtime.control_task = Threads.@spawn control_loop(runtime, control_callback)
    runtime.logger_task = Threads.@spawn logger_loop(runtime.stop_signal, runtime.logger)
    return nothing
end

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

    for state in runtime.io_states
        if is_write_enabled(state.config) && isopen(state.outflag) && !isready(state.outflag)
            put!(state.outflag, true)
        end
    end

    if isopen(runtime.logger.loggerflag) && !isready(runtime.logger.loggerflag)
        put!(runtime.logger.loggerflag, true)
    end

    sleep(0.2)

    for state in runtime.io_states
        isopen(state.rx_queue) && close(state.rx_queue)
        isopen(state.outflag) && close(state.outflag)
    end

    isopen(runtime.logger.loggerflag) && close(runtime.logger.loggerflag)
    return nothing
end
