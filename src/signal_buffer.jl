"""
    SignalBuffer <: AbstractDict{String,Float64}

Dense signal storage backed by a `Vector{Float64}` with string-to-index mapping.
Implements the full `AbstractDict` interface for backward compatibility with code
that uses `inputs["key"]` / `outputs["key"] = val`.

Pre-computed index pairs enable O(1) array-indexed copies in hot paths
(gather_inputs!, split_outputs!, copy_to_logger!, writeline, monitor_writer_loop)
instead of per-cycle hash lookups.
"""
mutable struct SignalBuffer <: AbstractDict{String,Float64}
    const names::Vector{String}
    values::Vector{Float64}
    const _index::Dict{String,Int}
end

function SignalBuffer(names::Vector{String})
    idx = Dict{String,Int}(name => i for (i, name) in enumerate(names))
    return SignalBuffer(copy(names), zeros(Float64, length(names)), idx)
end

function SignalBuffer(d::Dict{String,Float64}, ordered_names::Vector{String})
    sb = SignalBuffer(ordered_names)
    for (name, val) in d
        if haskey(sb._index, name)
            sb.values[sb._index[name]] = val
        end
    end
    return sb
end

# AbstractDict interface
Base.getindex(sb::SignalBuffer, key::AbstractString) = sb.values[sb._index[key]]
function Base.setindex!(sb::SignalBuffer, val, key::AbstractString)
    sb.values[sb._index[key]] = Float64(val)
    return val
end
function Base.get(sb::SignalBuffer, key::AbstractString, default)
    idx = get(sb._index, key, 0)
    return idx == 0 ? Float64(default) : sb.values[idx]
end
Base.haskey(sb::SignalBuffer, key::AbstractString) = haskey(sb._index, key)
Base.length(sb::SignalBuffer) = length(sb.names)
Base.keys(sb::SignalBuffer) = sb.names
Base.values(sb::SignalBuffer) = sb.values

function Base.iterate(sb::SignalBuffer)
    isempty(sb.names) && return nothing
    return (sb.names[1] => sb.values[1], 2)
end

function Base.iterate(sb::SignalBuffer, i::Int)
    i > length(sb.names) && return nothing
    return (sb.names[i] => sb.values[i], i + 1)
end

Base.copy(sb::SignalBuffer) = SignalBuffer(copy(sb.names), copy(sb.values), copy(sb._index))

"""
    sync_values!(dest::SignalBuffer, src::SignalBuffer)

Fast bulk copy for matching SignalBuffers (same names, same order).
"""
function sync_values!(dest::SignalBuffer, src::SignalBuffer)
    copyto!(dest.values, src.values)
    return dest
end

"""
    IndexPair

Pre-computed source→destination index mapping for zero-hash signal copies.
"""
struct IndexPair
    src::Int
    dst::Int
end

"""
    compute_index_pairs(src_names, src_index, dst_names, dst_index)

Build a vector of IndexPairs mapping matching signal names between two SignalBuffers.
"""
function compute_index_pairs(
    src_index::Dict{String,Int},
    dst_index::Dict{String,Int},
    names::Vector{String},
)::Vector{IndexPair}
    pairs = IndexPair[]
    for name in names
        si = get(src_index, name, 0)
        di = get(dst_index, name, 0)
        si > 0 && di > 0 && push!(pairs, IndexPair(si, di))
    end
    return pairs
end

"""
    copy_by_pairs!(dst_values, src_values, pairs)

Copy values using pre-computed index pairs. Zero allocations.
"""
@inline function copy_by_pairs!(
    dst_values::Vector{Float64},
    src_values::Vector{Float64},
    pairs::Vector{IndexPair},
)
    @inbounds for p in pairs
        dst_values[p.dst] = src_values[p.src]
    end
    return nothing
end

"""
    compute_gather_pairs(local_snapshot, local_keymap, global_inputs)

Build index pairs for gather_inputs!: local_snapshot[local_idx] → global_inputs[global_idx].
"""
function compute_gather_pairs(
    snapshot::SignalBuffer,
    keymap::Dict{String,String},
    inputs::SignalBuffer,
)::Vector{IndexPair}
    pairs = IndexPair[]
    for (local_name, global_name) in keymap
        li = get(snapshot._index, local_name, 0)
        gi = get(inputs._index, global_name, 0)
        li > 0 && gi > 0 && push!(pairs, IndexPair(li, gi))
    end
    return pairs
end

"""
    compute_split_pairs(global_outputs, local_keymap, local_output)

Build index pairs for split_outputs!: global_outputs[global_idx] → local_output[local_idx].
"""
function compute_split_pairs(
    outputs::SignalBuffer,
    keymap::Dict{String,String},
    local_output::SignalBuffer,
)::Vector{IndexPair}
    pairs = IndexPair[]
    for (local_name, global_name) in keymap
        gi = get(outputs._index, global_name, 0)
        li = get(local_output._index, local_name, 0)
        gi > 0 && li > 0 && push!(pairs, IndexPair(gi, li))
    end
    return pairs
end
