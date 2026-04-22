module UI

Base.@kwdef mutable struct TaskVM
    goal_id::String = ""
    description::String = ""
    allocation::String = "core"
    execution_state::String = "active"
    blocker::String = ""
end

Base.@kwdef mutable struct MemberVM
    name::String = ""
    capacity::Int = 100
    active::String = "true"
    note::String = ""
    tasks::Vector{TaskVM} = TaskVM[]
end

Base.@kwdef mutable struct WeeklyGoalVM
    goal_id::String = ""
    goal_description::String = ""
    priority::Int = 3
    completed::String = "false"
    workstream::String = ""
end

Base.@kwdef mutable struct TeamRosterMemberVM
    name::String = ""
    capacity::Int = 100
    active::String = "true"
    note::String = ""
end

end