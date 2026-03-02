using Test
import SystemSimulator as SS
import CANInterface as CI
import CANUtils as CU
import J1939Parser as CP

# -----------------------------------------------------------------------------
# Mock generic IO for SystemSimulator tests
# -----------------------------------------------------------------------------
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

function SS.decode_raw!(io::MockIO, raw, local_inputs::Dict{String,Float64})::Bool
    io.throw_decode && throw(ErrorException("mock decode failure"))
    raw isa AbstractDict || return false

    for name in io.in_names
        if haskey(raw, name)
            local_inputs[name] = Float64(raw[name])
        end
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

# -----------------------------------------------------------------------------
# Mock CAN Driver for CanIO integration tests
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Shared test catalogs and controller
# -----------------------------------------------------------------------------
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

struct TestController <: SS.AbstractController
    params::Dict{String,Float64}
end
TestController() = TestController(Dict{String,Float64}("gain" => 2.0))

struct BareController end

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
@testset "SystemSimulator" begin

    @testset "StopSignal" begin
        sf = SS.StopSignal()
        @test SS.stop_requested(sf) == false
        SS.request_stop!(sf)
        @test SS.stop_requested(sf) == true
        SS.cancel_stop!(sf)
        @test SS.stop_requested(sf) == false
    end

    @testset "AbstractIO interface defaults" begin
        struct DummyIO <: SS.AbstractIO end

        io = DummyIO()
        @test_throws ErrorException SS.read_raw(io)
        @test_throws ErrorException SS.decode_raw!(io, nothing, Dict{String,Float64}())
        @test_throws ErrorException SS.encode_raw(io, Dict{String,Float64}())
        @test_throws ErrorException SS.write_raw(io, nothing)
        @test_throws ErrorException SS.input_signal_names(io)
        @test_throws ErrorException SS.output_signal_names(io)
        @test Base.close(io) === nothing
    end

    @testset "global_key and keymap" begin
        @test SS.global_key(:can0, "Speed") == "can0.Speed"
        map = SS.build_keymap(:can0, ["Speed", "Torque"])
        @test map["Speed"] == "can0.Speed"
        @test map["Torque"] == "can0.Torque"
    end

    @testset "IO modes" begin
        io = MockIO(["Speed"], ["Command"])

        cfg_default = SS.IOConfig(:rw, io, 16)
        @test cfg_default.mode == SS.IO_MODE_READWRITE
        @test SS.is_read_enabled(cfg_default)
        @test SS.is_write_enabled(cfg_default)

        cfg_ro = SS.IOConfig(:ro, io, 16, SS.IO_MODE_READONLY)
        @test cfg_ro.mode == SS.IO_MODE_READONLY
        @test SS.is_read_enabled(cfg_ro)
        @test !SS.is_write_enabled(cfg_ro)

        cfg_wo = SS.IOConfig(:wo, io, 16, SS.IO_MODE_WRITEONLY)
        @test cfg_wo.mode == SS.IO_MODE_WRITEONLY
        @test !SS.is_read_enabled(cfg_wo)
        @test SS.is_write_enabled(cfg_wo)

        @test_throws ArgumentError SS.IOConfig(:bad, io, 16, :invalidmode)
    end

    @testset "IOState and SystemRuntime construction" begin
        io_a = MockIO(["Speed"], ["Command"])
        cfg = SS.IOConfig(:ioA, io_a, 32)
        state = SS.IOState(cfg)

        @test haskey(state.input_local_rx, "Speed")
        @test haskey(state.output_local, "Command")
        @test state.input_keymap["Speed"] == "ioA.Speed"
        @test state.output_keymap["Command"] == "ioA.Command"

        logfile = tempname() * ".csv"
        syscfg = SS.SystemConfig(20, [cfg], logfile)
        runtime = SS.SystemRuntime(syscfg, SS.StopSignal(), TestController())

        @test haskey(runtime.inputs, "ioA.Speed")
        @test haskey(runtime.outputs, "ioA.Command")
        @test runtime.params["gain"] == 2.0
        @test runtime.timestamp == 0.0
        @test runtime.step_count[] == 0

        close(runtime.logger.filehandle)
        rm(logfile; force=true)
    end

    @testset "controller_params fallback" begin
        logfile = tempname() * ".csv"
        io_a = MockIO(["Speed"], ["Command"])
        cfg = SS.SystemConfig(20, [SS.IOConfig(:ioA, io_a, 16)], logfile)
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), BareController())
        @test isempty(runtime.params)

        close(runtime.logger.filehandle)
        rm(logfile; force=true)
    end

    @testset "Lifecycle and task topology" begin
        io_a = MockIO(["Speed"], ["Command"])
        logfile = tempname() * ".csv"
        cfg = SS.SystemConfig(20, [SS.IOConfig(:ioA, io_a, 32)], logfile)
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), TestController())

        function passthrough_callback(ctrl, inputs, outputs, dt)
            outputs["ioA.Command"] = get(inputs, "ioA.Speed", 0.0)
            return nothing
        end

        SS.start!(runtime, passthrough_callback)
        inject_mock_frame!(io_a, Dict("Speed" => 123.0))
        sleep(1.2)

        all_tasks = Task[
            runtime.io_states[1].reader_task,
            runtime.io_states[1].parser_task,
            runtime.io_states[1].writer_task,
            runtime.control_task,
            runtime.logger_task,
        ]
        @test length(all_tasks) == 3 * length(runtime.io_states) + 2
        @test all(task -> task isa Task, all_tasks)

        SS.stop!(runtime)
        sleep(0.35)

        @test SS.stop_requested(runtime.stop_signal)
        @test isfile(logfile)
        @test length(readlines(logfile)) >= 1

        rm(logfile; force=true)
    end

    @testset "Multi-IO namespaced inputs" begin
        io_a = MockIO(["Speed"], ["Command"])
        io_b = MockIO(["Speed"], ["Command"])
        logfile = tempname() * ".csv"

        cfg = SS.SystemConfig(
            20,
            [SS.IOConfig(:ioA, io_a, 32), SS.IOConfig(:ioB, io_b, 32)],
            logfile,
        )
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), TestController())

        function noop_callback(ctrl, inputs, outputs, dt)
            return nothing
        end

        SS.start!(runtime, noop_callback)
        inject_mock_frame!(io_a, Dict("Speed" => 10.0))
        inject_mock_frame!(io_b, Dict("Speed" => 20.0))
        sleep(0.6)

        @test haskey(runtime.inputs, "ioA.Speed")
        @test haskey(runtime.inputs, "ioB.Speed")
        @test runtime.inputs["ioA.Speed"] ≈ 10.0 atol = 1e-6
        @test runtime.inputs["ioB.Speed"] ≈ 20.0 atol = 1e-6

        SS.stop!(runtime)
        sleep(0.3)
        rm(logfile; force=true)
    end

    @testset "Cross-IO callback bridge" begin
        io_rx = MockIO(["Speed"], String[])
        io_tx = MockIO(String[], ["Command"])
        logfile = tempname() * ".csv"

        cfg = SS.SystemConfig(
            20,
            [SS.IOConfig(:rx, io_rx, 32), SS.IOConfig(:tx, io_tx, 32)],
            logfile,
        )
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), TestController())

        function bridge_callback(ctrl, inputs, outputs, dt)
            outputs["tx.Command"] = get(inputs, "rx.Speed", 0.0)
            return nothing
        end

        SS.start!(runtime, bridge_callback)
        inject_mock_frame!(io_rx, Dict("Speed" => 88.0))
        sleep(0.6)

        @test runtime.outputs["tx.Command"] ≈ 88.0 atol = 1e-6
        @test isready(io_tx.tx)
        tx_payload = take!(io_tx.tx)
        @test tx_payload["Command"] ≈ 88.0 atol = 1e-6

        SS.stop!(runtime)
        sleep(0.3)
        rm(logfile; force=true)
    end

    @testset "Readonly and writeonly runtime behavior" begin
        io_rx = MockIO(["Speed"], String[])
        io_tx = MockIO(String[], ["Command"])
        logfile = tempname() * ".csv"

        cfg = SS.SystemConfig(
            20,
            [
                SS.IOConfig(:rx, io_rx, 32, SS.IO_MODE_READONLY),
                SS.IOConfig(:tx, io_tx, 32, SS.IO_MODE_WRITEONLY),
            ],
            logfile,
        )
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), TestController())

        @test haskey(runtime.inputs, "rx.Speed")
        @test !haskey(runtime.inputs, "tx.Command")
        @test haskey(runtime.outputs, "tx.Command")
        @test !haskey(runtime.outputs, "rx.Speed")

        function bridge_callback(ctrl, inputs, outputs, dt)
            outputs["tx.Command"] = get(inputs, "rx.Speed", 0.0)
            return nothing
        end

        SS.start!(runtime, bridge_callback)
        inject_mock_frame!(io_rx, Dict("Speed" => 77.0))
        sleep(0.6)

        rx_state = runtime.io_states[1]
        tx_state = runtime.io_states[2]
        @test istaskstarted(rx_state.reader_task)
        @test istaskstarted(rx_state.parser_task)
        @test !istaskstarted(rx_state.writer_task)
        @test !istaskstarted(tx_state.reader_task)
        @test !istaskstarted(tx_state.parser_task)
        @test istaskstarted(tx_state.writer_task)

        @test runtime.outputs["tx.Command"] ≈ 77.0 atol = 1e-6
        @test isready(io_tx.tx)
        tx_payload = take!(io_tx.tx)
        while isready(io_tx.tx)
            tx_payload = take!(io_tx.tx)
        end
        @test tx_payload["Command"] ≈ 77.0 atol = 1e-6

        SS.stop!(runtime)
        sleep(0.3)
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
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), TestController())

        function can_callback(ctrl, inputs, outputs, dt)
            outputs["tx.ReqSpeed_SpeedLimit"] = get(inputs, "rx.EngineSpeed", 0.0)
            return nothing
        end

        SS.start!(runtime, can_callback)

        canid = CP.encode_can_id(CP.CanId(3, 0xF0, 0x04, 0x00))
        data = UInt8[0x00, 0x00, 0x00, 0xE0, 0x2E, 0x00, 0x00, 0x00]  # 1500 RPM
        inject_can_frame!(rx_driver, canid, data)

        sleep(0.8)

        @test runtime.inputs["rx.EngineSpeed"] ≈ 1500.0 atol = 0.5
        @test isready(tx_driver.tx)

        tx_frame = take!(tx_driver.tx)
        @test tx_frame.can_dlc == 8

        SS.stop!(runtime)
        sleep(0.3)
        rm(logfile; force=true)
    end

    @testset "Failure paths: decode/write exceptions do not deadlock stop" begin
        io = MockIO(["Speed"], ["Command"])
        io.throw_decode = true
        io.throw_write = true

        logfile = tempname() * ".csv"
        cfg = SS.SystemConfig(20, [SS.IOConfig(:ioA, io, 32)], logfile)
        runtime = SS.SystemRuntime(cfg, SS.StopSignal(), TestController())

        function noisy_callback(ctrl, inputs, outputs, dt)
            outputs["ioA.Command"] = get(inputs, "ioA.Speed", 0.0) + 1.0
            return nothing
        end

        SS.start!(runtime, noisy_callback)
        inject_mock_frame!(io, Dict("Speed" => 5.0))
        sleep(0.4)

        SS.stop!(runtime)
        sleep(0.35)

        @test SS.stop_requested(runtime.stop_signal)
        @test runtime.control_task isa Task
        @test isfile(logfile)

        rm(logfile; force=true)
    end
end
