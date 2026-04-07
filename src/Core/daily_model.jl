module DailyModel

using Dates

using ..Domain: Task, TeamMember
import ..Serialization: to_dict, from_dict

export DailyEntry, DailyData, from_dict, to_dict

"""
Represents the daily input for one member.
"""
struct DailyEntry
    member::TeamMember 
    tasks::Vector{Task}
end

"""
Creates an empty daily entry for a member.
"""
function empty_entry(member::String)::DailyEntry
    DailyEntry(member, Task[], String[])
end


# -----------------------------
# DailyEntry serialization
# -----------------------------

function from_dict(::Type{DailyEntry}, d)
    member = haskey(d, :member) ?
        from_dict(TeamMember, d.member) :
        TeamMember(get(d, :member, ""))  # fallback legacy

    tasks = haskey(d, :tasks) ?
        [from_dict(Task, t) for t in d.tasks] :
        Task[]

    return DailyEntry(member, tasks)
end

function to_dict(e::DailyEntry)
    return Dict(
        "member" => to_dict(e.member),
        "tasks" => [to_dict(t) for t in e.tasks]
    )
end

"""
Represents the daily data for a specific date.
"""
struct DailyData
    date::Date
    entries::Vector{DailyEntry}
end

DailyData(date::String, entries::Vector{DailyEntry}; dateformat::DateFormat = dateformat"yyyy-mm-dd") = DailyData(Date(date, dateformat), entries)

function empty_daily_data(date::Date, team_members::Vector{String}=Config.TEAM_MEMBERS)::DailyData
    entries = [
        empty_entry(member)
        for member in team_members
    ]
    return DailyData(date, entries)
end

function from_dict(::Type{DailyData}, d)
    entries = haskey(d, :entries) ?
        [from_dict(DailyEntry, e) for e in d.entries] :
        DailyEntry[]

    return DailyData(
        get(d, :date, ""),
        entries
    )
end

function to_dict(d::DailyData)
    return Dict(
        "date" => d.date,
        "entries" => [to_dict(e) for e in d.entries]
    )
end

end # Module