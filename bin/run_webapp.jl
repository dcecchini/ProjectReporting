#!/usr/bin/env julia
using Genie, Stipple, StippleUI
using SimpleProjectReporting.Config
using SimpleProjectReporting.webapp.AppModel
using SimpleProjectReporting.webapp.Backend
using SimpleProjectReporting.webapp.UI

Config.ensure_directories()

model = AppModel.AppModel()

Backend.load_daily!(model)
Backend.update_weekly_metrics!(model)
Backend.update_monthly_metrics!(model)

Stipple.run(model, UI.build_ui(model); host="127.0.0.1", port=8000)
