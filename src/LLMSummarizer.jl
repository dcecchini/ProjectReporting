module LLMSummarizer

using JSON3
using HTTP
using Logging

using ..LLMConfigService: LLMConfigService, LLMSettings, load_llm_settings, get_active_model, get_api_key

export AbstractLLMProvider
export OllamaProvider, OpenAIProvider
export LLM
export generate
export get_llm_from_settings

# ----------------------------
# Abstract Type Hierarchy
# ----------------------------

abstract type AbstractLLMProvider end

struct OllamaProvider <: AbstractLLMProvider
    model::String
    url::String
    use_chat::Bool  # Use /api/chat instead of /api/generate
end

# Default constructors
OllamaProvider() = OllamaProvider("qwen3.5:9b", "http://localhost:11434/api/generate", false)
OllamaProvider(model::String, url::String) = OllamaProvider(model, url, false)

struct OpenAIProvider <: AbstractLLMProvider
    model::String
    api_key::String
end

# Default constructor
OpenAIProvider() = OpenAIProvider("gpt-4o", "")

# ----------------------------
# LLM Container
# ----------------------------

struct LLM{P<:AbstractLLMProvider}
    provider::P
end

# ----------------------------
# Factory Functions
# ----------------------------

function get_llm_from_settings()::LLM
    settings = load_llm_settings()
    
    if settings.provider == LLMConfigService.OPENAI
        provider = OpenAIProvider(settings.openai_model, settings.openai_api_key)
    else
        provider = OllamaProvider(settings.ollama_model, settings.ollama_url)
    end
    
    return LLM(provider)
end

function OllamaProvider(settings::LLMSettings)
    return OllamaProvider(settings.ollama_model, settings.ollama_url, false)
end

function OpenAIProvider(settings::LLMSettings)
    return OpenAIProvider(settings.openai_model, settings.openai_api_key)
end

# ----------------------------
# Generate - Multiple Dispatch
# ----------------------------

function generate(llm::LLM{OllamaProvider}, prompt::String; kwargs...)
    return generate(llm.provider, prompt; kwargs...)
end

function generate(llm::LLM{OpenAIProvider}, prompt::String; kwargs...)
    return generate(llm.provider, prompt; kwargs...)
end

# Ollama implementation - uses /api/generate or /api/chat depending on use_chat flag
function generate(provider::OllamaProvider, prompt::String; kwargs...)
    if provider.use_chat
        return generate_chat(provider, prompt; kwargs...)
    else
        return generate_generate(provider, prompt; kwargs...)
    end
end

# /api/generate endpoint (legacy completion-style)
function generate_generate(provider::OllamaProvider, prompt::String; kwargs...)
    url = replace(provider.url, "/api/chat" => "/api/generate")
    
    payload_dict = Dict{String,Any}(
        "model"  => provider.model,
        "prompt" => prompt,
        "stream" => false,
        "options" => Dict{String,Any}(
            "num_ctx" => 32768  # 32k context window to handle large prompts with full weekly reports
        )
    )
    
    # Handle kwargs
    for (k, v) in kwargs
        k_str = string(k)
        if k_str == "format" && v == "json"
            payload_dict["format"] = "json"
        elseif k_str == "options"
            # Merge options dicts
            merge!(payload_dict["options"], v)
        elseif k_str != "think"
            payload_dict[k_str] = v
        end
    end

    headers = ["Content-Type" => "application/json"]
    payload_json = JSON3.write(payload_dict)
    @info "[LLMSummarizer] Calling Ollama /api/generate" model=provider.model url=url prompt_chars=length(prompt) has_format=haskey(payload_dict, "format")
    
    resp = HTTP.post(url, headers, payload_json)
    body_str = String(resp.body)
    @info "[LLMSummarizer] Ollama raw response" status=resp.status length=length(body_str)
    
    if resp.status != 200
        error("Ollama returned HTTP $(resp.status): $(body_str[1:min(500, length(body_str))])")
    end
    
    data = JSON3.read(body_str)
    
    if haskey(data, "error")
        error("Ollama error: $(data["error"])")
    end
    
    if !haskey(data, "response")
        error("Ollama response missing 'response' field. Raw: $(body_str[1:min(200, length(body_str))])")
    end
    
    response_text = data["response"]
    if isempty(response_text)
        @warn "[LLMSummarizer] Ollama returned empty response. Trying /api/chat fallback..."
        return generate_chat(provider, prompt; kwargs...)
    end
    
    return response_text
end

# /api/chat endpoint (chat completion style - often works better)
function generate_chat(provider::OllamaProvider, prompt::String; kwargs...)
    url = replace(provider.url, "/api/generate" => "/api/chat")
    
    messages = [
        Dict("role" => "system", "content" => "You are a helpful assistant that follows instructions precisely."),
        Dict("role" => "user", "content" => prompt)
    ]
    
    payload_dict = Dict{String,Any}(
        "model" => provider.model,
        "messages" => messages,
        "stream" => false,
        "options" => Dict{String,Any}(
            "num_ctx" => 32768  # 32k context window to handle large prompts with full weekly reports
        )
    )
    
    # Handle kwargs
    for (k, v) in kwargs
        k_str = string(k)
        if k_str == "format" && v == "json"
            payload_dict["format"] = "json"
        elseif k_str == "options"
            # Merge options dicts
            merge!(payload_dict["options"], v)
        elseif k_str != "think"
            payload_dict[k_str] = v
        end
    end

    headers = ["Content-Type" => "application/json"]
    payload_json = JSON3.write(payload_dict)
    @info "[LLMSummarizer] Calling Ollama /api/chat" model=provider.model url=url prompt_chars=length(prompt) has_format=haskey(payload_dict, "format")
    
    resp = HTTP.post(url, headers, payload_json)
    body_str = String(resp.body)
    @info "[LLMSummarizer] Ollama chat response" status=resp.status length=length(body_str)
    
    if resp.status != 200
        error("Ollama chat returned HTTP $(resp.status): $(body_str[1:min(500, length(body_str))])")
    end
    
    data = JSON3.read(body_str)
    
    if haskey(data, "error")
        error("Ollama chat error: $(data["error"])")
    end
    
    if !haskey(data, "message")
        error("Ollama chat response missing 'message' field. Raw: $(body_str[1:min(200, length(body_str))])")
    end
    
    response_text = data["message"]["content"]
    return response_text
end

# OpenAI implementation
function generate(provider::OpenAIProvider, prompt::String; kwargs...)
    if isempty(provider.api_key)
        error("OpenAI API key not configured. Please set it in the LLM Settings page.")
    end

    url = "https://api.openai.com/v1/chat/completions"
    
    messages = [
        Dict("role" => "system", "content" => "You are a helpful assistant."),
        Dict("role" => "user", "content" => prompt)
    ]
    
    payload_dict = Dict{String,Any}(
        "model" => provider.model,
        "messages" => messages,
        "temperature" => 0.7
    )
    
    # Handle kwargs
    for (k, v) in kwargs
        k_str = string(k)
        if k_str == "format" && v == "json"
            payload_dict["response_format"] = Dict("type" => "json_object")
        elseif k_str != "think"
            payload_dict[k_str] = v
        end
    end

    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(provider.api_key)"
    ]
    
    @info "[LLMSummarizer] Calling OpenAI" model=provider.model
    
    resp = HTTP.post(url, headers, JSON3.write(payload_dict))
    data = JSON3.read(String(resp.body))
    
    if haskey(data, "choices") && length(data["choices"]) > 0
        return data["choices"][1]["message"]["content"]
    else
        error("Unexpected OpenAI response format")
    end
end

end