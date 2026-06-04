module TeamService

using JSON3
using Logging
using ..Config

export TeamRosterMember, TeamRosterData
export load_team_roster, save_team_roster
export active_member_names, inactive_members
export all_roster_members, find_member
export roster_path

struct TeamRosterMember
    name::String
    capacity::Int
    active::Bool
    note::String
end

struct TeamRosterData
    version::Int
    members::Vector{TeamRosterMember}
end

function roster_path()::String
    return joinpath(Config.DATA_DIR, "team", "roster.json")
end

function to_dict(m::TeamRosterMember)
    return Dict(
        "name" => m.name,
        "capacity" => m.capacity,
        "active" => m.active,
        "note" => m.note
    )
end

function from_dict(::Type{TeamRosterMember}, d)
    return TeamRosterMember(
        String(get(d, :name, get(d, "name", ""))),
        Int(get(d, :capacity, get(d, "capacity", 100))),
        Bool(get(d, :active, get(d, "active", true))),
        String(get(d, :note, get(d, "note", "")))
    )
end

function to_dict(r::TeamRosterData)
    return Dict(
        "version" => r.version,
        "members" => [to_dict(m) for m in r.members]
    )
end

function from_dict(::Type{TeamRosterData}, d)
    members_raw = get(d, :members, get(d, "members", []))
    members = TeamRosterMember[from_dict(TeamRosterMember, m) for m in members_raw]
    return TeamRosterData(Int(get(d, :version, get(d, "version", 1))), members)
end

function default_team_roster()::TeamRosterData
    return TeamRosterData(1, TeamRosterMember[])
end

function load_team_roster()::TeamRosterData
    path = roster_path()
    dir = dirname(path)
    isdir(dir) || mkpath(dir)

    if !isfile(path)
        data = default_team_roster()
        save_team_roster(data)
        return data
    end

    raw = JSON3.read(read(path, String))
    data = from_dict(TeamRosterData, raw)

    if isempty(data.members)
        data = default_team_roster()
        save_team_roster(data)
        return data
    end

    return data
end

function save_team_roster(data::TeamRosterData)
    path = roster_path()
    dir = dirname(path)
    isdir(dir) || mkpath(dir)

    open(path, "w") do io
        JSON3.write(io, to_dict(data); indent=2)
    end

    @info "[Team] Saved roster" path=path members=length(data.members)
    return nothing
end

function active_member_names()::Vector{String}
    roster = load_team_roster()
    return [m.name for m in roster.members if m.active]
end

function inactive_members()::Vector{TeamRosterMember}
    roster = load_team_roster()
    return [m for m in roster.members if !m.active]
end

function all_roster_members()::Vector{TeamRosterMember}
    roster = load_team_roster()
    return roster.members
end

function find_member(name::AbstractString)::Union{TeamRosterMember, Nothing}
    roster = load_team_roster()
    for m in roster.members
        if m.name == name
            return m
        end
    end
    return nothing
end

end
