"""
    MonitorConfig

Configuration for the optional TCP monitor that streams all runtime data
to a GUI and receives parameter updates.

## Fields

- `host` — bind address string, e.g. `"0.0.0.0"` for all interfaces or `"127.0.0.1"` for loopback only
- `in_port` — server port that receives tunable parameter vectors from the GUI; `0` disables the listener
- `out_port` — server port that streams all runtime signals (inputs, outputs, params, timestamp) to the GUI each control cycle; `0` disables streaming
"""
struct MonitorConfig
    host::String
    in_port::Int
    out_port::Int

    function MonitorConfig(host::AbstractString, in_port::Integer, out_port::Integer)
        in_port >= 0 || throw(ArgumentError("in_port must be >= 0"))
        out_port >= 0 || throw(ArgumentError("out_port must be >= 0"))
        in_port > 0 || out_port > 0 || throw(ArgumentError("At least one port must be > 0"))
        return new(String(host), Int(in_port), Int(out_port))
    end
end

MonitorConfig(; host::AbstractString="0.0.0.0", in_port::Integer=0, out_port::Integer=0) =
    MonitorConfig(host, in_port, out_port)

"""
    IOConfig{IO<:AbstractIO}

Configuration for one IO endpoint.

## Fields

- `name` — `Symbol` used as the namespace prefix for all signals on this endpoint;
  e.g. `:can_rx` makes every signal appear as `"can_rx.<signal_name>"` in the global dicts
- `io` — `AbstractIO` instance (e.g. `CanIO`); must be fully initialised before passing here
- `channel_length` — capacity of the raw-payload rx queue between reader and parser tasks;
  256 is typical for CAN
- `mode` — controls which tasks are spawned: `IO_MODE_READWRITE` (default), `IO_MODE_READONLY`
  (skips writer), or `IO_MODE_WRITEONLY` (skips reader/parser)
"""
# Spawns reader, parser, and writer tasks for the IO endpoint.
const IO_MODE_READWRITE = :readwrite
# Spawns reader and parser tasks only; writer task is skipped.
const IO_MODE_READONLY = :readonly
# Spawns writer task only; reader and parser tasks are skipped.
const IO_MODE_WRITEONLY = :writeonly
const VALID_IO_MODES = (IO_MODE_READWRITE, IO_MODE_READONLY, IO_MODE_WRITEONLY)

"""
    validate_io_mode(mode) -> Symbol

Validate and normalize IO mode.
"""
function validate_io_mode(mode)::Symbol
    normalized = Symbol(mode)
    normalized in VALID_IO_MODES || throw(
        ArgumentError("Invalid IO mode '$mode'. Expected one of: $(collect(VALID_IO_MODES))"),
    )
    return normalized
end

is_read_enabled(mode::Symbol) = mode != IO_MODE_WRITEONLY
is_write_enabled(mode::Symbol) = mode != IO_MODE_READONLY

struct IOConfig{IO<:AbstractIO}
    name::Symbol
    io::IO
    channel_length::Int
    mode::Symbol

    function IOConfig(
        name::Symbol,
        io::IO,
        channel_length::Int,
        mode::Symbol=IO_MODE_READWRITE,
    ) where {IO<:AbstractIO}
        channel_length > 0 || throw(ArgumentError("channel_length must be > 0"))
        return new{IO}(name, io, channel_length, validate_io_mode(mode))
    end
end

is_read_enabled(cfg::IOConfig) = is_read_enabled(cfg.mode)
is_write_enabled(cfg::IOConfig) = is_write_enabled(cfg.mode)

"""
    SystemConfig{IO<:AbstractIO}

Top-level simulator configuration.

## Fields

- `dt_ms` — control loop period in milliseconds; `system_loop` sleeps the remaining time
  after each callback completes to maintain the target rate
- `ios` — ordered list of `IOConfig` entries; order determines log column ordering for
  inputs and outputs
- `logfile` — path to the CSV log file; created (or truncated) at `SystemRuntime` construction
- `monitor` — optional `MonitorConfig`; pass `nothing` (default) to disable TCP monitoring
"""
struct SystemConfig{IO<:AbstractIO}
    dt_ms::Int
    ios::Vector{IOConfig{IO}}
    logfile::String
    monitor::Union{MonitorConfig,Nothing}

    function SystemConfig(
        dt_ms::Int,
        ios::Vector{IOConfig{IO}},
        logfile::String,
        monitor::Union{MonitorConfig,Nothing}=nothing,
    ) where {IO<:AbstractIO}
        dt_ms > 0 || throw(ArgumentError("dt_ms must be > 0"))
        return new{IO}(dt_ms, ios, logfile, monitor)
    end
end

"""
    sample_period_seconds(cfg) -> Float64

Converts the integer millisecond sample period to seconds.
"""
sample_period_seconds(cfg::SystemConfig) = cfg.dt_ms / 1000.0
