---
name: lua_llm
description: "lua-llm (LuaLLM) API reference. Use when writing Lua code that uses lua-llm modules (LuaLLM, Client, Config, Embeddings, Tool, ToolRegistry, StreamHelpers, RateLimiter, Logger) or provider names (openai, claude, gemini, grok, groq, openrouter, ollama, deepseek, mistral)."
---

# lua-llm API Reference

lua-llm is a unified Lua client for 9 LLM providers. `require("lua-llm")` returns the `LuaLLM` module table.

## Architecture

```
lua-llm/
  init.lua              -- Public API: LuaLLM.new(), .Config, .Embeddings, .Tool, .ToolRegistry, .Logger, .RateLimiter
  core/
    client.lua          -- Client wraps a provider, delegates all 7 methods
    config.lua          -- Config.new(opts), Config.merge(base, override)
    provider.lua        -- Provider base class, 7 abstract methods
    embeddings.lua      -- Embeddings.new(provider, config), emb.embed(input, opts)
  providers/
    openai.lua          -- Extends Provider directly
    claude.lua          -- Extends Provider directly
    gemini.lua          -- Extends Provider directly
    openai_compatible.lua -- Shared base for OpenAI-format providers
    grok.lua            -- Extends OpenAICompatible
    groq.lua            -- Extends OpenAICompatible
    openrouter.lua      -- Extends OpenAICompatible
    ollama.lua          -- Extends OpenAICompatible
    deepseek.lua        -- Extends OpenAICompatible
    mistral.lua         -- Extends OpenAICompatible
  tools/
    tool.lua            -- Tool.new(), .parse_tool_calls(), .to_provider_format()
    registry.lua        -- ToolRegistry singleton: register, execute, process_response
  utils/
    http.lua            -- HTTP client with retries and exponential backoff
    http_streaming.lua  -- SSE streaming for OpenAI and Claude formats
    stream_helpers.lua  -- StreamHelpers: content_callback, tool_call_detector, safe_writer
    rate_limiter.lua    -- Token bucket rate limiter per provider
    logger.lua          -- Logger with levels and payload redaction
    env.lua             -- .env file loader
```

Provider base class (`core/provider.lua`) defines 7 abstract methods: `chat`, `complete`, `chat_with_tools`, `stream_chat`, `stream_complete`, `stream_chat_with_tools`, `list_models`.

## Providers

| Provider | Name | Default Model | Base URL | Auth |
|---|---|---|---|---|
| OpenAI | `"openai"` | `gpt-4o` | `https://api.openai.com/v1` | Bearer |
| Claude | `"claude"` | `claude-sonnet-4-6` | `https://api.anthropic.com/v1` | x-api-key |
| Gemini | `"gemini"` | `gemini-2.5-flash` | `https://generativelanguage.googleapis.com/v1beta` | Query param |
| Grok | `"grok"` | `grok-3` | `https://api.x.ai/v1` | Bearer |
| Groq | `"groq"` | `llama-3.3-70b-versatile` | `https://api.groq.com/openai/v1` | Bearer |
| OpenRouter | `"openrouter"` | `openai/gpt-4o` | `https://openrouter.ai/api/v1` | Bearer |
| Ollama | `"ollama"` | `llama3.2` | `http://localhost:11434/v1` | Optional |
| DeepSeek | `"deepseek"` | `deepseek-chat` | `https://api.deepseek.com/v1` | Bearer |
| Mistral | `"mistral"` | `mistral-large-latest` | `https://api.mistral.ai/v1` | Bearer |

## Client Creation & Config

```lua
local LuaLLM = require("lua-llm")

local client = LuaLLM.new("openai", {
  api_key = os.getenv("OPENAI_API_KEY"),
  model = "gpt-4o",        -- default per provider (see table above)
  temperature = 0.7,        -- default
  max_tokens = 1024,        -- default
  timeout = 120,            -- seconds, default
  retries = 3,              -- default
  retry_delay = 1,          -- base seconds, default
  base_url = "...",         -- override endpoint
})
```

All config fields except `api_key` are optional. Config can be overridden per-call via `options`.

## Basic Chat Usage

Messages are tables with `role` (`"system"`, `"user"`, `"assistant"`) and `content`:

```lua
local messages = {
  { role = "system", content = "You are a helpful assistant." },
  { role = "user", content = "Hello!" },
}

local response, err = client:chat(messages)
if not response then
  print("Error: " .. err)
  return
end

-- Accessing content differs by provider:
-- OpenAI-compatible (OpenAI, Grok, Groq, OpenRouter, Ollama, DeepSeek, Mistral):
print(response.choices[1].message.content)

-- Claude:
print(response.content)        -- string or content blocks table
print(response.stop_reason)    -- "end_turn", "tool_use", etc.

-- Gemini (normalized to flat format):
print(response.content)        -- string
print(response.finish_reason)  -- "STOP", etc.
```

## Client Methods

All return `result, err` (nil + error string on failure):

- `client:chat(messages, options?)` — Chat completion
- `client:complete(prompt, options?)` — Text completion
- `client:chat_with_tools(messages, tools, options?)` — Chat with tool definitions
- `client:stream_chat(messages, callback, options?)` — Stream chat, `callback(delta, full)`
- `client:stream_complete(prompt, callback, options?)` — Stream completion
- `client:stream_chat_with_tools(messages, tools, callback, options?)` — Stream with tools
- `client:list_models()` — List available models

## Streaming

Streaming methods call `callback(delta, full)` where `delta` is the incremental chunk and `full` is the accumulated response. SSE streaming auto-falls back to non-streaming.

```lua
-- Raw callback (provider-specific delta format):
client:stream_chat(messages, function(delta, full)
  -- OpenAI-compatible: delta.choices[1].delta.content
  -- Claude: delta.content
  -- Gemini: delta.content
end)

-- StreamHelpers normalizes across all providers (recommended):
local StreamHelpers = require("lua-llm.utils.stream_helpers")

client:stream_chat(messages,
  StreamHelpers.content_callback(function(content, full)
    io.write(content)  -- always a plain string, any provider
    io.flush()
  end)
)

-- Detect tool calls during streaming:
client:stream_chat_with_tools(messages, tools,
  StreamHelpers.tool_call_detector(
    function() print("[Tool call detected]") end,  -- on_tool_call
    function(text) io.write(text) end              -- on_content
  )
)
```

Other StreamHelpers: `safe_writer(text)` (safe stdout write), `get_provider_type(client)` (returns `"claude"`, `"openai"`, etc.).

## Tool Calling

### Defining Tools

Tools use JSON Schema for parameters:

```lua
local tools = {
  {
    name = "get_weather",
    description = "Get weather for a location",
    parameters = {
      type = "object",
      properties = {
        location = { type = "string", description = "City and state" },
      },
      required = { "location" },
    },
  },
}
```

### Manual Tool Flow

```lua
local Tool = LuaLLM.Tool

-- 1. Send chat with tools
local response, err = client:chat_with_tools(messages, tools)

-- 2. Parse tool calls (provider-agnostic)
local calls = Tool.parse_tool_calls(response, "openai")
-- OpenAI-compatible returns: { { id, tool_type, tool_function = { name, arguments } }, ... }
-- Claude returns:           { { id, name, arguments }, ... }

-- 3. Execute tools, build result messages, send follow-up
```

`Tool.to_provider_format(tools, provider_name)` converts generic tool definitions to provider-specific wire format. Supports `"openai"`, `"claude"`, `"grok"`, `"groq"`, `"openrouter"`.

### ToolRegistry (Automatic Execution)

Register tools with handlers, then let the registry handle the full loop:

```lua
local ToolRegistry = LuaLLM.ToolRegistry

-- Register a tool with a handler function
ToolRegistry.register("get_weather", {
  description = "Get weather for a location",
  parameters = {
    type = "object",
    properties = { location = { type = "string" } },
    required = { "location" },
  },
  handler = function(args)
    return { temperature = 22, condition = "sunny" }
  end,
})

-- Execute a tool directly
local result, err = ToolRegistry.execute("get_weather", { location = "Tokyo" })

-- Get tool definitions (without handlers) for API calls
local tool_defs = ToolRegistry.collection({ "get_weather" })

-- Automatic tool loop: executes tools, sends results back, calls callback with final response
local response = client:chat_with_tools(messages, tool_defs)
ToolRegistry.process_response(client, response, messages, function(final_response)
  print(ToolRegistry.extract_content(final_response))
end)

-- Same but streams the final response
ToolRegistry.process_response_streaming(client, response, messages,
  function(text) io.write(text) end,         -- stream_callback
  function(final) print("\nDone") end         -- final_callback (optional)
)
```

Other ToolRegistry methods: `register_many(map)`, `get(name)`, `get_definition(name)`, `exists(name)`, `unregister(name)`, `list()`, `create_collection(name, tool_names)`, `get_collection(name)`, `list_collections()`, `process_tool_calls(client, response, provider?)`.

Built-in standard tools: `get_weather` (mock), `calculator`. Built-in collections: `"standard"`, `"weather"`, `"calculator"`.

## Embeddings

```lua
local emb = LuaLLM.Embeddings.new("openai", {
  api_key = os.getenv("OPENAI_API_KEY"),
  base_url = "https://api.openai.com/v1",
})

local result, err = emb.embed("Hello, world!")
-- result.embeddings[1].embedding = { 0.01, -0.02, ... }

-- Batch: pass a table of strings
local result, err = emb.embed({ "Hello", "World" })
```

Supported: `"openai"` (text-embedding-3-small), `"gemini"` (text-embedding-004), `"mistral"`, `"ollama"`, `"deepseek"` (all OpenAI-compatible). Override model with `options.model` or `config.embedding_model`.

## Config Defaults

`temperature = 0.7`, `max_tokens = 1024`, `timeout = 120`, `retries = 3`, `retry_delay = 1`, `debug = false`, `redact_payloads = true` (Logger).

## Development Patterns

**Adding a new provider**: Create `providers/new_name.lua` extending `Provider` or `OpenAICompatible`. Implement the 7 abstract methods. Register in `init.lua`'s `LuaLLM.new()` dispatch.

**Error handling**: All methods return `result, err`. Always check:

```lua
local result, err = client:chat(messages)
if not result then
  print("Error: " .. err)
  return
end
```

**Extended thinking**: Claude supports `{ thinking = true, thinking_budget = N }` (temperature forced to 1). OpenAI o-series supports `{ reasoning_effort = "low"|"medium"|"high" }` (uses `max_completion_tokens`, no `temperature`).

## Testing

```bash
busted                    # Unit tests (mock HTTP, no API keys)
busted --run integration  # Integration tests (requires API keys in .env)
```

Tests use busted framework. Unit tests mock HTTP; integration tests hit real APIs (missing keys auto-skip).

## Key Files

| File | Purpose |
|---|---|
| `lua-llm/init.lua` | Public API, provider dispatch |
| `lua-llm/core/client.lua` | Client class, delegates to provider |
| `lua-llm/core/config.lua` | Config defaults and merging |
| `lua-llm/core/provider.lua` | Abstract base with 7 methods |
| `lua-llm/core/embeddings.lua` | Embeddings client |
| `lua-llm/tools/tool.lua` | Tool format conversion and parsing |
| `lua-llm/tools/registry.lua` | ToolRegistry singleton |
| `lua-llm/utils/stream_helpers.lua` | StreamHelpers utilities |
| `lua-llm/utils/http_streaming.lua` | SSE streaming implementation |
| `lua-llm/utils/rate_limiter.lua` | Token bucket rate limiter |
| `lua-llm/utils/logger.lua` | Configurable logger |
| `lua-llm/utils/env.lua` | .env file loader |
