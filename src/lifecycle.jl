"""
    SystemLifecycle

Reusable start/stop/duration lifecycle for systems.

Handles rising-edge detection on `start_cmd`/`stop_cmd` counters,
elapsed time tracking, and duration-based auto-stop.

Usage in a system callback:
```julia
event = update_lifecycle!(ctrl.lifecycle, ctrl.params, dt_s)
if event == :started
    # reset state, etc.
end
if ctrl.lifecycle.active
    # do work
end
```
"""
mutable struct SystemLifecycle
    prev_start_cmd::Float64
    prev_stop_cmd::Float64
    active::Bool
    elapsed::Float64
end

SystemLifecycle() = SystemLifecycle(0.0, 0.0, false, 0.0)

"""
    update_lifecycle!(lc, params, dt_s) -> event::Symbol

Call at the top of every control callback. Returns one of:
  - `:started`  — `start_cmd` just rose, `elapsed` reset to 0
  - `:stopped`  — `stop_cmd` just rose or duration expired
  - `:running`  — active, `elapsed` incremented
  - `:idle`     — not active

Updates `params["running"]` and `params["elapsed"]` in-place.
"""
function update_lifecycle!(lc::SystemLifecycle, params::Dict{String,Float64}, dt_s::Float64)
    start_cmd = get(params, "start_cmd", 0.0)
    stop_cmd  = get(params, "stop_cmd", 0.0)
    duration  = get(params, "duration", Inf)

    event = :idle

    # Rising-edge start
    if start_cmd > lc.prev_start_cmd
        lc.active = true
        lc.elapsed = 0.0
        event = :started
    end
    lc.prev_start_cmd = start_cmd

    # Rising-edge stop
    if stop_cmd > lc.prev_stop_cmd && lc.active
        lc.active = false
        event = :stopped
    end
    lc.prev_stop_cmd = stop_cmd

    # Active: increment elapsed, check duration
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
