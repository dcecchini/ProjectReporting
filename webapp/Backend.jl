module Backend

using Dates
using JSON3
using SimpleProjectReporting.Config
using SimpleProjectReporting.Weekly: WeeklyData, Task, Goal, OwnerMetrics, evaluate_owner
using SimpleProjectReporting.weekly: generate_weekly_report
using SimpleProjectReporting.monthly: generate_monthly_report


export load_daily!, save_daily!, update_weekly_metrics!, update_monthly_metrics!

function load_daily!(model)
    fname = joinpath(Config.DAILY_DATA_DIR, string(model.selected_date[], dateformat"yyyy-mm-dd")*".json")
    if isfile(fname)
        data = JSON3.read(open(fname))
        tasks = Task[]
        for t in data["tasks"]
            push!(tasks, Task(
                t["owner"], t["title"],
                get(t,"linked_goal",false),
                get(t,"priority_changed",false)
            ))
        end
        model.daily_tasks[] = tasks
    else
        model.daily_tasks[] = Vector{Task}()
    end
end

function save_daily!(model)
    fname = joinpath(Config.DAILY_DATA_DIR, string(model.selected_date[], dateformat"yyyy-mm-dd")*".json")
    tasks = [Dict(
        "owner"=>t.owner,
        "title"=>t.title,
        "linked_goal"=>t.linked_goal,
        "priority_changed"=>t.priority_changed
    ) for t in model.daily_tasks[]]
    JSON3.write(fname, Dict("date"=>string(model.selected_date[]), "tasks"=>tasks))

    # Update metrics after saving
    update_weekly_metrics!(model)
    update_monthly_metrics!(model)
end

function update_weekly_metrics!(model)
    y, w = parse.(Int, split(model.selected_week[], "-W"))
    # Compute dates in week (Mon-Fri)
    first_day = Dates.Date(y,1,4) + Day(7*(w-1)) - Day(Dates.dayofweek(Dates.Date(y,1,4))-1)
    week_dates = first_day .+ Day.(0:4)

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
                push!(all_goals, Goal(
                    t["owner"],
                    t["title"],
                    get(t,"priority",1),
                    get(t,"execution_state","active") == "active"
                ))
            end
        end
    end

    weekly_data = WeeklyData(all_goals, all_tasks)
    # Use CLI function to compute metrics
    metrics_text = generate_weekly_report(weekly_data)
    
    # Also populate model.weekly_metrics[]
    owners = unique(g.owner for g in weekly_data.goals)
    model.weekly_metrics[] = [evaluate_owner(o, weekly_data) for o in owners]

    return metrics_text
end


function update_monthly_metrics!(model)
    y, m = parse.(Int, split(model.selected_month[], "-"))
    first_day = Date(y,m,1)
    last_day = Dates.lastdayofmonth(first_day)
    month_dates = first_day:last_day

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
                push!(all_goals, Goal(
                    t["owner"],
                    t["title"],
                    get(t,"priority",1),
                    get(t,"execution_state","active") == "active"
                ))
            end
        end
    end

    monthly_data = WeeklyData(all_goals, all_tasks)
    metrics_text = generate_monthly_report(monthly_data)

    owners = unique(g.owner for g in monthly_data.goals)
    model.monthly_metrics[] = [evaluate_owner(o, monthly_data) for o in owners]

    return metrics_text
end


end
