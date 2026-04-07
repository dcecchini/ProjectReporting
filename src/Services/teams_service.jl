module TeamsService

using HTTP
using JSON3
using Logging
using ..Config
using ..DiffUtils
using ..ReportService: Report, ReportTask, ReportSection, group_tasks_by_member
using ..Domain: allocation_to_label

export send_to_teams, send


function task_to_line(member::String, t::ReportTask)
    prefix =
        t.status == :new       ? "  🔵" :
        t.status == :completed ? "  ✅" :
        t.status == :unchanged ? "   •" :
        t.status == :blocked   ? "  ⚠" :
        "   •"

    return "$(prefix) [$(member)] $(t.description)"
end

function member_block(member::String, tasks::Vector{ReportTask})
    tasks_text = join((t -> task_to_line(member, t)).(tasks), "\n")

    Dict(
        "type" => "TextBlock",
        "text" => tasks_text,
        "wrap" => true,
        "spacing" => "None"
    )
end

function section_block(section::ReportSection)
    grouped = group_tasks_by_member(section.tasks)

    Dict(
        "type" => "Container",
        "bleed" => true,
        "spacing" => "Medium",
        "separator" => true,
        "items" => vcat(
            [
                Dict(
                    "type" => "TextBlock",
                    "text" => "▶️ $(allocation_to_label(section.allocation))",
                    "weight" => "Bolder",
                    "size" => "Medium",
                    "spacing" => "None"
                )
            ],
            [
                member_block(member, tasks)
                for (member, tasks) in grouped
            ]
        )
    )
end

function blockers_block(blockers::Vector{ReportTask})
    grouped = group_tasks_by_member(blockers)

    Dict(
        "type" => "Container",
        "bleed" => true,
        "items" => vcat(
            [
                Dict(
                    "type" => "TextBlock",
                    "text" => "⚠ Blockers",
                    "weight" => "Bolder",
                    "size" => "Medium",
                    "color" => "Attention"
                )
            ],
            [member_block(member, tasks) for (member, tasks) in grouped]
        )
    )
end

function build_adaptive_card(report::Report)
    body = Any[]

    # -----------------------------
    # Title
    # -----------------------------
    push!(body, Dict(
        "type" => "TextBlock",
        "text" => "📅 $(report.date) DS Team Updates",
        "weight" => "Bolder",
        "size" => "Large"
    ))

    # -----------------------------
    # Blockers
    # -----------------------------
    if !isempty(report.blockers)
        push!(body, blockers_block(report.blockers))
    end

    # -----------------------------
    # Sections
    # -----------------------------
    for section in report.sections
        push!(body, section_block(section))
    end

    return Dict(
        "type" => "AdaptiveCard",
        "version" => "1.4",
        "msteams" => Dict("width" => "Full"),
        "body" => body
    )
end


function build_teams_payload(card)
    return Dict(
        "type" => "message",
        "attachments" => [
            Dict(
                "contentType" => "application/vnd.microsoft.card.adaptive",
                "content" => card
            )
        ]
    )
end

function send_to_teams(report)
    url = Config.TEAMS_WEBHOOK_URL

    if isempty(url)
        error("TEAMS_WEBHOOK_URL is not set")
    end

    card = build_adaptive_card(report)
    payload = build_teams_payload(card)

    body = JSON3.write(payload)
    @info "[Teams] Sending to webhook" bytes=sizeof(body)

    resp = HTTP.post(
        url,
        ["Content-Type" => "application/json"],
        body
    )

    resp_body = try
        String(resp.body)
    catch
        ""
    end

    status_text = try
        HTTP.Messages.statustext(resp.status)
    catch
        ""
    end

    @info "[Teams] Response" status=resp.status status_text=status_text body=resp_body

    return resp.status
end

function send(payload)
    url = Config.TEAMS_WEBHOOK_URL

    if isempty(url)
        error("TEAMS_WEBHOOK_URL is not set")
    end

    body = JSON3.write(payload)
    @info "[Teams] Sending raw payload to webhook" bytes=sizeof(body)

    resp = HTTP.post(
        url,
        ["Content-Type" => "application/json"],
        body
    )

    resp_body = try
        String(resp.body)
    catch
        ""
    end

    status_text = try
        HTTP.Messages.statustext(resp.status)
    catch
        ""
    end

    @info "[Teams] Response" status=resp.status status_text=status_text body=resp_body

    return resp.status
end

end # Module