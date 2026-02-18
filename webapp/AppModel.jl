module AppModel

using Stipple
using SimpleProjectReporting.Weekly

@reactive mutable struct AppModel <: ReactiveModel
    # --- Daily data ---
    selected_date::Observable{Date} = Observable(Dates.today())
    daily_tasks::Observable{Vector{Task}} = Observable(Vector{Task}())

    # --- Weekly/Monthly metrics ---
    selected_week::Observable{String} = Observable(string(Dates.year(Dates.today()), "-W", lpad(Dates.week(Dates.today()),2,"0")))
    weekly_metrics::Observable{Vector{OwnerMetrics}} = Observable(Vector{OwnerMetrics}())

    selected_month::Observable{String} = Observable(string(Dates.year(Dates.today()), "-", lpad(Dates.month(Dates.today()),2,"0")))
    monthly_metrics::Observable{Vector{OwnerMetrics}} = Observable(Vector{OwnerMetrics}())
end

end
