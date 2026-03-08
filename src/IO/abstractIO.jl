"""
Abstract interface for IO transports used by `SystemSimulator`.

Concrete IO types must:
1. Provide a constructor that fully initializes transport/session resources.
2. Implement `read_raw`.
3. Implement `decode_raw!`.
4. Implement `encode_raw`.
5. Implement `write_raw`.
6. Implement `input_signal_names` and `output_signal_names`.
7. Optionally implement `Base.close` when resources must be released.
"""
abstract type AbstractIO end

"""
    raw_payload_type(::Type{IO}) -> Type

Return the concrete type of values produced by `read_raw` for IO type `IO`.
Used to specialize the IOState rx_queue channel.
Default: `Any` (works for test/mock IOs).
"""
raw_payload_type(::Type{<:AbstractIO}) = Any

"""
    read_raw(io::AbstractIO)

Read one raw payload from transport, or `nothing` when no payload is available.
"""
function read_raw(io::AbstractIO)
    error("read_raw not implemented for IO type: $(typeof(io))")
end

"""
    decode_raw!(io::AbstractIO, raw, local_inputs::Dict{String,Float64}) -> Bool

Decode one raw payload into `local_inputs`. Return `true` when snapshot should be
published and `false` otherwise.
"""
function decode_raw!(io::AbstractIO, raw, local_inputs::Dict{String,Float64})::Bool
    error("decode_raw! not implemented for IO type: $(typeof(io))")
end

"""
    encode_raw(io::AbstractIO, local_outputs::AbstractDict{String,<:Real}) -> Vector{Any}

Encode local outputs into one or more transport payloads.
"""
function encode_raw(io::AbstractIO, local_outputs::AbstractDict{String,<:Real})::Vector{Any}
    error("encode_raw not implemented for IO type: $(typeof(io))")
end

"""
    write_raw(io::AbstractIO, payload) -> Nothing

Write one encoded payload to transport.
"""
function write_raw(io::AbstractIO, payload)::Nothing
    error("write_raw not implemented for IO type: $(typeof(io))")
end

"""
    input_signal_names(io::AbstractIO) -> Vector{String}

List all local input signal names decoded by the IO.
"""
function input_signal_names(io::AbstractIO)::Vector{String}
    error("input_signal_names not implemented for IO type: $(typeof(io))")
end

"""
    output_signal_names(io::AbstractIO) -> Vector{String}

List all local output signal names encoded by the IO.
"""
function output_signal_names(io::AbstractIO)::Vector{String}
    error("output_signal_names not implemented for IO type: $(typeof(io))")
end

function Base.close(io::AbstractIO)::Nothing
    return nothing
end

"""
    global_key(io_name::Symbol, local_name::String) -> String

Namespace helper for global runtime dictionaries.
"""
global_key(io_name::Symbol, local_name::String) = string(io_name, ".", local_name)

"""
    build_keymap(io_name::Symbol, local_names::Vector{String}) -> Dict{String,String}

Constructs local-to-global key map for one IO.
"""
function build_keymap(io_name::Symbol, local_names::Vector{String})::Dict{String,String}
    map = Dict{String,String}()
    for local_name in local_names
        map[local_name] = global_key(io_name, local_name)
    end
    return map
end
