module ProjectReporting

include("config.jl")
include("utils/logging.jl")
include("SchemaValidator.jl")
include("Core/serialization.jl")
include("Core/domain.jl")
include("Core/daily_model.jl")
# include("weekly.jl")
# include("monthly.jl")
# include("LLMSummarizer.jl")
include("utils/diff.jl")
include("Services/daily_service.jl")
include("Services/weekly_goals_service.jl")
include("Services/report_service.jl")
include("Services/teams_service.jl")


using .Config
using .LoggingConfig
using .SchemaValidator
using .Serialization
using .Domain
using .DailyModel
# using .Weekly
# using .Monthly
# using .LLMSummarizer
using .DailyService
using .WeeklyGoalsService
using .DiffUtils
using .ReportService
using .TeamsService

# export generate_weekly_report
# export generate_monthly_report
# export generate_daily_report

end
