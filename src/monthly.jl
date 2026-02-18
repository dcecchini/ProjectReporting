module Monthly

using Dates
using Statistics
using ..Weekly
using ..Config

export MonthlyData
export load_monthly_data
export generate_monthly_report
export build_monthly_prompt

# TODO: Montly currently get weeks that span across months, this is not ideal

# ------------------------------------------------------------
# Data Structure
# ------------------------------------------------------------

struct MonthlyData
    weeks::Vector{WeeklyData}
end

# ------------------------------------------------------------
# Owner Monthly Metrics
# ------------------------------------------------------------

struct MonthlyOwnerMetrics
    owner::String
    avg_completion::Float64
    avg_weighted_completion::Float64
    avg_drift::Float64
    avg_unplanned::Float64
end

# -----------------------------
# Load all daily files for the month
# -----------------------------
function load_monthly_data(month_str::String)
    year, month = split(month_str, "-") .|> x -> parse(Int, x)
    start_date = Date(year, month, 1)
    end_date = Dates.lastdayofmonth(start_date)

    week_strs = unique(Config.iso_week_string(d) for d in start_date:end_date)
    sort!(week_strs)

    weeks = WeeklyData[]
    for week_str in week_strs
        push!(weeks, load_weekly_data(week_str))
    end

    return MonthlyData(weeks)
end

function evaluate_monthly_owner(owner::String, data::MonthlyData)

    weekly_metrics = [
        evaluate_owner(owner, week)
        for week in data.weeks
    ]

    # Filter weeks where owner had goals
    weekly_metrics = filter(m -> m.completion_pct > 0 ||
                                 m.weighted_completion > 0,
                            weekly_metrics)

    isempty(weekly_metrics) && return MonthlyOwnerMetrics(
        owner, 0, 0, 0, 0
    )

    MonthlyOwnerMetrics(
        owner,
        mean(m.completion_pct for m in weekly_metrics),
        mean(m.weighted_completion for m in weekly_metrics),
        mean(m.drift_ratio for m in weekly_metrics),
        mean(m.unplanned_ratio for m in weekly_metrics)
    )
end

# ------------------------------------------------------------
# Rendering
# ------------------------------------------------------------

function render_monthly_owner(m::MonthlyOwnerMetrics)
    """
Owner: $(m.owner)
  Avg Completion: $(round(m.avg_completion*100, digits=1))%
  Avg Weighted Completion: $(round(m.avg_weighted_completion*100, digits=1))%
  Avg Drift: $(round(m.avg_drift*100, digits=1))%
  Avg Unplanned Work: $(round(m.avg_unplanned*100, digits=1))%
"""
end

function generate_monthly_report(data::MonthlyData)
    # Collect unique owners across all weeks
    owners = unique(
        g.owner for week in data.weeks for g in week.goals
    )

    metrics = [
        evaluate_monthly_owner(owner, data)
        for owner in owners
    ]

    body = join((render_monthly_owner(m) for m in metrics), "\n")

    """
MONTHLY PERFORMANCE REPORT
===========================

Weeks analyzed: $(length(data.weeks))

$body
"""
end

function build_monthly_prompt(month_str::String, data::MonthlyData, report_text::String)
    owners = unique(g.owner for week in data.weeks for g in week.goals)
    prompt_lines = String[]
    push!(prompt_lines, "You are summarizing a monthly performance report for leadership.")
    push!(prompt_lines, "Month: $month_str")
    push!(prompt_lines, "Weeks analyzed: $(length(data.weeks))")
    push!(prompt_lines, "Owners: " * (isempty(owners) ? "(none)" : join(owners, ", ")))
    push!(prompt_lines, "")
    push!(prompt_lines, "Report:")
    push!(prompt_lines, report_text)
    push!(prompt_lines, "")
    push!(prompt_lines, "Write a concise 5-10 sentence executive summary: overall trends, notable improvements/declines per owner, and recommended focus areas for next month.")
    return join(prompt_lines, "\n")
end

end
