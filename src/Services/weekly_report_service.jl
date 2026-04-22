module WeeklyReportService

using Dates
using Logging

using ..Config
using ..Domain: Task, ExecutionState, allocation_to_label
using ..DailyModel: DailyData
using ..DailyService
using ..WeeklyGoalsService

export generate_weekly_report_text, save_weekly_report
export iso_week_to_monday

function iso_week_to_monday(week_str::String)::Date
    m = match(r"^(\d+)-W(\d+)$", week_str)
    m === nothing && error("Invalid week format. Use YYYY-WNN")
    y = parse(Int, m.captures[1])
    w = parse(Int, m.captures[2])

    # ISO week 1 always contains Jan 4
    jan4 = Date(y, 1, 4)
    monday_week1 = jan4 - Day(dayofweek(jan4) - 1)
    return monday_week1 + Week(w - 1)
end

function split_items(desc::AbstractString)::Vector{String}
    parts = split(String(desc), ';')
    return [strip(p) for p in parts if !isempty(strip(p))]
end

function task_items_for_day(data::DailyData)
    items = Dict{String, Dict{Symbol, Any}}()

    for e in data.entries
        member = e.member.name
        for t in e.tasks
            for item_desc in split_items(t.description)
                key = item_desc
                if !haskey(items, key)
                    items[key] = Dict(
                        :members => Set{String}(),
                        :goal_ids => Set{String}(),
                        :allocations => Set{String}(),
                        :states => Set{ExecutionState}(),
                        :has_blocker => false
                    )
                end

                push!(items[key][:members], member)
                if t.goal_id !== nothing && !isempty(t.goal_id)
                    push!(items[key][:goal_ids], t.goal_id)
                end
                push!(items[key][:allocations], string(t.allocation))
                push!(items[key][:states], t.execution_state)
                if t.blocker !== nothing && !isempty(String(t.blocker))
                    items[key][:has_blocker] = true
                end
            end
        end
    end

    return items
end

function load_day(date::Date)::Union{DailyData, Nothing}
    return DailyService.load_daily_data(string(date))
end

function working_days_for_week(monday::Date)::Vector{Date}
    return [monday + Day(i) for i in 0:4]
end

function next_working_day(d::Date)::Date
    nd = d + Day(1)
    while dayofweek(nd) in (6, 7)
        nd += Day(1)
    end
    return nd
end

function infer_completed_items(day_dates::Vector{Date}, day_items::Vector{Dict{String, Dict{Symbol, Any}}})
    completed = Dict{String, Date}()

    for i in 1:(length(day_dates) - 1)
        curr = day_items[i]
        nxt = day_items[i + 1]

        for key in keys(curr)
            if !haskey(nxt, key)
                completed[key] = day_dates[i]
            end
        end
    end

    # Friday -> next working day (usually next Monday) if data exists
    last_date = day_dates[end]
    last_items = day_items[end]
    lookahead_date = next_working_day(last_date)
    lookahead_data = load_day(lookahead_date)
    if lookahead_data !== nothing
        lookahead_items = task_items_for_day(lookahead_data)
        for key in keys(last_items)
            if !haskey(lookahead_items, key)
                completed[key] = last_date
            end
        end
    end

    return completed
end

function generate_weekly_report_text(week_str::String)::String
    monday = iso_week_to_monday(week_str)
    days = working_days_for_week(monday)

    day_data = DailyData[]
    day_dates = Date[]
    day_items = Vector{Dict{String, Dict{Symbol, Any}}}()

    for d in days
        data = load_day(d)
        if data === nothing
            continue
        end
        push!(day_data, data)
        push!(day_dates, d)
        push!(day_items, task_items_for_day(data))
    end

    if isempty(day_dates)
        return "WEEKLY REPORT ($week_str)\n====================\n\nNo daily data found for this week." 
    end

    completed = infer_completed_items(day_dates, day_items)

    all_keys = Set{String}()
    for items in day_items
        union!(all_keys, keys(items))
    end

    last_day_keys = Set(keys(day_items[end]))
    completed_keys = Set(keys(completed))
    active_keys = setdiff(all_keys, completed_keys)

    blockers = String[]
    for items in day_items
        for (k, meta) in items
            if get(meta, :has_blocker, false)
                push!(blockers, k)
            end
        end
    end
    blockers = unique(blockers)

    # Weekly goals progress (optional)
    goals_data = WeeklyGoalsService.load_weekly_goals_data(week_str)
    goals = goals_data.goals

    goal_lines = String[]
    for g in goals
        gid = g.goal_id
        linked = String[]
        for key in all_keys
            for items in day_items
                if haskey(items, key) && (gid in items[key][:goal_ids])
                    push!(linked, key)
                    break
                end
            end
        end
        linked = unique(linked)
        linked_completed = [k for k in linked if k in completed_keys]
        linked_active = [k for k in linked if k in active_keys]

        push!(goal_lines, "- [$(g.workstream)] $(g.goal_id): $(g.goal_description)")
        push!(goal_lines, "  Linked tasks: $(length(linked)) | Completed: $(length(linked_completed)) | Remaining: $(length(linked_active))")
    end

    lines = String[]
    push!(lines, "WEEKLY REPORT ($week_str)")
    push!(lines, "====================")
    push!(lines, "")
    push!(lines, "Range: $(string(day_dates[1])) to $(string(day_dates[end])) (Mon-Fri)")
    push!(lines, "")

    push!(lines, "Summary")
    push!(lines, "-------")
    push!(lines, "Completed (inferred): $(length(completed_keys))")
    push!(lines, "Still active: $(length(active_keys))")
    push!(lines, "Blockers mentioned: $(length(blockers))")
    push!(lines, "")

    push!(lines, "Completed tasks")
    push!(lines, "--------------")
    if isempty(completed_keys)
        push!(lines, "(none)")
    else
        for k in sort(collect(completed_keys))
            push!(lines, "- $k")
        end
    end
    push!(lines, "")

    push!(lines, "Still active tasks")
    push!(lines, "-----------------")
    if isempty(active_keys)
        push!(lines, "(none)")
    else
        for k in sort(collect(active_keys))
            push!(lines, "- $k")
        end
    end
    push!(lines, "")

    push!(lines, "Blockers")
    push!(lines, "--------")
    if isempty(blockers)
        push!(lines, "(none)")
    else
        for k in sort(blockers)
            push!(lines, "- $k")
        end
    end
    push!(lines, "")

    push!(lines, "Weekly goals progress")
    push!(lines, "--------------------")
    if isempty(goal_lines)
        push!(lines, "(no goals)")
    else
        append!(lines, goal_lines)
    end

    return join(lines, "\n")
end

function save_weekly_report(week_str::String; dir::String=Config.WEEKLY_REPORTS_DIR)
    Config.ensure_directories()
    report_text = generate_weekly_report_text(week_str)
    path = joinpath(dir, week_str * ".txt")
    open(path, "w") do io
        write(io, report_text)
    end
    @info "[WeeklyReport] Saved" week=week_str path=path
    return path
end

end
