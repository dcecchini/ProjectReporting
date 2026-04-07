#!/usr/bin/env julia

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using ArgParse
using ProjectReporting
using ProjectReporting.Weekly
using ProjectReporting.Config
using ProjectReporting.LLMSummarizer

# -----------------------------
# Main Execution
# -----------------------------
function main()
    s = ArgParseSettings()
    @add_arg_table s begin
        "--week"
            help = "Week to generate report for (format: YYYY-Www)"
            required = true
        "--llm-summary"
            help = "Generate an LLM summary for the report"
            action = :store_true
        "--llm-summary-output"
            help = "Where to put the LLM summary: append | separate"
            arg_type = String
            default = "append"
    end

    # Use the new ArgParse 1.0+ syntax
    args = parse_args(s)

    week_str = args["week"]
    llm_summary = get(args, "llm_summary", false)
    llm_output = get(args, "llm_summary_output", "append")
    data = load_weekly_data(week_str)

    owners = unique(g.owner for g in data.goals)
    metrics = [evaluate_owner(o, data) for o in owners]

    report_text = render_metrics_report(metrics)

    # Save everything
    save_weekly(week_str, data, report_text)

    if llm_summary
        prompt = build_weekly_prompt(week_str, data, metrics, report_text)
        summary_text = generate_summary(prompt)

        report_path = joinpath(Config.WEEKLY_REPORTS_DIR, "$week_str.txt")
        if llm_output == "append"
            open(report_path, "a") do io
                write(io, "\n\nLLM SUMMARY\n===========\n\n")
                write(io, summary_text)
                write(io, "\n")
            end
        elseif llm_output == "separate"
            summary_path = joinpath(Config.WEEKLY_REPORTS_DIR, "$week_str.llm.txt")
            open(summary_path, "w") do io
                write(io, summary_text)
            end
        else
            error("Invalid --llm-summary-output. Use 'append' or 'separate'.")
        end
    end

    println("Weekly report saved")
end

main()
