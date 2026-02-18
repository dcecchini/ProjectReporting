#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Dates
using ArgParse
using SimpleProjectReporting.Config
using SimpleProjectReporting.Daily
using SimpleProjectReporting.LLMSummarizer


# ----------------------------------------------------
# Main function
# ----------------------------------------------------
function main()
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--date", "-d"
        help = "Date for daily report (YYYY-MM-DD), default today"
        arg_type = String
        default = Dates.format(Dates.today(), "yyyy-mm-dd")

        "--llm-summary"
            help = "Generate an LLM summary for the report"
            action = :store_true
        "--llm-summary-output"
            help = "Where to put the LLM summary: append | separate"
            arg_type = String
            default = "append"
    end
    args = parse_args(s)

    println("Args: ", args)
    
    date_str = args["date"]
    llm_summary = get(args, "llm-summary", false)
    llm_output = get(args, "llm-summary-output", "append")

    # Load existing daily data if any
    daily_data = load_daily(date_str)

    if daily_data === nothing
        println("No daily data found for $date_str, creating new entry.")
        # Create template tasks (empty, or could prompt CLI input)
        tasks = []
    else
        println("Loaded existing daily data for $date_str")
        tasks = daily_data.tasks
    end

    # Optional: validate tasks
    for t in tasks
        # linked_goal and priority_changed are optional, default false
        if t.linked_goal === nothing
            t.linked_goal = false
        end
        if t.priority_changed === nothing
            t.priority_changed = false
        end
    end

    # Generate human-readable report
    report_text = generate_daily_report(date_str, tasks)

    if (llm_summary === true)
        println("Generating LLM summary...")
        prompt = build_daily_prompt(date_str, tasks, report_text)
        summary_text = generate_summary(prompt)
        println("LLM summary generated.")

        report_path = joinpath(Config.DAILY_REPORTS_DIR, "$date_str.txt")
        if llm_output == "append"
            open(report_path, "a") do io
                write(io, "\n\nLLM SUMMARY\n===========\n\n")
                write(io, summary_text)
                write(io, "\n")
            end
        elseif llm_output == "separate"
            summary_path = joinpath(Config.DAILY_REPORTS_DIR, "$date_str.llm.txt")
            open(summary_path, "w") do io
                write(io, summary_text)
            end
        else
            error("Invalid --llm-summary-output. Use 'append' or 'separate'.")
        end
    end

    println("Daily report generation complete for $date_str")
end

# ----------------------------------------------------
# Run main
# ----------------------------------------------------
main()
