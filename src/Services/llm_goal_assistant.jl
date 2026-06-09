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

export suggest_workstreams, suggest_goals_for_workstreams
export suggest_weekly_goals, build_context_summary
export is_relevant_workstream

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

function is_relevant_workstream(ws::String)::Bool
    lower_ws = lowercase(ws)
    return !(occursin("client", lower_ws) || occursin("r&d", lower_ws) || occursin("r & d", lower_ws))
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

    workstreams = WeeklyGoalsService.load_workstreams()
    relevant_workstreams = filter(is_relevant_workstream, workstreams)

    return (
        roster       = roster,
        target_week  = target_week,
        prev_week    = prev_week,
        curr_entries = curr_entries,
        prev_entries = prev_entries,
        prev_goals   = prev_goals,
        report_text  = report_text,
        workstreams  = workstreams,
        relevant_workstreams = relevant_workstreams
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
# Prompt building - Step 1: Workstreams
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

function build_workstreams_prompt(ctx, user_context::String="")::String
    lines = String[]

    push!(lines, "You are a project manager assistant. Suggest workstreams to focus on for $(ctx.target_week).")
    push!(lines, "Base your suggestions on team availability, ongoing work, and last week's outcomes.")
    push!(lines, "Exclude Client Support and R&D workstreams - those are handled separately.")
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

    if !isempty(user_context)
        push!(lines, "## User Priorities for This Week")
        push!(lines, user_context)
        push!(lines, "")
    end

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
    push!(lines, "Suggest 2-5 workstreams for $(ctx.target_week) based on:")
    push!(lines, "- Last week's work patterns and incomplete goals")
    push!(lines, "- The user priorities provided above (if any)")
    push!(lines, "- What makes sense given team capacity")
    push!(lines, "")
    push!(lines, "Output ONLY a JSON array of workstream names. Strict rules:")
    push!(lines, "1. Output ONLY the raw JSON array - no prose, no markdown fences, no comments, no thinking.")
    push!(lines, "2. Workstreams should be specific and actionable (e.g., 'API Integration' not 'General Development').")
    push!(lines, "3. Exclude Client Support and R&D.")
    push!(lines, "4. You may suggest existing workstreams from history or propose new ones if they fit the context.")
    push!(lines, "")
    push!(lines, "Required output format:")
    push!(lines, """["Workstream 1", "Workstream 2", "Workstream 3"]""")
    push!(lines, "/no_think")

    return join(lines, "\n")
end

# ---------------------------
# Prompt building - Step 2: Goals
# ---------------------------

function build_goals_for_workstreams_prompt(ctx, selected_workstreams::Vector{String}, user_context::String="")::String
    lines = String[]

    push!(lines, "You are a project manager assistant. Suggest specific weekly goals for $(ctx.target_week).")
    push!(lines, "")

    push!(lines, "## Focus Workstreams")
    for ws in selected_workstreams
        push!(lines, "- $ws")
    end
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

    if !isempty(user_context)
        push!(lines, "## User Priorities for This Week")
        push!(lines, user_context)
        push!(lines, "")
    end

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
    push!(lines, "For EACH of the $(length(selected_workstreams)) workstreams listed above, suggest 1-5 specific, actionable goals for $(ctx.target_week).")
    push!(lines, "")
    push!(lines, "Strict rules:")
    push!(lines, "1. Output ONLY a raw JSON array - no prose, no markdown fences, no comments, no thinking.")
    push!(lines, "2. Every string value must be properly quoted valid JSON.")
    push!(lines, "3. For EACH workstream, create 1-5 specific goals (NOT generic like 'finish all open tasks').")
    push!(lines, "4. Goals should be concrete and measurable (e.g., 'Complete OAuth integration test suite' not 'Work on auth').")
    push!(lines, "5. Incorporate User Priorities if provided above.")
    push!(lines, "6. Consider last week's incomplete goals - either complete them or adjust scope.")
    push!(lines, "7. Assign priorities 1 (highest) to 5 (lowest).")
    push!(lines, "8. Do NOT assign goals to individual members - assign to workstreams.")
    push!(lines, "9. Match each goal to one of the selected workstreams above.")
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

function parse_workstreams_from_response(response::String)::Vector{String}
    @info "[LLMGoalAssistant] Parsing workstreams from response" preview=first(response, 500)

    if isempty(strip(response))
        error("LLM returned empty response. Check if the model is installed (ollama pull <model>) or if Ollama is running.")
    end

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
    
    return [string(ws) for ws in arr]
end

function parse_goals_from_response(response::String)::Vector{WeeklyGoalsService.WeeklyGoal}
    @info "[LLMGoalAssistant] Parsing goals from response" preview=first(response, 500)

    cleaned = strip_think_blocks(response)
    cleaned = strip(replace(replace(cleaned, r"```[a-z]*" => ""), "```" => ""))

    # Try to find JSON array first [...]
    json_start = findfirst('[', cleaned)
    json_end   = findlast(']', cleaned)
    
    # If no array brackets found, try single object {...}
    if json_start === nothing || json_end === nothing
        json_start = findfirst('{', cleaned)
        json_end   = findlast('}', cleaned)
        
        if json_start === nothing || json_end === nothing
            @error "[LLMGoalAssistant] No JSON found in LLM response" preview=first(cleaned, 500)
            error("LLM response did not contain valid JSON. Preview: $(first(cleaned, 300))")
        end
        
        # Single object - parse and wrap in array
        json_str = cleaned[json_start:json_end]
        @info "[LLMGoalAssistant] Extracted single JSON object, wrapping in array" preview=first(json_str, 300)
        
        obj = JSON3.read(json_str)
        return [
            WeeklyGoalsService.WeeklyGoal(
                goal_id          = string(get(obj, :goal_id, "")),
                goal_description = string(get(obj, :goal_description, "")),
                priority         = Int(get(obj, :priority, 3)),
                completed        = false,
                workstream       = string(get(obj, :workstream, ""))
            )
        ]
    end

    # Array found
    json_str = cleaned[json_start:json_end]
    @info "[LLMGoalAssistant] Extracted JSON array" preview=first(json_str, 300)

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
# Public entry points - Two Step Workflow
# ---------------------------

function suggest_workstreams(target_week::String, user_context::String="")
    ctx    = gather_context(target_week)
    prompt = build_workstreams_prompt(ctx, user_context)

    @info "[LLMGoalAssistant] Step 1: Suggesting workstreams" week=target_week prompt_chars=length(prompt)

    llm = LLMSummarizer.get_llm_from_settings()
    response = LLMSummarizer.generate(llm, prompt; think=false)

    @info "[LLMGoalAssistant] Workstreams response received" response_chars=length(response)

    workstreams = parse_workstreams_from_response(response)
    summary = build_context_summary(ctx)

    @info "[LLMGoalAssistant] Workstreams parsed" count=length(workstreams)

    return workstreams, summary, ctx
end

function suggest_goals_for_workstreams(target_week::String, selected_workstreams::Vector{String}, user_context::String="")
    ctx    = gather_context(target_week)
    prompt = build_goals_for_workstreams_prompt(ctx, selected_workstreams, user_context)

    @info "[LLMGoalAssistant] Step 2: Suggesting goals" week=target_week workstreams=length(selected_workstreams) prompt_chars=length(prompt)

    llm = LLMSummarizer.get_llm_from_settings()
    response = LLMSummarizer.generate(llm, prompt; think=false, format="json")

    @info "[LLMGoalAssistant] Goals response received" response_chars=length(response)

    goals = parse_goals_from_response(response)

    @info "[LLMGoalAssistant] Goals parsed" count=length(goals)

    return goals, ctx
end

# ---------------------------
# Legacy single-step entry point (kept for compatibility)
# ---------------------------

function suggest_weekly_goals(target_week::String, user_context::String="")
    # First suggest workstreams
    workstreams, summary, ctx = suggest_workstreams(target_week, user_context)
    
    # Filter to relevant workstreams only
    relevant = filter(is_relevant_workstream, workstreams)
    
    if isempty(relevant)
        @warn "[LLMGoalAssistant] No relevant workstreams suggested"
        return WeeklyGoalsService.WeeklyGoal[], summary
    end
    
    # Then suggest goals for those workstreams
    goals, _ = suggest_goals_for_workstreams(target_week, relevant, user_context)
    
    return goals, summary
end

end # module
