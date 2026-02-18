module SchemaValidator

using JSON3
using JSONSchema

export validate_json_file, load_daily, load_weekly_goals, load_weekly_review

# ----------------------------
# Paths to schemas
# ----------------------------
const SCHEMA_PATHS = Dict(
    "daily" => "schema/daily_schema.json",
    "weekly_goals" => "schema/weekly_goals_schema.json",
    "weekly_review" => "schema/weekly_reviews_schema.json"
)

# ----------------------------
# Generic JSON validation
# ----------------------------
function validate_json_file(file_path::AbstractString, schema_type::AbstractString)
    @assert haskey(SCHEMA_PATHS, schema_type) "Unknown schema type: $schema_type"

    # Load schema
    schema_json = JSON3.read(open(SCHEMA_PATHS[schema_type], "r"), Dict)
    schema = JSONSchema.Schema(schema_json)

    # Load file
    data = JSON3.read(open(file_path, "r"), Dict)

    # Validate
    isvalid = JSONSchema.validate(schema, data)
    if !isvalid
        errors = JSONSchema.validate!(schema, data)
        error("JSON validation failed for $file_path under $schema_type schema:\n$errors")
    end

    return data
end

# ----------------------------
# Helper functions for specific data types
# ----------------------------

"""
    load_daily(file_path::String)

Load a daily JSON file and validate it against the daily schema.
Returns a Dict of parsed data.
"""
function load_daily(file_path::AbstractString)
    return validate_json_file(file_path, "daily")
end

"""
    load_weekly_goals(file_path::String)

Load a weekly goals JSON file and validate it.
"""
function load_weekly_goals(file_path::AbstractString)
    return validate_json_file(file_path, "weekly_goals")
end

"""
    load_weekly_review(file_path::String)

Load a weekly review JSON file and validate it.
"""
function load_weekly_review(file_path::AbstractString)
    return validate_json_file(file_path, "weekly_review")
end

end # module
