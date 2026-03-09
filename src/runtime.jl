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
                     inputs::Dict{String,Float64},
                     outputs::Dict{String,Float64},
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

## Fields

| Field                  | Type                    | Description |
|------------------------|-------------------------|-------------|
| `config`               | `IOConfig{IO}`          | Source configuration (name, io instance, mode) |
| `rx_queue`             | `Channel{RAW}`          | Raw payload channel between reader and parser tasks |
| `input_local_rx`       | `Dict{String,Float64}`  | Latest decoded values (local signal names) |
| `input_local_snapshot` | `Dict{String,Float64}`  | Locked copy read by the system loop |
| `output_local`         | `Dict{String,Float64}`  | Output values (local names) written by the system loop |
| `input_keymap`         | `Dict{String,String}`   | Maps local input name → global key (`"<name>.<signal>"`) |
| `output_keymap`        | `Dict{String,String}`   | Maps local output name → global key |
| `inputlock`            | `ReentrantLock`         | Guards `input_local_snapshot` |
| `outlock`              | `ReentrantLock`         | Guards `output_local` during encode |
| `outflag`              | `Channel{Bool}`         | Capacity-1 channel; system loop sends `true` to wake writer |
| `reader_task`          | `Task`                  | Blocking `read_raw` loop |
| `parser_task`          | `Task`                  | `decode_raw!` consumer loop |
| `writer_task`          | `Task`                  | `encode_raw` / `write_raw` loop |
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
    SystemRuntime{S,IO,RAW,MON}

Aggregate runtime bundle. Constructed via `SystemRuntime(config, stop_signal, system)`.

## Type parameters

| Parameter | Constraint         | Meaning |
|-----------|--------------------|---------|
| `S`       | `<:AbstractSystem` | Concrete system type; enables type-stable callback dispatch |
| `IO`      | `<:AbstractIO`     | Concrete IO transport type |
| `RAW`     |                    | Raw payload type (`raw_payload_type(IO)`); specializes `rx_queue` |
| `MON`     | `TcpMonitor` or `Nothing` | Concrete monitor type; `Nothing` when monitoring is disabled |

`SystemRuntime{S,IO,RAW,Nothing}` and `SystemRuntime{S,IO,RAW,TcpMonitor}` are distinct
concrete types, so all monitor-related dispatch is resolved at compile time.

## Fields

| Field                 | Type                    | Description |
|-----------------------|-------------------------|-------------|
| `config`              | `SystemConfig{IO}`      | Top-level configuration |
| `io_states`           | `Vector{IOState{IO,RAW}}` | Per-IO state (one entry per `IOConfig`) |
| `stop_signal`         | `StopSignal`            | Thread-safe shutdown flag |
| `system`              | `S`                     | User-defined system struct |
| `logger`              | `Logger`                | Write-behind CSV logger |
| `monitor`             | `MON`                   | `TcpMonitor` or `nothing` |
| `params`              | `Dict{String,Float64}`  | Snapshot of `system.params` (empty if field absent) |
| `inputs`              | `Dict{String,Float64}`  | Global-keyed input signals |
| `outputs`             | `Dict{String,Float64}`  | Global-keyed output signals |
| `step_count`          | `Threads.Atomic{Int}`   | Number of completed control cycles |
| `timestamp`           | `Float64`               | Accumulated simulated time in seconds |
| `system_task`         | `Task`                  | Handle for `system_loop` |
| `logger_task`         | `Task`                  | Handle for `logger_loop` |
| `monitor_reader_task` | `Task`                  | Handle for `monitor_reader_loop` (if enabled) |
| `monitor_writer_task` | `Task`                  | Handle for `monitor_writer_loop` (if enabled) |

## Constructor

```julia
SystemRuntime(config::SystemConfig, stop_signal::StopSignal, system) -> SystemRuntime
```
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
    # Fix monitor type parameter at construction time → SystemRuntime{S,IO,RAW,Nothing}
    # and {S,IO,RAW,TcpMonitor} are distinct concrete types, eliminating runtime dispatch.
    MON = typeof(monitor)

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
