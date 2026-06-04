module DailyService

using Dates
using JSON3
using Logging
using ..Domain: Task, Allocation, ExecutionState, TeamMember
using ..DailyModel
using ..Config

export get_or_create_daily, save_daily_entries


# -----------------------------
# File handling
# -----------------------------

function build_path(date::Date, dir::String=Config.DAILY_DATA_DIR)
    joinpath(dir, string(date) * ".json")
end
function build_path(date_str::String, dir::String=Config.DAILY_DATA_DIR)
    build_path(Date(date_str), dir)
end

function load_daily_data(date_str::String, dir::String=Config.DAILY_DATA_DIR)::Union{DailyData, Nothing}
    path = build_path(date_str, dir)

    if !isfile(path)
        return nothing
    end

    raw = JSON3.read(read(path, String))

    # New format
    if haskey(raw, :entries)
        return from_dict(DailyData, raw)
    end

    # Legacy fallback
    if haskey(raw, :tasks)
        @warn "Legacy format detected" date=date_str

        entries = [
            DailyEntry(
                get(t, :owner, "unknown"),
                "core",
                "active",
                get(t, :title, ""),
                String[],
                nothing
            )
            for t in raw.tasks
        ]

        return DailyData(date_str, entries)
    end

    error("Unknown format")
end

function save_daily_entries(date_str::String, entries::Vector{DailyEntry})
    path = build_path(date_str)

    data = DailyData(date_str, entries)

    open(path, "w") do io
        JSON3.write(io, to_dict(data); indent=2)
    end

    @info "Saved daily data" path=path
end

function save_daily_entries(data::DailyData)
    save_daily_entries(string(data.date), data.entries)
end

function get_previous_working_date(date::Date)
    d = date - Day(1)

    while dayofweek(d) in (6, 7)  # Saturday=6, Sunday=7
        d -= Day(1)
    end

    return d
end

function file_exists(date::Date)
    path = joinpath(Config.DAILY_DATA_DIR, string(date) * ".json")
    return isfile(path)
end

function list_dates()
    files = filter(f -> endswith(f, ".json"), readdir(Config.DAILY_DATA_DIR))
    return sort(Date.(replace.(files, ".json" => "")))
end

function load_last_available(team_members::Vector{String})
    files = filter(f -> endswith(f, ".json"), readdir(Config.DAILY_DATA_DIR))

    isempty(files) && return empty_daily_data(today(), team_members)

    dates = sort(Date.(replace.(files, ".json" => "")))

    last_date = dates[end]

    return get_or_create_daily(string(last_date), team_members)
end

# -----------------------------------------
# Helper: previous day string
# -----------------------------------------
function get_last_existing_date(current_date::Date, data_dir::String)
    files = readdir(data_dir)

    dates = Date[]
    for f in files
        if endswith(f, ".json")
            try
                push!(dates, Date(split(f, ".")[1]))
            catch e
                # ignore malformed filenames
                @warn "Malformed filename: $f" exception=(e, catch_backtrace())
            end
        end
    end

    # only consider dates before current
    valid_dates = filter(d -> d < current_date, dates)

    isempty(valid_dates) && return nothing

    return maximum(valid_dates)
end

function previous_date(date_str::String)
    d = Date(date_str)
    return string(d - Day(1))
end

function align_with_team(entries, team_members)
    existing = Dict(e.member => e for e in entries)

    result = DailyEntry[]

    for member in team_members
        if haskey(existing, member)
            push!(result, existing[member])
        else
            push!(result, empty_entry(member))
        end
    end

    return result
end

function get_previous_data(date::Date, data_dir::String, team_members::Vector{String})
    prev_date = get_previous_working_date(date)
    prev_str = string(prev_date)

    prev_data = load_daily_data(prev_str, data_dir)

    # -----------------------------
    # Case 1: no previous data
    # -----------------------------
    if prev_data === nothing
        entries = [
            DailyEntry(
                TeamMember(member),
                Task[]
            )
            for member in team_members
        ]

        return DailyData(string(date), entries)
    end

    # -----------------------------
    # Case 2: copy previous safely
    # -----------------------------
    prev_map = Dict(e.member.name => e for e in prev_data.entries)

    new_entries = DailyEntry[]

    for member in team_members
        if haskey(prev_map, member)
            prev_entry = prev_map[member]

            tasks_copy = [
                Task(
                    t.goal_id,
                    t.description,
                    t.allocation,
                    t.execution_state,
                    copy(t.tags),
                    t.blocker
                )
                for t in prev_entry.tasks
            ]

            push!(new_entries,
                DailyEntry(
                    TeamMember(member),
                    tasks_copy
                )
            )
        else
            push!(new_entries,
                DailyEntry(
                    TeamMember(member),
                    Task[]
                )
            )
        end
    end

    return DailyData(string(date), new_entries)
end

# -----------------------------------------
# Load or initialize daily data
# -----------------------------------------
function get_or_create_daily(date_str::String, team_members::Vector{String})
    data = load_daily_data(date_str)

    if data !== nothing
        return data
    end

    @warn "No data for selected date, starting day from scratch..." date=date_str

    return empty_daily_data(Date(date_str), team_members)
end

end
