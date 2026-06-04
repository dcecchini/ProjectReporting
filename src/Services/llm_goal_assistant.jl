module LLMGoalAssistant

using Dates
using JSON3
using Logging

using ..Config
using ..DailyModel: DailyData
using ..DailyService
using ..Domain: allocation_to_string, BLOCKED, execution_state_to_string
using ..TeamService
using ..WeeklyGoalsService
using ..WeeklyReportService
using ..LLMSummarizer

export suggest_weekly_goals, build_context_summary

# ---------------------------
# Context gathering
# ---------------------------

function load_week_entries(monday::Date)::Vector{DailyData}
    result = DailyData[]
    for i in 0:4
        d = monday + Day(i)
        data = DailyService.load_daily_data(string(d))
        data !== nothing && push!(result, data)
    end
    return result
end

function gather_context(target_week::String)
    monday      = WeeklyReportService.iso_week_to_monday(target_week)
    prev_monday = monday - Week(1)
    prev_week   = Config.iso_week_string(prev_monday)

    roster       = TeamService.load_team_roster()
    curr_entries = load_week_entries(monday)
    prev_entries = load_week_entries(prev_monday)
    prev_goals   = WeeklyGoalsService.load_weekly_goals_data(prev_week)

    report_path = Config.weekly_report_path(prev_week)
    report_text = isfile(report_path) ? read(report_path, String) : nothing

    return (
        roster       = roster,
        target_week  = target_week,
        prev_week    = prev_week,
        curr_entries = curr_entries,
        prev_entries = prev_entries,
        prev_goals   = prev_goals,
        report_text  = report_text
    )
end

# ---------------------------
# Context summary for UI
# ---------------------------

function build_context_summary(ctx)::String
    active   = [m for m in ctx.roster.members if m.active]
    inactive = [m for m in ctx.roster.members if !m.active]

    lines = String[
        "Team: $(length(active)) active member(s)$(isempty(inactive) ? "" : ", $(length(inactive)) unavailable")",
        "Previous week: $(ctx.prev_week) — $(length(ctx.prev_goals.goals)) goal(s), $(length(ctx.prev_entries)) day(s) of data",
        "Current week:  $(ctx.target_week) — $(length(ctx.curr_entries)) day(s) of data loaded",
        "Weekly report: $(ctx.report_text !== nothing ? "available" : "not found")"
    ]

    return join(lines, "\n")
end

# ---------------------------
# Prompt building
# ---------------------------

function format_daily_entries(entries::Vector{DailyData})::String
    isempty(entries) && return "(no data)"
    lines = String[]
    for data in entries
        push!(lines, "Date: $(data.date)")
        for e in data.entries
            for t in e.tasks
                blocked = t.execution_state == BLOCKED ? " [BLOCKED]" : ""
                push!(lines, "  - $(e.member.name) [$(allocation_to_string(t.allocation))]: $(t.description)$blocked")
            end
        end
    end
    return join(lines, "\n")
end

function build_prompt(ctx)::String
    lines = String[]

    push!(lines, "You are a project manager assistant. Suggest weekly goals for $(ctx.target_week).")
    push!(lines, "Base your suggestions on team availability, ongoing work, and last week's outcomes.")
    push!(lines, "")

    push!(lines, "## Team Availability")
    active   = [m for m in ctx.roster.members if m.active]
    inactive = [m for m in ctx.roster.members if !m.active]
    for m in active
        note = isempty(m.note) ? "" : " — $(m.note)"
        push!(lines, "- $(m.name): $(m.capacity)% capacity$note")
    end
    if !isempty(inactive)
        push!(lines, "Unavailable this week:")
        for m in inactive
            note = isempty(m.note) ? "" : " — $(m.note)"
            push!(lines, "- $(m.name)$note")
        end
    end
    push!(lines, "")

    push!(lines, "## Last Week Goals ($(ctx.prev_week))")
    if isempty(ctx.prev_goals.goals)
        push!(lines, "(none)")
    else
        for g in ctx.prev_goals.goals
            status = g.completed ? "completed" : "not completed"
            push!(lines, "- [$(g.workstream)] $(g.goal_description) — $status")
        end
    end
    push!(lines, "")

    push!(lines, "## Last Week Daily Activity")
    push!(lines, format_daily_entries(ctx.prev_entries))
    push!(lines, "")

    if !isempty(ctx.curr_entries)
        push!(lines, "## Current Week Activity So Far")
        push!(lines, format_daily_entries(ctx.curr_entries))
        push!(lines, "")
    end

    if ctx.report_text !== nothing
        push!(lines, "## Last Week Summary Report")
        push!(lines, ctx.report_text)
        push!(lines, "")
    end

    push!(lines, "## Instructions")
    push!(lines, "- Propose a realistic number of goals based on team capacity and ongoing work.")
    push!(lines, "- You may introduce new workstreams if they fit the context.")
    push!(lines, "- Assign priorities 1 (highest) to 5 (lowest).")
    push!(lines, "- Do NOT assign goals to individual members — assign to workstreams.")
    push!(lines, "- Return ONLY a valid JSON array. No explanation, no markdown fences, no extra text.")
    push!(lines, "")
    push!(lines, """Example output format:
[
  {
    "goal_id": "G-001",
    "goal_description": "Complete feature X and deploy to staging",
    "priority": 1,
    "completed": false,
    "workstream": "R & D"
  }
]""")

    return join(lines, "\n")
end

# ---------------------------
# Response parsing
# ---------------------------

function parse_goals_from_response(response::String)::Vector{WeeklyGoalsService.WeeklyGoal}
    cleaned = strip(replace(replace(response, r"```[a-z]*" => ""), "```" => ""))

    json_start = findfirst('[', cleaned)
    json_end   = findlast(']', cleaned)

    if json_start === nothing || json_end === nothing
        @error "[LLMGoalAssistant] No JSON array found in LLM response" preview=first(cleaned, 300)
        error("LLM response did not contain a JSON array. Preview: $(first(cleaned, 200))")
    end

    arr = JSON3.read(cleaned[json_start:json_end])

    return [
        WeeklyGoalsService.WeeklyGoal(
            goal_id          = string(get(g, :goal_id, "")),
            goal_description = string(get(g, :goal_description, "")),
            priority         = Int(get(g, :priority, 3)),
            completed        = false,
            workstream       = string(get(g, :workstream, ""))
        )
        for g in arr
    ]
end

# ---------------------------
# Public entry point
# ---------------------------

function suggest_weekly_goals(target_week::String)
    ctx    = gather_context(target_week)
    prompt = build_prompt(ctx)

    @info "[LLMGoalAssistant] Sending prompt to LLM" week=target_week prompt_chars=length(prompt)

    response = LLMSummarizer.generate_summary(prompt)

    @info "[LLMGoalAssistant] Response received" response_chars=length(response)

    goals   = parse_goals_from_response(response)
    summary = build_context_summary(ctx)

    @info "[LLMGoalAssistant] Goals parsed" count=length(goals)

    return goals, summary
end

end # module
