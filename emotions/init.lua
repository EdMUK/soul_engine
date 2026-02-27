-- emotions/init.lua — Facade: loads and wires all emotion system modules
-- require("emotions") returns the full system with all layers connected.
local EmotionSystem = require("emotions.core")
local History       = require("emotions.history")
local Presentation  = require("emotions.presentation")
local Beliefs       = require("emotions.beliefs")
local Erosion       = require("emotions.erosion")
local Triggers      = require("emotions.triggers")

-- Expose sub-modules
EmotionSystem.History      = History
EmotionSystem.Presentation = Presentation
EmotionSystem.Beliefs      = Beliefs
EmotionSystem.Erosion      = Erosion
EmotionSystem.Triggers     = Triggers

--- Create a fully-initialized character with all layers.
-- @param personality_name  personality profile name
-- @param opts              table with optional fields:
--   get_time       function() -> number (required for history)
--   beliefs        list of {text, strength, inertia, tags}
--   sensitivities  trigger sensitivity overrides
--   ema_alpha      history EMA smoothing factor
function EmotionSystem.new_full_character(personality_name, opts)
    opts = opts or {}
    local char = EmotionSystem.new_character(personality_name)

    -- Layer B: History
    if opts.get_time then
        History.init(char, opts.get_time, opts.ema_alpha)
    end

    -- Layer A: Presentation
    Presentation.init(char)

    -- Layer D: Beliefs
    Beliefs.init(char, opts.beliefs)

    -- Layer E: Erosion (must come after beliefs)
    if opts.beliefs and #opts.beliefs > 0 then
        Erosion.init(char)
    end

    -- Layer C: Triggers
    Triggers.init(char, opts.sensitivities)

    return char
end

-- Wire hooks in the correct order:
-- Pre-hooks: (none wired by default — beliefs pre-hook is for advanced use)
-- Post-hooks: history → erosion → presentation

-- History post-hook: track baselines and detect shifts
EmotionSystem.register_hook(History.make_post_hook())

-- Presentation post-hook: recompute presented emotions when core changes
EmotionSystem.register_hook(Presentation.make_post_hook())

-- Self-test / integration test block
if not pcall(debug.getlocal, 4, 1) then
    local function banner(msg) print("\n" .. string.rep("=", 60) .. "\n" .. msg .. "\n" .. string.rep("=", 60)) end

    local time = 0
    local function get_time() return time end

    banner("Integration Test: Full pipeline")

    -- Create a character with all layers
    local npc = EmotionSystem.new_full_character("worrier", {
        get_time = get_time,
        beliefs = {
            {
                text = "Violence is never the answer. There is always a peaceful solution.",
                strength = 0.8, inertia = 0.7,
                tags = {"pacifism", "conflict"},
            },
            {
                text = "People earn trust through actions, not words.",
                strength = 0.9, inertia = 0.8,
                tags = {"trust", "relationships"},
            },
        },
        sensitivities = {
            father = {
                deltas = {happiness = -0.4, anger = 0.3},
                intensity = 1.5,
                desensitize_rate = 0.1,
                min_intensity = 0.5,
            },
        },
    })

    -- Verify all layers initialized
    assert(npc.history, "history should be initialized")
    assert(npc.presentation, "presentation should be initialized")
    assert(npc.beliefs, "beliefs should be initialized")
    assert(npc.beliefs.entries[1].erosion, "erosion should be initialized")
    assert(npc.triggers, "triggers should be initialized")
    print("All layers initialized on character")

    -- Step 1: Enter a situation
    banner("Step 1: Enter job interview situation")
    Presentation.enter_situation(npc, "job_interview")
    local perceived = Presentation.get_perceived(npc)
    print("Core confidence: " .. string.format("%.3f", npc.emotions.confidence))
    print("Presented confidence: " .. string.format("%.3f", perceived.confidence))
    assert(perceived.confidence > npc.emotions.confidence,
        "presented confidence should be boosted in job interview")
    local strain = Presentation.get_masking_strain(npc)
    print("Masking strain: " .. string.format("%.3f", strain))
    print("PASS")

    -- Step 2: Process conversation text through triggers
    banner("Step 2: Process conversation with triggers")
    local before_happy = npc.emotions.happiness
    local fired = Triggers.process_text(npc, "My father always said I should be brave")
    assert(#fired > 0, "should fire father topic")
    print("Triggered: " .. fired[1].topic)
    print("Happiness change: " .. string.format("%.3f", npc.emotions.happiness - before_happy))
    print("PASS")

    -- Step 3: Apply an interaction (flows through hooks)
    banner("Step 3: Apply threat interaction (hooks fire)")
    time = 10
    local before_baseline = npc.history.baselines.fear
    EmotionSystem.apply_interaction(npc, "threat", 1.0)
    local after_baseline = npc.history.baselines.fear
    print("Fear baseline: " .. string.format("%.3f", before_baseline) .. " -> " .. string.format("%.3f", after_baseline))
    assert(after_baseline > before_baseline, "history hook should update fear baseline")
    -- Presentation should have recomputed
    local new_perceived = Presentation.get_perceived(npc)
    print("Presented emotions updated after interaction")
    print("PASS")

    -- Step 4: Evaluate beliefs against a violent scene
    banner("Step 4: Belief evaluation against violent scene")
    local deltas, impacts = Beliefs.evaluate(npc,
        "A fight breaks out in the street with violence",
        "Someone drew a weapon")
    print("Pacifism belief impact: " .. (impacts[1] or "nil"))
    assert(impacts[1] == "challenged", "pacifism should be challenged by violence")
    print("Emotion deltas from belief evaluation:")
    for emotion, delta in pairs(deltas) do
        print("  " .. emotion .. ": " .. string.format("%+.3f", delta))
    end
    print("PASS")

    -- Step 5: Feed evaluation into erosion
    banner("Step 5: Erosion processes belief evaluation")
    local prox_before = Erosion.get_tipping_proximity(npc, 1)
    local tip_events = Erosion.process_evaluation(npc, impacts, deltas)
    local prox_after = Erosion.get_tipping_proximity(npc, 1)
    print("Tipping proximity: " .. string.format("%.3f", prox_before) .. " -> " .. string.format("%.3f", prox_after))
    if tip_events and #tip_events > 0 then
        print("TIPPING EVENT: belief strength shifted!")
    else
        print("No tipping yet (pressure accumulating)")
    end
    print("PASS")

    -- Step 6: Repeat evaluations to build pressure toward tipping
    banner("Step 6: Repeated challenges build pressure")
    for i = 1, 20 do
        time = time + 1
        local d, imp = Beliefs.evaluate(npc,
            "More violence erupts, the battle continues",
            "The fighting spreads")
        local events = Erosion.process_evaluation(npc, imp, d)
        if events and #events > 0 then
            print("TIPPING at iteration " .. i .. "!")
            print("  Belief strength: " .. string.format("%.3f", events[1].old_strength)
                .. " -> " .. string.format("%.3f", events[1].new_strength))
            break
        end
    end
    assert(npc.beliefs.entries[1].strength < 0.8,
        "pacifism belief should have weakened after sustained challenges")
    print("Final pacifism strength: " .. string.format("%.3f", npc.beliefs.entries[1].strength))
    print("PASS")

    -- Step 7: Time decay reduces stale pressure
    banner("Step 7: Time decay")
    Erosion.apply_pressure(npc, 2, -1, 0.1)
    local pressure_before = npc.beliefs.entries[2].erosion.pressure
    Erosion.tick(npc, time + 100)
    local pressure_after = npc.beliefs.entries[2].erosion.pressure
    print("Pressure decay: " .. string.format("%.3f", pressure_before) .. " -> " .. string.format("%.3f", pressure_after))
    assert(math.abs(pressure_after) < math.abs(pressure_before), "pressure should decay")
    print("PASS")

    -- Step 8: History captures sustained shifts
    banner("Step 8: Check emotional history")
    -- Apply many threats to build up fear baseline shift
    for i = 1, 80 do
        time = time + 1
        EmotionSystem.apply_interaction(npc, "threat", 0.5)
    end
    local shifts = History.get_narrative_shifts(npc, 0.3)
    print("Narrative shifts found: " .. #shifts)
    for _, s in ipairs(shifts) do
        print("  " .. s.emotion .. ": " .. string.format("%.3f", s.from) .. " -> " .. string.format("%.3f", s.to) .. " (" .. s.cause .. ")")
    end
    assert(#shifts > 0, "should have narrative shifts after sustained threats")
    print("PASS")

    -- Step 9: Snapshot
    banner("Step 9: Save snapshot")
    History.take_snapshot(npc, time, "after_violence")
    assert(#npc.history.snapshots == 1, "should have 1 snapshot")
    print("Snapshot saved: " .. npc.history.snapshots[1].label)
    print("PASS")

    -- Step 10: Leave situation, check state
    banner("Step 10: Leave situation")
    Presentation.leave_situation(npc)
    local final = Presentation.get_perceived(npc)
    assert(final.confidence == npc.emotions.confidence, "should show core emotions after leaving")
    print("Back to core emotions after leaving situation")
    print("PASS")

    -- Step 11: Full describe
    banner("Step 11: Final character state")
    print(EmotionSystem.describe(npc))
    print()
    print(Beliefs.describe(npc))
    print()
    local topics = Triggers.get_sensitive_topics(npc)
    print("Sensitive topics:")
    for _, t in ipairs(topics) do
        print("  " .. t.topic .. " (intensity=" .. string.format("%.2f", t.intensity) .. ")")
    end

    -- Step 12: Trigger desensitization check
    banner("Step 12: Desensitization over repeated triggers")
    local initial_intensity = npc.triggers.sensitivities.father.intensity
    for i = 1, 5 do
        Triggers.advance_turn(npc)
        Triggers.advance_turn(npc)
        Triggers.advance_turn(npc)
        Triggers.process_text(npc, "My father would know what to do")
    end
    local final_intensity = npc.triggers.sensitivities.father.intensity
    print("Father trigger intensity: " .. string.format("%.2f", initial_intensity) .. " -> " .. string.format("%.2f", final_intensity))
    assert(final_intensity < initial_intensity, "intensity should decrease over repeated triggers")
    print("PASS")

    banner("ALL INTEGRATION TESTS PASSED!")
end

return EmotionSystem
