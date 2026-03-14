mutable struct TcpMonitor
    in_server::Union{Sockets.TCPServer,Nothing}
    in_client::Union{Sockets.TCPSocket,Nothing}
    in_lock::ReentrantLock
    param_names::Vector{String}
    param_values::Vector{Float64}
    param_lock::ReentrantLock
    param_seq::Threads.Atomic{UInt64}

    out_server::Union{Sockets.TCPServer,Nothing}
    out_client::Union{Sockets.TCPSocket,Nothing}
    out_lock::ReentrantLock
    out_names::Vector{String}
    snapshot::Vector{Float64}
    snapshot_seq::Threads.Atomic{UInt64}
    monitorflag::Base.Event

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

    n_out = length(out_names)
    nbytes_in = length(param_names) * sizeof(Float64)

    return TcpMonitor(
        in_srv, nothing, ReentrantLock(), copy(param_names), zeros(Float64, length(param_names)),
        ReentrantLock(), Threads.Atomic{UInt64}(0),
        out_srv, nothing, ReentrantLock(), copy(out_names), zeros(Float64, n_out),
        Threads.Atomic{UInt64}(0), Base.Event(),
        Vector{UInt8}(undef, nbytes_in),
        Vector{Float64}(undef, n_out),
        Vector{UInt8}(undef, n_out * sizeof(Float64)),
        Threads.Atomic{Bool}(false),
    )
end

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
            try
                close(new_sock)
            catch
            end
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
                try
                    close(old)
                catch
                end
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
            try
                close(client)
            catch
            end
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
                @inbounds for i in eachindex(mon.param_values)
                    mon.param_values[i] = ltoh(values[i])
                end
                mon.param_seq[] = mon.param_seq[] + UInt64(1)
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

function monitor_writer_loop(mon::TcpMonitor, stop_signal::StopSignal)
    nbytes = length(mon.out_names) * sizeof(Float64)
    @info "Monitor writer started" signals = length(mon.out_names)

    while !stop_requested(stop_signal)
        wait(mon.monitorflag)
        Base.reset(mon.monitorflag)
        stop_requested(stop_signal) && break

        sock = lock(mon.out_lock) do
            mon.out_client
        end
        sock === nothing && continue

        while true
            seq1 = mon.snapshot_seq[]
            isodd(seq1) && continue
            copyto!(mon._write_buf, mon.snapshot)
            seq2 = mon.snapshot_seq[]
            seq1 == seq2 && break
        end

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

function close_monitor!(mon::TcpMonitor)
    Threads.atomic_xchg!(mon.closed, true)
    _monitor_disconnect!(mon, :in)
    _monitor_disconnect!(mon, :out)
    if mon.in_server !== nothing
        try
            close(mon.in_server)
        catch
        end
    end
    if mon.out_server !== nothing
        try
            close(mon.out_server)
        catch
        end
    end
    return nothing
end
