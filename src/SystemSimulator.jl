module SystemSimulator

"""
SystemSimulator - General-purpose runtime for deterministic control loops over
multiple bidirectional IO transports.
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

export AbstractController,
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
       read_raw,
       decode_raw!,
       encode_raw,
       write_raw,
       input_signal_names,
       output_signal_names,
       TcpMonitor,
       start!,
       stop!

end # module SystemSimulator
