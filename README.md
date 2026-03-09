# SystemSimulator.jl

## Overview

SystemSimulator is a multi-threaded control loop runtime for deterministic, real-time control
over multiple bidirectional IO transports (CAN, mock, or any custom backend). The user provides
a system struct and a callback function; the framework handles threading, IO, logging, and optional
live parameter tuning over TCP.

## Installation & Threads

This is an unregistered local package. All simulations **must** run with multiple threads:

```bash
cd SystemSimulator.jl
julia --threads=auto --project=. examples/tcp_example.jl
```

`--threads=auto` is required because each IO endpoint spawns dedicated reader, parser, and writer
tasks, plus a global system task, logger task, and optional monitor tasks — all running
concurrently via `Threads.@spawn`.

## Five-Step Quickstart

```julia
import SystemSimulator as SS
import CANInterface as CI
import J1939Parser as CP

# 1. Define your system struct (optional: params and lifecycle fields)
mutable struct MySystem <: SS.AbstractSystem
    params::Dict{String,Float64}   # auto-synced by TcpMonitor when configured
end
MySystem() = MySystem(Dict("Kp" => 1.0))

# 2. Define the control callback
function my_callback(sys::MySystem, inputs, outputs, dt)
    # inputs: Dict{String,Float64} with keys like "can_rx.EngineSpeed"
    # outputs: Dict{String,Float64} with keys like "can_tx.DesiredTorque"
    outputs["can_tx.DesiredTorque"] = sys.params["Kp"] * inputs["can_rx.EngineSpeed"]
    return nothing
end

# 3. Set up CanIO endpoints
rx_io = SS.CanIO(CI.SocketCanDriver("vcan1"), rx_messages, CP.CanMessage[])
tx_io = SS.CanIO(CI.SocketCanDriver("vcan2"), CP.CanMessage[], tx_messages)

# 4. Build SystemConfig
cfg = SS.SystemConfig(
    100,   # dt_ms: 100 ms loop period
    [
        SS.IOConfig(:can_rx, rx_io, 256, SS.IO_MODE_READONLY),
        SS.IOConfig(:can_tx, tx_io, 256, SS.IO_MODE_WRITEONLY),
    ],
    "experiment.csv",
)

# 5. Construct runtime, start, sleep, stop
sf  = SS.StopSignal()
rt  = SS.SystemRuntime(cfg, sf, MySystem())
SS.start!(rt, my_callback)
sleep(10.0)
SS.request_stop!(sf)
SS.stop!(rt)
```

## Signal Namespacing

Every signal is prefixed with its IO endpoint name to avoid collisions. The contract is:

```
global_key = "<io_name>.<local_signal_name>"
```

Examples:

| `IOConfig` name | Local signal    | Global key                  |
|-----------------|-----------------|-----------------------------|
| `:can_rx`       | `"EngineSpeed"` | `"can_rx.EngineSpeed"`      |
| `:can_tx`       | `"EngineSpeed"` | `"can_tx.EngineSpeed"`      |
| `:sensors`      | `"Throttle"`    | `"sensors.Throttle"`        |

The helper `global_key(:can_rx, "EngineSpeed") == "can_rx.EngineSpeed"` is available for
constructing keys programmatically. The callback `inputs` and `outputs` dicts always use
global keys.

## Threading Model

```
┌──────────────────── per IOConfig ────────────────────┐
│  reader_task  →  rx_queue  →  parser_task            │
│  writer_task  ←  outflag   ←  (system_loop notifies) │
└──────────────────────────────────────────────────────┘

                    ┌─── global ───────────────────────┐
                    │  system_task   (system_loop)      │
                    │  logger_task   (logger_loop)      │
                    │  monitor_reader_task  (optional)  │
                    │  monitor_writer_task  (optional)  │
                    └──────────────────────────────────┘
```

- The **reader task** blocks on `read_raw` and enqueues raw payloads.
- The **parser task** drains the queue, calls `decode_raw!`, and updates the locked snapshot.
- The **system loop** runs at `dt_ms` cadence: gathers snapshots → callback → splits outputs →
  signals writer tasks.
- The **writer task** wakes on `outflag`, encodes outputs, calls `write_raw`.
- The **logger task** wakes each control cycle and writes a CSV row.

## Implementing `AbstractSystem`

Subtype `AbstractSystem` and optionally add two well-known fields:

```julia
mutable struct MySystem <: AbstractSystem
    params::Dict{String,Float64}    # optional: auto-synced from GUI via TcpMonitor
    lifecycle::SystemLifecycle      # optional: start/stop/duration control from GUI
end
```

The control callback signature is:

```julia
function my_callback(sys::MySystem,
                     inputs::Dict{String,Float64},
                     outputs::Dict{String,Float64},
                     dt::Float64)
    # Read from inputs, write to outputs. Return value is ignored.
end
```

For real-world examples see:
- `AcrobatSim.jl/src/system.jl` — physics simulation with lifecycle
- `SysId.jl/src/experiment.jl` — system identification with lifecycle and params

## TcpMonitor & Dash

Add a `MonitorConfig` to `SystemConfig` to enable live parameter tuning and signal streaming:

```julia
cfg = SS.SystemConfig(
    100,
    ios,
    "log.csv",
    SS.MonitorConfig("0.0.0.0", 9000, 9001),  # in_port=9000, out_port=9001
)
```

- `in_port`: receives `Float64` param vectors from the GUI (0 = disabled)
- `out_port`: streams all signals every control cycle (0 = disabled)

See `examples/tcp_example.jl` for a full runnable demo and the binary protocol details.
The `srt-dash` Python package provides a `SimulatorClient` that speaks this protocol;
see `TCPcom.md` for the wire format.

## Custom IO Transports

Subtype `AbstractIO` and implement these six methods:

| Method                             | Purpose                                        |
|------------------------------------|------------------------------------------------|
| `read_raw(io) -> payload\|nothing` | Block until one payload arrives                |
| `decode_raw!(io, raw, dict) -> Bool` | Decode raw payload into signal dict          |
| `encode_raw(io, dict) -> Vector`   | Encode signal dict into raw payloads           |
| `write_raw(io, payload) -> Nothing`| Write one encoded payload to transport         |
| `input_signal_names(io) -> Vector{String}` | All local input signal names         |
| `output_signal_names(io) -> Vector{String}` | All local output signal names       |

Optionally override `raw_payload_type(::Type{MyIO})` to return a concrete type. This specializes
the `IOState` rx queue channel and eliminates boxing overhead.

See `test/runtests.jl` for a `MockIO` implementation covering all six methods.

## Running Tests

```bash
cd SystemSimulator.jl
julia --project=. --threads=auto test/runtests.jl
```
