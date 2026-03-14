"""
    SignalSchema

Ordered signal layout used by the runtime. Names are resolved to integer slots once during
setup; steady-state code should use the integer slots directly.
"""
struct SignalSchema
    names::Vector{String}
    index::Dict{String,Int}
end

function SignalSchema(names::Vector{String})
    ordered = String[]
    seen = Set{String}()
    for name in names
        name in seen && continue
        push!(ordered, name)
        push!(seen, name)
    end
    return SignalSchema(ordered, Dict(name => i for (i, name) in enumerate(ordered)))
end

"""
    SignalBuffer

Dense runtime signal storage. The runtime owns and moves raw `Vector{Float64}` payloads;
name-based lookup exists only for setup and non-hot-path helpers.
"""
mutable struct SignalBuffer
    schema::SignalSchema
    values::Vector{Float64}
end

SignalBuffer(schema::SignalSchema) = SignalBuffer(schema, zeros(Float64, length(schema.names)))
SignalBuffer(names::Vector{String}) = SignalBuffer(SignalSchema(names))

"""
    NamedSignalView <: AbstractDict{String,Float64}

Dictionary adapter over a `SignalBuffer`. Used only at API boundaries where slower
name-based access is still convenient (custom IO implementations, tests, debugging).
The core runtime uses integer slots on `SignalBuffer` directly.
"""
struct NamedSignalView <: AbstractDict{String,Float64}
    buffer::SignalBuffer
end

SignalSchema(buffer::SignalBuffer) = buffer.schema
signal_names(schema::SignalSchema) = schema.names
signal_names(buffer::SignalBuffer) = buffer.schema.names
signal_slot(schema::SignalSchema, name::AbstractString) = schema.index[String(name)]
signal_slot(buffer::SignalBuffer, name::AbstractString) = signal_slot(buffer.schema, name)

function try_signal_slot(schema::SignalSchema, name::AbstractString)
    return get(schema.index, String(name), 0)
end

try_signal_slot(buffer::SignalBuffer, name::AbstractString) = try_signal_slot(buffer.schema, name)

Base.length(buffer::SignalBuffer) = length(buffer.values)
Base.getindex(buffer::SignalBuffer, slot::Int) = (@inbounds buffer.values[slot])
function Base.setindex!(buffer::SignalBuffer, value, slot::Int)
    @inbounds buffer.values[slot] = Float64(value)
    return value
end
Base.getindex(buffer::SignalBuffer, name::AbstractString) = buffer.values[signal_slot(buffer, name)]
function Base.setindex!(buffer::SignalBuffer, value, name::AbstractString)
    buffer.values[signal_slot(buffer, name)] = Float64(value)
    return value
end

function Base.get(buffer::SignalBuffer, name::AbstractString, default)
    idx = try_signal_slot(buffer, name)
    return idx == 0 ? Float64(default) : buffer.values[idx]
end

function Base.fill!(buffer::SignalBuffer, value)
    fill!(buffer.values, Float64(value))
    return buffer
end

Base.copy(buffer::SignalBuffer) = SignalBuffer(buffer.schema, copy(buffer.values))

# NamedSignalView dictionary interface
Base.length(view::NamedSignalView) = length(view.buffer)
Base.keys(view::NamedSignalView) = signal_names(view.buffer)
Base.values(view::NamedSignalView) = view.buffer.values
Base.haskey(view::NamedSignalView, key::AbstractString) = try_signal_slot(view.buffer, key) > 0
Base.getindex(view::NamedSignalView, key::AbstractString) = view.buffer[key]
Base.setindex!(view::NamedSignalView, value, key::AbstractString) = (view.buffer[key] = value)

function Base.get(view::NamedSignalView, key::AbstractString, default)
    return get(view.buffer, key, default)
end

function Base.iterate(view::NamedSignalView, i::Int=1)
    i > length(view.buffer) && return nothing
    names = signal_names(view.buffer)
    return (names[i] => view.buffer.values[i], i + 1)
end

"""
    sync_values!(dest, src)

Fast bulk copy for matching `SignalBuffer`s.
"""
function sync_values!(dest::SignalBuffer, src::SignalBuffer)
    copyto!(dest.values, src.values)
    return dest
end

"""
    IndexPair

Pre-computed source-to-destination slot mapping.
"""
struct IndexPair
    src::Int
    dst::Int
end

function compute_index_pairs(
    src_schema::SignalSchema,
    dst_schema::SignalSchema,
    names::Vector{String},
)::Vector{IndexPair}
    pairs = IndexPair[]
    for name in names
        si = get(src_schema.index, name, 0)
        di = get(dst_schema.index, name, 0)
        si > 0 && di > 0 && push!(pairs, IndexPair(si, di))
    end
    return pairs
end

@inline function copy_by_pairs!(
    dst_values::AbstractVector{Float64},
    src_values::Vector{Float64},
    pairs::Vector{IndexPair},
)
    @inbounds for p in pairs
        dst_values[p.dst] = src_values[p.src]
    end
    return nothing
end
