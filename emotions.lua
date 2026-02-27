-- emotions.lua — Emotion tracking system for virtual game characters
local EmotionSystem = {}

local function clamp(x) return math.max(-1, math.min(1, x)) end

local EMOTIONS = { "happiness", "anger", "fear", "trust", "energy", "loneliness", "anxiety", "confidence" }

local function default_emotions()
    local e = {}
    for _, name in ipairs(EMOTIONS) do e[name] = 0 end
    return e
end

-- Interaction definitions: base emotion deltas per interaction type
local INTERACTIONS = {
    social = {
        happiness = 0.2,  loneliness = -0.3, energy = -0.1,
        trust = 0.1,      confidence = 0.05,
    },
    conflict = {
        anger = 0.3,      fear = 0.2,        trust = -0.2,
        happiness = -0.1,  anxiety = 0.2,     confidence = -0.1,
    },
    achievement = {
        happiness = 0.3,  energy = 0.1,      fear = -0.1,
        confidence = 0.3, anxiety = -0.2,
    },
    loss = {
        happiness = -0.3, anger = 0.1,       fear = 0.1,
        loneliness = 0.2, confidence = -0.2,  anxiety = 0.2,
    },
    rest = {
        energy = 0.3,     anger = -0.1,      fear = -0.1,
        anxiety = -0.15,
    },
    threat = {
        fear = 0.4,       anger = 0.1,       trust = -0.2,
        happiness = -0.1,  anxiety = 0.3,     confidence = -0.1,
    },
}

-- Cross-effects matrix: when emotion A changes by delta, emotion B shifts by delta * factor
-- Single-pass, non-recursive — no feedback loops
local CROSS_EFFECTS = {
    happiness  = { anger = -0.3,  fear = -0.2,  loneliness = -0.15, anxiety = -0.15, confidence = 0.1 },
    anger      = { happiness = -0.2, trust = -0.25, anxiety = 0.1 },
    fear       = { anger = 0.1,  energy = -0.15, anxiety = 0.3,  confidence = -0.2 },
    trust      = { loneliness = -0.2, happiness = 0.15, anxiety = -0.1 },
    energy     = { happiness = 0.1, confidence = 0.1 },
    loneliness = { happiness = -0.2, trust = -0.1, anxiety = 0.2 },
    anxiety    = { happiness = -0.15, energy = -0.1, confidence = -0.2, fear = 0.1 },
    confidence = { happiness = 0.1, anxiety = -0.25, fear = -0.1 },
}

-- Personality profiles: per-emotion multipliers (default 1.0 when absent)
local PERSONALITIES = {
    default = {},
    worrier = { fear = 1.5, anxiety = 1.6, anger = 0.7, trust = 0.6, confidence = 0.5 },
    hothead = { anger = 1.8, happiness = 1.2, fear = 0.5, confidence = 1.3 },
    stoic   = { happiness = 0.5, anger = 0.4, fear = 0.4, anxiety = 0.4, loneliness = 0.6 },
    social  = { loneliness = 1.6, trust = 1.3, happiness = 1.2, confidence = 1.1 },
}

-- Get personality multiplier for a given emotion and personality name
local function personality_mult(personality, emotion)
    local profile = PERSONALITIES[personality] or PERSONALITIES.default
    return profile[emotion] or 1.0
end

--- Create a new character with the named personality profile.
function EmotionSystem.new_character(personality_name)
    personality_name = personality_name or "default"
    assert(PERSONALITIES[personality_name], "unknown personality: " .. tostring(personality_name))
    return {
        emotions = default_emotions(),
        personality = personality_name,
    }
end

--- Return a copy of all emotions for a character.
function EmotionSystem.get_emotions(char)
    local copy = {}
    for k, v in pairs(char.emotions) do copy[k] = v end
    return copy
end

--- Return a single emotion value.
function EmotionSystem.get_emotion(char, name)
    assert(char.emotions[name], "unknown emotion: " .. tostring(name))
    return char.emotions[name]
end

--- Apply an interaction to a character.
-- Returns a table of the final deltas that were applied.
function EmotionSystem.apply_interaction(char, interaction_name, intensity)
    intensity = intensity or 1.0
    local base = INTERACTIONS[interaction_name]
    assert(base, "unknown interaction: " .. tostring(interaction_name))

    -- Step 1-2: Compute intensity-scaled base deltas
    local base_deltas = {}
    for emotion, delta in pairs(base) do
        base_deltas[emotion] = delta * intensity
    end

    -- Step 3: Compute cross-effects from base deltas (single-pass, non-recursive)
    local cross_deltas = {}
    for _, emotion in ipairs(EMOTIONS) do cross_deltas[emotion] = 0 end

    for source_emotion, source_delta in pairs(base_deltas) do
        local effects = CROSS_EFFECTS[source_emotion]
        if effects then
            for target_emotion, factor in pairs(effects) do
                cross_deltas[target_emotion] = cross_deltas[target_emotion] + source_delta * factor
            end
        end
    end

    -- Step 4-5: Sum base + cross, then apply personality multipliers
    local applied = {}
    for _, emotion in ipairs(EMOTIONS) do
        local raw = (base_deltas[emotion] or 0) + cross_deltas[emotion]
        local mult = personality_mult(char.personality, emotion)
        local final_delta = raw * mult
        applied[emotion] = final_delta
        -- Step 6: Add to current state and clamp
        char.emotions[emotion] = clamp(char.emotions[emotion] + final_delta)
    end

    return applied
end

--- Directly adjust one emotion (for scripted events). Applies personality multiplier.
function EmotionSystem.nudge(char, emotion_name, delta)
    assert(char.emotions[emotion_name] ~= nil, "unknown emotion: " .. tostring(emotion_name))
    local mult = personality_mult(char.personality, emotion_name)
    local final_delta = delta * mult
    char.emotions[emotion_name] = clamp(char.emotions[emotion_name] + final_delta)
    return final_delta
end

--- Return a human-readable string summary of a character's emotional state.
function EmotionSystem.describe(char)
    local parts = { string.format("Character [%s]:", char.personality) }
    for _, emotion in ipairs(EMOTIONS) do
        table.insert(parts, string.format("  %-12s %+.3f", emotion, char.emotions[emotion]))
    end
    return table.concat(parts, "\n")
end

-- Self-test block: run with `lua emotions.lua` to see example output
if not pcall(debug.getlocal, 4, 1) then
    local function banner(msg) print("\n" .. string.rep("=", 50) .. "\n" .. msg .. "\n" .. string.rep("=", 50)) end

    -- Test 1: Social interaction reduces loneliness on a lonely character
    banner("Test 1: Social interaction on a lonely character")
    local alice = EmotionSystem.new_character("social")
    alice.emotions.loneliness = 0.6
    print("Before: loneliness=" .. alice.emotions.loneliness .. ", happiness=" .. alice.emotions.happiness)
    EmotionSystem.apply_interaction(alice, "social", 1.0)
    print("After:  loneliness=" .. string.format("%.3f", alice.emotions.loneliness)
        .. ", happiness=" .. string.format("%.3f", alice.emotions.happiness))
    assert(alice.emotions.loneliness < 0.6, "loneliness should decrease after social interaction")
    assert(alice.emotions.happiness > 0, "happiness should increase after social interaction")
    print("PASS")

    -- Test 2: Different personalities produce different results
    banner("Test 2: Personality differences under threat")
    local worrier = EmotionSystem.new_character("worrier")
    local hothead = EmotionSystem.new_character("hothead")
    local stoic   = EmotionSystem.new_character("stoic")
    EmotionSystem.apply_interaction(worrier, "threat", 1.0)
    EmotionSystem.apply_interaction(hothead, "threat", 1.0)
    EmotionSystem.apply_interaction(stoic,   "threat", 1.0)
    print(EmotionSystem.describe(worrier))
    print(EmotionSystem.describe(hothead))
    print(EmotionSystem.describe(stoic))
    assert(worrier.emotions.fear > hothead.emotions.fear, "worrier should be more afraid than hothead")
    assert(hothead.emotions.anger > worrier.emotions.anger, "hothead should be angrier than worrier")
    assert(stoic.emotions.fear < worrier.emotions.fear, "stoic should be less afraid than worrier")
    print("PASS")

    -- Test 3: Clamping — high intensity should not exceed [-1, +1]
    banner("Test 3: Clamping with extreme intensity")
    local extreme = EmotionSystem.new_character("default")
    EmotionSystem.apply_interaction(extreme, "threat", 10.0)
    print(EmotionSystem.describe(extreme))
    for _, emotion in ipairs(EMOTIONS) do
        local v = extreme.emotions[emotion]
        assert(v >= -1 and v <= 1, emotion .. " out of range: " .. v)
    end
    print("PASS")

    -- Test 4: Multiple interactions accumulate
    banner("Test 4: Accumulating interactions")
    local bob = EmotionSystem.new_character("default")
    EmotionSystem.apply_interaction(bob, "loss", 1.0)
    EmotionSystem.apply_interaction(bob, "loss", 1.0)
    EmotionSystem.apply_interaction(bob, "rest", 1.0)
    print(EmotionSystem.describe(bob))
    print("PASS")

    banner("All tests passed!")
end

return EmotionSystem
