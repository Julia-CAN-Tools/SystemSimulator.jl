"""
    Logger

Write-behind CSV logger. Batches rows in an in-memory ring buffer and flushes to disk
when the buffer is full or at shutdown, minimising IO overhead during the control loop.

## Fields

| Field        | Type                    | Description |
|--------------|-------------------------|-------------|
| `filepath`   | `String`                | Path to the CSV file |
| `filehandle` | `IOStream`              | Open file handle; closed by `logger_loop` at shutdown |
| `lengthbuf`  | `Int64`                 | Ring buffer capacity in rows |
| `counter`    | `Int64`                 | Number of rows currently in the buffer |
| `keysLD`     | `Vector{String}`        | Ordered column names: `["Time", sorted_inputs..., sorted_outputs..., sorted_params...]` |
| `buffer`     | `Matrix{Float64}`       | Ring buffer; shape `(lengthbuf, length(keysLD))` |
| `loggerdict` | `SignalBuffer`          | Current signal values copied from runtime each cycle |
| `loggerlock` | `ReentrantLock`         | Guards `loggerdict` during copy-in and read-out |
| `loggerflag` | `Base.Event`            | Wakeup event; system loop notifies each cycle |

Owned and managed by `SystemRuntime`; users do not interact with `Logger` directly.
"""
mutable struct Logger
    filepath::String
    filehandle::IOStream
    lengthbuf::Int64
    counter::Int64
    keysLD::Vector{String}
    buffer::Matrix{Float64}
    loggerdict::SignalBuffer
    loggerlock::ReentrantLock
    loggerflag::Base.Event
end

function Logger(filename::String, lengthbuf::Int64, keysLD::Vector{String})
    filehandle = open(filename, "w")
    loggerdict = SignalBuffer(copy(keysLD))
    return Logger(
        filename,
        filehandle,
        lengthbuf,
        0,
        keysLD,
        Matrix{Float64}(undef, lengthbuf, length(keysLD)),
        loggerdict,
        ReentrantLock(),
        Base.Event(),
    )
end

"""
    writeheader(logger)

Write the CSV header row. Column order: `Time`, then sorted input keys, sorted output keys,
sorted param keys (matching `logger.keysLD`).
"""
function writeheader(logger::Logger)
    @inbounds for key in @view logger.keysLD[1:end-1]
        write(logger.filehandle, key)
        write(logger.filehandle, ",")
    end
    write(logger.filehandle, logger.keysLD[end])
    write(logger.filehandle, "\n")
    flush(logger.filehandle)
end

"""
    writerow(logger, row)

Write one numeric row to the file handle without flushing. Internal; called by `writematrix`.
"""
function writerow(logger::Logger, row::AbstractVector{<:Real})
    @inbounds for val in @view row[1:end-1]
        print(logger.filehandle, val)
        write(logger.filehandle, ",")
    end
    print(logger.filehandle, row[end])
    write(logger.filehandle, "\n")
end

"""
    writematrix(logger, mat)

Write all rows of `mat` to the file handle and flush. Called when the ring buffer is full
or at shutdown to drain remaining buffered rows.
"""
function writematrix(logger::Logger, mat::AbstractMatrix{Float64})
    @inbounds for row in eachrow(mat)
        writerow(logger, row)
    end
    flush(logger.filehandle)
end

"""
    writeline(logger)

Snapshot current `loggerdict` values into the ring buffer using `copyto!` from the
SignalBuffer's dense values vector (zero hash lookups). If the buffer is now full,
flush it to disk via `writematrix` and reset the counter.
"""
function writeline(logger::Logger)
    logger.counter = logger.counter + 1
    lock(logger.loggerlock)
    try
        copyto!(@view(logger.buffer[logger.counter, :]), logger.loggerdict.values)
    finally
        unlock(logger.loggerlock)
    end

    if logger.counter == logger.lengthbuf
        logger.counter = 0
        writematrix(logger, logger.buffer)
    end
    return nothing
end
