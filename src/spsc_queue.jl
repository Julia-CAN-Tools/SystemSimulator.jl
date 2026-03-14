mutable struct SpscQueue{T}
    storage::Vector{Union{Nothing,T}}
    head::Threads.Atomic{Int}
    tail::Threads.Atomic{Int}
    dropped::Threads.Atomic{Int}
    closed::Threads.Atomic{Bool}
end

function SpscQueue{T}(capacity::Int) where {T}
    capacity > 0 || throw(ArgumentError("capacity must be > 0"))
    return SpscQueue{T}(
        Vector{Union{Nothing,T}}(nothing, capacity + 1),
        Threads.Atomic{Int}(1),
        Threads.Atomic{Int}(1),
        Threads.Atomic{Int}(0),
        Threads.Atomic{Bool}(false),
    )
end

function Base.close(queue::SpscQueue)
    Threads.atomic_xchg!(queue.closed, true)
    return nothing
end

Base.isopen(queue::SpscQueue) = !queue.closed[]

@inline function _queue_next(queue::SpscQueue, idx::Int)
    next = idx + 1
    return next > length(queue.storage) ? 1 : next
end

function try_push!(queue::SpscQueue{T}, value::T)::Bool where {T}
    queue.closed[] && return false
    head = queue.head[]
    next = _queue_next(queue, head)
    if next == queue.tail[]
        queue.dropped[] += 1
        return false
    end
    @inbounds queue.storage[head] = value
    queue.head[] = next
    return true
end

function try_pop!(queue::SpscQueue{T}) where {T}
    tail = queue.tail[]
    tail == queue.head[] && return nothing
    @inbounds value = queue.storage[tail]
    @inbounds queue.storage[tail] = nothing
    queue.tail[] = _queue_next(queue, tail)
    return value
end
