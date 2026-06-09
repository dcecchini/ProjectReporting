module LLMConfigService

using JSON3
using Logging

export LLMProvider, OLLAMA, OPENAI
export LLMSettings
export load_llm_settings, save_llm_settings
export get_active_model, get_api_key
export set_model, set_api_key, set_provider

@enum LLMProvider OLLAMA OPENAI

Base.@kwdef mutable struct LLMSettings
    provider::LLMProvider = OLLAMA
    ollama_model::String = "qwen3.5:9b"
    ollama_url::String = "http://localhost:11434/api/generate"
    openai_model::String = "gpt-4o"
    openai_api_key::String = ""
end

const SETTINGS_FILE = "llm_settings.json"

function settings_path()::String
    return joinpath(@__DIR__, "..", "..", "data", SETTINGS_FILE)
end

function load_llm_settings()::LLMSettings
    path = settings_path()
    
    if !isfile(path)
        @info "[LLMConfig] No settings file found, using defaults"
        return LLMSettings()
    end
    
    try
        data = JSON3.read(read(path, String))
        
        provider_str = get(data, :provider, "ollama")
        provider = provider_str == "openai" ? OPENAI : OLLAMA
        
        return LLMSettings(
            provider = provider,
            ollama_model = string(get(data, :ollama_model, "qwen3.5:9b")),
            ollama_url = string(get(data, :ollama_url, "http://localhost:11434/api/generate")),
            openai_model = string(get(data, :openai_model, "gpt-4o")),
            openai_api_key = string(get(data, :openai_api_key, ""))
        )
    catch e
        @error "[LLMConfig] Failed to load settings, using defaults" exception=(e, catch_backtrace())
        return LLMSettings()
    end
end

function save_llm_settings(settings::LLMSettings)
    path = settings_path()
    
    payload = Dict(
        "provider" => settings.provider == OPENAI ? "openai" : "ollama",
        "ollama_model" => settings.ollama_model,
        "ollama_url" => settings.ollama_url,
        "openai_model" => settings.openai_model,
        "openai_api_key" => settings.openai_api_key
    )
    
    open(path, "w") do io
        JSON3.write(io, payload; indent=2)
    end
    
    @info "[LLMConfig] Settings saved"
    return nothing
end

function get_active_model(settings::LLMSettings)::String
    if settings.provider == OPENAI
        return settings.openai_model
    else
        return settings.ollama_model
    end
end

function get_api_key(settings::LLMSettings)::String
    return settings.openai_api_key
end

function get_provider_name(settings::LLMSettings)::String
    return settings.provider == OPENAI ? "openai" : "ollama"
end

function set_provider(settings::LLMSettings, provider::String)
    if lowercase(provider) == "openai"
        settings.provider = OPENAI
    else
        settings.provider = OLLAMA
    end
    return settings
end

function set_model(settings::LLMSettings, model::String)
    if settings.provider == OPENAI
        settings.openai_model = model
    else
        settings.ollama_model = model
    end
    return settings
end

function set_api_key(settings::LLMSettings, key::String)
    settings.openai_api_key = key
    return settings
end

function set_ollama_url(settings::LLMSettings, url::String)
    settings.ollama_url = url
    return settings
end

end # module
