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
function call_llm_ollama(prompt::String)
    url = "http://localhost:11434/api/generate"
    payload = JSON3.write(Dict(
        "model" => "kamekichi128/qwen3-4b-instruct-2507",   
        "prompt" => prompt,
        "stream" => false
    ))

    headers = ["Content-Type" => "application/json"]
    resp = HTTP.post(url, headers, payload)
    data = JSON3.read(String(resp.body))
    return data["response"]
end

function generate_summary(prompt::String)
    return call_llm_ollama(prompt)
end

end
