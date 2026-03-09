module SystemSimulator

"""
SystemSimulator

General-purpose runtime for deterministic control loops over multiple bidirectional
IO transports (CAN, mock, or any custom backend).

## Exports by concern

**Configuration**
- `MonitorConfig` — TCP monitor host/ports
- `IOConfig` — per-endpoint name, IO instance, queue capacity, and mode
- `SystemConfig` — loop period, IO list, log path, optional monitor
- `IO_MODE_READWRITE`, `IO_MODE_READONLY`, `IO_MODE_WRITEONLY`

**Runtime types**
- `SystemRuntime` — aggregate bundle; constructed from `SystemConfig` + `StopSignal` + system
- `IOState` — per-IO task state (constructed automatically by `SystemRuntime`)

**Lifecycle**
- `SystemLifecycle`, `update_lifecycle!` — start/stop/duration control for system structs

**IO interface**
- `AbstractIO` — supertype for custom transports
- `global_key`, `build_keymap` — signal namespacing helpers
- `raw_payload_type`, `read_raw`, `decode_raw!`, `encode_raw`, `write_raw`
- `input_signal_names`, `output_signal_names`

**CAN adapter**
- `CanIO` — J1939 CAN transport (`SocketCanDriver` + message catalogs)

**Logging**
- `Logger`, `writeheader`, `writerow`, `writematrix`, `writeline`

**Monitoring**
- `TcpMonitor` — TCP server for GUI parameter updates and signal streaming

**Entry points**
- `start!(runtime, callback)` — spawn all tasks (non-blocking)
- `stop!(runtime)` — coordinated shutdown; call after `request_stop!`
- `StopSignal`, `request_stop!`, `stop_requested`, `cancel_stop!`
"""

import CANInterface as CI
import CANUtils as CU
import Dates
import Sockets

include("stopsignal.jl")
include("logger.jl")
include("IO/abstractIO.jl")
include("IO/canIO.jl")
include("config.jl")
include("tcpmonitor.jl")
include("runtime.jl")
include("utils.jl")
include("loops.jl")
include("lifecycle.jl")

export AbstractSystem,
       AbstractIO,
       CanIO,
       IO_MODE_READWRITE,
       IO_MODE_READONLY,
       IO_MODE_WRITEONLY,
       IOConfig,
       MonitorConfig,
       SystemConfig,
       IOState,
       SystemRuntime,
       sample_period_seconds,
       is_read_enabled,
       is_write_enabled,
       StopSignal,
       request_stop!,
       stop_requested,
       cancel_stop!,
       Logger,
       writeheader,
       writerow,
       writematrix,
       writeline,
       global_key,
       build_keymap,
       raw_payload_type,
       read_raw,
       decode_raw!,
       encode_raw,
       write_raw,
       input_signal_names,
       output_signal_names,
       TcpMonitor,
       SystemLifecycle,
       update_lifecycle!,
       start!,
       stop!

end # module SystemSimulator
