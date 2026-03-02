mutable struct Logger
    filepath::String
    filehandle::IOStream
    lengthbuf::Int64
    counter::Int64
    keysLD::Vector{String}
    buffer::Matrix{Float64}
    loggerdict::Dict{String,Float64}
    loggerlock::ReentrantLock
    loggerflag::Channel{Bool}
end

function Logger(filename::String, lengthbuf::Int64, keysLD::Vector{String})
    filehandle = open(filename, "w")
    counter = 0
    loggerdict = Dict{String,Float64}(key => 0.0 for key in keysLD)
    loggerlock = ReentrantLock()
    loggerflag = Channel{Bool}(1)
    return Logger(
        filename,
        filehandle,
        lengthbuf,
        counter,
        keysLD,
        Matrix{Float64}(undef, lengthbuf, length(keysLD)),
        loggerdict,
        loggerlock,
        loggerflag,
    )
end

function writeheader(logger::Logger)
    @inbounds for key in @view logger.keysLD[1:end-1]
        write(logger.filehandle, key)
        write(logger.filehandle, ",")
    end
    write(logger.filehandle, logger.keysLD[end])
    write(logger.filehandle, "\n")
    flush(logger.filehandle)
end

function writerow(logger::Logger, row::AbstractVector{<:Real})
    @inbounds for val in @view row[1:end-1]
        write(logger.filehandle, string(val))
        write(logger.filehandle, ",")
    end
    write(logger.filehandle, string(row[end]))
    write(logger.filehandle, "\n")
end

function writematrix(logger::Logger, mat::AbstractMatrix{Float64})
    @inbounds for row in eachrow(mat)
        writerow(logger, row)
    end
    flush(logger.filehandle)
end

function writeline(logger::Logger)
    logger.counter = logger.counter + 1
    lock(logger.loggerlock) do
        for (i, key) in enumerate(logger.keysLD)
            logger.buffer[logger.counter, i] = logger.loggerdict[key]
        end
    end

    if logger.counter == logger.lengthbuf
        logger.counter = 0
        writematrix(logger, logger.buffer)
    end
    return nothing
end
