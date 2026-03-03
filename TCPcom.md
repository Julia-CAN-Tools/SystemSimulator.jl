# TCP Communication for SystemSimulator

## Overview

Two components provide TCP-based communication between SystemSimulator and
external GUIs (Python Dash, Julia Bonito, etc.):

| Component | Level | Purpose |
|---|---|---|
| **TcpIO** | AbstractIO adapter | Generic TCP IO — plug into any IOConfig like CanIO |
| **TcpMonitor** | Runtime-level | Streams ALL runtime data (inputs, outputs, params, time) and receives param updates |

**For GUI integration, use `TcpMonitor`.** It wraps the entire `SystemRuntime`
and automatically sees every signal without manual wiring.

## Binary Wire Protocol (shared by both components)

### Handshake (server → client, sent once on connect)
```
[4 bytes] num_signals    : UInt32 LE
For each signal (in sorted order):
  [2 bytes] name_length  : UInt16 LE
  [N bytes] name         : UTF-8 string (no null terminator)
```

### Data Frame (repeated, fixed-size, no delimiter)
```
[num_signals × 8 bytes] : Float64 values in declared order, little-endian
```

---

## TcpMonitor — Full Runtime Telemetry

### Architecture
```
GUI                              SystemSimulator
────                             ────────────────
TCP client ──→ port 9000 ──→     TcpMonitor reader
                                   → updates runtime.params
                                   → updates controller.params

TCP client ←── port 9001 ←──     TcpMonitor writer
                                   ← streams: Time + all inputs + all outputs + all params
```

The monitor polls `runtime.inputs`, `runtime.outputs`, `runtime.params` every
control cycle and sends them as fixed-size binary frames. No manual signal
declaration needed — it discovers all signals from the runtime at construction.

### Usage
```julia
import SystemSimulator as SS

# Build runtime as usual (CAN, other IOs, etc.)
runtime = SS.SystemRuntime(cfg, sf, controller)

# Attach monitor — automatically discovers all signals
monitor = SS.TcpMonitor(runtime; in_port=9000, out_port=9001)

SS.start!(runtime, callback)
SS.start_monitor!(monitor)

# ... run ...

SS.stop_monitor!(monitor)
SS.stop!(runtime)
```

### Output port header (sent to GUI on connect)
Contains ALL signal names: `["Time", <sorted inputs>, <sorted outputs>, <sorted params>]`

### Input port header (sent to GUI on connect)
Contains param names: `sorted(keys(runtime.params))` — tells the GUI what
parameters it can tune, and in what order to send Float64 values.

### Python client example
```python
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
# Send new values in the declared order
s2.sendall(struct.pack(f'<{n2}d', *[1.5, 1200.0]))
```

---

## TcpIO — Generic TCP IO Adapter

`TcpIO` implements the `AbstractIO` interface and works like `CanIO` — you
declare input/output signal names at construction and wire it into `IOConfig`.

Use TcpIO when you need TCP as a transport for **specific signals** in the
IO pipeline (e.g., a remote sensor sending data over TCP).

### Usage
```julia
tcp_in  = SS.TcpIO("0.0.0.0", 9000, ["Kp", "setpoint"], String[])
tcp_out = SS.TcpIO("0.0.0.0", 9001, String[], ["EngineSpeed", "Torque"])

cfg = SS.SystemConfig(100, [
    SS.IOConfig(:gui_in,  tcp_in,  64, SS.IO_MODE_READONLY),
    SS.IOConfig(:gui_out, tcp_out, 64, SS.IO_MODE_WRITEONLY),
], "log.csv")
```

---

## Files

| File | Description |
|---|---|
| `src/IO/tcpIO.jl` | TcpIO: AbstractIO adapter for raw binary TCP |
| `src/tcpmonitor.jl` | TcpMonitor: runtime-level bidirectional telemetry |
| `src/SystemSimulator.jl` | Module file (imports Sockets, includes both, exports) |
| `examples/tcp_example.jl` | Demo using TcpMonitor with two ports |

## No External Dependencies
- `Sockets` is Julia stdlib
- Binary protocol — no JSON needed
- `reinterpret`, `unsafe_read`, `unsafe_write` are Julia builtins
