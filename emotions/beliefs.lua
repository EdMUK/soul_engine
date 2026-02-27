-- emotions/beliefs.lua — Layer D: Core Beliefs (text-based, LLM-queried)
-- Beliefs are natural language text with numerical metadata, evaluated by an LLM.
local Beliefs = {}

local EmotionSystem = require("emotions.core")
local EMOTIONS = EmotionSystem.EMOTIONS
local clamp = EmotionSystem.clamp

-- Pluggable LLM backend
local llm_backend = nil

--- Set the LLM backend function.
-- @param fn  function(prompt_string) -> response_string
function Beliefs.set_llm_backend(fn)
    llm_backend = fn
end

--- Default fake LLM: keyword heuristics that produce reasonable responses.
-- Scans scene+conversation for keywords matching belief tags, returns
-- emotion deltas and belief impact assessments.
local function fake_llm(beliefs, emotions, scene, conversation)
    local context = ((scene or "") .. " " .. (conversation or "")):lower()
    local deltas = {}
    local impacts = {}

    for i, belief in ipairs(beliefs) do
        local impact = "neutral"

        -- Check each tag against context keywords
        for _, tag in ipairs(belief.tags or {}) do
            local tag_lower = tag:lower()

            -- Define keyword clusters per common tag
            local challenge_keywords = {
                pacifism  = {"fight", "violence", "attack", "kill", "weapon", "war", "battle", "combat"},
                trust     = {"betray", "lie", "deceive", "cheat", "backstab", "trick"},
                conflict  = {"fight", "argue", "attack", "violence", "threat", "war"},
                justice   = {"unfair", "corrupt", "bribe", "cheat", "steal", "crime"},
                family    = {"abandon", "disown", "orphan", "neglect"},
                loyalty   = {"betray", "abandon", "desert", "traitor"},
            }
            local reinforce_keywords = {
                pacifism  = {"peace", "calm", "negotiate", "harmony", "truce", "forgive"},
                trust     = {"honest", "loyal", "faithful", "reliable", "dependable", "truth"},
                conflict  = {"peace", "resolve", "negotiate", "harmony", "calm"},
                justice   = {"fair", "justice", "court", "law", "right", "equal"},
                family    = {"family", "together", "reunion", "love", "home"},
                loyalty   = {"loyal", "faithful", "devoted", "steadfast"},
                relationships = {"friend", "bond", "together", "trust", "companion"},
            }

            local challenges = challenge_keywords[tag_lower] or {}
            local reinforces = reinforce_keywords[tag_lower] or {}

            for _, kw in ipairs(challenges) do
                if context:find(kw, 1, true) then
                    impact = "challenged"
                    break
                end
            end
            if impact == "challenged" then break end

            for _, kw in ipairs(reinforces) do
                if context:find(kw, 1, true) then
                    impact = "reinforced"
                    break
                end
            end
            if impact ~= "neutral" then break end
        end

        impacts[i] = impact

        -- Generate emotion deltas based on impact and belief content
        if impact == "challenged" then
            local magnitude = 0.1 * belief.strength
            deltas.anxiety = (deltas.anxiety or 0) + magnitude
            deltas.fear = (deltas.fear or 0) + magnitude * 0.5
            deltas.anger = (deltas.anger or 0) + magnitude * 0.3
            deltas.happiness = (deltas.happiness or 0) - magnitude * 0.5
        elseif impact == "reinforced" then
            local magnitude = 0.05 * belief.strength
            deltas.happiness = (deltas.happiness or 0) + magnitude
            deltas.confidence = (deltas.confidence or 0) + magnitude
            deltas.anxiety = (deltas.anxiety or 0) - magnitude * 0.5
        end
    end

    return deltas, impacts
end

Beliefs.set_llm_backend(fake_llm)

--- Initialize beliefs on a character.
-- @param char        character table
-- @param belief_list list of {text, strength, inertia, tags} tables
function Beliefs.init(char, belief_list)
    char.beliefs = { entries = {} }
    if belief_list then
        for _, b in ipairs(belief_list) do
            Beliefs.add_belief(char, b.text, b.strength, b.inertia, b.tags)
        end
    end
end

--- Add a belief to a character.
function Beliefs.add_belief(char, text, strength, inertia, tags)
    assert(char.beliefs, "Beliefs not initialized")
    table.insert(char.beliefs.entries, {
        text = text,
        strength = clamp(strength or 0.5),
        inertia = clamp(inertia or 0.5),
        tags = tags or {},
    })
end

--- Get all beliefs with strengths.
function Beliefs.get_beliefs(char)
    if not char.beliefs then return {} end
    return char.beliefs.entries
end

--- Get beliefs filtered by tag.
function Beliefs.get_beliefs_by_tag(char, tag)
    if not char.beliefs then return {} end
    local result = {}
    for _, b in ipairs(char.beliefs.entries) do
        for _, t in ipairs(b.tags) do
            if t == tag then
                table.insert(result, b)
                break
            end
        end
    end
    return result
end

--- Evaluate beliefs against a scene context via LLM.
-- @param char           character table
-- @param scene_context  string describing the current situation
-- @param conversation   string of recent dialogue
-- @return emotion_deltas  table of { emotion_name = delta }
-- @return belief_impacts  table of { belief_index = "challenged"|"reinforced"|"neutral" }
function Beliefs.evaluate(char, scene_context, conversation)
    assert(char.beliefs, "Beliefs not initialized")
    assert(llm_backend, "No LLM backend configured")

    return llm_backend(char.beliefs.entries, char.emotions, scene_context, conversation)
end

--- Apply a direct shock to a belief (for scripted events, bypasses LLM).
-- Must exceed (1 - inertia) threshold to have effect.
-- @param char        character table
-- @param belief_index  index into beliefs.entries
-- @param direction   +1 (reinforce) or -1 (weaken)
-- @param magnitude   shock strength 0..1
-- @return true if the shock had effect, false if blocked by inertia
function Beliefs.apply_shock(char, belief_index, direction, magnitude)
    assert(char.beliefs and char.beliefs.entries[belief_index],
        "invalid belief index: " .. tostring(belief_index))

    local belief = char.beliefs.entries[belief_index]
    local threshold = 1 - belief.inertia

    if magnitude <= threshold then
        return false  -- blocked by inertia
    end

    -- Apply: direction * (magnitude - threshold) as the effective change
    local effective = direction * (magnitude - threshold)
    belief.strength = clamp(belief.strength + effective)
    -- Shock slightly reduces inertia (belief becomes more flexible after being shaken)
    belief.inertia = clamp(belief.inertia - 0.05)

    return true
end

--- Return a text summary of all beliefs for debug or prompt inclusion.
function Beliefs.describe(char)
    if not char.beliefs then return "No beliefs." end
    local parts = { "Beliefs:" }
    for i, b in ipairs(char.beliefs.entries) do
        table.insert(parts, string.format(
            "  [%d] (str=%.2f, inertia=%.2f, tags=%s) %s",
            i, b.strength, b.inertia, table.concat(b.tags, ","), b.text
        ))
    end
    return table.concat(parts, "\n")
end

-- Self-test block
if not pcall(debug.getlocal, 4, 1) then
    local function banner(msg) print("\n" .. string.rep("=", 50) .. "\n" .. msg .. "\n" .. string.rep("=", 50)) end

    -- Test 1: Init and add beliefs
    banner("Test 1: Belief initialization")
    local char = EmotionSystem.new_character("default")
    Beliefs.init(char, {
        { text = "Violence is never the answer.", strength = 0.8, inertia = 0.7, tags = {"pacifism", "conflict"} },
        { text = "People earn trust through actions.", strength = 0.9, inertia = 0.8, tags = {"trust", "relationships"} },
    })
    assert(#char.beliefs.entries == 2, "should have 2 beliefs")
    assert(char.beliefs.entries[1].strength == 0.8, "strength should be 0.8")
    print(Beliefs.describe(char))
    print("PASS")

    -- Test 2: Tag filtering
    banner("Test 2: Get beliefs by tag")
    local pacifist = Beliefs.get_beliefs_by_tag(char, "pacifism")
    assert(#pacifist == 1, "should find 1 pacifism belief")
    local trust = Beliefs.get_beliefs_by_tag(char, "trust")
    assert(#trust == 1, "should find 1 trust belief")
    local none = Beliefs.get_beliefs_by_tag(char, "nonexistent")
    assert(#none == 0, "should find no matching beliefs")
    print("PASS")

    -- Test 3: Fake LLM evaluation — violence challenges pacifism
    banner("Test 3: LLM evaluation — violence scene")
    local deltas, impacts = Beliefs.evaluate(char, "A bar fight breaks out with violence everywhere", "")
    assert(impacts[1] == "challenged", "pacifism belief should be challenged by violence")
    assert(deltas.anxiety and deltas.anxiety > 0, "anxiety should increase")
    print("Impact on pacifism belief: " .. impacts[1])
    print("Anxiety delta: " .. string.format("%.3f", deltas.anxiety))
    print("PASS")

    -- Test 4: Fake LLM — peaceful scene reinforces pacifism
    banner("Test 4: LLM evaluation — peaceful scene")
    local deltas2, impacts2 = Beliefs.evaluate(char, "A peaceful negotiation leads to harmony", "")
    assert(impacts2[1] == "reinforced", "pacifism should be reinforced by peace")
    assert(deltas2.happiness and deltas2.happiness > 0, "happiness should increase")
    print("Impact on pacifism belief: " .. impacts2[1])
    print("Happiness delta: " .. string.format("%.3f", deltas2.happiness))
    print("PASS")

    -- Test 5: Neutral scene
    banner("Test 5: LLM evaluation — neutral scene")
    local deltas3, impacts3 = Beliefs.evaluate(char, "The weather is nice today", "Let's go for a walk")
    assert(impacts3[1] == "neutral", "pacifism should not be triggered by weather")
    print("Impact on pacifism belief: " .. impacts3[1])
    print("PASS")

    -- Test 6: Shock mechanism — high inertia blocks weak shock
    banner("Test 6: Shock mechanism")
    local char2 = EmotionSystem.new_character("default")
    Beliefs.init(char2, {
        { text = "I will never forgive.", strength = 0.8, inertia = 0.9, tags = {"grudge"} },
    })
    -- Threshold = 1 - 0.9 = 0.1, so magnitude must exceed 0.1
    local blocked = Beliefs.apply_shock(char2, 1, -1, 0.05)
    assert(not blocked, "weak shock should be blocked by high inertia")
    assert(char2.beliefs.entries[1].strength == 0.8, "strength unchanged after blocked shock")
    print("Weak shock blocked: strength still " .. char2.beliefs.entries[1].strength)

    -- Strong shock succeeds
    local success = Beliefs.apply_shock(char2, 1, -1, 0.5)
    assert(success, "strong shock should overcome inertia")
    assert(char2.beliefs.entries[1].strength < 0.8, "strength should decrease")
    print("Strong shock applied: strength now " .. string.format("%.3f", char2.beliefs.entries[1].strength))
    assert(char2.beliefs.entries[1].inertia < 0.9, "inertia should decrease slightly")
    print("Inertia reduced to: " .. string.format("%.3f", char2.beliefs.entries[1].inertia))
    print("PASS")

    -- Test 7: Add belief dynamically
    banner("Test 7: Dynamic belief addition")
    Beliefs.add_belief(char, "Knowledge is power.", 0.6, 0.4, {"knowledge"})
    assert(#char.beliefs.entries == 3, "should have 3 beliefs now")
    print("PASS")

    -- Test 8: Custom LLM backend
    banner("Test 8: Pluggable LLM backend")
    local custom_called = false
    Beliefs.set_llm_backend(function(beliefs, emotions, scene, conv)
        custom_called = true
        return { happiness = 0.5 }, { [1] = "reinforced", [2] = "neutral" }
    end)
    local d, i = Beliefs.evaluate(char, "test", "test")
    assert(custom_called, "custom backend should be called")
    assert(d.happiness == 0.5, "should use custom backend result")
    print("Custom backend works")
    -- Restore default
    Beliefs.set_llm_backend(fake_llm)
    print("PASS")

    banner("All beliefs tests passed!")
end

return Beliefs
