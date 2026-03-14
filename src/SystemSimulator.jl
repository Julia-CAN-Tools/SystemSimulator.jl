module SystemSimulator

import CANInterface as CI
import CANUtils as CU
import Dates
import Sockets

include("stopsignal.jl")
include("signal_buffer.jl")
include("spsc_queue.jl")
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
       SignalSchema,
       SignalBuffer,
       signal_names,
       signal_slot,
       try_signal_slot,
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
       global_key,
       build_keymap,
       raw_payload_type,
       read_raw,
       decode_raw!,
       encode_raw,
       encode_and_write!,
       write_raw,
       input_signal_names,
       output_signal_names,
       bind_io!,
       TcpMonitor,
       parameter_names,
       monitor_parameter_names,
       initialize_parameters!,
       bind!,
       parameters_updated!,
       control_step!,
       SystemLifecycle,
       LifecycleSlots,
       bind_lifecycle,
       update_lifecycle!,
       start!,
       stop!

end # module SystemSimulator
