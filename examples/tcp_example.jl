"""
Example: SystemSimulator with TcpMonitor for GUI communication.

TcpMonitor is integrated into the runtime like the Logger — it automatically
streams ALL runtime data (inputs, outputs, params, timestamp) each control
cycle, and applies parameter updates received from the GUI.

  - Port 9000 (input):  GUI sends tunable params (Kp, setpoint)
  - Port 9001 (output): Simulator streams every signal for plotting

## Running

    cd SystemSimulator.jl
    julia --threads=auto --project=. examples/tcp_example.jl

## Connecting from Python

    import socket, struct

    # --- Receive all signals for plotting ---
    s = socket.create_connection(("localhost", 9001))
    n = struct.unpack('<I', s.recv(4))[0]
    names = []
    for _ in range(n):
        slen = struct.unpack('<H', s.recv(2))[0]
        names.append(s.recv(slen).decode())
    print("Signals:", names)

    while True:
        data = s.recv(n * 8)
        if len(data) < n * 8:
            break
        values = struct.unpack(f'<{n}d', data)
        print(dict(zip(names, values)))

    # --- Send param updates ---
    s2 = socket.create_connection(("localhost", 9000))
    n2 = struct.unpack('<I', s2.recv(4))[0]
    param_names = []
    for _ in range(n2):
        slen = struct.unpack('<H', s2.recv(2))[0]
        param_names.append(s2.recv(slen).decode())
    print("Params:", param_names)
    # param_names are sorted alphabetically: ["Kp", "setpoint"]
    s2.sendall(struct.pack('<2d', 1.5, 1200.0))  # Kp=1.5, setpoint=1200
"""
import SystemSimulator as SS

# ---------------------------------------------------------------------------
# A minimal "virtual" IO (no real CAN needed for this demo)
# ---------------------------------------------------------------------------
mutable struct VirtualIO <: SS.AbstractIO
    closed::Bool
end
VirtualIO() = VirtualIO(false)
SS.read_raw(io::VirtualIO) = (io.closed ? nothing : (sleep(0.01); nothing))
SS.decode_raw!(::VirtualIO, _, ::Dict{String,Float64})::Bool = false
SS.encode_raw(::VirtualIO, ::AbstractDict{String,<:Real})::Vector{Any} = Any[]
SS.write_raw(::VirtualIO, _)::Nothing = nothing
SS.input_signal_names(::VirtualIO)::Vector{String} = String[]
SS.output_signal_names(::VirtualIO)::Vector{String} = String[]
Base.close(io::VirtualIO)::Nothing = (io.closed = true; nothing)

# ---------------------------------------------------------------------------
# Controller — params are tunable from GUI via TcpMonitor
# ---------------------------------------------------------------------------
mutable struct DemoController <: SS.AbstractController
    params::Dict{String,Float64}
    time::Float64
end

DemoController() = DemoController(
    Dict{String,Float64}("Kp" => 1.0, "setpoint" => 0.0),
    0.0,
)

# ---------------------------------------------------------------------------
# Control callback
# ---------------------------------------------------------------------------
function demo_callback(ctrl::DemoController, inputs, outputs, dt)
    ctrl.time += dt
    # params are updated automatically by TcpMonitor → apply_monitor_params!
    return nothing
end

# ---------------------------------------------------------------------------
# System configuration — MonitorConfig is part of SystemConfig (like logfile)
# ---------------------------------------------------------------------------
cfg = SS.SystemConfig(
    100,   # 100 ms control period
    [SS.IOConfig(:virtual, VirtualIO(), 16, SS.IO_MODE_READONLY)],
    joinpath(@__DIR__, "tcp_log.csv"),
    SS.MonitorConfig("0.0.0.0", 9000, 9001),   # param_port, stream_port
)

# ---------------------------------------------------------------------------
# Run — monitor starts/stops with the runtime (like the logger)
# ---------------------------------------------------------------------------
sf = SS.StopSignal()
ctrl = DemoController()
runtime = SS.SystemRuntime(cfg, sf, ctrl)

@info "Starting TCP monitor example" param_port = 9000 stream_port = 9001
@info "Params the GUI can tune:" keys = sort(collect(keys(runtime.params)))
@info "Signals streamed to GUI:" keys = runtime.monitor.out_names

SS.start!(runtime, demo_callback)

RUN_SECONDS = 60.0
@info "Running for $(RUN_SECONDS)s — press Ctrl+C to stop early"
try
    sleep(RUN_SECONDS)
catch e
    e isa InterruptException || rethrow(e)
end

@info "Stopping" steps = runtime.step_count[] timestamp = runtime.timestamp
SS.request_stop!(runtime.stop_signal)
SS.stop!(runtime)
