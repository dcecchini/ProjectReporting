using GenieFramework
@genietools

using Dates
using JSON3

using ProjectReporting.Config
using ProjectReporting.Domain: Task, TeamMember, Allocation, ExecutionState, ALLOCATION_ORDER, allocation_to_string, execution_state_to_string, allocation_from_string, execution_state_from_string, allocation_to_label
using ProjectReporting.DailyModel
using ProjectReporting.DailyService
using ProjectReporting.LoggingConfig
using ProjectReporting.TeamsService
using ProjectReporting.ReportService
using ProjectReporting.WeeklyGoalsService

include("ui.jl")
using .UI

import Base.deepcopy


Genie.config.run_as_server = true
LoggingConfig.init_logger()


function weekly_goal_options_for_date(date_str::String)
    try
        week = Config.iso_week_string(Date(date_str))
        data = WeeklyGoalsService.load_weekly_goals_data(week)
        opts = String[""]
        append!(opts, [g.goal_id for g in data.goals])
        return unique(opts)
    catch e
        @error "[WeeklyGoals] Failed to load weekly goal options; falling back to defaults" date=date_str exception=(e, catch_backtrace())
        return String["", "CLIENT_SUPPORT", "R_AND_D"]
    end
end

function next_weekly_goal_id(goals::Vector{UI.WeeklyGoalVM})::String
    max_n = 0
    for g in goals
        m = match(r"^G-(\d+)$", g.goal_id)
        if m !== nothing
            n = tryparse(Int, m.captures[1])
            if n !== nothing
                max_n = max(max_n, n)
            end
        end
    end
    return "G-" * lpad(string(max_n + 1), 3, '0')
end


function ensure_vector(x)
    x isa AbstractVector ? collect(x) : [x]
end

function get_array_param(p, name)
    return get(p, Symbol(name * "[]"), nothing)
end

# -----------------------------------------
# Helper: parse entries from form
# -----------------------------------------
function parse_entries(p)
    members = p[Symbol("member[]")]
    allocations = p[Symbol("allocation[]")]
    states = p[Symbol("execution_state[]")]
    descriptions = p[Symbol("description[]")]
    blockers = p[Symbol("blocker[]")]
    goal_ids = get_array_param(p, "goal_id")

    n = length(descriptions)

    entries_map = Dict{String, Vector{Task}}()

    for i in 1:n
        member = members[i]

        task = Task(
            goal_ids === nothing ? nothing : (isempty(goal_ids[i]) ? nothing : goal_ids[i]),
            descriptions[i],
            allocation_from_string(allocations[i]),
            execution_state_from_string(states[i]),
            String[],
            isempty(blockers[i]) ? nothing : blockers[i]
        )

        push!(get!(entries_map, member, Task[]), task)
    end

    return [
        DailyEntry(TeamMember(member), tasks)
        for (member, tasks) in entries_map
    ]
end

function ui_weekly_goals()
    [
        h1("Project Reporting Tool - {{project_name}}"),
        h2("Weekly Goals"),

        row(class="items-center q-gutter-sm q-mb-md", [
            Html.a("Daily", href="/daily", class="text-primary")
        ]),

        row(class="items-center q-gutter-sm q-mb-md", [
            textfield("Week (YYYY-WNN)", :selected_week, dense=true, outlined=true),
            btn("Load", @click(:load_weekly_goals), color="primary"),
            btn("Save", @click(:save_weekly_goals), color="primary"),
            btn("+ Goal", @click(:add_weekly_goal), color="secondary")
        ]),

        row(class="items-center q-gutter-sm q-mb-md", [
            textfield("New Workstream", :new_workstream, dense=true, outlined=true),
            btn("Add Workstream", @click(:add_workstream), color="secondary")
        ]),

        card(class="q-pa-md", [
            p("No goals for this week.", @showif("weekly_goals.length === 0"), class="text-grey"),
            Html.div(@recur(:"(g, gi) in weekly_goals"), [
                Html.div(class="row items-center q-gutter-sm q-mb-sm", [
                    Html.div(class="col-2", [textfield("Goal ID", R"g.goal_id", dense=true, outlined=true, readonly=true)]),
                    Html.div(class="col-5", [textfield("Description", R"g.goal_description", dense=true, outlined=true)]),
                    Html.div(class="col-2", [Stipple.select(R"g.workstream", options=:workstream_options, dense=true, outlined=true, label="Workstream")]),
                    Html.div(class="col-1", [textfield("Priority", R"g.priority", dense=true, outlined=true, type="number")]),
                    Html.div(class="col-1", [Stipple.select(R"g.completed", options=["false", "true"], dense=true, outlined=true, label="Completed")]),
                    Html.div(class="col-1", [btn("", icon="delete", @click("delete_weekly_goal_index = gi + 1"), color="negative", flat=true, round=true, size="sm")])
                ])
            ])
        ])
    ]
end

function to_vm(data::DailyData)
    UI.MemberVM[
        UI.MemberVM(
            name = e.member.name,
            tasks = [
                UI.TaskVM(
                    goal_id = something(t.goal_id, ""),
                    description = t.description,
                    allocation = allocation_to_string(t.allocation),
                    execution_state = execution_state_to_string(t.execution_state),
                    blocker = something(t.blocker, "")
                )
                for t in e.tasks
            ]
        )
        for e in data.entries
    ]
end

function from_vm(members::Vector{UI.MemberVM})
    DailyEntry[
        DailyEntry(
            TeamMember(m.name),
            Task[
                Task(
                    isempty(t.goal_id) ? nothing : t.goal_id,
                    t.description,
                    allocation_from_string(t.allocation),
                    execution_state_from_string(t.execution_state),
                    String[],
                    isempty(t.blocker) ? nothing : t.blocker
                )
                for t in m.tasks
            ]
        )
        for m in members
    ]
end

function group_by_allocation(members_vm)
    tmp = Dict{String, Vector{Tuple{String, UI.TaskVM}}}()

    for m in members_vm
        for t in m.tasks
            alloc = t.allocation
            get!(tmp, alloc, Tuple{String, UI.TaskVM}[])
            push!(tmp[alloc], (m.name, t))
        end
    end

    return tmp
end

function compute_grouping(members::Vector{UI.MemberVM})
    # Build dict first
    grouped_dict = Dict{String, Vector{Tuple{String, UI.TaskVM}}}()
    for m in members
        for t in m.tasks
            key = t.allocation
            push!(get!(grouped_dict, key, []), (m.name, t))
        end
    end

    # Convert to ordered array based on ALLOCATION_ORDER
    ordered = Vector{Tuple{String, Vector{Tuple{String, UI.TaskVM}}}}()
    for alloc in ALLOCATION_ORDER
        key = allocation_to_string(alloc)
        if haskey(grouped_dict, key)
            push!(ordered, (key, grouped_dict[key]))
        end
    end

    # Add any remaining allocations not in ALLOCATION_ORDER
    for (key, items) in grouped_dict
        if !any(x -> x[1] == key, ordered)
            push!(ordered, (key, items))
        end
    end

    return ordered
end

# Build options from enums
const ALLOCATION_OPTIONS = [allocation_to_string(a) for a in instances(Allocation)]
const EXECUTION_STATE_OPTIONS = [execution_state_to_string(e) for e in instances(ExecutionState)]
const ALLOCATION_LABELS_MAP = Dict(allocation_to_string(a) => allocation_to_label(a) for a in instances(Allocation))

@app begin
    # Reactive state variables
    @in date::String = string(today())
    @in members::Vector{UI.MemberVM} = UI.MemberVM[]
    @out grouped::Vector{Tuple{String, Vector{Tuple{String, UI.TaskVM}}}} = []
    @out preview::String = ""
    @in mode::String = "member"
    @out project_name::String = Config.PROJECT_NAME

    @out weekly_goal_options::Vector{String} = weekly_goal_options_for_date(string(today()))

    @out workstream_options::Vector{String} = WeeklyGoalsService.load_workstreams()
    @in new_workstream::String = ""
    @in add_workstream::Bool = false

    # Weekly goals
    @in selected_week::String = Config.iso_week_string(today())
    @in weekly_goals::Vector{UI.WeeklyGoalVM} = UI.WeeklyGoalVM[]
    @in add_weekly_goal::Bool = false
    @in delete_weekly_goal_index::Int = 0
    @in load_weekly_goals::Bool = false
    @in save_weekly_goals::Bool = false
    
    # Options from domain enums and config
    @out allocation_options::Vector{String} = ALLOCATION_OPTIONS
    @out execution_state_options::Vector{String} = EXECUTION_STATE_OPTIONS
    @out allocation_labels::Dict{String, String} = ALLOCATION_LABELS_MAP
    @out team_members::Vector{String} = Config.TEAM_MEMBERS
    
    # Button triggers
    @in add_task::Int = 0
    @in add_task_member::String = ""
    @in delete_task_member::Int = 0
    @in delete_task_index::Int = 0
    @in load::Bool = false
    @in load_previous::Bool = false
    @in save::Bool = false
    @in generate::Bool = false
    @in send::Bool = false

    # -----------------------------
    # INIT
    # -----------------------------
    @onchange isready begin
        @info "Loading data for date: $date"
        data = DailyService.get_or_create_daily(date, Config.TEAM_MEMBERS)
        @info "Loaded $(length(data.entries)) entries"
        members = to_vm(data)
        @info "Converted to $(length(members)) members"
        @push members
        grouped = compute_grouping(members)
        @push grouped

        weekly_goal_options = weekly_goal_options_for_date(date)
        @push weekly_goal_options

        workstream_options = WeeklyGoalsService.load_workstreams()
        @push workstream_options
    end

    @onchange date begin
        try
            weekly_goal_options = weekly_goal_options_for_date(date)
            @push weekly_goal_options
        catch e
            @error "[WeeklyGoals] Failed to refresh options for date" date=date exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # GROUPING REFRESH
    # -----------------------------
    @onchange members begin
        grouped = compute_grouping(members)
    end

    # -----------------------------
    # ADD TASK
    # -----------------------------
    @onchange add_task begin
        if add_task > 0
            push!(members[add_task].tasks, UI.TaskVM())
            members = copy(members)  # trigger reactivity
            add_task = 0  # reset so same member can be selected again
        end
    end

    # -----------------------------
    # DELETE TASK
    # -----------------------------
    @onchange delete_task_index begin
        if delete_task_member > 0 && delete_task_index > 0
            deleteat!(members[delete_task_member].tasks, delete_task_index)
            members = copy(members)  # trigger reactivity
            delete_task_member = 0
            delete_task_index = 0
        end
    end

    # -----------------------------
    # LOAD
    # -----------------------------
    @onbutton load begin
        @info "Loading data for date: $date"
        data = DailyService.get_or_create_daily(date, Config.TEAM_MEMBERS)
        @info "Loaded $(length(data.entries)) entries"
        members = to_vm(data)
        grouped = compute_grouping(members)
        preview = ""
        @push members
        @push grouped
        @push preview

        weekly_goal_options = weekly_goal_options_for_date(date)
        @push weekly_goal_options
    end

    # -----------------------------
    # LOAD PREVIOUS DAY TASKS
    # -----------------------------
    @onbutton load_previous begin
        @info "Loading previous day tasks for date: $date"
        data = DailyService.get_previous_data(
            Date(date),
            Config.DAILY_DATA_DIR,
            Config.TEAM_MEMBERS
        )
        @info "Loaded $(length(data.entries)) entries"
        members = to_vm(data)
        grouped = compute_grouping(members)
        preview = ""
        @push members
        @push grouped
        @push preview

        weekly_goal_options = weekly_goal_options_for_date(date)
        @push weekly_goal_options
    end

    # -----------------------------
    # SAVE
    # -----------------------------
    @onbutton save begin
        entries = from_vm(members)
        DailyService.save_daily_entries(date, entries)
    end

    # -----------------------------
    # GENERATE
    # -----------------------------
    @onbutton generate begin
        try
            @info "[Generate] Starting generation..."
            entries = from_vm(members)
            @info "[Generate] Converted $(length(entries)) entries"

            prev = DailyService.get_previous_data(
                Date(date),
                Config.DAILY_DATA_DIR,
                Config.TEAM_MEMBERS
            )
            @info "[Generate] Previous data: $(length(prev.entries)) entries"

            report = ReportService.generate_report(
                date,
                entries,
                prev.entries
            )
            @info "[Generate] Report generated"

            preview_text = ReportService.render_text_report(report)
            @info "[Generate] Preview length: $(length(preview_text))"
            preview = preview_text
        catch e
            @error "[Generate] Error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # SEND
    # -----------------------------
    @onbutton send begin
        try
            @info "[Send] Starting send..." date=date

            entries = from_vm(members)
            @info "[Send] Converted $(length(entries)) entries"

            prev = DailyService.get_previous_data(
                Date(date),
                Config.DAILY_DATA_DIR,
                Config.TEAM_MEMBERS
            )
            @info "[Send] Previous data: $(length(prev.entries)) entries"

            report = ReportService.generate_report(
                date,
                entries,
                prev.entries
            )
            @info "[Send] Report generated"

            status = TeamsService.send_to_teams(report)
            @info "[Send] Teams send complete" status=status
        catch e
            @error "[Send] Error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # WEEKLY GOALS - LOAD
    # -----------------------------
    @onbutton load_weekly_goals begin
        try
            @info "[WeeklyGoals] Loading" week=selected_week
            data = WeeklyGoalsService.load_weekly_goals_data(selected_week)

            workstream_options = WeeklyGoalsService.load_workstreams()
            @push workstream_options

            weekly_goals = UI.WeeklyGoalVM[
                UI.WeeklyGoalVM(
                    goal_id = g.goal_id,
                    goal_description = g.goal_description,
                    priority = g.priority,
                    completed = g.completed ? "true" : "false",
                    workstream = g.workstream
                )
                for g in data.goals
            ]
            @push weekly_goals

            if Config.iso_week_string(Date(date)) == selected_week
                weekly_goal_options = weekly_goal_options_for_date(date)
                @push weekly_goal_options
            end
        catch e
            @error "[WeeklyGoals] Load error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # WEEKLY GOALS - SAVE
    # -----------------------------
    @onbutton save_weekly_goals begin
        try
            @info "[WeeklyGoals] Saving" week=selected_week goals=length(weekly_goals)
            goals = WeeklyGoalsService.WeeklyGoal[
                WeeklyGoalsService.WeeklyGoal(
                    goal_id = g.goal_id,
                    goal_description = g.goal_description,
                    priority = Int(g.priority),
                    completed = lowercase(strip(g.completed)) == "true",
                    workstream = g.workstream
                )
                for g in weekly_goals
            ]
            data = WeeklyGoalsService.WeeklyGoalsData(1, selected_week, goals)
            WeeklyGoalsService.save_weekly_goals_data(data)

            if Config.iso_week_string(Date(date)) == selected_week
                weekly_goal_options = weekly_goal_options_for_date(date)
                @push weekly_goal_options
            end
        catch e
            @error "[WeeklyGoals] Save error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # WORKSTREAMS - ADD
    # -----------------------------
    @onbutton add_workstream begin
        try
            workstream_options = WeeklyGoalsService.add_workstream(new_workstream)
            new_workstream = ""
            @push workstream_options
            @push new_workstream
        catch e
            @error "[WeeklyGoals] Add workstream error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # WEEKLY GOALS - ADD
    # -----------------------------
    @onbutton add_weekly_goal begin
        try
            ws_default = isempty(workstream_options) ? "" : workstream_options[1]
            push!(weekly_goals, UI.WeeklyGoalVM(
                goal_id = next_weekly_goal_id(weekly_goals),
                workstream = ws_default
            ))
            weekly_goals = copy(weekly_goals)
            @push weekly_goals
        catch e
            @error "[WeeklyGoals] Add error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # WEEKLY GOALS - DELETE
    # -----------------------------
    @onchange delete_weekly_goal_index begin
        if delete_weekly_goal_index > 0
            try
                deleteat!(weekly_goals, delete_weekly_goal_index)
                weekly_goals = copy(weekly_goals)
                delete_weekly_goal_index = 0
                @push weekly_goals
            catch e
                @error "[WeeklyGoals] Delete error" exception=(e, catch_backtrace())
            end
        end
    end
end

# -----------------------------
# UI FUNCTION  
# -----------------------------
function ui()
    [
        h1("Project Reporting Tool - {{project_name}}"),
        h2("{{date}} Tasks"),

        row(class="items-center q-gutter-sm q-mb-md", [
            Html.a("Weekly Goals", href="/weekly_goals", class="text-primary")
        ]),

        row(class="items-center q-gutter-sm q-mb-md", [
            textfield("Date", :date, dense=true, outlined=true, type="date"),
            btn("Load", @click(:load), color="primary"),
            btn("Load Previous Day Tasks", @click(:load_previous), color="secondary")
        ]),

        p("Members: {{members.length}}"),
        
        # Mode toggle
        row([
            btn("By Allocation", @click("mode = 'allocation'"), color="primary"),
            btn("By Member", @click("mode = 'member'"), color="primary")
        ]),
        
        separator(),
        
        # Blockers section
        card(class="q-pa-md q-mb-md", [
            h2("⚠ Blockers"),
            Html.div(@recur(:"m in members"), [
                Html.div(@recur(:"(t, ti) in m.tasks"), [
                    Html.div(@showif("t.blocker && t.blocker.trim() !== ''"), [
                        Html.span("⚠ {{m.name}} — {{t.blocker}}")
                    ])
                ])
            ]),
            p("No blockers reported.", @showif("!members.some(m => m.tasks.some(t => t.blocker && t.blocker.trim() !== ''))"), class="text-grey")
        ]),
        
        separator(),
        
        # Allocation view
        card(class="q-pa-md", @showif("mode === 'allocation'"), [
            h2("📦 By Allocation"),
            
            p("No tasks to display.", @showif("grouped.length === 0")),
            
            Html.div(@recur(:"group in grouped"), [
                h3("{{allocation_labels[group[0]] || group[0]}}"),
                Html.table(class="q-table q-table--flat q-table--bordered q-table--dense", [
                    Html.thead([
                        Html.tr([
                            Html.th("Member", style="width: 120px;"),
                            Html.th("Description", style="width: 300px;"),
                            Html.th("State", style="width: 120px;"),
                            Html.th("Blocker", style="width: 150px;")
                        ])
                    ]),
                    Html.tbody([
                        Html.tr(@recur(:"(item, idx) in group[1]"), [
                            Html.td("{{item[0]}}"),
                            Html.td([textfield("", R"item[1].description", dense=true, borderless=true)]),
                            Html.td([Stipple.select(R"item[1].execution_state", options=:execution_state_options, dense=true, borderless=true)]),
                            Html.td([textfield("", R"item[1].blocker", dense=true, borderless=true)])
                        ])
                    ])
                ])
            ])
        ]),
        
        # Member view
        card(class="q-pa-md", @showif("mode === 'member'"), [
            h2("👤 By Member"),
            
            # Show message if no members
            p("No members loaded.", @showif("members.length === 0")),
            
            card(class="q-mb-md", @recur(:"(m, mIndex) in members"), [
                card_section([
                    h3("{{m.name}}")
                ]),
                card_section([
                    Html.div(class="row items-center q-gutter-sm q-mb-sm", @recur(:"(t, tIndex) in m.tasks"), [
                        Html.div(class="col-3", [
                            textfield("Description", R"t.description", dense=true, outlined=true)
                        ]),
                        Html.div(class="col-1", [
                            Stipple.select(R"t.goal_id", options=:weekly_goal_options, dense=true, outlined=true, label="Goal")
                        ]),
                        Html.div(class="col-2", [
                            Stipple.select(R"t.allocation", options=:allocation_options, dense=true, outlined=true, label="Allocation")
                        ]),
                        Html.div(class="col-2", [
                            Stipple.select(R"t.execution_state", options=:execution_state_options, dense=true, outlined=true, label="State")
                        ]),
                        Html.div(class="col-2", [
                            textfield("Blocker", R"t.blocker", dense=true, outlined=true)
                        ]),
                        Html.div(class="col-1", [
                            btn("", icon="delete", @click("delete_task_member = mIndex + 1; delete_task_index = tIndex + 1"), color="negative", flat=true, round=true, size="sm")
                        ])
                    ])
                ]),
                card_actions([
                    btn("+ Task", @click("add_task = mIndex + 1"), color="secondary", size="sm")
                ])
            ])
        ]),
        
        separator(),
        
        # Actions
        row(class="q-gutter-sm", [
            btn("Save", @click(:save), color="primary"),
            btn("Generate", @click(:generate), color="primary"),
            btn("Send", @click(:send), color="primary")
        ]),
        
        # Preview
        card(class="q-mt-md", @showif("preview && preview.length > 0"), [
            card_section([
                h3("Preview")
            ]),
            card_section([
                Html.pre("{{preview}}")
            ])
        ])
    ]
end

@page("/daily", ui)

@page("/weekly_goals", ui_weekly_goals)

Genie.up()
