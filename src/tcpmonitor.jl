"""
    TcpMonitor

Runtime-level component (parallel to `Logger`) that streams all simulator data
(inputs, outputs, params, timestamp) to a GUI over raw binary TCP, and receives
parameter updates from the GUI.

Integrated into the system loop like the Logger:
- System loop calls `snapshot_to_sinks!` then signals `monitorflag` each cycle.
- Writer task waits on `monitorflag`, reads `monitordict`, sends binary frame.
- Reader task writes received params into `param_updates`; control loop applies
  them via `apply_monitor_params!` before each callback invocation.

## Wire Protocol

**Handshake** (server → client, once on connect):
```
[4 bytes] num_signals  : UInt32 LE
Per signal:
  [2 bytes] name_len   : UInt16 LE
  [N bytes] name       : UTF-8
```

**Data frame** (repeated, fixed-size):
```
[num_signals × 8 bytes] : Float64 values in declared order, LE
```
"""
mutable struct TcpMonitor
    # Input side (param receiver)
    in_server::Union{Sockets.TCPServer,Nothing}
    in_client::Union{Sockets.TCPSocket,Nothing}
    in_lock::ReentrantLock
    param_names::Vector{String}
    param_updates::Dict{String,Float64}
    param_lock::ReentrantLock

    # Output side (data streamer — mirrors Logger pattern)
    out_server::Union{Sockets.TCPServer,Nothing}
    out_client::Union{Sockets.TCPSocket,Nothing}
    out_lock::ReentrantLock
    out_names::Vector{String}
    monitordict::SignalBuffer
    monitorlock::ReentrantLock
    monitorflag::Base.Event

    # Pre-allocated buffers
    _read_buf::Vector{UInt8}
    _write_buf::Vector{Float64}
    _write_bytes::Vector{UInt8}

    closed::Threads.Atomic{Bool}
end

function TcpMonitor(
    host::AbstractString,
    in_port::Integer,
    out_port::Integer,
    param_names::Vector{String},
    out_names::Vector{String},
)
    h = String(host)
    in_srv = in_port > 0 ? Sockets.listen(Sockets.getaddrinfo(h), UInt16(in_port)) : nothing
    out_srv = out_port > 0 ? Sockets.listen(Sockets.getaddrinfo(h), UInt16(out_port)) : nothing

    param_updates = Dict{String,Float64}(name => 0.0 for name in param_names)
    monitordict = SignalBuffer(copy(out_names))

    n_out = length(out_names)
    nbytes_in = length(param_names) * sizeof(Float64)

    mon = TcpMonitor(
        in_srv, nothing, ReentrantLock(), param_names, param_updates, ReentrantLock(),
        out_srv, nothing, ReentrantLock(), out_names, monitordict, ReentrantLock(),
        Base.Event(),
        Vector{UInt8}(undef, nbytes_in),
        Vector{Float64}(undef, n_out),
        Vector{UInt8}(undef, n_out * sizeof(Float64)),
        Threads.Atomic{Bool}(false),
    )

    return mon
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

"""
    _send_header(sock, names)

Send the TcpMonitor handshake header to a newly connected client.
Protocol: UInt32 LE count, then for each name: UInt16 LE length + UTF-8 bytes.
"""
function _send_header(sock::Sockets.TCPSocket, names::Vector{String})
    write(sock, htol(UInt32(length(names))))
    for name in names
        encoded = Vector{UInt8}(name)
        write(sock, htol(UInt16(length(encoded))))
        write(sock, encoded)
    end
    flush(sock)
    return nothing
end

function _monitor_accept_loop!(mon::TcpMonitor, side::Symbol)
    server = side === :in ? mon.in_server : mon.out_server
    lck = side === :in ? mon.in_lock : mon.out_lock
    names = side === :in ? mon.param_names : mon.out_names

    while !mon.closed[]
        new_sock = try
            Sockets.accept(server)
        catch
            mon.closed[] && return nothing
            sleep(0.01)
            continue
        end

        try
            _send_header(new_sock, names)
        catch
            try; close(new_sock); catch; end
            continue
        end

        lock(lck)
        try
            old = side === :in ? mon.in_client : mon.out_client
            if side === :in
                mon.in_client = new_sock
            else
                mon.out_client = new_sock
            end
            if old !== nothing
                try; close(old); catch; end
            end
        finally
            unlock(lck)
        end
    end
    return nothing
end

function _monitor_disconnect!(mon::TcpMonitor, side::Symbol)
    lck = side === :in ? mon.in_lock : mon.out_lock
    lock(lck)
    try
        client = side === :in ? mon.in_client : mon.out_client
        if client !== nothing
            try; close(client); catch; end
            if side === :in
                mon.in_client = nothing
            else
                mon.out_client = nothing
            end
        end
    finally
        unlock(lck)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Reader loop — receives param updates from GUI, stages into param_updates
# ---------------------------------------------------------------------------

function monitor_reader_loop(mon::TcpMonitor, stop_signal::StopSignal)
    nbytes = length(mon.param_names) * sizeof(Float64)
    @info "Monitor reader started" params = mon.param_names

    while !stop_requested(stop_signal)
        if nbytes == 0
            sleep(0.1)
            continue
        end

        sock = lock(mon.in_lock) do
            mon.in_client
        end
        if sock === nothing
            sleep(0.01)
            continue
        end

        try
            unsafe_read(sock, pointer(mon._read_buf), nbytes)
            values = reinterpret(Float64, mon._read_buf)

            lock(mon.param_lock)
            try
                for (i, name) in enumerate(mon.param_names)
                    mon.param_updates[name] = ltoh(values[i])
                end
            finally
                unlock(mon.param_lock)
            end
        catch
            _monitor_disconnect!(mon, :in)
        end
    end

    @info "Monitor reader exiting"
    return nothing
end

# ---------------------------------------------------------------------------
# Writer loop — waits on monitorflag, sends snapshot (mirrors logger_loop)
# Uses copyto! from SignalBuffer.values for zero-hash bulk copy.
# ---------------------------------------------------------------------------

function monitor_writer_loop(mon::TcpMonitor, stop_signal::StopSignal)
    n = length(mon.out_names)
    nbytes = n * sizeof(Float64)
    @info "Monitor writer started" signals = n

    while !stop_requested(stop_signal)
        wait(mon.monitorflag)
        Base.reset(mon.monitorflag)
        stop_requested(stop_signal) && break

        sock = lock(mon.out_lock) do
            mon.out_client
        end
        sock === nothing && continue

        lock(mon.monitorlock)
        try
            copyto!(mon._write_buf, mon.monitordict.values)
        finally
            unlock(mon.monitorlock)
        end

        # htol is identity on little-endian (x86/ARM), so reinterpret directly
        unsafe_copyto!(pointer(mon._write_bytes), Ptr{UInt8}(pointer(mon._write_buf)), nbytes)
        try
            unsafe_write(sock, pointer(mon._write_bytes), nbytes)
            flush(sock)
        catch
            _monitor_disconnect!(mon, :out)
        end
    end

    @info "Monitor writer exiting"
    return nothing
end

# ---------------------------------------------------------------------------
# Close — release TCP resources (called by stop!)
# ---------------------------------------------------------------------------

function close_monitor!(mon::TcpMonitor)
    Threads.atomic_xchg!(mon.closed, true)
    _monitor_disconnect!(mon, :in)
    _monitor_disconnect!(mon, :out)
    if mon.in_server !== nothing
        try; close(mon.in_server); catch; end
    end
    if mon.out_server !== nothing
        try; close(mon.out_server); catch; end
    end
    return nothing
end
