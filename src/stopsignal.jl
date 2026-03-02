using Base: Threads

"""
    StopSignal

Thread-safe shutdown latch shared across all simulator tasks.
"""
mutable struct StopSignal
    flag::Threads.Atomic{Bool}
end

StopSignal() = StopSignal(Threads.Atomic{Bool}(false))

"""
    request_stop!(signal)

Request runtime shutdown.
"""
function request_stop!(signal::StopSignal)
    Threads.atomic_xchg!(signal.flag, true)
    return nothing
end

"""
    cancel_stop!(signal)

Clear shutdown request.
"""
function cancel_stop!(signal::StopSignal)
    Threads.atomic_xchg!(signal.flag, false)
    return nothing
end

"""
    stop_requested(signal) -> Bool

Read the stop flag with atomic semantics.
"""
function stop_requested(signal::StopSignal)
    return Threads.atomic_or!(signal.flag, false)
end
