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

# JSON schema passed to Ollama `format` field for structured output
const GOALS_JSON_SCHEMA = Dict{String,Any}(
    "type" => "array",
    "items" => Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "goal_id"          => Dict("type" => "string"),
            "goal_description" => Dict("type" => "string"),
            "priority"         => Dict("type" => "integer"),
            "completed"        => Dict("type" => "boolean"),
            "workstream"       => Dict("type" => "string")
        ),
        "required" => ["goal_id", "goal_description", "priority", "completed", "workstream"],
        "additionalProperties" => false
    )
)

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

    push!(lines, "## Task")
    push!(lines, "Produce ONLY a JSON array of weekly goals for $(ctx.target_week). Strict rules:")
    push!(lines, "1. Output ONLY the raw JSON array - no prose, no markdown fences, no comments, no thinking.")
    push!(lines, "2. Every string value must be properly quoted valid JSON.")
    push!(lines, "3. Propose a realistic number of goals based on team capacity.")
    push!(lines, "4. You may introduce new workstreams if they fit the context.")
    push!(lines, "5. Assign priorities 1 (highest) to 5 (lowest).")
    push!(lines, "6. Do NOT assign goals to individual members - assign to workstreams.")
    push!(lines, "")
    push!(lines, "Required output format - exactly these five fields per element:")
    push!(lines, """[
  {
    "goal_id": "G-001",
    "goal_description": "Short plain-English description",
    "priority": 1,
    "completed": false,
    "workstream": "WorkstreamName"
  }
]
/no_think""")

    return join(lines, "\n")
end

# ---------------------------
# Response parsing
# ---------------------------

function strip_think_blocks(s::String)::String
    return replace(s, r"<think>.*?</think>"s => "")
end

function parse_goals_from_response(response::String)::Vector{WeeklyGoalsService.WeeklyGoal}
    @info "[LLMGoalAssistant] Raw response" preview=first(response, 500)

    cleaned = strip_think_blocks(response)
    cleaned = strip(replace(replace(cleaned, r"```[a-z]*" => ""), "```" => ""))

    json_start = findfirst('[', cleaned)
    json_end   = findlast(']', cleaned)

    if json_start === nothing || json_end === nothing
        @error "[LLMGoalAssistant] No JSON array found in LLM response" preview=first(cleaned, 500)
        error("LLM response did not contain a JSON array. Preview: $(first(cleaned, 300))")
    end

    json_str = cleaned[json_start:json_end]
    @info "[LLMGoalAssistant] Extracted JSON" preview=first(json_str, 300)

    arr = JSON3.read(json_str)

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

    response = LLMSummarizer.generate_summary(prompt; think=false, format="json")

    @info "[LLMGoalAssistant] Response received" response_chars=length(response)

    goals   = parse_goals_from_response(response)
    summary = build_context_summary(ctx)

    @info "[LLMGoalAssistant] Goals parsed" count=length(goals)

    return goals, summary
end

end # module
