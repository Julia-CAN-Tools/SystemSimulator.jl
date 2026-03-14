"""
Example: SystemSimulator CAN echo — vehicle status read + EEC1 write.

Reads all vehicle status signals from `vcan1` (J1939 traffic replayed by `canplayer`)
and echoes the `EEC1` message back to `vcan2`.  Logs all signals to a CSV file.

## Prerequisites

1. Virtual CAN interfaces configured:
       bash J1939Parser.jl/logs/setupVirtualCAN.sh
2. CAN traffic replaying on vcan1 (see `J1939Parser.jl/logs/`):
       canplayer vcan1=can1 -I <logfile> -l i

## Running

    cd SystemSimulator.jl
    julia --threads=auto --project=. examples/runscript.jl

## Signal namespacing

- `:can_rx` prefix  →  input keys like `"can_rx.EngineSpeed"`
- `:can_tx` prefix  →  output keys like `"can_tx.EngineSpeed"`

The callback copies matching signals from `can_rx.*` to `can_tx.*`.
"""

import SystemSimulator as SS
import CANInterface as CI
import J1939Parser as CP

include(joinpath(@__DIR__, "catalogs.jl"))

sf = SS.StopSignal()

function _message_by_name(messages::Vector{CP.CanMessage}, name::String)
    for msg in messages
        msg.name == name && return msg
    end
    throw(ArgumentError("Message '$name' not found in catalog"))
end

# Read all vehicle status traffic from vcan1.
rx_io = SS.CanIO(
    CI.SocketCanDriver("vcan1"),
    VEHICLE_STATUS_MESSAGES,
    CP.CanMessage[],
)

# Write one representative message to vcan2.
tx_catalog = CP.CanMessage[deepcopy(_message_by_name(VEHICLE_STATUS_MESSAGES, "EEC1"))]
tx_io = SS.CanIO(
    CI.SocketCanDriver("vcan2"),
    CP.CanMessage[],
    tx_catalog,
)

cfg = SS.SystemConfig(
    100,
    [
        SS.IOConfig(:can_rx, rx_io, 256, SS.IO_MODE_READONLY),
        SS.IOConfig(:can_tx, tx_io, 256, SS.IO_MODE_WRITEONLY),
    ],
    joinpath(@__DIR__, "Logger1.csv"),
)

mutable struct DummySystem <: SS.AbstractSystem
    input_slots::Vector{Int}
    output_slots::Vector{Int}
end

DummySystem() = DummySystem(Int[], Int[])

function SS.bind!(dc::DummySystem, runtime)
    dc.input_slots = [SS.signal_slot(runtime.inputs, "can_rx.$name") for name in SS.signal_names(runtime.io_states[1].input_snapshot)]
    dc.output_slots = [SS.signal_slot(runtime.outputs, "can_tx.$name") for name in SS.signal_names(runtime.io_states[2].output_shared)]
    return nothing
end

function SS.control_step!(dc::DummySystem, inputs, outputs, _params, _dt)
    @inbounds for i in eachindex(dc.output_slots)
        outputs[dc.output_slots[i]] = inputs[dc.input_slots[i]]
    end
    return nothing
end

runtime = SS.SystemRuntime(cfg, sf, DummySystem())

SS.start!(runtime)

RUN_SECONDS = 10.0
@info "Running SystemSimulator example" run_seconds = RUN_SECONDS
sleep(RUN_SECONDS)

# Wake vcan1 once so blocking read can unwind immediately during shutdown.
SS.request_stop!(runtime.stop_signal)
_waker = CI.SocketCanDriver("vcan1")
try
    CI.write(_waker, UInt32(0x18FF0000), ntuple(_ -> UInt8(0), 8))
catch err
    @warn "Wake frame write failed" exception = (err, catch_backtrace())
finally
    CI.close(_waker)
end

@info "Stopping" steps = runtime.step_count[] timestamp = runtime.timestamp
SS.stop!(runtime)
