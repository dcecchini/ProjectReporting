module WeeklyGoalsService

using Dates
using JSON3
using Logging

using ..Config
using ..SchemaValidator

export WeeklyGoal, WeeklyGoalsData
export empty_weekly_goals, load_weekly_goals_data, save_weekly_goals_data
export load_workstreams, add_workstream

Base.@kwdef mutable struct WeeklyGoal
    goal_id::String = ""
    goal_description::String = ""
    priority::Int = 3
    completed::Bool = false
    workstream::String = ""
end

struct WeeklyGoalsData
    schema_version::Int
    week::String
    goals::Vector{WeeklyGoal}
end

function workstreams_path()::String
    Config.ensure_directories()
    return joinpath(Config.WEEKLY_GOALS_DIR, "workstreams.txt")
end

function default_workstreams()::Vector{String}
    return ["R & D", "Client Support"]
end

function load_workstreams()::Vector{String}
    path = workstreams_path()

    if !isfile(path)
        open(path, "w") do io
            for ws in default_workstreams()
                println(io, ws)
            end
        end
        return default_workstreams()
    end

    lines = readlines(path)
    streams = String[strip(s) for s in lines if !isempty(strip(s))]

    existing = Set(streams)
    for ws in default_workstreams()
        if !(ws in existing)
            push!(streams, ws)
        end
    end

    return unique(streams)
end

function add_workstream(workstream::AbstractString)
    ws = strip(String(workstream))
    isempty(ws) && return load_workstreams()

    streams = load_workstreams()
    if ws in Set(streams)
        return streams
    end

    path = workstreams_path()
    open(path, "a") do io
        println(io, ws)
    end

    return load_workstreams()
end

function default_weekly_goals()::Vector{WeeklyGoal}
    return WeeklyGoal[
        WeeklyGoal(
            goal_id = "CLIENT_SUPPORT",
            goal_description = "Client support",
            priority = 3,
            completed = false,
            workstream = "Client Support"
        ),
        WeeklyGoal(
            goal_id = "R_AND_D",
            goal_description = "R & D",
            priority = 3,
            completed = false,
            workstream = "R & D"
        )
    ]
end

function ensure_default_weekly_goals(goals::Vector{WeeklyGoal})::Vector{WeeklyGoal}
    existing = Set(g.goal_id for g in goals)
    merged = copy(goals)
    for g in default_weekly_goals()
        if !(g.goal_id in existing)
            push!(merged, g)
        end
    end
    return merged
end

function empty_weekly_goals(week::String)
    return WeeklyGoalsData(1, week, default_weekly_goals())
end

function _goal_from_dict(d)::WeeklyGoal
    return WeeklyGoal(
        goal_id = string(get(d, "goal_id", "")),
        goal_description = string(get(d, "goal_description", "")),
        priority = Int(get(d, "priority", 3)),
        completed = Bool(get(d, "completed", false)),
        workstream = string(get(d, "workstream", ""))
    )
end

function _goal_from_dict_legacy(d)::WeeklyGoal
    # Legacy file format: goal_id, owner, title, priority, completed
    owner = string(get(d, "owner", ""))
    title = string(get(d, "title", ""))

    return WeeklyGoal(
        goal_id = string(get(d, "goal_id", "")),
        goal_description = title,
        priority = Int(get(d, "priority", 3)),
        completed = Bool(get(d, "completed", false)),
        workstream = owner
    )
end

function _to_dict(g::WeeklyGoal)
    return Dict(
        "goal_id" => g.goal_id,
        "goal_description" => g.goal_description,
        "priority" => g.priority,
        "completed" => g.completed,
        "workstream" => g.workstream
    )
end

function load_weekly_goals_data(week::String)::WeeklyGoalsData
    Config.ensure_directories()
    path = Config.weekly_goals_path(week)

    if !isfile(path)
        return empty_weekly_goals(week)
    end

    raw = JSON3.read(read(path, String))

    if get(raw, :schema_version, nothing) == 1
        validated = SchemaValidator.load_weekly_goals(path)
        goals = WeeklyGoal[_goal_from_dict(g) for g in validated["goals"]]
        return WeeklyGoalsData(1, string(validated["week"]), ensure_default_weekly_goals(goals))
    end

    @warn "[WeeklyGoals] Legacy or unknown weekly goals format detected; loading with compatibility shim" path=path
    goals_raw = get(raw, :goals, [])
    goals = WeeklyGoal[_goal_from_dict_legacy(g) for g in goals_raw]
    return WeeklyGoalsData(1, week, ensure_default_weekly_goals(goals))
end

function save_weekly_goals_data(data::WeeklyGoalsData)
    Config.ensure_directories()
    path = Config.weekly_goals_path(data.week)

    payload = Dict(
        "schema_version" => 1,
        "week" => data.week,
        "goals" => [_to_dict(g) for g in data.goals]
    )

    open(path, "w") do io
        JSON3.write(io, payload; indent=2)
    end

    # Validate after write to ensure correctness
    SchemaValidator.load_weekly_goals(path)

    @info "[WeeklyGoals] Saved weekly goals" path=path goals=length(data.goals)
    return nothing
end

end # module
