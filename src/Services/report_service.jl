module ReportService

using Dates
using ..Domain: Task, Allocation, ExecutionState, BLOCKED, CORE, ALLOCATION_ORDER, allocation_to_string, allocation_to_label
using ..DailyModel
using ..DiffUtils
using ..Config

import ..Serialization: to_dict, from_dict

export Report, ReportTask, ReportSection, render_text_report, to_dict, from_dict


# -----------------------------
# ReportTask
# -----------------------------
struct ReportTask
    member::String
    description::String
    allocation::Allocation
    status::Symbol   # :new, :unchanged, :completed, :blocked
end

function to_dict(t::ReportTask)
    return Dict(
        "member" => t.member,
        "description" => t.description,
        "allocation" => allocation_to_string(t.allocation),
        "status" => String(t.status)
    )
end

function from_dict(::Type{ReportTask}, d::Dict)
    return ReportTask(
        d["member"],
        d["description"],
        parse_allocation(d["allocation"]),
        Symbol(d["status"])
    )
end


# -----------------------------
# ReportSection
# -----------------------------
struct ReportSection
    allocation::Allocation
    tasks::Vector{ReportTask}
end

function to_dict(s::ReportSection)
    return Dict(
        "allocation" => allocation_to_string(s.allocation),
        "tasks" => [to_dict(t) for t in s.tasks]
    )
end

function from_dict(::Type{ReportSection}, d::Dict)
    return ReportSection(
        parse_allocation(d["allocation"]),
        [task_from_dict(t) for t in d["tasks"]]
    )
end


# -----------------------------
# Report
# -----------------------------
struct Report
    date::String
    blockers::Vector{ReportTask}
    sections::Vector{ReportSection}
end

function to_dict(r::Report)
    return Dict(
        "date" => r.date,
        "blockers" => [to_dict(t) for t in r.blockers],
        "sections" => [to_dict(s) for s in r.sections]
    )
end

function split_tasks(desc::String)
    return Set(strip.(split(desc, ';')))
end

function group_tasks_by_member(tasks::Vector{ReportTask})
    grouped = Dict{String, Vector{ReportTask}}()

    for t in tasks
        push!(get!(grouped, t.member, ReportTask[]), t)
    end

    return grouped
end

function generate_report(date::String, entries::Vector{DailyEntry}, prev_entries::Union{Nothing, Vector{DailyEntry}})
    prev_map = prev_entries === nothing ?
        Dict{String, Vector{Task}}() :
        Dict(e.member.name => e.tasks for e in prev_entries)

    # -----------------------------
    # Collect tasks
    # -----------------------------
    all_tasks = ReportTask[]
    blockers = ReportTask[]

    for entry in entries
        member = entry.member.name
        prev_tasks = get(prev_map, member, Task[])

        prev_desc_set = Set{String}()
        for t in prev_tasks
            union!(prev_desc_set, split_tasks(t.description))
        end

        curr_desc_set = Set{String}()
        for t in entry.tasks
            union!(curr_desc_set, split_tasks(t.description))
        end

        # -------------------------
        # Detect new & unchanged
        # -------------------------
        for t in entry.tasks
            for chunk in split_tasks(t.description)
                status =
                    t.execution_state == BLOCKED ? :blocked :
                    chunk ∉ prev_desc_set ? :new :
                    :unchanged

                task = ReportTask(member, chunk, t.allocation, status)

                if status == :blocked
                    push!(blockers, task)
                else
                    push!(all_tasks, task)
                end
            end
        end

        # -------------------------
        # Detect completed
        # -------------------------
        for chunk in setdiff(prev_desc_set, curr_desc_set)
            push!(all_tasks,
                ReportTask(member, chunk, CORE, :completed)
            )
        end
    end

    # -----------------------------
    # Group by allocation
    # -----------------------------
    sections = ReportSection[]

    for alloc in ALLOCATION_ORDER
        tasks = [t for t in all_tasks if t.allocation == alloc]

        if !isempty(tasks)
            push!(sections, ReportSection(alloc, tasks))
        end
    end

    return Report(date, blockers, sections)
end

function render_text_report(report::Report)
    lines = String[]

    # -----------------------------
    # Title
    # -----------------------------
    push!(lines, "📅 $(report.date) DS Team Updates")
    push!(lines, "")

    # -----------------------------
    # Blockers
    # -----------------------------
    if !isempty(report.blockers)
        push!(lines, "⚠ Blockers")

        for t in report.blockers
            push!(lines, "  ⚠ $(t.description) [$(t.member)]")
        end

        push!(lines, "")
    end

    # -----------------------------
    # Allocation sections
    # -----------------------------
    for section in report.sections
        label = allocation_to_label(section.allocation)

        push!(lines, "▶️ $label")

        for t in section.tasks
            prefix =
                t.status == :new       ? "🔵" :
                t.status == :completed ? "✅" :
                "•"

            push!(lines, "  $prefix $(t.description) [$(t.member)]")
        end

        push!(lines, "")
    end

    return join(lines, "\n")
end



end