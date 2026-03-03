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

struct DummyController <: SS.AbstractController
    params::Dict{String,Float64}
end

DummyController() = DummyController(Dict{String,Float64}())

function ccb(dc, inputs, outputs, dt)
    for (key, value) in inputs
        startswith(key, "can_rx.") || continue
        local_key = split(key, "."; limit=2)[2]
        out_key = string("can_tx.", local_key)
        if haskey(outputs, out_key)
            outputs[out_key] = value
        end
    end
    return nothing
end

runtime = SS.SystemRuntime(cfg, sf, DummyController())

SS.start!(runtime, ccb)

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
