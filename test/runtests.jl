using Test
using Sockets
import SystemSimulator as SS
import CANInterface as CI
import CANUtils as CU
import J1939Parser as CP

mutable struct MockIO <: SS.AbstractIO
    rx::Channel{Any}
    tx::Channel{Any}
    in_names::Vector{String}
    out_names::Vector{String}
    closed::Bool
    throw_decode::Bool
    throw_write::Bool
end

function MockIO(in_names::Vector{String}, out_names::Vector{String}; bufsize::Int=128)
    return MockIO(
        Channel{Any}(bufsize),
        Channel{Any}(bufsize),
        in_names,
        out_names,
        false,
        false,
        false,
    )
end

function SS.read_raw(io::MockIO)
    io.closed && return nothing
    try
        if isready(io.rx)
            return take!(io.rx)
        end
    catch
        return nothing
    end
    sleep(0.005)
    return nothing
end

function SS.decode_raw!(io::MockIO, raw, local_inputs::AbstractDict{String,Float64})::Bool
    io.throw_decode && throw(ErrorException("mock decode failure"))
    raw isa AbstractDict || return false
    for name in io.in_names
        haskey(raw, name) && (local_inputs[name] = Float64(raw[name]))
    end
    return true
end

function SS.encode_raw(io::MockIO, local_outputs::AbstractDict{String,<:Real})::Vector{Any}
    isempty(io.out_names) && return Any[]
    payload = Dict{String,Float64}(name => Float64(get(local_outputs, name, 0.0)) for name in io.out_names)
    return Any[payload]
end

function SS.write_raw(io::MockIO, payload)::Nothing
    io.throw_write && throw(ErrorException("mock write failure"))
    io.closed && return nothing
    put!(io.tx, payload)
    return nothing
end

SS.input_signal_names(io::MockIO) = copy(io.in_names)
SS.output_signal_names(io::MockIO) = copy(io.out_names)

function Base.close(io::MockIO)::Nothing
    io.closed = true
    isopen(io.rx) && close(io.rx)
    isopen(io.tx) && close(io.tx)
    return nothing
end

inject_mock_frame!(io::MockIO, frame::Dict{String,Float64}) = put!(io.rx, frame)

mutable struct MockCanDriver <: CI.AbstractCanDriver
    channelname::String
    rx::Channel{CI.CanFrameRaw}
    tx::Channel{CI.CanFrameRaw}
    closed::Bool
end

function MockCanDriver(name::String; bufsize=256)
    MockCanDriver(name, Channel{CI.CanFrameRaw}(bufsize), Channel{CI.CanFrameRaw}(bufsize), false)
end

function CI.read(d::MockCanDriver)
    d.closed && return nothing
    try
        if isready(d.rx)
            return take!(d.rx)
        end
    catch
        return nothing
    end
    sleep(0.005)
    return nothing
end

function CI.write(d::MockCanDriver, canid::UInt32, data::NTuple{8,UInt8})
    d.closed && return nothing
    put!(d.tx, CI.CanFrameRaw(canid, UInt8(8), 0x00, 0x00, 0x00, data))
    return nothing
end

function CI.write(d::MockCanDriver, canid::UInt32, data::AbstractVector{UInt8})
    CI.write(d, canid, ntuple(i -> data[i], 8))
end

function CI.close(d::MockCanDriver)
    d.closed = true
    isopen(d.rx) && close(d.rx)
    isopen(d.tx) && close(d.tx)
    return nothing
end

function inject_can_frame!(driver::MockCanDriver, canid::UInt32, data::Vector{UInt8})
    frame = CI.CanFrameRaw(canid, UInt8(8), 0x00, 0x00, 0x00, ntuple(i -> data[i], 8))
    put!(driver.rx, frame)
end

const TEST_RX_CATALOG = CP.CanMessage[
    CP.CanMessage(
        "EEC1",
        CP.CanId(3, 0xF0, 0x04, 0x00),
        CU.Signal[
            CU.Signal("EngineSpeed", 4, 1, 16, 0.125, 0.0),
            CU.Signal("ActualEngTorque", 3, 1, 8, 1.0, -125.0),
        ],
    ),
]

const TEST_TX_CATALOG = CP.CanMessage[
    CP.CanMessage(
        "TSC1",
        CP.CanId(3, 0x00, 0x00, 0x03),
        CU.Signal[
            CU.Signal("ReqSpeed_SpeedLimit", 2, 1, 16, 0.125, 0.0),
            CU.Signal("ReqTorque_TorqueLimit", 4, 1, 8, 1.0, -125.0),
        ],
    ),
]

mutable struct EchoSystem <: SS.AbstractSystem
    gain_default::Float64
    in_slot::Int
    out_slot::Int
    gain_slot::Int
end

EchoSystem(; gain=1.0) = EchoSystem(gain, 0, 0, 0)
SS.parameter_names(::EchoSystem) = ["gain"]

function SS.initialize_parameters!(sys::EchoSystem, params)
    params["gain"] = sys.gain_default
    return nothing
end

function SS.bind!(sys::EchoSystem, runtime)
    sys.in_slot = SS.signal_slot(runtime.inputs, "io.Speed")
    sys.out_slot = SS.signal_slot(runtime.outputs, "io.Command")
    sys.gain_slot = SS.signal_slot(runtime.params, "gain")
    return nothing
end

function SS.control_step!(sys::EchoSystem, inputs, outputs, params, _dt)
    outputs[sys.out_slot] = inputs[sys.in_slot] * params[sys.gain_slot]
    return nothing
end

mutable struct MultiIOSystem <: SS.AbstractSystem
    in_slots::Vector{Int}
    out_slot::Int
end

MultiIOSystem() = MultiIOSystem(Int[], 0)

function SS.bind!(sys::MultiIOSystem, runtime)
    sys.in_slots = [
        SS.signal_slot(runtime.inputs, "ioA.Speed"),
        SS.signal_slot(runtime.inputs, "ioB.Speed"),
    ]
    sys.out_slot = SS.signal_slot(runtime.outputs, "ioOut.Command")
    return nothing
end

function SS.control_step!(sys::MultiIOSystem, inputs, outputs, _params, _dt)
    outputs[sys.out_slot] = inputs[sys.in_slots[1]] + inputs[sys.in_slots[2]]
    return nothing
end

mutable struct CanBridgeSystem <: SS.AbstractSystem
    in_slot::Int
    out_slot::Int
end

CanBridgeSystem() = CanBridgeSystem(0, 0)

function SS.bind!(sys::CanBridgeSystem, runtime)
    sys.in_slot = SS.signal_slot(runtime.inputs, "rx.EngineSpeed")
    sys.out_slot = SS.signal_slot(runtime.outputs, "tx.ReqSpeed_SpeedLimit")
    return nothing
end

function SS.control_step!(sys::CanBridgeSystem, inputs, outputs, _params, _dt)
    outputs[sys.out_slot] = inputs[sys.in_slot]
    return nothing
end

function wait_until(predicate; timeout=2.0, step=0.01)
    t0 = time()
    while time() - t0 < timeout
        predicate() && return true
        sleep(step)
    end
    return predicate()
end

@testset "SystemSimulator" begin
    @testset "StopSignal and signal storage" begin
        sf = SS.StopSignal()
        @test !SS.stop_requested(sf)
        SS.request_stop!(sf)
        @test SS.stop_requested(sf)
        SS.cancel_stop!(sf)
        @test !SS.stop_requested(sf)

        buf = SS.SignalBuffer(["a", "b", "a"])
        @test SS.signal_names(buf) == ["a", "b"]
        @test SS.signal_slot(buf, "a") == 1
        buf[1] = 10.0
        buf["b"] = 5.0
        @test buf["a"] == 10.0
        @test buf[2] == 5.0
    end

    @testset "IO modes and runtime construction" begin
        io = MockIO(["Speed"], ["Command"])
        cfg = SS.IOConfig(:io, io, 16)
        @test SS.is_read_enabled(cfg)
        @test SS.is_write_enabled(cfg)

        logfile = tempname() * ".csv"
        runtime = SS.SystemRuntime(SS.SystemConfig(20, [cfg], logfile), SS.StopSignal(), EchoSystem())
        @test SS.signal_names(runtime.inputs) == ["io.Speed"]
        @test SS.signal_names(runtime.outputs) == ["io.Command"]
        @test SS.signal_names(runtime.params) == ["gain"]
        @test runtime.params["gain"] == 1.0
        close(runtime.logger.filehandle)
        rm(logfile; force=true)
    end

    @testset "Slot-based control loop with mock IO" begin
        io = MockIO(["Speed"], ["Command"])
        logfile = tempname() * ".csv"
        cfg = SS.SystemConfig(20, [SS.IOConfig(:io, io, 32)], logfile)
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), EchoSystem(gain=2.0))
        SS.start!(runtime)

        inject_mock_frame!(io, Dict("Speed" => 12.5))
        @test wait_until(() -> isapprox(runtime.outputs["io.Command"], 25.0; atol=1e-6))
        @test isready(io.tx)
        payload = take!(io.tx)
        while isready(io.tx)
            payload = take!(io.tx)
        end
        @test payload["Command"] ≈ 25.0 atol=1e-6

        SS.stop!(runtime)
        @test wait_until(() -> isfile(logfile))
        rm(logfile; force=true)
    end

    @testset "Multiple IO endpoints" begin
        io_a = MockIO(["Speed"], String[])
        io_b = MockIO(["Speed"], String[])
        io_out = MockIO(String[], ["Command"])
        logfile = tempname() * ".csv"
        cfg = SS.SystemConfig(
            20,
            [
                SS.IOConfig(:ioA, io_a, 32, SS.IO_MODE_READONLY),
                SS.IOConfig(:ioB, io_b, 32, SS.IO_MODE_READONLY),
                SS.IOConfig(:ioOut, io_out, 32, SS.IO_MODE_WRITEONLY),
            ],
            logfile,
        )
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), MultiIOSystem())
        SS.start!(runtime)

        inject_mock_frame!(io_a, Dict("Speed" => 10.0))
        inject_mock_frame!(io_b, Dict("Speed" => 15.0))
        @test wait_until(() -> isapprox(runtime.outputs["ioOut.Command"], 25.0; atol=1e-6))
        tx_payload = take!(io_out.tx)
        while isready(io_out.tx)
            tx_payload = take!(io_out.tx)
        end
        @test tx_payload["Command"] ≈ 25.0 atol=1e-6

        SS.stop!(runtime)
        rm(logfile; force=true)
    end

    @testset "CAN adapter end-to-end" begin
        rx_driver = MockCanDriver("mock_rx")
        tx_driver = MockCanDriver("mock_tx")
        rx_io = SS.CanIO(rx_driver, TEST_RX_CATALOG, CP.CanMessage[])
        tx_io = SS.CanIO(tx_driver, CP.CanMessage[], TEST_TX_CATALOG)
        logfile = tempname() * ".csv"
        cfg = SS.SystemConfig(
            20,
            [SS.IOConfig(:rx, rx_io, 64), SS.IOConfig(:tx, tx_io, 64)],
            logfile,
        )
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), CanBridgeSystem())
        SS.start!(runtime)

        canid = CP.encode_can_id(CP.CanId(3, 0xF0, 0x04, 0x00))
        data = UInt8[0x00, 0x00, 0x00, 0xE0, 0x2E, 0x00, 0x00, 0x00]
        inject_can_frame!(rx_driver, canid, data)

        @test wait_until(() -> isapprox(runtime.inputs["rx.EngineSpeed"], 1500.0; atol=0.5); timeout=3.0)
        @test wait_until(() -> isready(tx_driver.tx))
        tx_frame = take!(tx_driver.tx)
        @test tx_frame.can_dlc == 8

        SS.stop!(runtime)
        rm(logfile; force=true)
    end

    @testset "TcpMonitor streaming and param updates" begin
        io = MockIO(["Speed"], ["Command"])
        logfile = tempname() * ".csv"
        mcfg = SS.MonitorConfig("127.0.0.1", 19200, 19201)
        cfg = SS.SystemConfig(20, [SS.IOConfig(:io, io, 32)], logfile, mcfg)
        runtime = try
            SS.SystemRuntime(cfg, SS.StopSignal(), EchoSystem(gain=1.0))
        catch err
            if err isa Base.IOError
                @test_skip "TCP listen blocked in sandbox"
                rm(logfile; force=true)
                return
            end
            rethrow(err)
        end
        SS.start!(runtime)
        sleep(0.2)

        out_sock = Sockets.connect("127.0.0.1", 19201)
        num_sigs = ltoh(read(out_sock, UInt32))
        sig_names = String[]
        for _ in 1:num_sigs
            nlen = ltoh(read(out_sock, UInt16))
            push!(sig_names, String(read(out_sock, nlen)))
        end
        @test "Time" in sig_names
        @test "io.Speed" in sig_names
        @test "io.Command" in sig_names
        @test "gain" in sig_names

        in_sock = Sockets.connect("127.0.0.1", 19200)
        num_params = ltoh(read(in_sock, UInt32))
        param_names = String[]
        for _ in 1:num_params
            nlen = ltoh(read(in_sock, UInt16))
            push!(param_names, String(read(in_sock, nlen)))
        end
        @test param_names == ["gain"]

        write(in_sock, reinterpret(UInt8, htol.([3.0])))
        flush(in_sock)
        @test wait_until(() -> isapprox(runtime.params["gain"], 3.0; atol=1e-6))

        frame_bytes = num_sigs * sizeof(Float64)
        while bytesavailable(out_sock) >= frame_bytes
            read(out_sock, frame_bytes)
        end

        inject_mock_frame!(io, Dict("Speed" => 7.0))
        matched = false
        deadline = time() + 3.0
        while time() < deadline
            raw = read(out_sock, frame_bytes)
            values = ltoh.(reinterpret(Float64, raw))
            stream = Dict(sig_names[i] => values[i] for i in eachindex(sig_names))
            if isapprox(stream["io.Command"], 21.0; atol=1e-6)
                matched = true
                break
            end
        end
        @test matched

        close(in_sock)
        close(out_sock)
        SS.stop!(runtime)
        rm(logfile; force=true)
    end
end
