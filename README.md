# SystemSimulator.jl

`SystemSimulator.jl` is a deterministic multi-threaded runtime for control loops over
multiple bidirectional IO transports such as CAN.

The runtime is now schema-driven and performance-oriented:

- systems operate on dense `SignalBuffer` storage
- signal names are resolved to integer slots during `bind!`
- the steady-state control path uses `control_step!`
- runtime-owned parameters replace the old `Dict`-based callback contract

## Running

```bash
cd SystemSimulator.jl
julia --threads=auto --project=. test/runtests.jl
```

## Core API

Define a system by implementing these hooks on your `AbstractSystem` subtype:

```julia
import SystemSimulator as SS

mutable struct MySystem <: SS.AbstractSystem
    input_slot::Int
    output_slot::Int
    gain_slot::Int
end

MySystem() = MySystem(0, 0, 0)

SS.parameter_names(::MySystem) = ["gain"]

function SS.initialize_parameters!(sys::MySystem, params)
    params["gain"] = 1.0
    return nothing
end

function SS.bind!(sys::MySystem, runtime)
    sys.input_slot = SS.signal_slot(runtime.inputs, "can_rx.EngineSpeed")
    sys.output_slot = SS.signal_slot(runtime.outputs, "can_tx.DesiredTorque")
    sys.gain_slot = SS.signal_slot(runtime.params, "gain")
    return nothing
end

function SS.control_step!(sys::MySystem, inputs, outputs, params, dt)
    outputs[sys.output_slot] = params[sys.gain_slot] * inputs[sys.input_slot]
    return nothing
end
```

Build the runtime and start it:

```julia
rx_io = SS.CanIO(driver_rx, rx_messages, typeof(rx_messages[1])[])
tx_io = SS.CanIO(driver_tx, typeof(tx_messages[1])[], tx_messages)

cfg = SS.SystemConfig(
    10,
    [
        SS.IOConfig(:can_rx, rx_io, 256, SS.IO_MODE_READONLY),
        SS.IOConfig(:can_tx, tx_io, 256, SS.IO_MODE_WRITEONLY),
    ],
    "log.csv",
)

runtime = SS.SystemRuntime(cfg, SS.StopSignal(), MySystem())
SS.start!(runtime)
sleep(5.0)
SS.request_stop!(runtime.stop_signal)
SS.stop!(runtime)
```

## Signal Access

Use names only during setup:

```julia
slot = SS.signal_slot(runtime.inputs, "can_rx.EngineSpeed")
```

Use integer slots inside `control_step!`:

```julia
value = inputs[slot]
outputs[out_slot] = value
```

`SignalBuffer` still supports name-based access for setup, tests, and debugging:

```julia
runtime.params["gain"] = 2.0
```

## Parameters and Monitor Input

Parameters live in `runtime.params`. Systems can opt into monitor input by overriding:

```julia
SS.monitor_parameter_names(::MySystem) = ["gain"]
```

If not overridden, monitor input uses `parameter_names(system)`.

## Lifecycle Helper

`SystemLifecycle` is still available, but the fast path uses cached lifecycle slots:

```julia
mutable struct MyTimedSystem <: SS.AbstractSystem
    lifecycle::SS.SystemLifecycle
    lifecycle_slots::Union{SS.LifecycleSlots,Nothing}
end

function SS.bind!(sys::MyTimedSystem, runtime)
    sys.lifecycle_slots = SS.bind_lifecycle(runtime.params)
end

function SS.control_step!(sys::MyTimedSystem, inputs, outputs, params, dt)
    event = SS.update_lifecycle!(sys.lifecycle, params, sys.lifecycle_slots, dt)
    return nothing
end
```

## IO Interface

Custom IO types subtype `AbstractIO` and implement:

- `read_raw`
- `decode_raw!`
- `encode_and_write!` or `encode_raw` + `write_raw`
- `input_signal_names`
- `output_signal_names`

The runtime passes named adapters at the IO boundary, so custom backends can still decode
and encode by signal name without changing the hot system API.

## TcpMonitor

`TcpMonitor` is configured through `MonitorConfig` on `SystemConfig`.

- input port: receives parameter vectors in declared monitor-parameter order
- output port: streams `Time`, inputs, outputs, and params in logger-column order

See [examples/tcp_example.jl](/home/aditya/Desktop/SRT/SystemSimulator.jl/examples/tcp_example.jl) for a minimal runnable example.
