abstract type AbstractSystem end

parameter_names(::AbstractSystem)::Vector{String} = String[]
monitor_parameter_names(system::AbstractSystem)::Vector{String} = parameter_names(system)

function initialize_parameters!(::AbstractSystem, _params)::Nothing
    return nothing
end

function bind!(::AbstractSystem, _runtime)::Nothing
    return nothing
end

function parameters_updated!(::AbstractSystem, _params)::Nothing
    return nothing
end

function control_step!(system::AbstractSystem, inputs, outputs, params, dt)
    error("control_step! not implemented for system type: $(typeof(system))")
end

mutable struct IOState{IO<:AbstractIO, RAW}
    config::IOConfig{IO}
    rx_queue::SpscQueue{RAW}
    input_work::SignalBuffer
    input_view::NamedSignalView
    input_snapshot::SignalBuffer
    output_shared::SignalBuffer
    output_view::NamedSignalView
    output_shadow::SignalBuffer
    output_shadow_view::NamedSignalView
    outflag::Base.Event
    reader_task::Task
    parser_task::Task
    writer_task::Task
    gather_pairs::Vector{IndexPair}
    split_pairs::Vector{IndexPair}
    input_seq::Threads.Atomic{UInt64}
    output_seq::Threads.Atomic{UInt64}

    function IOState(config::IOConfig{IO}) where {IO<:AbstractIO}
        RAW = raw_payload_type(IO)
        input_buffer = SignalBuffer(is_read_enabled(config) ? input_signal_names(config.io) : String[])
        output_buffer = SignalBuffer(is_write_enabled(config) ? output_signal_names(config.io) : String[])
        output_shadow = SignalBuffer(output_buffer.schema)
        bind_io!(config.io, input_buffer.schema, output_buffer.schema)

        return new{IO,RAW}(
            config,
            SpscQueue{RAW}(config.channel_length),
            input_buffer,
            NamedSignalView(input_buffer),
            SignalBuffer(input_buffer.schema),
            output_buffer,
            NamedSignalView(output_buffer),
            output_shadow,
            NamedSignalView(output_shadow),
            Base.Event(),
            Task(() -> nothing),
            Task(() -> nothing),
            Task(() -> nothing),
            IndexPair[],
            IndexPair[],
            Threads.Atomic{UInt64}(0),
            Threads.Atomic{UInt64}(0),
        )
    end
end

mutable struct SystemRuntime{S, IO<:AbstractIO, RAW, MON}
    config::SystemConfig{IO}
    io_states::Vector{IOState{IO,RAW}}
    stop_signal::StopSignal
    system::S
    logger::Logger
    monitor::MON

    inputs::SignalBuffer
    outputs::SignalBuffer
    params::SignalBuffer

    system_task::Task
    logger_task::Task
    monitor_reader_task::Task
    monitor_writer_task::Task

    step_count::Threads.Atomic{Int}
    timestamp::Float64
    dt_seconds::Float64

    _logger_input_pairs::Vector{IndexPair}
    _logger_output_pairs::Vector{IndexPair}
    _logger_param_pairs::Vector{IndexPair}
    _logger_time_idx::Int

    _monitor_input_pairs::Vector{IndexPair}
    _monitor_output_pairs::Vector{IndexPair}
    _monitor_param_pairs::Vector{IndexPair}
    _monitor_time_idx::Int

    _monitor_param_apply_pairs::Vector{IndexPair}
    _last_param_seq::UInt64
end

function _global_names(io_name::Symbol, local_names::Vector{String})
    return String[global_key(io_name, local_name) for local_name in local_names]
end

function _build_global_inputs(io_states::Vector{IOState{IO,RAW}})::SignalBuffer where {IO,RAW}
    names = String[]
    for state in io_states
        is_read_enabled(state.config) || continue
        append!(names, _global_names(state.config.name, signal_names(state.input_snapshot)))
    end
    return SignalBuffer(names)
end

function _build_global_outputs(io_states::Vector{IOState{IO,RAW}})::SignalBuffer where {IO,RAW}
    names = String[]
    for state in io_states
        is_write_enabled(state.config) || continue
        append!(names, _global_names(state.config.name, signal_names(state.output_shared)))
    end
    return SignalBuffer(names)
end

function _build_logger_keys(inputs::SignalBuffer, outputs::SignalBuffer, params::SignalBuffer)
    keys = String["Time"]
    append!(keys, signal_names(inputs))
    append!(keys, signal_names(outputs))
    append!(keys, signal_names(params))
    return keys
end

function _compute_gather_pairs!(state::IOState, inputs::SignalBuffer)
    pairs = IndexPair[]
    local_names = signal_names(state.input_snapshot)
    for (i, local_name) in enumerate(local_names)
        push!(pairs, IndexPair(i, signal_slot(inputs, global_key(state.config.name, local_name))))
    end
    state.gather_pairs = pairs
    return nothing
end

function _compute_split_pairs!(state::IOState, outputs::SignalBuffer)
    pairs = IndexPair[]
    local_names = signal_names(state.output_shared)
    for (i, local_name) in enumerate(local_names)
        push!(pairs, IndexPair(signal_slot(outputs, global_key(state.config.name, local_name)), i))
    end
    state.split_pairs = pairs
    return nothing
end

function SystemRuntime(
    config::SystemConfig{IO},
    io_states::Vector{IOState{IO,RAW}},
    stop_signal::StopSignal,
    system::S,
) where {S, IO<:AbstractIO, RAW}
    inputs = _build_global_inputs(io_states)
    outputs = _build_global_outputs(io_states)
    params = SignalBuffer(parameter_names(system))
    initialize_parameters!(system, params)

    for state in io_states
        is_read_enabled(state.config) && _compute_gather_pairs!(state, inputs)
        is_write_enabled(state.config) && _compute_split_pairs!(state, outputs)
    end

    logger_keys = _build_logger_keys(inputs, outputs, params)
    logger = Logger(config.logfile, 256, logger_keys)
    writeheader(logger)
    logger_schema = SignalSchema(logger_keys)

    logger_input_pairs = compute_index_pairs(inputs.schema, logger_schema, signal_names(inputs))
    logger_output_pairs = compute_index_pairs(outputs.schema, logger_schema, signal_names(outputs))
    logger_param_pairs = compute_index_pairs(params.schema, logger_schema, signal_names(params))
    logger_time_idx = signal_slot(logger_schema, "Time")

    monitor = if config.monitor === nothing
        nothing
    else
        mc = config.monitor
        TcpMonitor(mc.host, mc.in_port, mc.out_port, monitor_parameter_names(system), logger_keys)
    end
    MON = typeof(monitor)

    if monitor === nothing
        monitor_input_pairs = IndexPair[]
        monitor_output_pairs = IndexPair[]
        monitor_param_pairs = IndexPair[]
        monitor_time_idx = 0
        monitor_param_apply_pairs = IndexPair[]
    else
        monitor_schema = SignalSchema(monitor.out_names)
        monitor_param_schema = SignalSchema(monitor.param_names)
        monitor_input_pairs = compute_index_pairs(inputs.schema, monitor_schema, signal_names(inputs))
        monitor_output_pairs = compute_index_pairs(outputs.schema, monitor_schema, signal_names(outputs))
        monitor_param_pairs = compute_index_pairs(params.schema, monitor_schema, signal_names(params))
        monitor_time_idx = signal_slot(monitor_schema, "Time")
        monitor_param_apply_pairs = compute_index_pairs(monitor_param_schema, params.schema, monitor.param_names)
    end

    runtime = SystemRuntime{S,IO,RAW,MON}(
        config,
        io_states,
        stop_signal,
        system,
        logger,
        monitor,
        inputs,
        outputs,
        params,
        Task(() -> nothing),
        Task(() -> nothing),
        Task(() -> nothing),
        Task(() -> nothing),
        Threads.Atomic{Int}(0),
        0.0,
        config.dt_ms / 1000.0,
        logger_input_pairs,
        logger_output_pairs,
        logger_param_pairs,
        logger_time_idx,
        monitor_input_pairs,
        monitor_output_pairs,
        monitor_param_pairs,
        monitor_time_idx,
        monitor_param_apply_pairs,
        UInt64(0),
    )

    bind!(system, runtime)
    parameters_updated!(system, runtime.params)
    return runtime
end

function SystemRuntime(config::SystemConfig{IO}, stop_signal::StopSignal, system::S) where {S, IO<:AbstractIO}
    RAW = raw_payload_type(IO)
    io_states = IOState{IO,RAW}[IOState(io_cfg) for io_cfg in config.ios]
    return SystemRuntime(config, io_states, stop_signal, system)
end
