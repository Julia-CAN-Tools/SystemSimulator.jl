"""
    CanIO <: AbstractIO

CAN adapter that reuses `CANInterface` for transport and `CANUtils` message
catalog encode/decode functions.
"""
struct CanIO{D<:CI.AbstractCanDriver,R<:CU.AbstractCanMessage,T<:CU.AbstractCanMessage} <: AbstractIO
    driver::D
    rx_catalog::Vector{R}
    tx_catalog::Vector{T}
end

function CanIO(
    driver::D,
    rx_catalog::AbstractVector{R},
    tx_catalog::AbstractVector{T},
) where {D<:CI.AbstractCanDriver,R<:CU.AbstractCanMessage,T<:CU.AbstractCanMessage}
    return CanIO{D,R,T}(driver, collect(rx_catalog), collect(tx_catalog))
end

function CanIO(
    driver::D,
    rx_catalog::AbstractVector{R},
) where {D<:CI.AbstractCanDriver,R<:CU.AbstractCanMessage}
    return CanIO(driver, rx_catalog, R[])
end

raw_payload_type(::Type{<:CanIO}) = CI.CanFrameRaw

function read_raw(io::CanIO{<:CI.SocketCanDriver})::Union{CI.CanFrameRaw,Nothing}
    # Poll with a bounded timeout so reader loops can observe stop requests
    # even when no CAN traffic is present.
    return CI.read(io.driver; timeout_ms=10)
end

function read_raw(io::CanIO)::Union{CI.CanFrameRaw,Nothing}
    return CI.read(io.driver)
end

function decode_raw!(io::CanIO, raw::CI.CanFrameRaw, local_inputs::Dict{String,Float64})::Bool
    isempty(io.rx_catalog) && return false
    raw.can_dlc != UInt8(8) && return false
    frame = CU.CanFrame(raw.can_id, collect(raw.data))
    return CU.match_and_decode!(frame, io.rx_catalog, local_inputs)
end

function encode_raw(io::CanIO, local_outputs::AbstractDict{String,<:Real})::Vector{CU.CanFrame}
    isempty(io.tx_catalog) && return CU.CanFrame[]
    payloads = Vector{CU.CanFrame}(undef, length(io.tx_catalog))
    for (i, message) in enumerate(io.tx_catalog)
        payloads[i] = CU.encode(message, local_outputs)
    end
    return payloads
end

function write_raw(io::CanIO, payload::CU.CanFrame)::Nothing
    CI.write(io.driver, payload.canid, payload.data)
    return nothing
end

function input_signal_names(io::CanIO)::Vector{String}
    isempty(io.rx_catalog) && return String[]
    signal_dict = CU.create_signal_dict(io.rx_catalog)
    return collect(keys(signal_dict))
end

function output_signal_names(io::CanIO)::Vector{String}
    isempty(io.tx_catalog) && return String[]
    signal_dict = CU.create_signal_dict(io.tx_catalog)
    return collect(keys(signal_dict))
end

function Base.close(io::CanIO)::Nothing
    CI.close(io.driver)
    return nothing
end
