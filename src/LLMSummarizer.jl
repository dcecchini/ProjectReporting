module LLMSummarizer

using JSON3
using HTTP

export call_llm_ollama
export generate_summary

# ----------------------------
# Call Ollama local API
# ----------------------------
"""
    call_llm_ollama(prompt::String) -> String

Calls the local Ollama LLM API and returns the generated summary.
"""
function call_llm_ollama(prompt::String; kwargs...)
    url = "http://localhost:11434/api/generate"
    payload_dict = Dict{String,Any}(
        "model"  => "kamekichi128/qwen3-4b-instruct-2507",
        "prompt" => prompt,
        "stream" => false
    )
    for (k, v) in kwargs
        payload_dict[string(k)] = v
    end

    headers = ["Content-Type" => "application/json"]
    resp = HTTP.post(url, headers, JSON3.write(payload_dict))
    data = JSON3.read(String(resp.body))
    return data["response"]
end

function generate_summary(prompt::String; kwargs...)
    return call_llm_ollama(prompt; kwargs...)
end

end
