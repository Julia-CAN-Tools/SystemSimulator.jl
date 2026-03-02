# SystemSimulator

`SystemSimulator.jl` is a general-purpose simulator runtime for systems connected to multiple bidirectional IO endpoints.

## What Was Implemented

- New sibling package: `SystemSimulator.jl`
- Generic IO interface:
  - `read_raw(io)`
  - `decode_raw!(io, raw, local_inputs)`
  - `encode_raw(io, local_outputs)`
  - `write_raw(io, payload)`
  - `input_signal_names(io)`
  - `output_signal_names(io)`
  - `Base.close(io)`
- Namespaced signal model: `io_name.signal_name`
- Runtime and lifecycle:
  - `IOConfig`, `SystemConfig`, `IOState`, `SystemRuntime`
  - `start!(runtime, callback)`
  - `stop!(runtime)`
- Generic task loops:
  - Per IO: reader/parser/writer
  - Global: deterministic control loop + logger loop
- CAN adapter included:
  - `CanIO` (uses `CANInterface` and `CANUtils`)

## File Layout

- `SystemSimulator.jl/src/SystemSimulator.jl`
- `SystemSimulator.jl/src/config.jl`
- `SystemSimulator.jl/src/runtime.jl`
- `SystemSimulator.jl/src/loops.jl`
- `SystemSimulator.jl/src/utils.jl`
- `SystemSimulator.jl/src/logger.jl`
- `SystemSimulator.jl/src/stopsignal.jl`
- `SystemSimulator.jl/src/IO/abstractIO.jl`
- `SystemSimulator.jl/src/IO/canIO.jl`
- `SystemSimulator.jl/test/runtests.jl`

## Callback Contract

Control callback signature:

```julia
callback(controller, inputs::Dict{String,Float64}, outputs::Dict{String,Float64}, dt_s::Float64)
```

Inputs and outputs are namespaced flat keys, for example:

- `"can_rx.EngineSpeed"`
- `"can_tx.ReqSpeed_SpeedLimit"`

## Migration Map

- `ControlSimulator.CanChannelConfig` -> `SystemSimulator.IOConfig`
- `ControlSimulator.ControlConfig` -> `SystemSimulator.SystemConfig`
- `ControlSimulator.RxCanChannelState` / `TxCanChannelState` -> `SystemSimulator.IOState`
- `ControlSimulator.ControlRuntime` -> `SystemSimulator.SystemRuntime`
- `can_reader_loop` / `actuator_loop` -> generic `reader_loop` / `writer_loop`

## Notes

- `ControlSimulator.jl` was left untouched.
- `SystemSimulator.jl` tests include:
  - mock generic IO integration
  - multi-IO namespacing
  - cross-IO control callback routing
  - CAN adapter end-to-end flow
  - failure-path shutdown resilience
