-- emotions/triggers.lua — Layer C: Conversation Triggers
-- Keyword-based fast/cheap emotional reactions to conversation topics.
-- Runs alongside LLM belief evaluation for quick, deterministic responses.
local Triggers = {}

local EmotionSystem = require("emotions.core")

-- Global topic definitions
Triggers.TOPICS = {
    father = {
        keywords = {"father", "dad", "papa", "old man"},
        default_deltas = {happiness = -0.1, loneliness = 0.1},
    },
    war = {
        keywords = {"war", "battle", "combat", "soldiers"},
        default_deltas = {fear = 0.1, anxiety = 0.1},
    },
    home = {
        keywords = {"home", "hometown", "where i grew up"},
        default_deltas = {happiness = 0.1, loneliness = -0.05},
    },
    death = {
        keywords = {"death", "died", "killed", "dead", "funeral"},
        default_deltas = {happiness = -0.15, fear = 0.1, anxiety = 0.1},
    },
    love = {
        keywords = {"love", "beloved", "sweetheart", "darling"},
        default_deltas = {happiness = 0.15, loneliness = -0.1},
    },
}

local DEFAULT_COOLDOWN = 3  -- turns before same topic can fire again

--- Initialize trigger tracking on a character.
-- @param char           character table
-- @param sensitivities  optional table of topic overrides
function Triggers.init(char, sensitivities)
    char.triggers = {
        sensitivities = {},
        _cooldowns = {},
    }
    if sensitivities then
        for topic, config in pairs(sensitivities) do
            char.triggers.sensitivities[topic] = {
                deltas = config.deltas,
                intensity = config.intensity or 1.0,
                desensitize_rate = config.desensitize_rate or 0.05,
                min_intensity = config.min_intensity or 0.3,
                times_triggered = 0,
            }
        end
    end
end

--- Check if a keyword appears in text with word boundaries.
-- Uses Lua frontier patterns for boundary matching.
local function word_match(text, keyword)
    -- Convert to lowercase for case-insensitive matching
    local lower_text = text:lower()
    local lower_kw = keyword:lower()

    -- Use frontier patterns for word-boundary matching
    local pattern = "%f[%w]" .. lower_kw:gsub("(%W)", "%%%1") .. "%f[%W]"
    return lower_text:find(pattern) ~= nil
end

--- Scan text for keyword matches and fire matching topics.
-- @param char  character table
-- @param text  conversation text to scan
-- @return list of {topic, deltas} tables for topics that fired
function Triggers.process_text(char, text)
    if not char.triggers then return {} end

    local fired = {}

    for topic_name, topic_def in pairs(Triggers.TOPICS) do
        -- Skip if on cooldown
        if (char.triggers._cooldowns[topic_name] or 0) > 0 then
            goto continue
        end

        -- Check keywords
        local matched = false
        for _, keyword in ipairs(topic_def.keywords) do
            if word_match(text, keyword) then
                matched = true
                break
            end
        end

        if matched then
            local result = Triggers.trigger_topic(char, topic_name)
            if result then
                table.insert(fired, result)
            end
        end

        ::continue::
    end

    return fired
end

--- Fire a specific topic directly (for scripted use or internal calls).
-- @param char        character table
-- @param topic_name  name of the topic to fire
-- @return {topic, deltas} table or nil if topic unknown
function Triggers.trigger_topic(char, topic_name)
    if not char.triggers then return nil end
    local topic_def = Triggers.TOPICS[topic_name]
    if not topic_def then return nil end

    -- Get character-specific sensitivity or use defaults
    local sensitivity = char.triggers.sensitivities[topic_name]
    local deltas
    local intensity

    if sensitivity then
        deltas = sensitivity.deltas or topic_def.default_deltas
        intensity = sensitivity.intensity
        -- Track and desensitize
        sensitivity.times_triggered = sensitivity.times_triggered + 1
        sensitivity.intensity = math.max(
            sensitivity.min_intensity,
            sensitivity.intensity - sensitivity.desensitize_rate
        )
    else
        deltas = topic_def.default_deltas
        intensity = 1.0
    end

    -- Apply deltas via nudge (respects personality multipliers)
    local applied = {}
    for emotion, delta in pairs(deltas) do
        local scaled = delta * intensity
        local actual = EmotionSystem.nudge(char, emotion, scaled)
        applied[emotion] = actual
    end

    -- Set cooldown
    char.triggers._cooldowns[topic_name] = DEFAULT_COOLDOWN

    return { topic = topic_name, deltas = applied }
end

--- Advance cooldowns by one turn. Call this at the end of each conversation turn.
function Triggers.advance_turn(char)
    if not char.triggers then return end
    for topic, remaining in pairs(char.triggers._cooldowns) do
        if remaining > 0 then
            char.triggers._cooldowns[topic] = remaining - 1
        end
    end
end

--- Get topics this character is sensitive to (for LLM prompt hints).
-- @return list of {topic, intensity} tables
function Triggers.get_sensitive_topics(char)
    if not char.triggers then return {} end
    local result = {}
    for topic, config in pairs(char.triggers.sensitivities) do
        table.insert(result, { topic = topic, intensity = config.intensity })
    end
    return result
end

-- Self-test block
if not pcall(debug.getlocal, 4, 1) then
    local function banner(msg) print("\n" .. string.rep("=", 50) .. "\n" .. msg .. "\n" .. string.rep("=", 50)) end

    -- Test 1: Word boundary matching
    banner("Test 1: Word boundary matching")
    assert(word_match("My father was kind", "father"), "should match 'father'")
    assert(word_match("He is my dad", "dad"), "should match 'dad'")
    assert(not word_match("grandfather", "father"), "should NOT match 'father' in 'grandfather'")
    assert(not word_match("dadaism", "dad"), "should NOT match 'dad' in 'dadaism'")
    assert(word_match("DAD, come here!", "dad"), "case insensitive match")
    print("PASS")

    -- Test 2: Basic topic firing
    banner("Test 2: Topic fires on keyword")
    local char = EmotionSystem.new_character("default")
    Triggers.init(char)
    local before_happy = char.emotions.happiness
    local fired = Triggers.process_text(char, "My father always told me stories")
    assert(#fired == 1, "should fire 1 topic, got " .. #fired)
    assert(fired[1].topic == "father", "should fire father topic")
    assert(char.emotions.happiness < before_happy, "happiness should decrease")
    print("Fired: " .. fired[1].topic)
    print("Happiness delta: " .. string.format("%.3f", fired[1].deltas.happiness))
    print("PASS")

    -- Test 3: Cooldown prevents re-fire
    banner("Test 3: Cooldown mechanism")
    local fired2 = Triggers.process_text(char, "My father was a good man")
    assert(#fired2 == 0, "should not fire during cooldown")
    print("Correctly blocked by cooldown")
    -- Advance turns
    Triggers.advance_turn(char)
    Triggers.advance_turn(char)
    Triggers.advance_turn(char)
    local fired3 = Triggers.process_text(char, "Dad would have loved this")
    assert(#fired3 == 1, "should fire after cooldown expires")
    print("Fires again after 3 turns")
    print("PASS")

    -- Test 4: Multiple topics in one text
    banner("Test 4: Multiple topics fire from one text")
    local char2 = EmotionSystem.new_character("default")
    Triggers.init(char2)
    local multi = Triggers.process_text(char2, "The war killed my father")
    assert(#multi == 3, "should fire 3 topics (war, death, father), got " .. #multi)
    local topics_fired = {}
    for _, f in ipairs(multi) do topics_fired[f.topic] = true end
    assert(topics_fired.war, "should fire war")
    assert(topics_fired.father, "should fire father")
    assert(topics_fired.death, "should fire death (via 'killed')")
    print("Fired: war, death, and father")
    print("PASS")

    -- Test 5: Character sensitivity with desensitization
    banner("Test 5: Sensitivity and desensitization")
    local char3 = EmotionSystem.new_character("default")
    Triggers.init(char3, {
        father = {
            deltas = {happiness = -0.4, anger = 0.3},
            intensity = 1.5,
            desensitize_rate = 0.1,
            min_intensity = 0.5,
        },
    })
    -- First trigger at full intensity
    local f1 = Triggers.process_text(char3, "Tell me about your father")
    print("First trigger intensity: 1.5")
    print("Happiness delta: " .. string.format("%.3f", f1[1].deltas.happiness))
    -- Intensity should decrease
    assert(char3.triggers.sensitivities.father.intensity == 1.4,
        "intensity should decrease by 0.1")
    -- Trigger again after cooldown
    for i = 1, 3 do Triggers.advance_turn(char3) end
    Triggers.process_text(char3, "Your dad was mentioned")
    assert(math.abs(char3.triggers.sensitivities.father.intensity - 1.3) < 0.001,
        "intensity should decrease again")
    print("Intensity decreasing: " .. char3.triggers.sensitivities.father.intensity)
    print("PASS")

    -- Test 6: Desensitization floor
    banner("Test 6: Minimum intensity floor")
    -- Force intensity to near minimum
    char3.triggers.sensitivities.father.intensity = 0.55
    char3.triggers._cooldowns.father = 0
    Triggers.process_text(char3, "father")
    assert(char3.triggers.sensitivities.father.intensity == 0.5,
        "should not go below min_intensity")
    char3.triggers._cooldowns.father = 0
    Triggers.process_text(char3, "dad")
    assert(char3.triggers.sensitivities.father.intensity == 0.5,
        "should stay at floor")
    print("Intensity floor holds at 0.5")
    print("PASS")

    -- Test 7: get_sensitive_topics
    banner("Test 7: Sensitive topics listing")
    local topics = Triggers.get_sensitive_topics(char3)
    assert(#topics == 1, "should have 1 sensitive topic")
    assert(topics[1].topic == "father", "should be father")
    print("Sensitive topics: " .. topics[1].topic .. " (intensity=" .. topics[1].intensity .. ")")
    print("PASS")

    -- Test 8: trigger_topic directly
    banner("Test 8: Direct topic trigger")
    local char4 = EmotionSystem.new_character("default")
    Triggers.init(char4)
    char4.triggers._cooldowns.war = 0
    local result = Triggers.trigger_topic(char4, "war")
    assert(result, "should return result")
    assert(result.topic == "war", "should be war topic")
    assert(char4.emotions.fear > 0, "fear should increase")
    print("Direct trigger works: fear=" .. string.format("%.3f", char4.emotions.fear))
    print("PASS")

    banner("All trigger tests passed!")
end

return Triggers
