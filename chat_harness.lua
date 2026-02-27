package.path = package.path .. ";/home/edmorley/dev/github/xyz-ai-dev/xyz-llm/?.lua;/home/edmorley/dev/github/xyz-ai-dev/xyz-llm/?/init.lua"

local LuaLLM = require("lua-llm")
local env = require("lua-llm.utils.env")

env.load(".env")

local client = LuaLLM.new("claude", {
  api_key = env.get("ANTHROPIC_API_KEY"),
  model = "claude-sonnet-4-6",
})

local messages = {
  { role = "system", content = "You are a helpful assistant." },
}

print("Chat started (type 'quit' to exit)\n")

while true do
  io.write("You: ")
  io.flush()
  local input = io.read("*l")

  if not input or input:lower() == "quit" then
    print("Goodbye!")
    break
  end

  if input:match("^%s*$") then
    goto continue
  end

  table.insert(messages, { role = "user", content = input })

  io.write("\nAssistant: ")
  io.flush()

  local reply_parts = {}
  local response, err = client:stream_chat(messages, function(delta)
    local text = delta.content
    if type(text) == "string" and text ~= "" then
      reply_parts[#reply_parts + 1] = text
      io.write(text)
      io.flush()
    elseif type(text) == "table" then
      -- Fallback path: non-streaming content blocks
      for _, block in ipairs(text) do
        if block.type == "text" and block.text then
          reply_parts[#reply_parts + 1] = block.text
          io.write(block.text)
          io.flush()
        end
      end
    end
  end)

  if not response then
    print("\nError: " .. tostring(err))
    table.remove(messages) -- remove the failed user message
  else
    table.insert(messages, { role = "assistant", content = table.concat(reply_parts) })
  end

  io.write("\n\n")
  io.flush()
  ::continue::
end
