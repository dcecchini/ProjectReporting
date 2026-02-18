module Daily

using JSON3
using SimpleProjectReporting.Config

export DailyData, Task, load_daily, save_daily, generate_daily_report, task_to_dict, build_daily_prompt

struct Task
    goal_id::String
    title::String
    owner::String
    allocation::String
    execution_state::String
    priority_changed::Bool
    linked_goal::Bool
end

struct DailyData
    tasks::Vector{Task}
end

function task_to_dict(t::Task)
    return Dict(
        "goal_id" => t.goal_id,
        "title" => t.title,
        "owner" => t.owner,
        "allocation" => t.allocation,
        "execution_state" => t.execution_state,
        "priority_changed" => t.priority_changed,
        "linked_goal" => t.linked_goal
    )
end



# ----------------------------------------------------
# Load daily JSON
# ----------------------------------------------------
function load_daily(date_str::String)::Union{DailyData,Nothing}
    fname = joinpath(Config.DAILY_DATA_DIR, "$date_str.json")
    if isfile(fname)
        open(fname, "r") do io
            return JSON3.read(io, DailyData)
        end
    else
        return nothing
    end
end

# ----------------------------------------------------
# Save daily JSON
# ----------------------------------------------------
function save_daily(date_str::String, tasks::Vector{Task})
    fname = joinpath(Config.DAILY_REPORTS_DIR, "$date_str.json")
    open(fname, "w") do io
        JSON3.write(io, Dict(
            "date" => date_str,
            "tasks" => [task_to_dict(t) for t in tasks]
        ); indent=2)
    end
    println("Saved daily JSON to $fname")
end

# ----------------------------------------------------
# Generate formatted daily report
# ----------------------------------------------------
function generate_daily_report(date_str::String, tasks::Vector{Task})
    lines = []
    for t in tasks
        push!(lines, "$(t.owner): $(t.title)")
    end
    report_text = join(lines, "\n")

    # Save to report dir
    Config.ensure_directories()
    report_fname = joinpath(Config.DAILY_REPORTS_DIR, "$date_str.txt")
    open(report_fname, "w") do io
        write(io, report_text)
    end
    println("Saved daily report to $report_fname")

    return report_text
end

function build_daily_prompt(date_str::String, tasks::Vector{Task}, report_text::String)
    owners = unique(t.owner for t in tasks)
    prompt_lines = String[]
    push!(prompt_lines, "You are generating a brief daily activities summary for leadership. ")

    
    push!(prompt_lines, "Avoid progressive verbs ending in “-ing” unless they denote a defined activity (e.g., benchmarking).")
    push!(prompt_lines, "Prefer nouns that represent structured initiatives.")
    push!(prompt_lines, "Avoid vague words like \"improving.\"")
    push!(prompt_lines, "Avoid internal shorthand unless leadership understands it.")
    push!(prompt_lines, "Keep each line ≤ 8-10 words per activity cluster.")
    push!(prompt_lines, "Date: $date_str")
    push!(prompt_lines, "Owners: " * (isempty(owners) ? "(none)" : join(owners, ", ")))
    push!(prompt_lines, "Total tasks: $(length(tasks))")
    push!(prompt_lines, "")
    push!(prompt_lines, "Report:")
    push!(prompt_lines, report_text)
    push!(prompt_lines, "")
    push!(prompt_lines, "Write a concise bullet-point summary highlighting progress for each owner, blockers/risks, and focus for next day.")
    return join(prompt_lines, "\n")
end


end # module Daily