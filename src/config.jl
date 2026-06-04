module Config

using Dates
using DotEnv
using Logging

export ensure_directories
export daily_data_path
export weekly_goals_path
export weekly_metrics_path
export monthly_metrics_path
export weekly_report_path
export monthly_report_path
export iso_week_string
export month_string


# Load environment variables (secrets)
DotEnv.load!()

const PROJECT_NAME = get(ENV, "PROJECT_NAME", "Patient Journey Intelligence")
const PROJECT_SHORTNAME = get(ENV, "PROJECT_SHORTNAME", "PJI")

# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

const ROOT_DIR = normpath(joinpath(@__DIR__, ".."))


# Set logging
const LOG_LEVEL = Logging.Info         # Debug | Info | Warn | Error
const LOG_DIR = joinpath(ROOT_DIR, "log")


# ------------------------------------------------------------
# Data Directories
# ------------------------------------------------------------

const DATA_DIR = joinpath(ROOT_DIR, "data")

const DAILY_DATA_DIR      = joinpath(DATA_DIR, "daily")
const WEEKLY_GOALS_DIR    = joinpath(DATA_DIR, "weekly_goals")
const WEEKLY_METRICS_DIR  = joinpath(DATA_DIR, "weekly_metrics")
const MONTHLY_METRICS_DIR = joinpath(DATA_DIR, "monthly_metrics")

# ------------------------------------------------------------
# Reports Directories
# ------------------------------------------------------------

const REPORTS_DIR          = joinpath(ROOT_DIR, "reports")

const DAILY_REPORTS_DIR    = joinpath(REPORTS_DIR, "daily")
const WEEKLY_REPORTS_DIR   = joinpath(REPORTS_DIR, "weekly")
const MONTHLY_REPORTS_DIR  = joinpath(REPORTS_DIR, "monthly")


# ------------------------------------------------------------
# Secrets from environment variables
# ------------------------------------------------------------

const TEAMS_WEBHOOK_URL = get(ENV, "TEAMS_WEBHOOK_URL", "")


# ------------------------------------------------------------
# Directory Initialization
# ------------------------------------------------------------

function ensure_directories()

    dirs = (
        DATA_DIR,
        DAILY_DATA_DIR,
        WEEKLY_GOALS_DIR,
        WEEKLY_METRICS_DIR,
        MONTHLY_METRICS_DIR,
        REPORTS_DIR,
        DAILY_REPORTS_DIR,
        WEEKLY_REPORTS_DIR,
        MONTHLY_REPORTS_DIR
    )

    for dir in dirs
        isdir(dir) || mkpath(dir)
    end

    return nothing
end

# ------------------------------------------------------------
# Date Formatting Helpers
# ------------------------------------------------------------

"""
Return ISO week string like: 2026-W07
"""
function iso_week_string(d::Date)
    y, w = year(d), week(d)
    return string(y, "-W", lpad(w, 2, '0'))
end

"""
Return month string like: 2026-02
"""
function month_string(d::Date)
    return string(year(d), "-", lpad(month(d), 2, '0'))
end

# ------------------------------------------------------------
# Data Path Helpers
# ------------------------------------------------------------

function daily_data_path(d::Date)
    joinpath(DAILY_DATA_DIR,
        string(d) * ".json")
end

function weekly_goals_path(week::String)
    joinpath(WEEKLY_GOALS_DIR,
        week * ".json")
end

function weekly_metrics_path(week::String)
    joinpath(WEEKLY_METRICS_DIR,
        week * ".json")
end

function monthly_metrics_path(month::String)
    joinpath(MONTHLY_METRICS_DIR,
        month * ".json")
end

# ------------------------------------------------------------
# Report Path Helpers
# ------------------------------------------------------------

function weekly_report_path(week::String)
    joinpath(WEEKLY_REPORTS_DIR,
        week * ".txt")
end

function monthly_report_path(month::String)
    joinpath(MONTHLY_REPORTS_DIR,
        month * ".txt")
end


# --- Split into tasks ---
function split_tasks(text::String; sep::Union{Char,String}=';')
    isempty(strip(text)) && return String[]
    return strip.(split(text, sep))
end

end
