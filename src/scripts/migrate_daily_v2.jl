#!/usr/bin/env julia

using JSON3
using Dates
using Glob

# Adjust path if needed
DATA_DIR = joinpath("D:", "Repositories", "ProjectReporting", "data", "daily")

function migrate_file(path)
    raw = JSON3.read(read(path, String))

    # Already migrated
    if haskey(raw, :entries) && haskey(raw.entries[1], :tasks)
        println("Skipping (already v2): $path")
        return
    end

    println("Migrating: $path")

    entries_map = Dict{String, Vector{Dict}}()

    # Handle OLD formats
    if haskey(raw, :tasks)
        for t in raw.tasks
            member = get(t, :owner, "unknown")

            task = Dict(
                "description" => get(t, :title, ""),
                "allocation" => "core",
                "execution_state" => "active",
                "tags" => String[],
                "blocker" => nothing
            )

            push!(get!(entries_map, member, Vector{Dict}()), task)
        end
    elseif haskey(raw, :entries)
        # Intermediate format (flat entries)
        for e in raw.entries
            member = get(e, :member, "unknown")

            task = Dict(
                "description" => get(e, :description, ""),
                "allocation" => get(e, :allocation, "core"),
                "execution_state" => get(e, :execution_state, "active"),
                "tags" => get(e, :tags, String[]),
                "blocker" => get(e, :blocker, nothing)
            )

            push!(get!(entries_map, member, Vector{Dict}()), task)
        end
    else
        error("Unknown format in $path")
    end

    # Build new structure
    new_entries = []

    for (member, tasks) in entries_map
        push!(new_entries, Dict(
            "member" => Dict("name" => member),
            "tasks" => tasks
        ))
    end

    new_data = Dict(
        "date" => get(raw, :date, ""),
        "entries" => new_entries
    )

    open(path, "w") do io
        JSON3.pretty(io, new_data, JSON3.AlignmentContext(indent=2))
    end
end

# --------------------------
# Run migration
# --------------------------
files = Glob.glob("*.json", DATA_DIR)
println(files)

for f in files
    migrate_file(f)
end

println("Migration complete.")