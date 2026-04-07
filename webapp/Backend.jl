module Backend

using Dates

# Import from core library modules
using ProjectReporting.Config
using ProjectReporting.Daily: Task, DailyData, load_daily, save_daily
using ProjectReporting.Daily: generate_daily_report as core_generate_daily_report
using ProjectReporting.Weekly: WeeklyData, Goal, OwnerMetrics, evaluate_owner
using ProjectReporting.Weekly: load_weekly_data, generate_weekly_report as core_generate_weekly_report
using ProjectReporting.Weekly: render_metrics_report
using ProjectReporting.Monthly: MonthlyData, MonthlyOwnerMetrics
using ProjectReporting.Monthly: load_monthly_data, generate_monthly_report as core_generate_monthly_report

# ============================================================
# Daily Functions
# ============================================================

function load_daily_tasks(selected_date::Date)::Vector{Task}
    date_str = Dates.format(selected_date, "yyyy-mm-dd")
    @info "Loading daily tasks for $date_str"
    daily_data = load_daily(date_str)
    if daily_data === nothing
        return Task[]
    end
    return daily_data.tasks
end

function save_daily_tasks(tasks, selected_date::Date)
    date_str = Dates.format(selected_date, "yyyy-mm-dd")
    # Convert to Vector{Task} if needed
    task_vec = tasks isa Vector{Task} ? tasks : collect(Task, tasks)
    save_daily(date_str, task_vec)
end

function generate_daily_report(selected_date::Date, tasks)::String
    date_str = Dates.format(selected_date, "yyyy-mm-dd")
    if isempty(tasks)
        return "No tasks for $date_str"
    end
    task_vec = tasks isa Vector{Task} ? tasks : collect(Task, tasks)
    return core_generate_daily_report(date_str, task_vec)
end

# ============================================================
# Weekly Functions
# ============================================================

function load_weekly_metrics(selected_week::String)::Vector{OwnerMetrics}
    if isempty(selected_week)
        return OwnerMetrics[]
    end
    try
        weekly_data = load_weekly_data(selected_week)
        owners = unique(g.owner for g in weekly_data.goals)
        return [evaluate_owner(o, weekly_data) for o in owners]
    catch e
        @warn "Failed to load weekly metrics for $selected_week: $e"
        return OwnerMetrics[]
    end
end

function generate_weekly_report(metrics)::String
    if isempty(metrics)
        return "No weekly metrics available"
    end
    metrics_vec = metrics isa Vector{OwnerMetrics} ? metrics : collect(OwnerMetrics, metrics)
    return render_metrics_report(metrics_vec)
end

function update_weekly_metrics(metrics)
end

# ============================================================
# Monthly Functions
# ============================================================

function load_monthly_metrics(selected_month::String)::Vector{MonthlyOwnerMetrics}
    if isempty(selected_month)
        return MonthlyOwnerMetrics[]
    end
    try
        monthly_data = load_monthly_data(selected_month)
        # Generate report returns the formatted text, but we need metrics
        # For now, return empty - the report generation handles this
        return MonthlyOwnerMetrics[]
    catch e
        @warn "Failed to load monthly metrics for $selected_month: $e"
        return MonthlyOwnerMetrics[]
    end
end

function generate_monthly_report(metrics)::String
    if isempty(metrics)
        return "No monthly metrics available"
    end
    # For now, format the metrics manually since we have MonthlyOwnerMetrics
    lines = ["MONTHLY PERFORMANCE REPORT", "=" ^ 27, ""]
    for m in metrics
        push!(lines, "Owner: $(m.owner)")
        push!(lines, "  Avg Completion: $(round(m.avg_completion*100, digits=1))%")
        push!(lines, "  Avg Weighted: $(round(m.avg_weighted_completion*100, digits=1))%")
        push!(lines, "  Avg Drift: $(round(m.avg_drift*100, digits=1))%")
        push!(lines, "  Avg Unplanned: $(round(m.avg_unplanned*100, digits=1))%")
        push!(lines, "")
    end
    return join(lines, "\n")
end

function update_monthly_metrics(metrics)
end

end # module Backend