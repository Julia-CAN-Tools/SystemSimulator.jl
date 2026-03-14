"""
Abstract interface for IO transports used by `SystemSimulator`.

Concrete IO types must:
1. Provide a constructor that fully initializes transport/session resources.
2. Implement `read_raw`.
3. Implement `decode_raw!`.
4. Implement `encode_and_write!` or `encode_raw` + `write_raw`.
5. Implement `input_signal_names` and `output_signal_names`.
6. Optionally implement `bind_io!` for setup-time slot binding.
7. Optionally implement `Base.close` when resources must be released.
"""
abstract type AbstractIO end

raw_payload_type(::Type{<:AbstractIO}) = Any

function read_raw(io::AbstractIO)
    error("read_raw not implemented for IO type: $(typeof(io))")
end

function decode_raw!(io::AbstractIO, raw, local_inputs::AbstractDict{String,Float64})::Bool
    error("decode_raw! not implemented for IO type: $(typeof(io))")
end

function encode_raw(io::AbstractIO, local_outputs::AbstractDict{String,<:Real})::Vector{Any}
    error("encode_raw not implemented for IO type: $(typeof(io))")
end

function write_raw(io::AbstractIO, payload)::Nothing
    error("write_raw not implemented for IO type: $(typeof(io))")
end

function input_signal_names(io::AbstractIO)::Vector{String}
    error("input_signal_names not implemented for IO type: $(typeof(io))")
end

function output_signal_names(io::AbstractIO)::Vector{String}
    error("output_signal_names not implemented for IO type: $(typeof(io))")
end

function bind_io!(io::AbstractIO, _input_schema::SignalSchema, _output_schema::SignalSchema)::Nothing
    return nothing
end

function Base.close(io::AbstractIO)::Nothing
    return nothing
end

function encode_and_write!(io::AbstractIO, local_outputs::AbstractDict{String,<:Real})::Nothing
    payloads = encode_raw(io, local_outputs)
    for payload in payloads
        write_raw(io, payload)
    end
    return nothing
end

global_key(io_name::Symbol, local_name::String) = string(io_name, ".", local_name)

function build_keymap(io_name::Symbol, local_names::Vector{String})::Dict{String,String}
    map = Dict{String,String}()
    for local_name in local_names
        map[local_name] = global_key(io_name, local_name)
    end
    return map
end
