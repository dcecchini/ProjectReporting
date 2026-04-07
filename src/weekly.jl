module Weekly

using Dates
using JSON3
using ..Config
using ..Daily: Task, task_to_dict

export WeeklyData, Goal
export OwnerMetrics
export evaluate_owner, render_owner_metrics
export generate_weekly_report, render_metrics_report, load_weekly_data, save_weekly, build_weekly_prompt

# -----------------------------
# Data Structures
# -----------------------------

struct Goal
    owner::String
    title::String
    priority::Int
    completed::Bool
end

function goal_to_dict(g::Goal)
    return Dict(
        "owner" => g.owner,
        "title" => g.title,
        "priority" => g.priority,
        "completed" => g.completed
    )
end

struct WeeklyData
    goals::Vector{Goal}
    tasks::Vector{Task}
end

# -----------------------------
# Metrics
# -----------------------------

struct OwnerMetrics
    owner::String
    completion_pct::Float64
    weighted_completion::Float64
    drift_ratio::Float64
    unplanned_ratio::Float64
    priority_changes::Int
end

function owner_metrics_to_dict(m::OwnerMetrics)
    return Dict(
        "owner" => m.owner,
        "completion_pct" => m.completion_pct,
        "weighted_completion" => m.weighted_completion,
        "drift_ratio" => m.drift_ratio,
        "unplanned_ratio" => m.unplanned_ratio,
        "priority_changes" => m.priority_changes
    )
end

# -----------------------------
# Load Weekly Data
# -----------------------------
function iso_week_to_date(week_str::String)
    m = match(r"(\d+)-W(\d+)", week_str)
    m === nothing && error("Invalid week format. Use YYYY-Www")
    year, week = parse.(Int, m.captures)

    # ISO week 1 always contains Jan 4
    jan4 = Date(year, 1, 4)
    monday_week1 = jan4 - Day(dayofweek(jan4) - 1)

    # Monday of requested week
    start_date = monday_week1 + Week(week - 1)
    return start_date
end

function load_weekly_data(week_str::String)
    start_date = iso_week_to_date(week_str)
    daily_files = [joinpath(Config.DAILY_DATA_DIR, string(start_date + Day(i)) * ".json") for i in 0:4]

    all_goals = Goal[]
    all_tasks = Task[]

    for f in daily_files
        isfile(f) || continue
        data = JSON3.read(open(f))
        for t in data["tasks"]
            push!(all_tasks, Task(
                string(get(t, "goal_id", "")),
                string(t["title"]),
                string(t["owner"]),
                string(get(t, "allocation", "")),
                string(get(t, "execution_state", "")),
                Bool(get(t, "priority_changed", false)),
                Bool(get(t, "linked_goal", false))
            ))
            if haskey(t, "goal_id")
                push!(all_goals, Goal(t["owner"], t["title"], 1, t["execution_state"] == "active"))
            end
        end
    end

    return WeeklyData(all_goals, all_tasks)
end


# --------------------------
# Save weekly metrics and report
# --------------------------
function save_weekly(week_str::String, weekly_data::WeeklyData, report_text::String)

    Config.ensure_directories()

    owners = unique(g.owner for g in weekly_data.goals)
    metrics = [evaluate_owner(o, weekly_data) for o in owners]

    # Save weekly data JSON
    data_fname = joinpath(Config.WEEKLY_REPORTS_DIR, "$week_str.json")
    open(data_fname, "w") do io
        JSON3.write(io, Dict(
            "week" => week_str,
            "goals" => [goal_to_dict(g) for g in weekly_data.goals],
            "tasks" => [task_to_dict(t) for t in weekly_data.tasks]
        ); indent=2)
    end
    println("Saved weekly data JSON to $data_fname")

    # Save JSON metrics
    metrics_fname = joinpath(Config.WEEKLY_METRICS_DIR, "$week_str.json")
    open(metrics_fname, "w") do io
        JSON3.write(io, Dict(
            "week" => week_str,
            "owners" => [owner_metrics_to_dict(m) for m in metrics]
        ); indent=2)
    end
    println("Saved weekly metrics JSON to $metrics_fname")

    # Save human-readable report
    report_fname = joinpath(Config.WEEKLY_REPORTS_DIR, "$week_str.txt")
    open(report_fname, "w") do io
        write(io, report_text)
    end
    println("Saved weekly report to $report_fname")
end


function evaluate_owner(owner::String, data::WeeklyData)
    goals = filter(g -> g.owner == owner, data.goals)
    tasks = filter(t -> t.owner == owner, data.tasks)

    isempty(goals) && return OwnerMetrics(owner, 0, 0, 0, 0, 0)

    completed = count(g -> g.completed, goals)
    completion_pct = completed / length(goals)

    total_weight = sum(g.priority for g in goals; init=0)
    achieved_weight = sum(g.priority for g in goals if g.completed; init=0)
    weighted_completion = total_weight == 0 ? 0.0 : achieved_weight / total_weight

    priority_changes = count(t -> t.priority_changed, tasks)
    drift_ratio = isempty(tasks) ? 0.0 : priority_changes / length(tasks)

    unplanned = count(t -> !t.linked_goal, tasks)
    unplanned_ratio = isempty(tasks) ? 0.0 : unplanned / length(tasks)

    OwnerMetrics(owner, completion_pct, weighted_completion, drift_ratio, unplanned_ratio, priority_changes)
end

function render_owner_metrics(m::OwnerMetrics)
    """
Owner: $(m.owner)
  Completion: $(round(m.completion_pct*100, digits=1))%
  Weighted Completion: $(round(m.weighted_completion*100, digits=1))%
  Drift Ratio: $(round(m.drift_ratio*100, digits=1))%
  Unplanned Work: $(round(m.unplanned_ratio*100, digits=1))%
  Priority Changes: $(m.priority_changes)
"""
end

# -----------------------------
# Report Generation
# -----------------------------

# Use this when you already have OwnerMetrics
function render_metrics_report(metrics::Vector{OwnerMetrics})
    header = "Weekly Report\n==============\n"
    body = join((render_owner_metrics(m) for m in metrics), "\n")
    return header * body
end

# Use this when you have WeeklyData
function generate_weekly_report(data::WeeklyData)
    owners = unique(g.owner for g in data.goals)
    metrics = [evaluate_owner(o, data) for o in owners]

    body = join((render_owner_metrics(m) for m in metrics), "\n")

    """
WEEKLY PERFORMANCE REPORT
==========================

$body
"""
end

function build_weekly_prompt(week_str::String, data::WeeklyData, metrics::Vector{OwnerMetrics}, report_text::String)
    owners = unique(m.owner for m in metrics)
    prompt_lines = String[]
    push!(prompt_lines, "You are summarizing a weekly performance report for leadership.")
    push!(prompt_lines, "Week: $week_str")
    push!(prompt_lines, "Owners: " * (isempty(owners) ? "(none)" : join(owners, ", ")))
    push!(prompt_lines, "Total goals: $(length(data.goals))")
    push!(prompt_lines, "Total tasks: $(length(data.tasks))")
    push!(prompt_lines, "")
    push!(prompt_lines, "Metrics report:")
    push!(prompt_lines, report_text)
    push!(prompt_lines, "")
    push!(prompt_lines, "Write a concise 3-6 sentence summary: achievements, key risks/blockeds inferred from metrics, and notable priority drift/unplanned work.")
    return join(prompt_lines, "\n")
end

end
