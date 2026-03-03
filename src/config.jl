"""
    MonitorConfig

Configuration for the optional TCP monitor that streams all runtime data
to a GUI and receives parameter updates.
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
    IOConfig

Configuration for one bidirectional IO endpoint.
"""
const IO_MODE_READWRITE = :readwrite
const IO_MODE_READONLY = :readonly
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

struct IOConfig
    name::Symbol
    io::AbstractIO
    channel_length::Int
    mode::Symbol

    function IOConfig(
        name::Symbol,
        io::AbstractIO,
        channel_length::Int,
        mode::Symbol=IO_MODE_READWRITE,
    )
        channel_length > 0 || throw(ArgumentError("channel_length must be > 0"))
        return new(name, io, channel_length, validate_io_mode(mode))
    end
end

is_read_enabled(cfg::IOConfig) = is_read_enabled(cfg.mode)
is_write_enabled(cfg::IOConfig) = is_write_enabled(cfg.mode)

"""
    SystemConfig

Top-level simulator configuration.
"""
struct SystemConfig
    dt_ms::Int
    ios::Vector{IOConfig}
    logfile::String
    monitor::Union{MonitorConfig,Nothing}

    function SystemConfig(
        dt_ms::Int,
        ios::Vector{IOConfig},
        logfile::String,
        monitor::Union{MonitorConfig,Nothing}=nothing,
    )
        dt_ms > 0 || throw(ArgumentError("dt_ms must be > 0"))
        return new(dt_ms, ios, logfile, monitor)
    end
end

"""
    sample_period_seconds(cfg) -> Float64

Converts the integer millisecond sample period to seconds.
"""
sample_period_seconds(cfg::SystemConfig) = cfg.dt_ms / 1000.0
