module WeeklyMetrics

using Dates
using SimpleProjectReporting.SchemaValidator

export compute_weekly_metrics, GoalMetrics

# ----------------------------
# Struct for per-goal metrics
# ----------------------------
struct GoalMetrics
    goal_id::String
    owner::Vector{String}
    completion_ratio::Float64
    blocked_ratio::Float64
    priority_drift_ratio::Float64
end

# ----------------------------
# Compute weekly metrics
# ----------------------------
"""
    compute_weekly_metrics(daily_files::Vector{String}, weekly_goals_file::String)

Compute per-goal metrics for a given week:

- completion_ratio: fraction of tasks linked to this goal that were completed (execution_state != blocked)
- blocked_ratio: fraction of tasks blocked
- priority_drift_ratio: fraction of tasks where priority_changed == true
"""
function compute_weekly_metrics(daily_files::Vector{String}, weekly_goals_file::String)
    # Load weekly goals
    weekly_goals = load_weekly_goals(weekly_goals_file)["goals"]
    
    # Initialize result dictionary
    goal_metrics = Dict{String, GoalMetrics}()
    
    # Flatten all daily tasks
    all_tasks = []
    for file in daily_files
        daily_data = load_daily(file)
        append!(all_tasks, daily_data["tasks"])
    end

    # Compute metrics per goal
    for goal in weekly_goals
        goal_id = goal["goal_id"]
        owner = goal["owners"]

        # Filter tasks linked to this goal
        goal_tasks = [t for t in all_tasks if t["goal_id"] == goal_id]

        n_tasks = length(goal_tasks)
        if n_tasks == 0
            completion_ratio = 0.0
            blocked_ratio = 0.0
            priority_drift_ratio = 0.0
        else
            # Completion: tasks active or done
            n_completed = count(t -> t["execution_state"] == "active", goal_tasks)
            n_blocked = count(t -> t["execution_state"] == "blocked", goal_tasks)
            n_priority_changed = count(t -> t["priority_changed"] == true, goal_tasks)

            completion_ratio = n_completed / n_tasks
            blocked_ratio = n_blocked / n_tasks
            priority_drift_ratio = n_priority_changed / n_tasks
        end

        goal_metrics[goal_id] = GoalMetrics(
            goal_id,
            owner,
            completion_ratio,
            blocked_ratio,
            priority_drift_ratio
        )
    end

    return goal_metrics
end

end # module
