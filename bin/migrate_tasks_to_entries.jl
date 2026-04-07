#!/usr/bin/env julia

using JSON3
using Dates
using Glob
using ProjectReporting.Config
using ProjectReporting.LoggingConfig

LoggingConfig.init_logger()


function migrate_file(path)
    @info "Migrating $path"

    data = JSON3.read(read(path, String))

    # Old format: tasks
    tasks = get(data, "tasks", [])

    entries = []

    for t in tasks
        push!(entries, Dict(
            "member" => t["owner"],
            "allocation" => t["allocation"],
            "execution_state" => t["execution_state"],
            "description" => t["title"],
            "goal_ids" => get(t, "goal_id", nothing) === nothing ? String[] : [t["goal_id"]],
            "blocked" => nothing
        ))
    end

    new_data = Dict(
        "date" => data["date"],
        "entries" => entries
    )

    open(path, "w") do io
        JSON3.write(io, new_data; indent=2)
    end
end

files = glob("*.json", Config.DAILY_DATA_DIR)

@info "Found $(length(files)) files to migrate"

for f in files
    migrate_file(f)
end

@info "Migration complete."