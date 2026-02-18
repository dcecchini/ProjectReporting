module SimpleProjectReporting

include("config.jl")
include("daily.jl")
include("weekly.jl")
include("monthly.jl")
include("LLMSummarizer.jl")

using .Config
using .Daily
using .Weekly
using .Monthly
using .LLMSummarizer

export generate_weekly_report
export generate_monthly_report
export generate_daily_report

end
