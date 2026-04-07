module DiffUtils

export diff_tasks

"""
    diff_tasks(prev::Union{Nothing,String}, curr::String; sep::Union{Char,String}=';')

Compute the difference between two task strings and return a list of tasks with their status.

The separator is used to split the task strings into individual tasks. Then the tasks are compared
and the status of each task is determined: 
- `:added`: The task is new
- `:unchanged`: The task is still in progress
- `:removed`: The task is assumed to be completed

# Arguments
- `prev::Union{Nothing,String}`: The previous task string.
- `curr::String`: The current task string.

# Returns
- `Vector{NamedTuple{(:text, :status), Tuple{String, Symbol}}}`: A list of tasks with their status.
"""
function diff_tasks(prev::Union{Nothing,String}, curr::String; sep::Union{Char,String}=';')
    prev_set = prev === nothing ? Set{String}() :
        Set(strip.(split(prev, sep)))

    curr_set = Set(strip.(split(curr, sep)))

    added = setdiff(curr_set, prev_set)
    removed = setdiff(prev_set, curr_set)
    unchanged = intersect(prev_set, curr_set)

    result = []

    append!(result, [(text=t, status=:added) for t in added])
    append!(result, [(text=t, status=:unchanged) for t in unchanged])
    append!(result, [(text=t, status=:removed) for t in removed])

    return result
end

end