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
using ProjectReporting.WeeklyReportService
using ProjectReporting.TeamService
using ProjectReporting.LLMGoalAssistant
using ProjectReporting.LLMConfigService

include("UI.jl")
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

function merge_members_with_roster(members_vm::Vector{UI.MemberVM})::Vector{UI.MemberVM}
    roster = TeamService.load_team_roster()
    roster_names = [m.name for m in roster.members]

    by_name = Dict(m.name => m for m in members_vm)

    result = UI.MemberVM[]

    # 1) Roster members first (active + inactive) with metadata
    for rm in roster.members
        if haskey(by_name, rm.name)
            m = by_name[rm.name]
            push!(result, UI.MemberVM(
                name = m.name,
                capacity = rm.capacity,
                active = rm.active ? "true" : "false",
                note = rm.note,
                tasks = m.tasks
            ))
        else
            push!(result, UI.MemberVM(
                name = rm.name,
                capacity = rm.capacity,
                active = rm.active ? "true" : "false",
                note = rm.note,
                tasks = UI.TaskVM[]
            ))
        end
    end

    # 2) Any historical members not in roster, appended (kept readable)
    for m in members_vm
        if !(m.name in roster_names)
            push!(result, UI.MemberVM(
                name = m.name,
                capacity = m.capacity,
                active = m.active,
                note = m.note,
                tasks = m.tasks
            ))
        end
    end

    return result
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

function ui_home()
    [
        h1("Project Reporting Tool - {{project_name}}"),
        h2("Home"),

        card(class="q-pa-md q-mt-md", [
            h3("Pages"),
            row(class="items-center q-gutter-sm", [
                Html.a("Daily", href="/daily", class="text-primary"),
                Html.a("Weekly Goals", href="/weekly_goals", class="text-primary"),
                Html.a("Goals Assistant", href="/weekly_goals_assistant", class="text-primary"),
                Html.a("Team", href="/team", class="text-primary"),
                Html.a("LLM Settings", href="/llm_settings", class="text-primary")
            ])
        ])
    ]
end

function ui_team()
    [
        h1("Project Reporting Tool - {{project_name}}"),
        h2("Team Management"),

        row(class="items-center q-gutter-sm q-mb-md", [
            Html.a("Daily", href="/daily", class="text-primary"),
            Html.a("Weekly Goals", href="/weekly_goals", class="text-primary"),
            Html.a("Goals Assistant", href="/weekly_goals_assistant", class="text-primary"),
            Html.a("LLM Settings", href="/llm_settings", class="text-primary")
        ]),

        row(class="items-center q-gutter-sm q-mb-md", [
            btn("Load", @click(:load_team_roster), color="primary"),
            btn("Save", @click(:save_team_roster), color="primary")
        ]),

        row(class="items-center q-gutter-sm q-mb-md", [
            textfield("New member name", :new_team_member_name, dense=true, outlined=true),
            btn("Add Member", @click(:add_team_member), color="secondary")
        ]),

        card(class="q-pa-md q-mb-md", [
            h3("Active Members"),
            p("No active members.", @showif("team_roster.length === 0 || !team_roster.some(m => m.active === 'true')"), class="text-grey"),
            Html.table(class="q-table q-table--flat q-table--bordered q-table--dense", [
                Html.thead([
                    Html.tr([
                        Html.th("Name"),
                        Html.th("Capacity (%)"),
                        Html.th("Active"),
                        Html.th("Note"),
                        Html.th("")
                    ])
                ]),
                Html.tbody([
                    Html.tr(@recur(:"(m, mi) in team_roster"), @showif("m.active === 'true'"), [
                        Html.td([textfield("", R"m.name", dense=true, borderless=true)]),
                        Html.td([textfield("", R"m.capacity", dense=true, borderless=true, type="number")]),
                        Html.td([Stipple.select(R"m.active", options=["true", "false"], dense=true, borderless=true)]),
                        Html.td([textfield("", R"m.note", dense=true, borderless=true)]),
                        Html.td([btn("", icon="delete", @click("delete_team_member_index = mi + 1"), color="negative", flat=true, round=true, size="sm")])
                    ])
                ])
            ])
        ]),

        card(class="q-pa-md", [
            h3("Inactive / OOO / Other Projects"),
            p("No inactive members.", @showif("team_roster.length === 0 || !team_roster.some(m => m.active === 'false')"), class="text-grey"),
            Html.table(class="q-table q-table--flat q-table--bordered q-table--dense", [
                Html.thead([
                    Html.tr([
                        Html.th("Name"),
                        Html.th("Capacity (%)"),
                        Html.th("Active"),
                        Html.th("Note"),
                        Html.th("")
                    ])
                ]),
                Html.tbody([
                    Html.tr(@recur(:"(m, mi) in team_roster"), @showif("m.active === 'false'"), [
                        Html.td([textfield("", R"m.name", dense=true, borderless=true)]),
                        Html.td([textfield("", R"m.capacity", dense=true, borderless=true, type="number")]),
                        Html.td([Stipple.select(R"m.active", options=["true", "false"], dense=true, borderless=true)]),
                        Html.td([textfield("", R"m.note", dense=true, borderless=true)]),
                        Html.td([btn("", icon="delete", @click("delete_team_member_index = mi + 1"), color="negative", flat=true, round=true, size="sm")])
                    ])
                ])
            ])
        ])
    ]
end

function ui_weekly_goals()
    [
        h1("Project Reporting Tool - {{project_name}}"),
        h2("Weekly Goals & AI Assistant"),

        row(class="items-center q-gutter-sm q-mb-md", [
            Html.a("Daily", href="/daily", class="text-primary"),
            Html.a("Team", href="/team", class="text-primary"),
            Html.a("LLM Settings", href="/llm_settings", class="text-primary")
        ]),

        # Week selector and actions
        row(class="items-center q-gutter-sm q-mb-md", [
            textfield("Week (YYYY-WNN)", :selected_week, dense=true, outlined=true),
            btn("Load", @click(:load_weekly_goals), color="primary"),
            btn("Save", @click(:save_weekly_goals), color="primary"),
            btn("+ Goal", @click(:add_weekly_goal), color="secondary"),
            btn("Generate Report", @click(:generate_weekly_report_btn), color="secondary")
        ]),
        p("{{weekly_report_status}}", @showif("weekly_report_status && weekly_report_status.length > 0"), class="text-caption q-mt-sm"),

        # AI Assistant Section
        separator(),
        h3("🤖 AI Goal Assistant"),

        card(class="q-pa-md q-mb-md", [
            h4("Step 1: Context & Workstreams"),
            row(class="items-start q-gutter-sm q-mb-sm", [
                textfield("Priority / Context (optional): e.g. 'focus on FHIR integration'",
                    :user_context,
                    dense=true,
                    outlined=true,
                    style="width: 100%;")
            ]),
            row(class="items-center q-gutter-sm q-mb-sm", [
                btn("Suggest Workstreams", @click(:suggest_workstreams_step), color="primary")
            ])
        ]),

        # Suggested workstreams selection
        card(class="q-pa-md q-mb-md", @showif("suggested_workstreams.length > 0"), [
            h4("Select Workstreams to Use:"),
            Html.div(@recur(:"(ws, wi) in suggested_workstreams"), [
                Html.div(class="row items-center q-gutter-sm q-mb-sm", [
                    Html.div(class="col-10", [
                        checkbox(R"selected_workstreams.includes(ws)", 
                            label=R"ws",
                            @click("if (selected_workstreams.includes(ws)) { selected_workstreams = selected_workstreams.filter(s => s !== ws); } else { selected_workstreams.push(ws); }"))
                    ])
                ])
            ]),
            row(class="q-mt-md", [
                btn("Step 2: Generate Goals", @click(:suggest_goals_step), color="primary", @showif("selected_workstreams.length > 0"))
            ])
        ]),

        # AI suggested goals (editable before adding)
        card(class="q-pa-md q-mb-md", @showif("suggested_goals.length > 0"), [
            row(class="items-center q-gutter-sm q-mb-md", [
                h4("AI Suggested Goals (Review & Edit)"),
                btn("+ Add to List", @click(:add_suggested_to_weekly), color="secondary", size="sm"),
                btn("Replace All", @click(:replace_with_suggested), color="warning", size="sm")
            ]),
            Html.div(@recur(:"(g, gi) in suggested_goals"), [
                Html.div(class="row items-center q-gutter-sm q-mb-sm", [
                    Html.div(class="col-2",
                        [textfield("Goal ID", R"g.goal_id", dense=true, outlined=true)]),
                    Html.div(class="col-5",
                        [textfield("Description", R"g.goal_description", dense=true, outlined=true)]),
                    Html.div(class="col-2",
                        [textfield("Workstream", R"g.workstream", dense=true, outlined=true)]),
                    Html.div(class="col-1",
                        [textfield("Priority", R"g.priority", dense=true, outlined=true, type="number")]),
                    Html.div(class="col-1",
                        [Stipple.select(R"g.completed", options=["false", "true"], dense=true, outlined=true, label="Done")]),
                    Html.div(class="col-1",
                        [btn("", icon="delete",
                            @click("delete_suggested_index = gi + 1"),
                            color="negative", flat=true, round=true, size="sm")])
                ])
            ])
        ]),

        # Status messages
        card(class="q-pa-sm q-mb-md bg-grey-1", @showif("suggestion_status && suggestion_status.length > 0"), [
            p("{{suggestion_status}}", class="text-weight-bold")
        ]),
        card(class="q-pa-sm q-mb-md bg-grey-1",
            @showif("context_summary && context_summary.length > 0"), [
            p("Context used:", class="text-weight-bold"),
            Html.pre("{{context_summary}}", style="font-size:0.85em; white-space:pre-wrap;")
        ]),

        separator(),

        # Current Weekly Goals (main editable list)
        h3("Weekly Goals"),

        row(class="items-center q-gutter-sm q-mb-md", [
            textfield("New Workstream", :new_workstream, dense=true, outlined=true),
            btn("Add Workstream", @click(:add_workstream), color="secondary")
        ]),

        card(class="q-pa-md", [
            p("No goals for this week. Use AI Assistant above or click '+ Goal' to add manually.", 
                @showif("weekly_goals.length === 0"), class="text-grey"),
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
            capacity = 100,
            active = "true",
            note = "",
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
    @in generate_weekly_report_btn::Bool = false
    @out weekly_report_status::String = ""

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
    @out team_members::Vector{String} = [m.name for m in TeamService.load_team_roster().members]

    # Team roster
    @in team_roster::Vector{UI.TeamRosterMemberVM} = UI.TeamRosterMemberVM[]
    @in load_team_roster::Bool = false
    @in save_team_roster::Bool = false
    @in new_team_member_name::String = ""
    @in add_team_member::Bool = false
    @in delete_team_member_index::Int = 0
    
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

    # Goal Assistant - Two Step Workflow
    @in target_week_assistant::String = Config.iso_week_string(today() + Week(1))
    @in suggested_goals::Vector{UI.WeeklyGoalVM} = UI.WeeklyGoalVM[]
    @in suggested_workstreams::Vector{String} = String[]
    @in selected_workstreams::Vector{String} = String[]
    @in suggest_workstreams_step::Bool = false
    @in suggest_goals_step::Bool = false
    @in save_suggested::Bool = false
    @out suggestion_status::String = ""
    @out context_summary::String = ""
    @in delete_suggested_index::Int = 0
    @in add_suggested_goal::Bool = false
    @in user_context::String = ""
    @in assistant_step::String = "workstreams"  # "workstreams" or "goals"
    
    # LLM Settings
    @in llm_provider::String = "ollama"
    @in ollama_model::String = "qwen3.5:9b"
    @in ollama_url::String = "http://localhost:11434/api/generate"
    @in openai_model::String = "gpt-4o"
    @in openai_api_key_input::String = ""  # Input field (masked)
    @out openai_api_key_masked::String = ""  # Display as masked
    @in save_llm_settings::Bool = false
    @in load_llm_settings_btn::Bool = false

    # -----------------------------
    # INIT
    # -----------------------------
    @onchange isready begin
        @info "Loading data for date: $date"
        team_members = [m.name for m in TeamService.load_team_roster().members]
        data = DailyService.get_or_create_daily(date, team_members)
        @info "Loaded $(length(data.entries)) entries"
        members = to_vm(data)
        members = merge_members_with_roster(members)
        @info "Converted to $(length(members)) members"
        @push members
        grouped = compute_grouping(members)
        @push grouped

        weekly_goal_options = weekly_goal_options_for_date(date)

        workstream_options = WeeklyGoalsService.load_workstreams()

        roster = TeamService.load_team_roster()
        team_roster = UI.TeamRosterMemberVM[
            UI.TeamRosterMemberVM(
                name = m.name,
                capacity = m.capacity,
                active = m.active ? "true" : "false",
                note = m.note
            )
            for m in roster.members
        ]
    end

    @onchange date begin
        try
            weekly_goal_options = weekly_goal_options_for_date(date)
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
        team_members = [m.name for m in TeamService.load_team_roster().members]
        data = DailyService.get_or_create_daily(date, team_members)
        @info "Loaded $(length(data.entries)) entries"
        members = to_vm(data)
        members = merge_members_with_roster(members)
        grouped = compute_grouping(members)
        preview = ""
        @push members
        @push grouped
        @push preview

        weekly_goal_options = weekly_goal_options_for_date(date)
    end

    # -----------------------------
    # LOAD PREVIOUS DAY TASKS
    # -----------------------------
    @onbutton load_previous begin
        @info "Loading previous day tasks for date: $date"
        team_members = [m.name for m in TeamService.load_team_roster().members]
        data = DailyService.get_previous_data(
            Date(date),
            Config.DAILY_DATA_DIR,
            team_members
        )
        @info "Loaded $(length(data.entries)) entries"
        members = to_vm(data)
        members = merge_members_with_roster(members)
        grouped = compute_grouping(members)
        preview = ""
        @push members
        @push grouped
        @push preview

        weekly_goal_options = weekly_goal_options_for_date(date)
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

            team_members = [m.name for m in members]
            prev = DailyService.get_previous_data(
                Date(date),
                Config.DAILY_DATA_DIR,
                team_members
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

            team_members = [m.name for m in members]
            prev = DailyService.get_previous_data(
                Date(date),
                Config.DAILY_DATA_DIR,
                team_members
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
    # WEEKLY GOALS - GENERATE REPORT
    # -----------------------------
    @onbutton generate_weekly_report_btn begin
        try
            weekly_report_status = "⏳ Generating report for $(selected_week)..."
            path = WeeklyReportService.save_weekly_report(selected_week)
            weekly_report_status = "✅ Report saved: $(path)"
        catch e
            @error "[WeeklyGoals] Report generation error" exception=(e, catch_backtrace())
            weekly_report_status = "❌ Error: $(sprint(showerror, e))"
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

            if Config.iso_week_string(Date(date)) == selected_week
                weekly_goal_options = weekly_goal_options_for_date(date)
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
            catch e
                @error "[WeeklyGoals] Delete error" exception=(e, catch_backtrace())
            end
        end
    end

    # -----------------------------
    # TEAM ROSTER - LOAD
    # -----------------------------
    @onbutton load_team_roster begin
        try
            roster = TeamService.load_team_roster()
            team_roster = UI.TeamRosterMemberVM[
                UI.TeamRosterMemberVM(
                    name = m.name,
                    capacity = m.capacity,
                    active = m.active ? "true" : "false",
                    note = m.note
                )
                for m in roster.members
            ]
        catch e
            @error "[Team] Load roster error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # TEAM ROSTER - SAVE
    # -----------------------------
    @onbutton save_team_roster begin
        try
            members_data = TeamService.TeamRosterMember[
                TeamService.TeamRosterMember(
                    String(r.name),
                    Int(r.capacity),
                    lowercase(strip(r.active)) == "true",
                    String(r.note)
                )
                for r in team_roster
                if !isempty(strip(r.name))
            ]
            data = TeamService.TeamRosterData(1, members_data)
            TeamService.save_team_roster(data)

            team_members = [m.name for m in TeamService.load_team_roster().members]
            members = merge_members_with_roster(members)
            grouped = compute_grouping(members)
        catch e
            @error "[Team] Save roster error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # TEAM ROSTER - ADD
    # -----------------------------
    @onbutton add_team_member begin
        try
            name = strip(new_team_member_name)
            if !isempty(name)
                push!(team_roster, UI.TeamRosterMemberVM(name=name, capacity=100, active="true", note=""))
                team_roster = copy(team_roster)
                new_team_member_name = ""
                @push new_team_member_name
            end
        catch e
            @error "[Team] Add member error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # TEAM ROSTER - DELETE
    # -----------------------------
    @onchange delete_team_member_index begin
        if delete_team_member_index > 0
            try
                deleteat!(team_roster, delete_team_member_index)
                team_roster = copy(team_roster)
                delete_team_member_index = 0
            catch e
                @error "[Team] Delete member error" exception=(e, catch_backtrace())
            end
        end
    end

    # -----------------------------
    # GOAL ASSISTANT - STEP 1: SUGGEST WORKSTREAMS
    # -----------------------------
    @onbutton suggest_workstreams_step begin
        try
            suggestion_status = "⏳ Step 1: Analyzing context and suggesting workstreams..."
            suggested_workstreams, summary, ctx = LLMGoalAssistant.suggest_workstreams(selected_week, user_context)
            context_summary = summary
            
            # Filter to relevant workstreams only
            relevant = filter(LLMGoalAssistant.is_relevant_workstream, suggested_workstreams)
            
            # Initialize selected workstreams with all suggested relevant ones
            selected_workstreams = relevant
            
            assistant_step = "workstreams"
            suggestion_status = "✅ Step 1 complete: $(length(relevant)) relevant workstream(s) suggested. Select which to use, then proceed to generate goals."
        catch e
            @error "[Assistant] Workstreams suggest error" exception=(e, catch_backtrace())
            suggestion_status = "❌ Error: $(sprint(showerror, e))"
        end
    end

    # -----------------------------
    # GOAL ASSISTANT - STEP 2: SUGGEST GOALS FOR SELECTED WORKSTREAMS
    # -----------------------------
    @onbutton suggest_goals_step begin
        try
            if isempty(selected_workstreams)
                suggestion_status = "⚠️ Please select at least one workstream first."
                return
            end
            
            suggestion_status = "⏳ Step 2: Generating specific goals for $(length(selected_workstreams)) workstream(s)..."
            goals, ctx = LLMGoalAssistant.suggest_goals_for_workstreams(selected_week, selected_workstreams, user_context)
            
            suggested_goals = UI.WeeklyGoalVM[
                UI.WeeklyGoalVM(
                    goal_id          = g.goal_id,
                    goal_description = g.goal_description,
                    priority         = g.priority,
                    completed        = "false",
                    workstream       = g.workstream
                )
                for g in goals
            ]
            workstream_options = WeeklyGoalsService.load_workstreams()
            assistant_step = "goals"
            suggestion_status = "✅ Step 2 complete: $(length(goals)) goal(s) suggested for $(length(selected_workstreams)) workstream(s). Review and edit above, then click '+ Add to List' to merge with existing goals."
        catch e
            @error "[Assistant] Goals suggest error" exception=(e, catch_backtrace())
            suggestion_status = "❌ Error: $(sprint(showerror, e))"
        end
    end

    # -----------------------------
    # GOAL ASSISTANT - ADD SUGGESTED TO WEEKLY GOALS
    # -----------------------------
    @onbutton add_suggested_to_weekly begin
        try
            # Append suggested goals to weekly_goals, generating new IDs to avoid conflicts
            for g in suggested_goals
                new_id = next_weekly_goal_id(weekly_goals)
                push!(weekly_goals, UI.WeeklyGoalVM(
                    goal_id          = new_id,
                    goal_description = g.goal_description,
                    priority         = g.priority,
                    completed        = g.completed,
                    workstream       = g.workstream
                ))
            end
            weekly_goals = copy(weekly_goals)  # trigger reactivity
            
            # Clear suggestions
            suggested_goals = UI.WeeklyGoalVM[]
            suggested_workstreams = String[]
            selected_workstreams = String[]
            
            suggestion_status = "✅ Added $(length(suggested_goals)) goal(s) to weekly goals. Click 'Save' to persist."
        catch e
            @error "[Assistant] Add suggested to weekly error" exception=(e, catch_backtrace())
            suggestion_status = "❌ Error: $(sprint(showerror, e))"
        end
    end

    # -----------------------------
    # GOAL ASSISTANT - REPLACE WEEKLY GOALS WITH SUGGESTED
    # -----------------------------
    @onbutton replace_with_suggested begin
        try
            weekly_goals = suggested_goals
            suggested_goals = UI.WeeklyGoalVM[]
            suggested_workstreams = String[]
            selected_workstreams = String[]
            
            suggestion_status = "✅ Replaced weekly goals with AI suggestions. Click 'Save' to persist."
        catch e
            @error "[Assistant] Replace weekly goals error" exception=(e, catch_backtrace())
            suggestion_status = "❌ Error: $(sprint(showerror, e))"
        end
    end

    # -----------------------------
    # GOAL ASSISTANT - ADD GOAL
    # -----------------------------
    @onbutton add_suggested_goal begin
        try
            ws_default = isempty(workstream_options) ? "" : workstream_options[1]
            push!(suggested_goals, UI.WeeklyGoalVM(
                goal_id   = next_weekly_goal_id(suggested_goals),
                workstream = ws_default
            ))
            suggested_goals = copy(suggested_goals)
        catch e
            @error "[Assistant] Add goal error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # GOAL ASSISTANT - DELETE GOAL
    # -----------------------------
    @onchange delete_suggested_index begin
        if delete_suggested_index > 0
            try
                deleteat!(suggested_goals, delete_suggested_index)
                suggested_goals = copy(suggested_goals)
                delete_suggested_index = 0
            catch e
                @error "[Assistant] Delete goal error" exception=(e, catch_backtrace())
            end
        end
    end

    # -----------------------------
    # GOAL ASSISTANT - SAVE
    # -----------------------------
    @onbutton save_suggested begin
        try
            goals = WeeklyGoalsService.WeeklyGoal[
                WeeklyGoalsService.WeeklyGoal(
                    goal_id          = g.goal_id,
                    goal_description = g.goal_description,
                    priority         = Int(g.priority),
                    completed        = lowercase(strip(g.completed)) == "true",
                    workstream       = g.workstream
                )
                for g in suggested_goals
            ]
            for g in goals
                WeeklyGoalsService.add_workstream(g.workstream)
            end
            workstream_options = WeeklyGoalsService.load_workstreams()
            data = WeeklyGoalsService.WeeklyGoalsData(1, target_week_assistant, goals)
            WeeklyGoalsService.save_weekly_goals_data(data)
            suggestion_status = "✅ Goals saved for $(target_week_assistant). View them on the Weekly Goals page."
        catch e
            @error "[Assistant] Save error" exception=(e, catch_backtrace())
            suggestion_status = "❌ Error saving: $(sprint(showerror, e))"
        end
    end

    # -----------------------------
    # LLM SETTINGS - LOAD
    # -----------------------------
    @onbutton load_llm_settings_btn begin
        try
            settings = LLMConfigService.load_llm_settings()
            llm_provider = settings.provider == LLMConfigService.OPENAI ? "openai" : "ollama"
            ollama_model = settings.ollama_model
            ollama_url = settings.ollama_url
            openai_model = settings.openai_model
            openai_api_key_masked = isempty(settings.openai_api_key) ? "" : "••••••••" * (length(settings.openai_api_key) > 8 ? settings.openai_api_key[end-3:end] : "")
            openai_api_key_input = ""  # Clear input field
        catch e
            @error "[LLMSettings] Load error" exception=(e, catch_backtrace())
        end
    end

    # -----------------------------
    # LLM SETTINGS - SAVE
    # -----------------------------
    @onbutton save_llm_settings begin
        try
            settings = LLMConfigService.load_llm_settings()
            
            # Update provider
            settings = LLMConfigService.set_provider(settings, llm_provider)
            
            # Update models
            settings.ollama_model = ollama_model
            settings.ollama_url = ollama_url
            settings.openai_model = openai_model
            
            # Only update API key if a new one was entered
            if !isempty(openai_api_key_input)
                settings = LLMConfigService.set_api_key(settings, openai_api_key_input)
            end
            
            LLMConfigService.save_llm_settings(settings)
            
            # Update masked display
            current_key = LLMConfigService.get_api_key(settings)
            openai_api_key_masked = isempty(current_key) ? "" : "••••••••" * (length(current_key) > 8 ? current_key[end-3:end] : "")
            openai_api_key_input = ""  # Clear input field
        catch e
            @error "[LLMSettings] Save error" exception=(e, catch_backtrace())
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
            Html.a("Weekly Goals", href="/weekly_goals", class="text-primary"),
            Html.a("Goals Assistant", href="/weekly_goals_assistant", class="text-primary"),
            Html.a("Team", href="/team", class="text-primary"),
            Html.a("LLM Settings", href="/llm_settings", class="text-primary")
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
                    h3("{{m.name}}"),
                    p("{{m.active === 'true' ? 'Active' : 'Inactive'}} — {{m.capacity}}% {{m.note}}", class="text-grey")
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

function ui_weekly_goals_assistant()
    [
        h1("Project Reporting Tool - {{project_name}}"),
        h2("Weekly Goals Assistant"),

        row(class="items-center q-gutter-sm q-mb-md", [
            Html.a("Daily", href="/daily", class="text-primary"),
            Html.a("Weekly Goals", href="/weekly_goals", class="text-primary"),
            Html.a("Team", href="/team", class="text-primary"),
            Html.a("LLM Settings", href="/llm_settings", class="text-primary")
        ]),

        # Step 1: Suggest Workstreams
        card(class="q-pa-md q-mb-md", [
            h3("Step 1: Select Workstreams"),
            row(class="items-center q-gutter-sm q-mb-sm", [
                textfield("Target Week (YYYY-WNN)", :target_week_assistant, dense=true, outlined=true),
                btn("Suggest Workstreams", @click(:suggest_workstreams_step), color="primary")
            ]),
            row(class="items-start q-gutter-sm q-mb-sm", [
                textfield("Priority / Context (optional): e.g. 'priority for this week is demo recordings'",
                    :user_context,
                    dense=true,
                    outlined=true,
                    style="width: 100%;")
            ])
        ]),

        # Show suggested workstreams for selection
        card(class="q-pa-md q-mb-md", @showif("suggested_workstreams.length > 0"), [
            h4("Suggested Workstreams - Select which to use:"),
            Html.div(@recur(:"(ws, wi) in suggested_workstreams"), [
                Html.div(class="row items-center q-gutter-sm q-mb-sm", [
                    Html.div(class="col-10", [
                        checkbox(R"selected_workstreams.includes(ws)", 
                            label=R"ws",
                            @click("if (selected_workstreams.includes(ws)) { selected_workstreams = selected_workstreams.filter(s => s !== ws); } else { selected_workstreams.push(ws); }"))
                    ])
                ])
            ]),
            row(class="q-mt-md", [
                btn("Proceed to Generate Goals", @click(:suggest_goals_step), color="primary", @showif("selected_workstreams.length > 0"))
            ])
        ]),

        # Step 2: Suggested Goals
        card(class="q-pa-md", @showif("suggested_goals.length > 0"), [
            row(class="items-center q-gutter-sm q-mb-md", [
                h3("Step 2: Suggested Goals"),
                btn("+ Goal", @click(:add_suggested_goal), color="secondary", size="sm"),
                btn("Save to Weekly Goals", @click(:save_suggested), color="primary")
            ]),
            Html.div(@recur(:"(g, gi) in suggested_goals"), [
                Html.div(class="row items-center q-gutter-sm q-mb-sm", [
                    Html.div(class="col-2",
                        [textfield("Goal ID", R"g.goal_id", dense=true, outlined=true)]),
                    Html.div(class="col-4",
                        [textfield("Description", R"g.goal_description", dense=true, outlined=true)]),
                    Html.div(class="col-2",
                        [textfield("Workstream", R"g.workstream", dense=true, outlined=true)]),
                    Html.div(class="col-1",
                        [textfield("Priority", R"g.priority", dense=true, outlined=true, type="number")]),
                    Html.div(class="col-1",
                        [Stipple.select(R"g.completed", options=["false", "true"], dense=true, outlined=true, label="Done")]),
                    Html.div(class="col-1",
                        [btn("", icon="delete",
                            @click("delete_suggested_index = gi + 1"),
                            color="negative", flat=true, round=true, size="sm")])
                ])
            ])
        ]),

        # Status and Context
        card(class="q-pa-sm q-mt-md bg-grey-1", @showif("suggestion_status && suggestion_status.length > 0"), [
            p("Status: {{suggestion_status}}", class="text-weight-bold")
        ]),
        card(class="q-pa-sm q-mt-md bg-grey-1",
            @showif("context_summary && context_summary.length > 0"), [
            p("Context used:", class="text-weight-bold"),
            Html.pre("{{context_summary}}", style="font-size:0.85em; white-space:pre-wrap;")
        ])
    ]
end

function ui_llm_settings()
    [
        h1("Project Reporting Tool - {{project_name}}"),
        h2("LLM Settings"),

        row(class="items-center q-gutter-sm q-mb-md", [
            Html.a("Daily", href="/daily", class="text-primary"),
            Html.a("Weekly Goals", href="/weekly_goals", class="text-primary"),
            Html.a("Team", href="/team", class="text-primary")
        ]),

        card(class="q-pa-md", [
            row(class="items-center q-gutter-sm q-mb-md", [
                btn("Load Settings", @click(:load_llm_settings_btn), color="primary"),
                btn("Save Settings", @click(:save_llm_settings), color="primary")
            ]),

            # Provider Selection
            row(class="items-center q-gutter-sm q-mb-md", [
                h4("Provider:"),
                Stipple.select(R"llm_provider", options=["ollama", "openai"], dense=true, outlined=true)
            ]),

            # Ollama Settings
            card(class="q-pa-md q-mb-md", @showif("llm_provider === 'ollama'"), [
                h4("Ollama Settings"),
                row(class="items-center q-gutter-sm q-mb-sm", [
                    textfield("Model", :ollama_model, dense=true, outlined=true),
                    textfield("URL", :ollama_url, dense=true, outlined=true, style="width: 400px;")
                ])
            ]),

            # OpenAI Settings
            card(class="q-pa-md q-mb-md", @showif("llm_provider === 'openai'"), [
                h4("OpenAI Settings"),
                row(class="items-center q-gutter-sm q-mb-sm", [
                    textfield("Model", :openai_model, dense=true, outlined=true)
                ]),
                row(class="items-center q-gutter-sm q-mb-sm", [
                    textfield("API Key", :openai_api_key_input, dense=true, outlined=true, type="password", style="width: 400px;"),
                    p(@showif("openai_api_key_masked && openai_api_key_masked.length > 0"), [
                        "Current: {{openai_api_key_masked}}"
                    ], class="text-grey")
                ]),
                p("Leave API Key empty to keep existing key.", class="text-caption text-grey")
            ])
        ])
    ]
end

@page("/daily", ui)

@page("/weekly_goals", ui_weekly_goals)

@page("/weekly_goals_assistant", ui_weekly_goals_assistant)

@page("/team", ui_team)

@page("/llm_settings", ui_llm_settings)

@page("/", ui_home)

Genie.up()
