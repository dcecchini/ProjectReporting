module Domain


import ..Serialization: to_dict, from_dict

export Allocation,
       ExecutionState,
       Task,
       TeamMember,
       parse_allocation,
       allocation_to_string,
       allocation_from_string,
       allocation_to_label,
       execution_state_to_string,
       execution_state_from_string,
       allocation_sort_key,
       ALLOCATION_ORDER,
       ALLOCATION_LABELS,
       from_dict,
       to_dict

# -----------------------------
# Allocation Enum
# -----------------------------
@enum Allocation begin
    CORE                # main product development
    CORE_NLP            # NLP-related tasks
    CORE_INGESTION      # Ingestion-related tasks
    CORE_OMOP           # OMOP-related tasks
    CORE_PROVENANCE     # Provenance-related tasks
    CORE_GENAI          # GenAI-related tasks
    PROJECT_CLIENT      # implementation of your product for a client
    EXTERNAL_CLIENT     # work for client outside your product
    EXTERNAL_INHOUSE    # internal R&D / non-core initiatives
    AWAY                # PTO / unavailable
end

# Human-readable labels (configurable later)
const ALLOCATION_LABELS = Dict(
    CORE => get(ENV, "PROJECT_SHORTNAME", "Core") * "Development",
    CORE_NLP => get(ENV, "PROJECT_SHORTNAME", "Core") * " - NLP Pipeline",
    CORE_INGESTION => get(ENV, "PROJECT_SHORTNAME", "Core") * " - Ingestion",
    CORE_OMOP => get(ENV, "PROJECT_SHORTNAME", "Core") * " - OMOP Modeling",
    CORE_PROVENANCE => get(ENV, "PROJECT_SHORTNAME", "Core") * " - Provenance",
    CORE_GENAI => get(ENV, "PROJECT_SHORTNAME", "Core") * " - GenAI",
    PROJECT_CLIENT => get(ENV, "ALLOCATION_CLIENT_PROJECT", "Client Project"),
    EXTERNAL_CLIENT => get(ENV, "ALLOCATION_CLIENT_EXTERNAL", "External Client"),
    EXTERNAL_INHOUSE => get(ENV, "ALLOCATION_EXTERNAL_INHOUSE", "External Inhouse"),
    AWAY => get(ENV, "ALLOCATION_AWAY", "Away")
)

# -------------------------
# Parsing (string → enum)
# -------------------------
function allocation_from_string(s::String)::Allocation
    s = lowercase(strip(s))

    if s == "core"
        return CORE
    elseif s == "project_client"
        return PROJECT_CLIENT
    elseif s == "external_client"
        return EXTERNAL_CLIENT
    elseif s == "external_inhouse"
        return EXTERNAL_INHOUSE
    elseif s == "away"
        return AWAY
    elseif s in ["core_nlp", "nlp", "nlp_pipeline"]
        return CORE_NLP
    elseif s in ["core_ingestion", "ingestion"]
        return CORE_INGESTION
    elseif s in ["core_omop", "omop"]
        return CORE_OMOP
    elseif s in ["core_provenance", "provenance"]
        return CORE_PROVENANCE
    elseif s in ["core_genai", "genai"]
        return CORE_GENAI
    else
        @warn "Unknown allocation, defaulting to CORE" input=s
        return CORE
    end
end

# -------------------------
# Serialization (enum → string)
# -------------------------
function allocation_to_string(a::Allocation)::String
    return lowercase(string(a))
end

function allocation_to_label(a::Allocation)
    get(ALLOCATION_LABELS, a, ALLOCATION_LABELS[CORE])
end

function allocation_to_label(a::AbstractString)
    allocation_to_label(parse_allocation(a))
end

const STRING_TO_ALLOCATION = Dict(
    "CORE" => CORE,
    "PROJECT_CLIENT" => PROJECT_CLIENT,
    "EXTERNAL_CLIENT" => EXTERNAL_CLIENT,
    "EXTERNAL_INHOUSE" => EXTERNAL_INHOUSE,
    "AWAY" => AWAY,
    "CORE_NLP" => CORE_NLP,
    "CORE_INGESTION" => CORE_INGESTION,
    "CORE_OMOP" => CORE_OMOP,
    "CORE_PROVENANCE" => CORE_PROVENANCE,
    "CORE_GENAI" => CORE_GENAI
)

const ALLOCATION_TO_STRING = Dict(
    v => k for (k, v) in STRING_TO_ALLOCATION
)

function parse_allocation(s::AbstractString)
    get(STRING_TO_ALLOCATION, uppercase(s), CORE)  # fallback = CORE
end


const ALLOCATION_ORDER = [
    PROJECT_CLIENT,     # client delivery first
    CORE_INGESTION,
    CORE_NLP,
    CORE_OMOP,
    CORE_PROVENANCE,
    CORE_GENAI,
    CORE,               # core product
    EXTERNAL_CLIENT,    # other client work
    EXTERNAL_INHOUSE,   # internal R&D
    AWAY
]

function allocation_sort_key(a::Allocation)
    idx = findfirst(==(a), ALLOCATION_ORDER)
    return isnothing(idx) ? typemax(Int) : idx
end



# -----------------------------
# Core Entities
# -----------------------------

@enum ExecutionState begin
    ACTIVE
    BLOCKED
    SUPPORTING
    INACTIVE
    AWAY
end

function execution_state_from_string(s::String)
    s = lowercase(s)

    s == "active" && return ACTIVE
    s == "blocked" && return BLOCKED
    s == "supporting" && return SUPPORTING
    s == "inactive" && return INACTIVE
    s == "away" && return AWAY

    error("Unknown execution_state: $s")
end

function execution_state_to_string(e::ExecutionState)
    String(Symbol(e)) |> lowercase
end

"""
Represents a unit of work.
"""
struct Task
    goal_id::Union{Nothing, String}
    description::String
    allocation::Allocation
    execution_state::ExecutionState
    tags::Vector{String}
    blocker::Union{Nothing, String}
end

# -----------------------------
# Task serialization
# -----------------------------

function to_dict(t::Task)
    return Dict(
        "goal_id" => t.goal_id,
        "description" => t.description,
        "allocation" => allocation_to_string(t.allocation),
        "execution_state" => execution_state_to_string(t.execution_state),
        "tags" => t.tags,
        "blocker" => t.blocker
    )
end

function from_dict(::Type{Task}, d)
    return Task(
        get(d, :goal_id, nothing),
        get(d, :description, ""),
        parse_allocation(get(d, :allocation, "core")),
        execution_state_from_string(get(d, :execution_state, "active")),
        get(d, :tags, String[]),
        get(d, :blocker, nothing)
    )
end

"""
Represents a team member.
(kept minimal for now, but extensible)
"""
struct TeamMember
    name::String
end

to_dict(m::TeamMember) = Dict("name" => m.name)

function from_dict(::Type{TeamMember}, d)
    return TeamMember(get(d, :name, ""))
end

end # module