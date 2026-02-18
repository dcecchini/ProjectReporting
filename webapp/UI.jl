module UI

using Stipple
using StippleUI
using AppModel
using Backend

export build_ui

function build_ui(model::AppModel.AppModel)
    page(
        title="SimpleProjectReporting",
        
        # -------------------
        # Daily Logs Section
        # -------------------
        section("Daily Logs",
            DatePicker(model.selected_date, label="Select Date"),
            Table(
                model.daily_tasks,
                editable=true,
                columns=[:owner, :title, :linked_goal, :priority_changed],
                labels=Dict(
                    :owner=>"Owner",
                    :title=>"Task",
                    :linked_goal=>"Linked Goal",
                    :priority_changed=>"Priority Changed"
                )
            ),
            Button("Save Daily Log", save_daily!(model))
        ),

        # -------------------
        # Weekly Metrics Section
        # -------------------
        section("Weekly Metrics",
            HBox(
                label("Select Week (YYYY-W##):"),
                TextInput(model.selected_week)
            ),
            Button("Update Weekly Metrics", Backend.update_weekly_metrics!(model)),
            # Table view
            Table(
                model.weekly_metrics,
                columns=[:owner, :completion_pct, :weighted_completion, :drift_ratio, :unplanned_ratio, :priority_changes],
                labels=Dict(
                    :owner=>"Owner",
                    :completion_pct=>"Completion %",
                    :weighted_completion=>"Weighted Completion %",
                    :drift_ratio=>"Drift Ratio %",
                    :unplanned_ratio=>"Unplanned Work %",
                    :priority_changes=>"Priority Changes"
                )
            )
        ),

        # -------------------
        # Monthly Metrics Section
        # -------------------
        section("Monthly Metrics",
            HBox(
                label("Select Month (YYYY-MM):"),
                TextInput(model.selected_month)
            ),
            Button("Update Monthly Metrics", Backend.update_monthly_metrics!(model)),
            # Table view
            Table(
                model.monthly_metrics,
                columns=[:owner, :completion_pct, :weighted_completion, :drift_ratio, :unplanned_ratio, :priority_changes],
                labels=Dict(
                    :owner=>"Owner",
                    :completion_pct=>"Completion %",
                    :weighted_completion=>"Weighted Completion %",
                    :drift_ratio=>"Drift Ratio %",
                    :unplanned_ratio=>"Unplanned Work %",
                    :priority_changes=>"Priority Changes"
                )
            )
        )
    )
end

end
