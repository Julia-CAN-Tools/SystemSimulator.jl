mutable struct SystemLifecycle
    prev_start_cmd::Float64
    prev_stop_cmd::Float64
    active::Bool
    elapsed::Float64
end

SystemLifecycle() = SystemLifecycle(0.0, 0.0, false, 0.0)

struct LifecycleSlots
    start_cmd::Int
    stop_cmd::Int
    running::Int
    elapsed::Int
    duration::Int
end

function bind_lifecycle(params::SignalBuffer)
    return LifecycleSlots(
        signal_slot(params, "start_cmd"),
        signal_slot(params, "stop_cmd"),
        signal_slot(params, "running"),
        signal_slot(params, "elapsed"),
        signal_slot(params, "duration"),
    )
end

function update_lifecycle!(
    lc::SystemLifecycle,
    params::SignalBuffer,
    slots::LifecycleSlots,
    dt_s::Float64,
)
    start_cmd = params[slots.start_cmd]
    stop_cmd = params[slots.stop_cmd]
    duration = params[slots.duration]

    event = :idle

    if start_cmd > lc.prev_start_cmd
        lc.active = true
        lc.elapsed = 0.0
        event = :started
    end
    lc.prev_start_cmd = start_cmd

    if stop_cmd > lc.prev_stop_cmd && lc.active
        lc.active = false
        event = :stopped
    end
    lc.prev_stop_cmd = stop_cmd

    if lc.active
        lc.elapsed += dt_s
        if lc.elapsed >= duration
            lc.active = false
            event = :stopped
        elseif event != :started
            event = :running
        end
    end

    params[slots.running] = lc.active ? 1.0 : 0.0
    params[slots.elapsed] = lc.elapsed
    return event
end

function update_lifecycle!(lc::SystemLifecycle, params::AbstractDict{String,Float64}, dt_s::Float64)
    start_cmd = get(params, "start_cmd", 0.0)
    stop_cmd  = get(params, "stop_cmd", 0.0)
    duration  = get(params, "duration", Inf)

    event = :idle

    if start_cmd > lc.prev_start_cmd
        lc.active = true
        lc.elapsed = 0.0
        event = :started
    end
    lc.prev_start_cmd = start_cmd

    if stop_cmd > lc.prev_stop_cmd && lc.active
        lc.active = false
        event = :stopped
    end
    lc.prev_stop_cmd = stop_cmd

    if lc.active
        lc.elapsed += dt_s
        if lc.elapsed >= duration
            lc.active = false
            event = :stopped
        elseif event != :started
            event = :running
        end
    end

    params["running"] = lc.active ? 1.0 : 0.0
    params["elapsed"] = lc.elapsed
    return event
end
