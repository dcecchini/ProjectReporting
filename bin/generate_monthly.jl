#!/usr/bin/env julia

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))  # Activate project environment

using Dates
using ArgParse
using ProjectReporting
using ProjectReporting.Monthly
using ProjectReporting.Config
using ProjectReporting.LLMSummarizer


# -----------------------------
# Main
# -----------------------------
function main()
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--month"
            help = "Month to generate report for (format: YYYY-MM)"
            required = true
        "--llm-summary"
            help = "Generate an LLM summary for the report"
            action = :store_true
        "--llm-summary-output"
            help = "Where to put the LLM summary: append | separate"
            arg_type = String
            default = "append"
    end

    args = parse_args(s)
    month_str = args["month"]
    llm_summary = get(args, "llm_summary", false)
    llm_output = get(args, "llm_summary_output", "append")

    Config.ensure_directories()
    data = load_monthly_data(month_str)

    report_text = generate_monthly_report(data)

    report_path = joinpath(Config.MONTHLY_REPORTS_DIR, "$month_str.txt")
    open(report_path, "w") do io
        write(io, report_text)
    end

    if llm_summary
        prompt = build_monthly_prompt(month_str, data, report_text)
        summary_text = generate_summary(prompt)
        if llm_output == "append"
            open(report_path, "a") do io
                write(io, "\n\nLLM SUMMARY\n===========\n\n")
                write(io, summary_text)
                write(io, "\n")
            end
        elseif llm_output == "separate"
            summary_path = joinpath(Config.MONTHLY_REPORTS_DIR, "$month_str.llm.txt")
            open(summary_path, "w") do io
                write(io, summary_text)
            end
        else
            error("Invalid --llm-summary-output. Use 'append' or 'separate'.")
        end
    end

    println("Monthly report saved to $report_path")
end

main()
