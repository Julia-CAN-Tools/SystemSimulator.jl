abstract type AbstractSystem end

"""
    IOState

Per-IO runtime state for reader/parser/writer tasks and local signal dictionaries.
"""
mutable struct IOState{IO<:AbstractIO, RAW}
    config::IOConfig{IO}
    rx_queue::Channel{RAW}
    input_local_rx::Dict{String,Float64}
    input_local_snapshot::Dict{String,Float64}
    output_local::Dict{String,Float64}
    input_keymap::Dict{String,String}
    output_keymap::Dict{String,String}
    inputlock::ReentrantLock
    outlock::ReentrantLock
    outflag::Channel{Bool}
    reader_task::Task
    parser_task::Task
    writer_task::Task

    function IOState(config::IOConfig{IO}) where {IO<:AbstractIO}
        RAW = raw_payload_type(IO)
        input_names = is_read_enabled(config) ? unique(input_signal_names(config.io)) : String[]
        output_names = is_write_enabled(config) ? unique(output_signal_names(config.io)) : String[]

        input_local_rx = Dict{String,Float64}(name => 0.0 for name in input_names)
        input_local_snapshot = copy(input_local_rx)
        output_local = Dict{String,Float64}(name => 0.0 for name in output_names)

        input_keymap = build_keymap(config.name, input_names)
        output_keymap = build_keymap(config.name, output_names)

        return new{IO,RAW}(
            config,
            Channel{RAW}(config.channel_length),
            input_local_rx,
            input_local_snapshot,
            output_local,
            input_keymap,
            output_keymap,
            ReentrantLock(),
            ReentrantLock(),
            Channel{Bool}(1),
            Task(() -> nothing),
            Task(() -> nothing),
            Task(() -> nothing),
        )
    end
end

"""
    SystemRuntime

Aggregate runtime bundle for lifecycle management.
"""
mutable struct SystemRuntime{S, IO<:AbstractIO, RAW, MON}
    config::SystemConfig{IO}
    io_states::Vector{IOState{IO,RAW}}
    stop_signal::StopSignal
    system::S
    logger::Logger
    monitor::MON

    params::Dict{String,Float64}
    paramlock::ReentrantLock
    inputs::Dict{String,Float64}
    inputlock::ReentrantLock
    outputs::Dict{String,Float64}
    outputlock::ReentrantLock

    system_task::Task
    logger_task::Task
    monitor_reader_task::Task
    monitor_writer_task::Task

    step_count::Threads.Atomic{Int}
    timestamp::Float64
end

function _as_float64_dict(values)::Dict{String,Float64}
    if values isa AbstractDict
        return Dict{String,Float64}(string(k) => Float64(v) for (k, v) in pairs(values))
    end
    return Dict{String,Float64}()
end

function system_params(system)::Dict{String,Float64}
    if hasproperty(system, :params)
        return _as_float64_dict(getproperty(system, :params)::AbstractDict)
    end
    return Dict{String,Float64}()
end

function _build_global_inputs(io_states::Vector{IOState{IO,RAW}})::Dict{String,Float64} where {IO,RAW}
    global_inputs = Dict{String,Float64}()
    for state in io_states
        is_read_enabled(state.config) || continue
        for (local_name, global_name) in state.input_keymap
            global_inputs[global_name] = get(state.input_local_snapshot, local_name, 0.0)
        end
    end
    return global_inputs
end

function _build_global_outputs(io_states::Vector{IOState{IO,RAW}})::Dict{String,Float64} where {IO,RAW}
    global_outputs = Dict{String,Float64}()
    for state in io_states
        is_write_enabled(state.config) || continue
        for (local_name, global_name) in state.output_keymap
            global_outputs[global_name] = get(state.output_local, local_name, 0.0)
        end
    end
    return global_outputs
end

function _build_logger_keys(
    inputs::Dict{String,Float64},
    outputs::Dict{String,Float64},
    params::Dict{String,Float64},
)::Vector{String}
    keys_ld = String["Time"]
    append!(keys_ld, sort(collect(keys(inputs))))
    append!(keys_ld, sort(collect(keys(outputs))))
    append!(keys_ld, sort(collect(keys(params))))
    return keys_ld
end

function SystemRuntime(
    config::SystemConfig{IO},
    io_states::Vector{IOState{IO,RAW}},
    stop_signal::StopSignal,
    system::S,
) where {S, IO<:AbstractIO, RAW}
    params = system_params(system)
    inputs = _build_global_inputs(io_states)
    outputs = _build_global_outputs(io_states)

    logger_keys = _build_logger_keys(inputs, outputs, params)
    logger = Logger(config.logfile, 64, logger_keys)
    writeheader(logger)

    # Build monitor if configured (uses same signal keys as logger)
    monitor = if config.monitor !== nothing
        mc = config.monitor
        param_names = sort(collect(keys(params)))
        TcpMonitor(mc.host, mc.in_port, mc.out_port, param_names, logger_keys)
    else
        nothing
    end
    MON = typeof(monitor)   # TcpMonitor or Nothing — always concrete

    return SystemRuntime{S,IO,RAW,MON}(
        config,
        io_states,
        stop_signal,
        system,
        logger,
        monitor,
        params,
        ReentrantLock(),
        inputs,
        ReentrantLock(),
        outputs,
        ReentrantLock(),
        Task(() -> nothing),
        Task(() -> nothing),
        Task(() -> nothing),
        Task(() -> nothing),
        Threads.Atomic{Int}(0),
        0.0,
    )
end

function SystemRuntime(config::SystemConfig{IO}, stop_signal::StopSignal, system::S) where {S, IO<:AbstractIO}
    RAW = raw_payload_type(IO)
    io_states = IOState{IO,RAW}[IOState(io_cfg) for io_cfg in config.ios]
    return SystemRuntime(config, io_states, stop_signal, system)
end
