"""
    AbstractSystem

Marker supertype for user-defined control systems.

Concrete subtypes are passed to `SystemRuntime` and receive the control callback each cycle.
Two fields are recognised by convention (both optional):

- `params::Dict{String,Float64}` — tunable parameters; `TcpMonitor` writes incoming GUI
  updates here automatically via `apply_monitor_params!` before each callback invocation.
- `lifecycle::SystemLifecycle` — start/stop/duration state; updated each cycle by
  `update_lifecycle!` when the field is present.

## Callback contract

```julia
function my_callback(sys::MySystem,
                     inputs::AbstractDict{String,Float64},
                     outputs::AbstractDict{String,Float64},
                     dt::Float64)
    # inputs:  global-keyed signals from all read-enabled IOs, e.g. "can_rx.EngineSpeed"
    # outputs: global-keyed signals for all write-enabled IOs, e.g. "can_tx.DesiredTorque"
    # dt:      loop period in seconds (= SystemConfig.dt_ms / 1000)
    # Return value is ignored.
end
```

## Minimal example

```julia
mutable struct MySystem <: AbstractSystem
    params::Dict{String,Float64}
end
MySystem() = MySystem(Dict("Kp" => 1.0))
```
"""
abstract type AbstractSystem end

"""
    IOState{IO,RAW}

Per-IO runtime state managed by `SystemRuntime`. Constructed automatically — users do
not build `IOState` directly.

## Optimizations
- `input_local_snapshot::SignalBuffer` — dense vector-backed signal storage (3.1)
- `output_local::SignalBuffer` — dense vector-backed signal storage (3.1)
- `_gather_pairs` / `_split_pairs` — pre-computed index mappings for zero-hash copies (3.1)
- `_snap_seq::Atomic{UInt64}` — SeqLock for lock-free snapshot reads (3.2)
"""
mutable struct IOState{IO<:AbstractIO, RAW}
    config::IOConfig{IO}
    rx_queue::Channel{RAW}
    input_local_rx::Dict{String,Float64}
    input_local_snapshot::SignalBuffer
    output_local::SignalBuffer
    input_keymap::Dict{String,String}
    output_keymap::Dict{String,String}
    outlock::Base.Threads.SpinLock
    outflag::Base.Event
    reader_task::Task
    parser_task::Task
    writer_task::Task
    _gather_pairs::Vector{IndexPair}
    _split_pairs::Vector{IndexPair}
    _snap_seq::Threads.Atomic{UInt64}

    function IOState(config::IOConfig{IO}) where {IO<:AbstractIO}
        RAW = raw_payload_type(IO)
        input_names = is_read_enabled(config) ? unique(input_signal_names(config.io)) : String[]
        output_names = is_write_enabled(config) ? unique(output_signal_names(config.io)) : String[]

        input_local_rx = Dict{String,Float64}(name => 0.0 for name in input_names)
        input_local_snapshot = SignalBuffer(sort(copy(input_names)))
        output_local = SignalBuffer(sort(copy(output_names)))

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
            Base.Threads.SpinLock(),
            Base.Event(),
            Task(() -> nothing),
            Task(() -> nothing),
            Task(() -> nothing),
            IndexPair[],
            IndexPair[],
            Threads.Atomic{UInt64}(0),
        )
    end
end

"""
    SystemRuntime{S,IO,RAW,MON}

Aggregate runtime bundle. Constructed via `SystemRuntime(config, stop_signal, system)`.

## Type parameters

| Parameter | Constraint         | Meaning |
|-----------|--------------------|---------|
| `S`       | `<:AbstractSystem` | Concrete system type; enables type-stable callback dispatch |
| `IO`      | `<:AbstractIO`     | Concrete IO transport type |
| `RAW`     |                    | Raw payload type (`raw_payload_type(IO)`); specializes `rx_queue` |
| `MON`     | `TcpMonitor` or `Nothing` | Concrete monitor type; `Nothing` when monitoring is disabled |

## Optimizations (3.1)
- `inputs`, `outputs`, `params` are `SignalBuffer` for dense vector-backed storage
- Pre-computed `IndexPair` vectors for zero-hash copies to logger and monitor sinks
"""
mutable struct SystemRuntime{S, IO<:AbstractIO, RAW, MON}
    config::SystemConfig{IO}
    io_states::Vector{IOState{IO,RAW}}
    stop_signal::StopSignal
    system::S
    logger::Logger
    monitor::MON

    params::SignalBuffer
    paramlock::ReentrantLock
    inputs::SignalBuffer
    outputs::SignalBuffer

    # Cached reference to system.params (avoids hasproperty reflection per cycle)
    _sys_params_ref::Union{Dict{String,Float64},Nothing}

    system_task::Task
    logger_task::Task
    monitor_reader_task::Task
    monitor_writer_task::Task

    step_count::Threads.Atomic{Int}
    timestamp::Float64

    # Pre-computed logger pairs (3.1)
    _logger_input_pairs::Vector{IndexPair}
    _logger_output_pairs::Vector{IndexPair}
    _logger_param_pairs::Vector{IndexPair}
    _logger_time_idx::Int

    # Pre-computed monitor pairs (3.1)
    _monitor_input_pairs::Vector{IndexPair}
    _monitor_output_pairs::Vector{IndexPair}
    _monitor_param_pairs::Vector{IndexPair}
    _monitor_time_idx::Int
    _last_param_seq::UInt64
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

function _build_global_inputs(io_states::Vector{IOState{IO,RAW}})::SignalBuffer where {IO,RAW}
    names = String[]
    for state in io_states
        is_read_enabled(state.config) || continue
        for (_, global_name) in state.input_keymap
            push!(names, global_name)
        end
    end
    sort!(names)
    unique!(names)
    return SignalBuffer(names)
end

function _build_global_outputs(io_states::Vector{IOState{IO,RAW}})::SignalBuffer where {IO,RAW}
    names = String[]
    for state in io_states
        is_write_enabled(state.config) || continue
        for (_, global_name) in state.output_keymap
            push!(names, global_name)
        end
    end
    sort!(names)
    unique!(names)
    return SignalBuffer(names)
end

function _build_logger_keys(
    inputs::AbstractDict{String,Float64},
    outputs::AbstractDict{String,Float64},
    params::AbstractDict{String,Float64},
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
    params_dict = system_params(system)
    inputs = _build_global_inputs(io_states)
    outputs = _build_global_outputs(io_states)

    # Convert params Dict to SignalBuffer
    params_names = sort(collect(keys(params_dict)))
    params = SignalBuffer(params_dict, params_names)

    logger_keys = _build_logger_keys(inputs, outputs, params)
    logger = Logger(config.logfile, 64, logger_keys)
    writeheader(logger)

    # Back-fill gather/split pairs on each IOState
    for state in io_states
        if is_read_enabled(state.config)
            state._gather_pairs = compute_gather_pairs(
                state.input_local_snapshot, state.input_keymap, inputs)
        end
        if is_write_enabled(state.config)
            state._split_pairs = compute_split_pairs(
                outputs, state.output_keymap, state.output_local)
        end
    end

    # Pre-compute logger index pairs
    logger_input_pairs = compute_index_pairs(inputs._index, logger.loggerdict._index, inputs.names)
    logger_output_pairs = compute_index_pairs(outputs._index, logger.loggerdict._index, outputs.names)
    logger_param_pairs = compute_index_pairs(params._index, logger.loggerdict._index, params.names)
    logger_time_idx = get(logger.loggerdict._index, "Time", 0)

    # Build monitor if configured (uses same signal keys as logger)
    monitor = if config.monitor !== nothing
        mc = config.monitor
        param_names = sort(collect(keys(params_dict)))
        TcpMonitor(mc.host, mc.in_port, mc.out_port, param_names, logger_keys)
    else
        nothing
    end
    MON = typeof(monitor)

    # Pre-compute monitor index pairs
    if monitor !== nothing
        monitor_input_pairs = compute_index_pairs(inputs._index, monitor.monitordict._index, inputs.names)
        monitor_output_pairs = compute_index_pairs(outputs._index, monitor.monitordict._index, outputs.names)
        monitor_param_pairs = compute_index_pairs(params._index, monitor.monitordict._index, params.names)
        monitor_time_idx = get(monitor.monitordict._index, "Time", 0)
    else
        monitor_input_pairs = IndexPair[]
        monitor_output_pairs = IndexPair[]
        monitor_param_pairs = IndexPair[]
        monitor_time_idx = 0
    end

    # Cache direct reference to system.params (eliminates hasproperty reflection per cycle)
    sys_params_ref = hasproperty(system, :params) ?
        getproperty(system, :params)::Dict{String,Float64} : nothing

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
        outputs,
        sys_params_ref,
        Task(() -> nothing),
        Task(() -> nothing),
        Task(() -> nothing),
        Task(() -> nothing),
        Threads.Atomic{Int}(0),
        0.0,
        logger_input_pairs,
        logger_output_pairs,
        logger_param_pairs,
        logger_time_idx,
        monitor_input_pairs,
        monitor_output_pairs,
        monitor_param_pairs,
        monitor_time_idx,
        UInt64(0),
    )
end

function SystemRuntime(config::SystemConfig{IO}, stop_signal::StopSignal, system::S) where {S, IO<:AbstractIO}
    RAW = raw_payload_type(IO)
    io_states = IOState{IO,RAW}[IOState(io_cfg) for io_cfg in config.ios]
    return SystemRuntime(config, io_states, stop_signal, system)
end
