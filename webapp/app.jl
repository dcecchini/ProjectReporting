using Genie, Genie.Router, Genie.Renderer.Html
using Genie.Requests, Genie.Responses
using Dates, JSON3
using SimpleProjectReporting
using SimpleProjectReporting.Config
using SimpleProjectReporting.Weekly
using SimpleProjectReporting.Monthly  # if exists

# -----------------------------
# Start Genie app
# -----------------------------
Genie.config.run_as_server = true
Genie.config.server_host = "127.0.0.1"
Genie.config.server_port = 8000

# Ensure directories exist
Config.ensure_directories()

# -----------------------------
# Helper to load/save daily JSON
# -----------------------------
function load_daily(date::Date)
    fname = joinpath(Config.DAILY_DATA_DIR, string(date, dateformat"yyyy-mm-dd") * ".json")
    return isfile(fname) ? JSON3.read(open(fname)) : nothing
end

function save_daily(date::Date, tasks::Vector{Dict})
    # Validate: must have owner, title, allocation, execution_state
    for t in tasks
        for key in ["owner", "title", "allocation", "execution_state"]
            haskey(t, key) || error("Task missing $key")
        end
    end
    fname = joinpath(Config.DAILY_DATA_DIR, string(date, dateformat"yyyy-mm-dd") * ".json")
    open(fname, "w") do io
        JSON3.write(io, Dict("date"=>string(date), "tasks"=>tasks))
    end
end

# -----------------------------
# Routes
# -----------------------------
# Home page
route("/") do
    redirect("/daily")
end

# -----------------------------
# Daily page
# -----------------------------
route("/daily", method=:GET) do
    date_str = getquery(:date, string(Dates.today()))
    date = Date(date_str)
    data = load_daily(date)
    tasks = data === nothing ? [] : data["tasks"]
    html(:daily, date=date_str, tasks=tasks)
end

route("/daily/save", method=:POST) do
    # 1️⃣ Parse date
    date_str = Genie.Requests.params(:date)
    date = try
        Date(date_str)
    catch
        return "Invalid date format: $date_str"
    end

    # 2️⃣ Read form fields
    owners = Genie.Requests.params(:owner)
    titles = Genie.Requests.params(:title)
    allocations = Genie.Requests.params(:allocation)
    states = Genie.Requests.params(:execution_state)
    linked_goal_raw = Genie.Requests.params(:linked_goal, "")
    priority_changed_raw = Genie.Requests.params(:priority_changed, "")

    # Ensure arrays
    nrows = length(owners)
    @assert all(length(arr) == nrows for arr in (titles, allocations, states)) "Form arrays must match in length"

    # Checkbox fields: linked_goal, priority_changed may be missing for unchecked
    linked_goal_flags = [i in linked_goal_raw ? true : false for i in 1:nrows]
    priority_changed_flags = [i in priority_changed_raw ? true : false for i in 1:nrows]

    # 3️⃣ Allowed values
    allowed_allocations = ["core", "client", "outside-client", "ooo", "outside-tasks"]
    allowed_states = ["active", "blocked", "none"]

    # 4️⃣ Build tasks
    tasks = Vector{Dict{String,Any}}()
    for i in 1:nrows
        owner = strip(owners[i])
        title = strip(titles[i])
        allocation = allocations[i]
        state = states[i]
        linked_goal = linked_goal_flags[i]
        priority_changed = priority_changed_flags[i]

        # Validation
        isempty(owner) && return "Owner cannot be empty on row $i"
        isempty(title) && return "Title cannot be empty on row $i"
        !(allocation in allowed_allocations) && return "Invalid allocation '$allocation' on row $i"
        !(state in allowed_states) && return "Invalid execution_state '$state' on row $i"

        push!(tasks, Dict(
            "owner" => owner,
            "title" => title,
            "allocation" => allocation,
            "execution_state" => state,
            "linked_goal" => linked_goal,
            "priority_changed" => priority_changed
        ))
    end

    # 5️⃣ Save to JSON
    fname = joinpath(Config.DAILY_DATA_DIR, string(date, dateformat"yyyy-mm-dd") * ".json")
    open(fname, "w") do io
        JSON3.write(io, Dict("date"=>string(date), "tasks"=>tasks, "schema_version"=>5))
    end

    redirect("/daily?date=$(date)")
end


# -----------------------------
# Weekly page
# -----------------------------
# Weekly JSON endpoint
route("/weekly", method=:GET) do
    week_str = getquery(:week, string(Dates.year(Dates.today()), "-W", lpad(Dates.week(Dates.today()),2,"0")))
    format = getquery(:format, "html")

    # Parse week
    year, w = split(week_str, "-W")
    year = parse(Int, year)
    weeknum = parse(Int, w)
    first_day = Dates.Date(year,1,4) + Day(7*(weeknum-1)) - Day(Dates.dayofweek(Dates.Date(year,1,4))-1)
    week_dates = first_day .+ Day.(0:4)

    # Load daily JSONs
    all_tasks = Task[]
    all_goals = Goal[]
    for d in week_dates
        fname = joinpath(Config.DAILY_DATA_DIR, string(d, dateformat"yyyy-mm-dd")*".json")
        isfile(fname) || continue
        data = JSON3.read(open(fname))
        for t in data["tasks"]
            push!(all_tasks, Task(
                t["owner"], t["title"],
                get(t,"linked_goal",false),
                get(t,"priority_changed",false)
            ))
            if haskey(t,"goal_id")
                push!(all_goals, Goal(t["owner"], t["title"], 1, t["execution_state"]=="active"))
            end
        end
    end

    weekly_data = WeeklyData(all_goals, all_tasks)
    owners = unique(g.owner for g in weekly_data.goals)
    metrics = [evaluate_owner(o, weekly_data) for o in owners]

    if format == "json"
        # return JSON for AJAX
        return JSON3.write(Dict(
            "week"=>week_str,
            "metrics"=>[Dict(
                "owner"=>m.owner,
                "completion_pct"=>m.completion_pct,
                "weighted_completion"=>m.weighted_completion,
                "drift_ratio"=>m.drift_ratio,
                "unplanned_ratio"=>m.unplanned_ratio,
                "priority_changes"=>m.priority_changes
            ) for m in metrics]
        ))
    else
        html(:weekly, week_str=week_str, metrics=metrics)
    end
end


# -----------------------------
# Monthly page
# -----------------------------
route("/monthly", method=:GET) do
    # Get month string from query, default current month
    month_str = getquery(:month, string(Dates.year(Dates.today()), "-", lpad(Dates.month(Dates.today()),2,"0")))

    try
        year, month = split(month_str, "-")
        year = parse(Int, year)
        month = parse(Int, month)
    catch
        return "Invalid month format: $month_str, expected YYYY-MM"
    end

    # Dates in month
    first_day = Date(year, month, 1)
    last_day = Dates.lastdayofmonth(first_day)
    month_dates = first_day:last_day

    # Load all daily JSONs
    all_tasks = Task[]
    all_goals = Goal[]
    for d in month_dates
        fname = joinpath(Config.DAILY_DATA_DIR, string(d, dateformat"yyyy-mm-dd")*".json")
        isfile(fname) || continue
        data = JSON3.read(open(fname))
        for t in data["tasks"]
            push!(all_tasks, Task(
                t["owner"], t["title"],
                get(t,"linked_goal",false),
                get(t,"priority_changed",false)
            ))
            if haskey(t,"goal_id")
                push!(all_goals, Goal(t["owner"], t["title"], 1, t["execution_state"]=="active"))
            end
        end
    end

    monthly_data = WeeklyData(all_goals, all_tasks) # reuse WeeklyData
    owners = unique(g.owner for g in monthly_data.goals)
    metrics = [evaluate_owner(o, monthly_data) for o in owners]

    html(:monthly, month_str=month_str, metrics=metrics)
end


# -----------------------------
# Start server
# -----------------------------
Genie.startup()
