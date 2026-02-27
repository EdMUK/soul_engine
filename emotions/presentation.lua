-- emotions/presentation.lua — Layer A: Situational Presentation
-- NPCs have core emotions (truth) and presented emotions (what they display).
-- The gap is the "front" — this produces data for LLM prompts.
local Presentation = {}

local EmotionSystem = require("emotions.core")
local EMOTIONS = EmotionSystem.EMOTIONS
local clamp = EmotionSystem.clamp

-- Situation definitions: per-emotion bias and strength
Presentation.SITUATIONS = {
    loud_party    = { happiness={bias=0.5, strength=0.4}, energy={bias=0.3, strength=0.3} },
    job_interview = { confidence={bias=0.4, strength=0.5}, anger={bias=-0.5, strength=0.6} },
    quiet_library = { energy={bias=-0.2, strength=0.3}, anxiety={bias=-0.1, strength=0.2} },
}

-- Masking ability by personality type (0 = transparent, 1 = perfect poker face)
Presentation.MASKING_ABILITY = {
    default = 0.5,
    stoic   = 0.9,
    hothead = 0.2,
    worrier = 0.3,
    social  = 0.6,
}

--- Initialize presentation state on a character.
function Presentation.init(char)
    char.presentation = {
        active_situation = nil,
        presented = nil,
        person_modifiers = {},
    }
end

--- Enter a situation, optionally with people present who modify the front.
-- @param char           character table
-- @param situation_name key in SITUATIONS table
-- @param people_list    optional list of person IDs whose modifiers apply
function Presentation.enter_situation(char, situation_name, people_list)
    if not char.presentation then Presentation.init(char) end
    assert(Presentation.SITUATIONS[situation_name],
        "unknown situation: " .. tostring(situation_name))

    char.presentation.active_situation = situation_name
    char.presentation._active_people = people_list or {}
    Presentation._recompute(char)
end

--- Leave the current situation.
function Presentation.leave_situation(char)
    if not char.presentation then return end
    char.presentation.active_situation = nil
    char.presentation._active_people = {}
    char.presentation.presented = nil
end

--- Get the perceived (presented) emotions for a character.
-- Returns core emotions if no situation is active.
function Presentation.get_perceived(char)
    if char.presentation and char.presentation.presented then
        return char.presentation.presented
    end
    -- No situation active — return copy of core emotions
    return EmotionSystem.get_emotions(char)
end

--- Get the masking strain (0..1): how hard the character is faking it.
-- Higher strain = bigger gap between truth and facade.
function Presentation.get_masking_strain(char)
    if not char.presentation or not char.presentation.presented then
        return 0
    end

    local total_gap = 0
    local count = 0
    for _, e in ipairs(EMOTIONS) do
        local gap = math.abs(char.emotions[e] - char.presentation.presented[e])
        total_gap = total_gap + gap
        count = count + 1
    end
    return clamp(total_gap / count / 0.5)  -- normalize: 0.5 avg gap = strain 1.0
end

--- Recompute presented emotions from core + situation + people.
-- presented[e] = core[e] + (bias - core[e]) * strength * masking_ability
function Presentation._recompute(char)
    if not char.presentation or not char.presentation.active_situation then
        char.presentation.presented = nil
        return
    end

    local situation = Presentation.SITUATIONS[char.presentation.active_situation]
    local masking = Presentation.MASKING_ABILITY[char.personality] or Presentation.MASKING_ABILITY.default

    -- Collect all active modifiers: situation base + any person modifiers
    local modifiers = {}
    for e, mod in pairs(situation) do
        modifiers[e] = { bias = mod.bias, strength = mod.strength }
    end

    -- Layer person modifiers on top (additive bias, max strength)
    if char.presentation.person_modifiers and char.presentation._active_people then
        for _, person_id in ipairs(char.presentation._active_people) do
            local person_mods = char.presentation.person_modifiers[person_id]
            if person_mods then
                for e, mod in pairs(person_mods) do
                    if modifiers[e] then
                        modifiers[e].bias = modifiers[e].bias + mod.bias
                        modifiers[e].strength = math.max(modifiers[e].strength, mod.strength)
                    else
                        modifiers[e] = { bias = mod.bias, strength = mod.strength }
                    end
                end
            end
        end
    end

    -- Apply formula
    local presented = {}
    for _, e in ipairs(EMOTIONS) do
        local core = char.emotions[e]
        local mod = modifiers[e]
        if mod then
            presented[e] = clamp(core + (mod.bias - core) * mod.strength * masking)
        else
            presented[e] = core
        end
    end
    char.presentation.presented = presented
end

--- Create a post-hook function for use with EmotionSystem.register_hook.
-- Recomputes presented emotions when core emotions change.
function Presentation.make_post_hook()
    return function(char, interaction_name, applied_deltas)
        if char.presentation and char.presentation.active_situation then
            Presentation._recompute(char)
        end
    end
end

-- Self-test block
if not pcall(debug.getlocal, 4, 1) then
    local function banner(msg) print("\n" .. string.rep("=", 50) .. "\n" .. msg .. "\n" .. string.rep("=", 50)) end

    -- Test 1: No situation = core emotions returned
    banner("Test 1: No situation returns core emotions")
    local char = EmotionSystem.new_character("default")
    Presentation.init(char)
    char.emotions.happiness = 0.5
    local perceived = Presentation.get_perceived(char)
    assert(perceived.happiness == 0.5, "should return core emotions")
    assert(Presentation.get_masking_strain(char) == 0, "no strain without situation")
    print("PASS")

    -- Test 2: Situation modifies presented emotions
    banner("Test 2: Situation creates facade")
    local sad_char = EmotionSystem.new_character("default")  -- masking_ability=0.5
    Presentation.init(sad_char)
    sad_char.emotions.happiness = -0.5
    Presentation.enter_situation(sad_char, "loud_party")
    local presented = Presentation.get_perceived(sad_char)
    -- happiness bias=0.5, strength=0.4, masking=0.5
    -- presented = -0.5 + (0.5 - (-0.5)) * 0.4 * 0.5 = -0.5 + 0.2 = -0.3
    print("Core happiness: -0.5, Presented: " .. string.format("%.3f", presented.happiness))
    assert(presented.happiness > -0.5, "presented happiness should be pulled toward bias")
    assert(presented.happiness < 0.5, "presented should not reach bias fully")
    assert(math.abs(presented.happiness - (-0.3)) < 0.001,
        "expected -0.3, got " .. presented.happiness)
    print("PASS")

    -- Test 3: Stoic masks better than hothead
    banner("Test 3: Personality affects masking")
    local stoic = EmotionSystem.new_character("stoic")
    Presentation.init(stoic)
    stoic.emotions.happiness = -0.8
    Presentation.enter_situation(stoic, "loud_party")
    local stoic_presented = Presentation.get_perceived(stoic)

    local hothead = EmotionSystem.new_character("hothead")
    Presentation.init(hothead)
    hothead.emotions.happiness = -0.8
    Presentation.enter_situation(hothead, "loud_party")
    local hothead_presented = Presentation.get_perceived(hothead)

    print("Stoic presented happiness: " .. string.format("%.3f", stoic_presented.happiness))
    print("Hothead presented happiness: " .. string.format("%.3f", hothead_presented.happiness))
    assert(stoic_presented.happiness > hothead_presented.happiness,
        "stoic should mask better (closer to bias)")
    print("PASS")

    -- Test 4: Masking strain
    banner("Test 4: Masking strain calculation")
    local strain = Presentation.get_masking_strain(stoic)
    print("Stoic strain: " .. string.format("%.3f", strain))
    assert(strain > 0, "should have positive strain when masking")
    -- Stoic is great at masking, so presented is far from core -> strain reflects the gap
    print("PASS")

    -- Test 5: Person modifiers add to situation
    banner("Test 5: Person modifiers")
    local char2 = EmotionSystem.new_character("default")
    Presentation.init(char2)
    char2.emotions.anxiety = 0
    char2.presentation.person_modifiers["npc_father"] = {
        anxiety = { bias = 0.6, strength = 0.5 },
    }
    Presentation.enter_situation(char2, "quiet_library", {"npc_father"})
    local perceived2 = Presentation.get_perceived(char2)
    print("Anxiety with father in library: " .. string.format("%.3f", perceived2.anxiety))
    -- Library: anxiety bias=-0.1, strength=0.2
    -- Father: anxiety bias=0.6, strength=0.5
    -- Combined: bias=-0.1+0.6=0.5, strength=max(0.2,0.5)=0.5, masking=0.5
    -- presented = 0 + (0.5 - 0) * 0.5 * 0.5 = 0.125
    assert(perceived2.anxiety > 0, "father's presence should raise presented anxiety")
    print("PASS")

    -- Test 6: Leave situation clears presentation
    banner("Test 6: Leaving situation")
    Presentation.leave_situation(char2)
    local after = Presentation.get_perceived(char2)
    assert(after.anxiety == char2.emotions.anxiety, "should return core after leaving")
    assert(Presentation.get_masking_strain(char2) == 0, "no strain after leaving")
    print("PASS")

    -- Test 7: Post-hook recomputes on emotion change
    banner("Test 7: Post-hook recomputation")
    EmotionSystem._post_interaction_hooks = {}
    EmotionSystem._pre_interaction_hooks = {}
    local char3 = EmotionSystem.new_character("default")
    Presentation.init(char3)
    char3.emotions.happiness = -0.5
    Presentation.enter_situation(char3, "loud_party")
    local before_presented = Presentation.get_perceived(char3).happiness

    EmotionSystem.register_hook(Presentation.make_post_hook())
    EmotionSystem.apply_interaction(char3, "achievement", 1.0)
    local after_presented = Presentation.get_perceived(char3).happiness

    print("Presented before achievement: " .. string.format("%.3f", before_presented))
    print("Presented after achievement: " .. string.format("%.3f", after_presented))
    assert(after_presented ~= before_presented, "presented should update when core changes")
    print("PASS")

    EmotionSystem._post_interaction_hooks = {}
    EmotionSystem._pre_interaction_hooks = {}
    banner("All presentation tests passed!")
end

return Presentation
