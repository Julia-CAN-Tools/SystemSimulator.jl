mutable struct Logger
    filepath::String
    filehandle::IOStream
    keys::Vector{String}
    active_buffer::Matrix{Float64}
    flush_buffer::Matrix{Float64}
    active_count::Int
    flush_count::Int
    swaplock::Base.Threads.SpinLock
    flush_pending::Threads.Atomic{Bool}
    dropped_rows::Threads.Atomic{Int}
    flushflag::Base.Event
end

function Logger(filename::String, capacity::Int, keys::Vector{String})
    filehandle = open(filename, "w")
    return Logger(
        filename,
        filehandle,
        copy(keys),
        Matrix{Float64}(undef, capacity, length(keys)),
        Matrix{Float64}(undef, capacity, length(keys)),
        0,
        0,
        Base.Threads.SpinLock(),
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Int}(0),
        Base.Event(),
    )
end

function writeheader(logger::Logger)
    @inbounds for key in @view logger.keys[1:end-1]
        write(logger.filehandle, key)
        write(logger.filehandle, ",")
    end
    write(logger.filehandle, logger.keys[end])
    write(logger.filehandle, "\n")
    flush(logger.filehandle)
end

function writerow(logger::Logger, row::AbstractVector{<:Real})
    @inbounds for val in @view row[1:end-1]
        print(logger.filehandle, val)
        write(logger.filehandle, ",")
    end
    print(logger.filehandle, row[end])
    write(logger.filehandle, "\n")
    return nothing
end

function writematrix(logger::Logger, mat::AbstractMatrix{Float64}, nrows::Int=size(mat, 1))
    @inbounds for i in 1:nrows
        writerow(logger, @view mat[i, :])
    end
    flush(logger.filehandle)
    return nothing
end

function _swap_logger_buffers!(logger::Logger)::Bool
    lock(logger.swaplock)
    try
        logger.flush_pending[] && return false
        logger.active_count == 0 && return true
        logger.active_buffer, logger.flush_buffer = logger.flush_buffer, logger.active_buffer
        logger.flush_count = logger.active_count
        logger.active_count = 0
        logger.flush_pending[] = true
    finally
        unlock(logger.swaplock)
    end
    notify(logger.flushflag)
    return true
end

function push_logger_row!(logger::Logger, row_writer!)
    row = logger.active_count + 1
    if row > size(logger.active_buffer, 1)
        if !_swap_logger_buffers!(logger)
            logger.dropped_rows[] += logger.active_count
            logger.active_count = 0
        end
        row = 1
    end

    row_writer!(@view logger.active_buffer[row, :])
    logger.active_count = row

    if row == size(logger.active_buffer, 1)
        _swap_logger_buffers!(logger)
    end
    return nothing
end

function drain_logger!(logger::Logger)
    _swap_logger_buffers!(logger)
    while logger.flush_pending[]
        sleep(0.001)
    end
    if logger.active_count > 0
        writematrix(logger, logger.active_buffer, logger.active_count)
        logger.active_count = 0
    end
    return nothing
end
