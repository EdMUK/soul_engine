-- room_harness.lua — Multi-NPC tavern chat harness for the soul engine
-- Simulates "The Hollow Lantern" tavern with 5 NPCs, each running the full
-- 6-layer emotion pipeline. Tests emergent group conversation dynamics.

package.path = package.path .. ";/home/edmorley/dev/github/xyz-ai-dev/xyz-llm/?.lua;/home/edmorley/dev/github/xyz-ai-dev/xyz-llm/?/init.lua"

local LuaLLM = require("lua-llm")
local env = require("lua-llm.utils.env")
local EmotionSystem = require("emotions.init")
local Triggers = EmotionSystem.Triggers
local Presentation = EmotionSystem.Presentation
local Beliefs = EmotionSystem.Beliefs
local Erosion = EmotionSystem.Erosion
local History = EmotionSystem.History

env.load(".env")

local client = LuaLLM.new("claude", {
    api_key = env.get("ANTHROPIC_API_KEY"),
    model = "claude-sonnet-4-6",
})

-- ---------------------------------------------------------------------------
-- ANSI color helpers
-- ---------------------------------------------------------------------------
local COLORS = {
    reset   = "\27[0m",
    bold    = "\27[1m",
    dim     = "\27[2m",
    green   = "\27[32m",
    red     = "\27[31m",
    yellow  = "\27[33m",
    cyan    = "\27[36m",
    magenta = "\27[35m",
    white   = "\27[37m",
    grey    = "\27[90m",
}

local NPC_COLORS = {
    Marta   = COLORS.green,
    Garrick = COLORS.red,
    ["Old Fen"] = COLORS.yellow,
    Tess    = COLORS.cyan,
    ["Brother Aldric"] = COLORS.magenta,
}

local function colored(name, text)
    return (NPC_COLORS[name] or COLORS.white) .. text .. COLORS.reset
end

-- ---------------------------------------------------------------------------
-- Custom trigger topics
-- ---------------------------------------------------------------------------
Triggers.TOPICS.mining = {
    keywords = {"mine", "mining", "miner", "cave", "tunnel", "ore"},
    default_deltas = {happiness = -0.05, anxiety = 0.1},
}
Triggers.TOPICS.faith = {
    keywords = {"faith", "gods", "prayer", "temple", "blessing", "divine", "monk"},
    default_deltas = {confidence = 0.05, anxiety = -0.05},
}
Triggers.TOPICS.trade = {
    keywords = {"merchant", "trade", "caravan", "goods", "coin", "market"},
    default_deltas = {happiness = 0.1, energy = 0.05},
}

-- ---------------------------------------------------------------------------
-- Custom presentation situation: tavern
-- ---------------------------------------------------------------------------
Presentation.SITUATIONS.tavern = {
    happiness = {bias = 0.15, strength = 0.2},
    anger     = {bias = -0.2, strength = 0.3},
    anxiety   = {bias = -0.1, strength = 0.15},
    energy    = {bias = -0.05, strength = 0.1},
}

-- ---------------------------------------------------------------------------
-- Time tracking
-- ---------------------------------------------------------------------------
local game_time = 0
local function get_time() return game_time end

-- ---------------------------------------------------------------------------
-- NPC definitions
-- ---------------------------------------------------------------------------
local NPC_DEFS = {
    {
        name = "Marta",
        personality = "worrier",
        role = "Displaced village healer",
        backstory = "Marta fled her village when soldiers burned it. She carries herbs and guilt in equal measure, tending to anyone who needs healing while wondering if she could have saved more.",
        beliefs = {
            {text = "Every life has equal value", strength = 0.85, inertia = 0.7, tags = {"pacifism", "justice"}},
            {text = "The gods test us through suffering", strength = 0.75, inertia = 0.6, tags = {"faith", "family"}},
        },
        sensitivities = {
            war   = {deltas = {happiness = -0.3, fear = 0.2, anxiety = 0.2}, intensity = 1.3, desensitize_rate = 0.05, min_intensity = 0.4},
            home  = {deltas = {happiness = -0.25, loneliness = 0.2}, intensity = 1.2, desensitize_rate = 0.05, min_intensity = 0.3},
            death = {deltas = {happiness = -0.3, fear = 0.15, anxiety = 0.2}, intensity = 1.4, desensitize_rate = 0.05, min_intensity = 0.4},
        },
        starting_nudges = {anxiety = 0.3, fear = 0.15, happiness = -0.1},
        speaking_style = "Speaks softly, often trailing off. Uses healing metaphors. Hesitant but compassionate.",
    },
    {
        name = "Garrick",
        personality = "hothead",
        role = "Bitter mercenary, betrayed by his commander",
        backstory = "Garrick served loyally for twelve years until his captain sold his unit out for gold. He survived the ambush. Most didn't. Now he drinks to forget and fights anyone who mentions loyalty.",
        beliefs = {
            {text = "Loyalty means nothing in the end", strength = 0.8, inertia = 0.6, tags = {"loyalty", "trust"}},
            {text = "Strength is the only thing that keeps you alive", strength = 0.9, inertia = 0.8, tags = {"conflict", "self"}},
        },
        sensitivities = {
            war   = {deltas = {anger = 0.3, happiness = -0.1}, intensity = 1.3, desensitize_rate = 0.05, min_intensity = 0.5},
            death = {deltas = {anger = 0.25, happiness = -0.15}, intensity = 1.2, desensitize_rate = 0.05, min_intensity = 0.4},
            love  = {deltas = {loneliness = 0.3, anger = 0.1, happiness = -0.15}, intensity = 1.1, desensitize_rate = 0.05, min_intensity = 0.3},
        },
        starting_nudges = {anger = 0.4, trust = -0.3, happiness = -0.2},
        speaking_style = "Blunt and aggressive. Short sentences. Swears occasionally. Challenges others directly.",
    },
    {
        name = "Old Fen",
        personality = "stoic",
        role = "Retired miner who lost his son",
        backstory = "Fen spent forty years in the deep mines. His son followed him down and never came back up. Fen doesn't talk about it. He nurses his ale and watches the fire, speaking only when something matters.",
        beliefs = {
            {text = "Hard work is the only honest way", strength = 0.9, inertia = 0.85, tags = {"justice", "self"}},
            {text = "The dead are at peace — it's the living who suffer", strength = 0.7, inertia = 0.6, tags = {"family", "faith"}},
        },
        sensitivities = {
            father = {deltas = {happiness = -0.2, loneliness = 0.15}, intensity = 1.3, desensitize_rate = 0.03, min_intensity = 0.5},
            death  = {deltas = {happiness = -0.15, loneliness = 0.1}, intensity = 1.2, desensitize_rate = 0.03, min_intensity = 0.4},
            home   = {deltas = {happiness = -0.1, loneliness = 0.1}, intensity = 1.0, desensitize_rate = 0.05, min_intensity = 0.3},
            mining = {deltas = {happiness = -0.1, anxiety = 0.15, loneliness = 0.1}, intensity = 1.4, desensitize_rate = 0.03, min_intensity = 0.5},
        },
        starting_nudges = {happiness = -0.15, loneliness = 0.2, energy = -0.1},
        speaking_style = "Speaks rarely and briefly. Measured words. Uses mining metaphors. Long pauses implied.",
    },
    {
        name = "Tess",
        personality = "social",
        role = "Merchant's daughter, young and curious",
        backstory = "Tess travels with her father's caravan, seeing the world for the first time. Everything is new and exciting. She hasn't yet learned that the world can be cruel, but the road is teaching her.",
        beliefs = {
            {text = "People are basically good at heart", strength = 0.85, inertia = 0.5, tags = {"trust", "relationships"}},
            {text = "Something wonderful is always around the next corner", strength = 0.8, inertia = 0.4, tags = {"family", "self"}},
        },
        sensitivities = {
            father = {deltas = {happiness = 0.2, confidence = 0.1}, intensity = 1.2, desensitize_rate = 0.05, min_intensity = 0.3},
            love   = {deltas = {happiness = 0.2, energy = 0.1}, intensity = 1.1, desensitize_rate = 0.05, min_intensity = 0.3},
            home   = {deltas = {happiness = 0.15, loneliness = -0.1}, intensity = 1.0, desensitize_rate = 0.05, min_intensity = 0.3},
            trade  = {deltas = {happiness = 0.15, confidence = 0.1, energy = 0.1}, intensity = 1.3, desensitize_rate = 0.05, min_intensity = 0.4},
        },
        starting_nudges = {happiness = 0.3, energy = 0.25, confidence = 0.15, trust = 0.2},
        speaking_style = "Enthusiastic and chatty. Asks lots of questions. Uses 'oh!' and exclamations. Optimistic.",
    },
    {
        name = "Brother Aldric",
        personality = "default",
        role = "Traveling monk wrestling with doubt",
        backstory = "Aldric left his monastery to walk the world and test his faith against reality. He's seen kindness and cruelty in equal measure. His prayers feel hollow some nights, fervent on others.",
        beliefs = {
            {text = "Faith requires doubt to be genuine", strength = 0.75, inertia = 0.65, tags = {"faith", "self"}},
            {text = "Violence is sometimes necessary to protect the innocent", strength = 0.6, inertia = 0.5, tags = {"pacifism", "conflict"}},
        },
        sensitivities = {
            death = {deltas = {happiness = -0.15, anxiety = 0.15, fear = 0.1}, intensity = 1.2, desensitize_rate = 0.05, min_intensity = 0.3},
            war   = {deltas = {anxiety = 0.2, anger = 0.1, happiness = -0.1}, intensity = 1.1, desensitize_rate = 0.05, min_intensity = 0.3},
            love  = {deltas = {happiness = 0.1, loneliness = 0.1}, intensity = 1.0, desensitize_rate = 0.05, min_intensity = 0.3},
            faith = {deltas = {confidence = 0.1, anxiety = -0.1}, intensity = 1.3, desensitize_rate = 0.03, min_intensity = 0.5},
        },
        starting_nudges = {anxiety = 0.15, confidence = -0.1},
        speaking_style = "Thoughtful and measured. Uses religious references naturally. Sometimes quotes scripture then questions it.",
    },
}

-- ---------------------------------------------------------------------------
-- Initialize NPCs
-- ---------------------------------------------------------------------------
local npcs = {}
for _, def in ipairs(NPC_DEFS) do
    local char = EmotionSystem.new_full_character(def.personality, {
        get_time = get_time,
        beliefs = def.beliefs,
        sensitivities = def.sensitivities,
    })
    -- Apply starting nudges
    for emotion, delta in pairs(def.starting_nudges) do
        EmotionSystem.nudge(char, emotion, delta)
    end
    -- Enter tavern situation
    Presentation.enter_situation(char, "tavern")
    table.insert(npcs, {
        char = char,
        name = def.name,
        role = def.role,
        backstory = def.backstory,
        speaking_style = def.speaking_style,
        spoke_last_turn = false,
        _last_triggers = {},
        _last_belief_impacts = {},
        _last_emotion_snapshot = EmotionSystem.get_emotions(char),
    })
end

-- ---------------------------------------------------------------------------
-- Room transcript (sliding window)
-- ---------------------------------------------------------------------------
local MAX_TRANSCRIPT = 30
local transcript = {}

local function add_to_transcript(name, text)
    table.insert(transcript, {name = name, text = text})
    while #transcript > MAX_TRANSCRIPT do
        table.remove(transcript, 1)
    end
end

local function format_transcript()
    local lines = {}
    for _, entry in ipairs(transcript) do
        table.insert(lines, "[" .. entry.name .. "]: " .. entry.text)
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Emotion label helper
-- ---------------------------------------------------------------------------
local function emotion_label(value)
    local abs = math.abs(value)
    if abs < 0.1 then return "neutral"
    elseif abs < 0.3 then return value > 0 and "slight" or "slightly negative"
    elseif abs < 0.5 then return value > 0 and "moderate" or "moderately negative"
    elseif abs < 0.7 then return value > 0 and "strong" or "strongly negative"
    else return value > 0 and "intense" or "intensely negative"
    end
end

-- ---------------------------------------------------------------------------
-- System prompt builder
-- ---------------------------------------------------------------------------
local function build_system_prompt(npc)
    local char = npc.char
    local parts = {}

    -- Identity
    table.insert(parts, string.format("You are %s, a %s.", npc.name, npc.role))
    table.insert(parts, npc.backstory)
    table.insert(parts, "")

    -- Personality
    table.insert(parts, string.format("Personality type: %s", char.personality))
    table.insert(parts, string.format("Speaking style: %s", npc.speaking_style))
    table.insert(parts, "")

    -- Core emotions (true feelings)
    table.insert(parts, "YOUR TRUE FEELINGS (what you actually feel):")
    local core = EmotionSystem.get_emotions(char)
    for _, e in ipairs(EmotionSystem.EMOTIONS) do
        local v = core[e]
        if math.abs(v) > 0.05 then
            table.insert(parts, string.format("  %s: %.2f (%s)", e, v, emotion_label(v)))
        end
    end
    table.insert(parts, "")

    -- Presented emotions (what they show)
    local perceived = Presentation.get_perceived(char)
    local strain = Presentation.get_masking_strain(char)
    table.insert(parts, "WHAT YOU SHOW OTHERS (your outward demeanor):")
    for _, e in ipairs(EmotionSystem.EMOTIONS) do
        local v = perceived[e]
        if math.abs(v) > 0.05 then
            table.insert(parts, string.format("  %s: %.2f (%s)", e, v, emotion_label(v)))
        end
    end
    if strain > 0.1 then
        table.insert(parts, string.format("  Masking strain: %.2f — %s",
            strain,
            strain > 0.5 and "your facade is cracking" or "you're holding it together"))
    end
    table.insert(parts, "")

    -- Beliefs
    local beliefs = Beliefs.get_beliefs(char)
    if #beliefs > 0 then
        table.insert(parts, "YOUR CORE BELIEFS:")
        for i, b in ipairs(beliefs) do
            local prox = ""
            if b.erosion then
                local p = Erosion.get_tipping_proximity(char, i)
                if p > 0.3 then
                    prox = string.format(" [under pressure: %.0f%%]", p * 100)
                end
            end
            table.insert(parts, string.format('  - "%s" (conviction: %.0f%%)%s',
                b.text, b.strength * 100, prox))
        end
        table.insert(parts, "")
    end

    -- Emotional history
    local shifts = History.get_narrative_shifts(char, 0.2)
    if #shifts > 0 then
        table.insert(parts, "EMOTIONAL SHIFTS YOU'VE EXPERIENCED TONIGHT:")
        for _, s in ipairs(shifts) do
            table.insert(parts, string.format("  Your %s shifted from %s to %s",
                s.emotion, emotion_label(s.from), emotion_label(s.to)))
        end
        table.insert(parts, "")
    end

    -- Instructions
    table.insert(parts, "INSTRUCTIONS:")
    table.insert(parts, "- Stay fully in character as " .. npc.name)
    table.insert(parts, "- Respond in 1-3 sentences, first person")
    table.insert(parts, "- Let your emotions color your speech naturally")
    table.insert(parts, "- React to what others say based on your beliefs and feelings")
    table.insert(parts, "- Never mention game mechanics, emotion numbers, or that you are an AI")
    table.insert(parts, "- You are in a dimly lit tavern called The Hollow Lantern, late evening, rain outside")

    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Room manager: score NPCs and pick responders
-- ---------------------------------------------------------------------------
local TALKATIVENESS = {
    social  = 0.3,
    hothead = 0.2,
    default = 0.15,
    worrier = 0.1,
    stoic   = 0.05,
}

local function score_npc(npc)
    local score = 0
    local char = npc.char

    -- 1. Trigger activation (weight 0.3)
    local trigger_score = math.min(1, #npc._last_triggers * 0.4)
    score = score + trigger_score * 0.3

    -- 2. Belief impact (weight 0.3)
    local belief_score = 0
    for _, impact in pairs(npc._last_belief_impacts) do
        if impact == "challenged" then
            belief_score = belief_score + 0.5
        elseif impact == "reinforced" then
            belief_score = belief_score + 0.3
        end
    end
    belief_score = math.min(1, belief_score)
    score = score + belief_score * 0.3

    -- 3. Peak emotion intensity (weight 0.2)
    local peak = 0
    for _, e in ipairs(EmotionSystem.EMOTIONS) do
        local v = math.abs(char.emotions[e])
        if v > peak then peak = v end
    end
    score = score + peak * 0.2

    -- 4. Personality talkativeness
    score = score + (TALKATIVENESS[char.personality] or 0.15)

    -- 5. Cooldown penalty
    if npc.spoke_last_turn then
        score = score * 0.5
    end

    -- 6. Random factor
    score = score + math.random() * 0.15

    return score
end

local function select_responders()
    local scores = {}
    for i, npc in ipairs(npcs) do
        scores[i] = {index = i, score = score_npc(npc), name = npc.name}
    end
    table.sort(scores, function(a, b) return a.score > b.score end)

    local top_score = scores[1].score
    local threshold = top_score * 0.6
    local responders = {scores[1].index}  -- top scorer always speaks

    -- Others speak if within 60% of top score (up to 3 total)
    for i = 2, #scores do
        if #responders >= 3 then break end
        if scores[i].score >= threshold then
            table.insert(responders, scores[i].index)
        end
    end

    return responders
end

-- ---------------------------------------------------------------------------
-- Emotion pipeline: process a message through all NPCs
-- ---------------------------------------------------------------------------
local function run_emotion_pipeline(text)
    game_time = game_time + 1
    for _, npc in ipairs(npcs) do
        local char = npc.char

        -- Snapshot emotions before processing
        npc._last_emotion_snapshot = EmotionSystem.get_emotions(char)

        -- Advance trigger cooldowns
        Triggers.advance_turn(char)

        -- Process text through triggers
        npc._last_triggers = Triggers.process_text(char, text)

        -- Evaluate beliefs
        local scene = "A dimly lit tavern called The Hollow Lantern. Late evening, rain outside."
        local deltas, impacts = Beliefs.evaluate(char, scene, text)
        npc._last_belief_impacts = impacts

        -- Apply belief emotion deltas via nudge
        for emotion, delta in pairs(deltas) do
            if char.emotions[emotion] ~= nil then
                EmotionSystem.nudge(char, emotion, delta)
            end
        end

        -- Erosion: process evaluation and tick time
        if char.beliefs and #char.beliefs.entries > 0 then
            Erosion.process_evaluation(char, impacts, deltas)
            Erosion.tick(char, game_time)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Display helpers
-- ---------------------------------------------------------------------------
local function show_emotion_changes(npc)
    local char = npc.char
    local old = npc._last_emotion_snapshot
    local current = EmotionSystem.get_emotions(char)
    local changes = {}
    for _, e in ipairs(EmotionSystem.EMOTIONS) do
        local delta = current[e] - old[e]
        if math.abs(delta) > 0.05 then
            table.insert(changes, string.format("%s %+.2f", e, delta))
        end
    end
    if #changes > 0 then
        print(COLORS.dim .. "  [emotions: " .. table.concat(changes, ", ") .. "]" .. COLORS.reset)
    end
end

local function show_triggers(npc)
    if #npc._last_triggers > 0 then
        local topics = {}
        for _, t in ipairs(npc._last_triggers) do
            table.insert(topics, t.topic)
        end
        print(COLORS.dim .. "  [triggers: " .. table.concat(topics, ", ") .. "]" .. COLORS.reset)
    end
end

local function show_belief_impacts(npc)
    local char = npc.char
    local beliefs = Beliefs.get_beliefs(char)
    for idx, impact in pairs(npc._last_belief_impacts) do
        if type(idx) == "number" and impact ~= "neutral" and beliefs[idx] then
            local prox = ""
            if beliefs[idx].erosion then
                local p = Erosion.get_tipping_proximity(char, idx)
                if p > 0.1 then
                    prox = string.format(" (tipping: %.0f%%)", p * 100)
                end
            end
            print(COLORS.dim .. string.format('  [belief %s: "%s"%s]',
                impact, beliefs[idx].text, prox) .. COLORS.reset)
        end
    end
end

-- ---------------------------------------------------------------------------
-- LLM call with streaming
-- ---------------------------------------------------------------------------
local function stream_npc_response(npc)
    local system_prompt = build_system_prompt(npc)
    local transcript_text = format_transcript()

    local user_content
    if #transcript > 0 then
        user_content = "Here is the conversation so far:\n\n" .. transcript_text
            .. "\n\nNow respond as " .. npc.name .. "."
    else
        user_content = "The tavern is quiet. A stranger just walked in from the rain. Respond as " .. npc.name .. "."
    end

    local messages = {
        {role = "system", content = system_prompt},
        {role = "user", content = user_content},
    }

    io.write(colored(npc.name, npc.name .. ": "))
    io.flush()

    local reply_parts = {}
    local response, err = client:stream_chat(messages, function(delta)
        local text = delta.content
        if type(text) == "string" and text ~= "" then
            reply_parts[#reply_parts + 1] = text
            io.write(colored(npc.name, text))
            io.flush()
        elseif type(text) == "table" then
            for _, block in ipairs(text) do
                if block.type == "text" and block.text then
                    reply_parts[#reply_parts + 1] = block.text
                    io.write(colored(npc.name, block.text))
                    io.flush()
                end
            end
        end
    end, {max_tokens = 256, temperature = 0.8})

    io.write("\n")

    if not response then
        print(COLORS.red .. "  [LLM error: " .. tostring(err) .. "]" .. COLORS.reset)
        return nil
    end

    local full_reply = table.concat(reply_parts)
    return full_reply
end

-- ---------------------------------------------------------------------------
-- Special commands
-- ---------------------------------------------------------------------------
local function cmd_status()
    print(COLORS.bold .. "\n=== Emotional Status ===" .. COLORS.reset)
    for _, npc in ipairs(npcs) do
        print(colored(npc.name, "\n" .. npc.name) .. COLORS.dim .. " (" .. npc.char.personality .. ")" .. COLORS.reset)
        local core = EmotionSystem.get_emotions(npc.char)
        local perceived = Presentation.get_perceived(npc.char)
        for _, e in ipairs(EmotionSystem.EMOTIONS) do
            local c = core[e]
            local p = perceived[e]
            if math.abs(c) > 0.05 or math.abs(p) > 0.05 then
                local mask_indicator = ""
                if math.abs(c - p) > 0.05 then
                    mask_indicator = COLORS.dim .. string.format(" (shows %.2f)", p) .. COLORS.reset
                end
                print(string.format("  %-12s %+.2f %s%s", e, c, emotion_label(c), mask_indicator))
            end
        end
        local strain = Presentation.get_masking_strain(npc.char)
        if strain > 0.05 then
            print(COLORS.dim .. string.format("  masking strain: %.2f", strain) .. COLORS.reset)
        end
    end
    print("")
end

local function cmd_beliefs()
    print(COLORS.bold .. "\n=== Beliefs ===" .. COLORS.reset)
    for _, npc in ipairs(npcs) do
        print(colored(npc.name, "\n" .. npc.name))
        local beliefs = Beliefs.get_beliefs(npc.char)
        for i, b in ipairs(beliefs) do
            local prox = ""
            if b.erosion then
                local p = Erosion.get_tipping_proximity(npc.char, i)
                prox = string.format(" | pressure: %.0f%%", p * 100)
            end
            print(string.format('  [%d] "%.50s" — strength: %.0f%%, inertia: %.0f%%%s',
                i, b.text, b.strength * 100, b.inertia * 100, prox))
        end
    end
    print("")
end

local function cmd_history()
    print(COLORS.bold .. "\n=== Emotional History ===" .. COLORS.reset)
    for _, npc in ipairs(npcs) do
        local shifts = History.get_narrative_shifts(npc.char, 0.15)
        if #shifts > 0 then
            print(colored(npc.name, "\n" .. npc.name))
            for _, s in ipairs(shifts) do
                print(string.format("  %s: %.2f -> %.2f (%s)",
                    s.emotion, s.from, s.to, s.cause))
            end
        end
    end
    print("")
end

local function cmd_triggers()
    print(COLORS.bold .. "\n=== Trigger Sensitivities ===" .. COLORS.reset)
    for _, npc in ipairs(npcs) do
        local topics = Triggers.get_sensitive_topics(npc.char)
        if #topics > 0 then
            print(colored(npc.name, "\n" .. npc.name))
            for _, t in ipairs(topics) do
                print(string.format("  %s — intensity: %.2f", t.topic, t.intensity))
            end
        end
    end
    print("")
end

-- ---------------------------------------------------------------------------
-- Welcome banner
-- ---------------------------------------------------------------------------
local function show_banner()
    print(COLORS.bold .. [[

╔══════════════════════════════════════════════════════╗
║            THE HOLLOW LANTERN                        ║
║         A dimly lit tavern at the edge of a forest   ║
╚══════════════════════════════════════════════════════╝]] .. COLORS.reset)
    print()
    print(COLORS.dim .. "Rain drums against the shutters. A fire crackles low." .. COLORS.reset)
    print(COLORS.dim .. "Five souls share the warmth tonight:" .. COLORS.reset)
    print()
    print(colored("Marta", "  Marta") .. "           — Displaced village healer, haunted by loss")
    print(colored("Garrick", "  Garrick") .. "         — Bitter mercenary, trust long broken")
    print(colored("Old Fen", "  Old Fen") .. "         — Retired miner, grief worn into silence")
    print(colored("Tess", "  Tess") .. "            — Merchant's daughter, bright-eyed and curious")
    print(colored("Brother Aldric", "  Brother Aldric") .. "  — Traveling monk, faith cracking at the edges")
    print()
    print(COLORS.dim .. "Commands: /status  /beliefs  /history  /triggers  quit" .. COLORS.reset)
    print(COLORS.dim .. string.rep("─", 55) .. COLORS.reset)
    print()
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
show_banner()

while true do
    io.write(COLORS.bold .. "You: " .. COLORS.reset)
    io.flush()
    local input = io.read("*l")

    if not input or input:lower() == "quit" then
        print(COLORS.dim .. "\nYou step out into the rain. The door closes behind you." .. COLORS.reset)
        break
    end

    if input:match("^%s*$") then goto continue end

    -- Handle commands
    if input == "/status" then cmd_status(); goto continue end
    if input == "/beliefs" then cmd_beliefs(); goto continue end
    if input == "/history" then cmd_history(); goto continue end
    if input == "/triggers" then cmd_triggers(); goto continue end

    -- Add player message to transcript
    add_to_transcript("You", input)
    print()

    -- Run emotion pipeline on player message for all NPCs
    run_emotion_pipeline(input)

    -- Select who speaks
    local responder_indices = select_responders()

    -- Mark spoke_last_turn
    for _, npc in ipairs(npcs) do npc.spoke_last_turn = false end

    -- Each responder speaks in sequence
    for _, idx in ipairs(responder_indices) do
        local npc = npcs[idx]
        npc.spoke_last_turn = true

        -- Generate and stream response
        local reply = stream_npc_response(npc)
        if reply then
            -- Show emotion debug info
            show_emotion_changes(npc)
            show_triggers(npc)
            show_belief_impacts(npc)

            -- Add NPC response to transcript
            add_to_transcript(npc.name, reply)

            -- Process this NPC's speech through all OTHER NPCs' pipelines
            for _, other_npc in ipairs(npcs) do
                if other_npc ~= npc then
                    local other = other_npc.char
                    other_npc._last_emotion_snapshot = EmotionSystem.get_emotions(other)
                    Triggers.advance_turn(other)
                    local triggers = Triggers.process_text(other, reply)
                    local scene = "A dimly lit tavern called The Hollow Lantern."
                    local deltas, impacts = Beliefs.evaluate(other, scene, reply)
                    for emotion, delta in pairs(deltas) do
                        if other.emotions[emotion] ~= nil then
                            EmotionSystem.nudge(other, emotion, delta)
                        end
                    end
                    if other.beliefs and #other.beliefs.entries > 0 then
                        Erosion.process_evaluation(other, impacts, deltas)
                        Erosion.tick(other, game_time)
                    end
                    -- Merge triggers/impacts for display purposes (accumulate)
                    for _, t in ipairs(triggers) do
                        table.insert(other_npc._last_triggers, t)
                    end
                end
            end

            print()
        end
    end

    ::continue::
end
