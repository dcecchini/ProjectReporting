module WeeklyReviewValidator

export validate_weekly_review

const VALID_STATUSES = Set([
    "achieved",
    "partially_achieved",
    "not_achieved",
    "cancelled",
    "rolled_over"
])

function validate_weekly_review(review::Dict)
    @assert review["schema_version"] == 1 "Invalid schema_version"

    @assert haskey(review, "week")
    @assert haskey(review, "goals")

    for goal in review["goals"]
        validate_goal(goal)
    end

    return true
end

function validate_goal(goal::Dict)
    status = goal["status"]

    @assert status in VALID_STATUSES "Invalid status: $status"

    if status != "cancelled"
        ratio = goal["completion_ratio"]
        @assert 0.0 <= ratio <= 1.0 "Invalid completion_ratio"
    end

    if status == "achieved"
        @assert goal["completion_ratio"] == 1.0
    end

    if status == "not_achieved"
        @assert goal["completion_ratio"] == 0.0
    end

    if status == "rolled_over"
        @assert !isnothing(goal["rolled_over_to"])
    end

    return true
end

end
