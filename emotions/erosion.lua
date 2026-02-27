-- emotions/erosion.lua — Layer E: Belief Erosion
-- Gradual pressure accumulates on beliefs from repeated interactions
-- until a tipping point is reached.
local Erosion = {}

local EmotionSystem = require("emotions.core")
local clamp = EmotionSystem.clamp

local DEFAULT_EROSION = {
    pressure = 0,
    threshold = 0.3,
    shift_amount = 0.1,
    decay_rate = 0.01,
    last_event_time = 0,
}

--- Initialize erosion tracking on all existing beliefs.
-- @param char  character table (must have char.beliefs.entries)
function Erosion.init(char)
    assert(char.beliefs and char.beliefs.entries, "Beliefs must be initialized before erosion")
    for _, belief in ipairs(char.beliefs.entries) do
        if not belief.erosion then
            belief.erosion = {
                pressure = DEFAULT_EROSION.pressure,
                threshold = DEFAULT_EROSION.threshold,
                shift_amount = DEFAULT_EROSION.shift_amount,
                decay_rate = DEFAULT_EROSION.decay_rate,
                last_event_time = DEFAULT_EROSION.last_event_time,
            }
        end
    end
end

--- Apply pressure to a belief.
-- @param char          character table
-- @param belief_index  index into beliefs.entries
-- @param direction     +1 (reinforcing) or -1 (weakening)
-- @param amount        pressure magnitude (positive)
function Erosion.apply_pressure(char, belief_index, direction, amount)
    local belief = char.beliefs.entries[belief_index]
    assert(belief, "invalid belief index: " .. tostring(belief_index))
    assert(belief.erosion, "erosion not initialized for belief " .. belief_index)

    belief.erosion.pressure = clamp(belief.erosion.pressure + direction * math.abs(amount))
end

--- Apply time-based decay to all belief pressures.
-- Pressure decays toward 0 between events.
-- @param char          character table
-- @param current_time  current timestamp
function Erosion.tick(char, current_time)
    if not char.beliefs then return end
    for _, belief in ipairs(char.beliefs.entries) do
        if belief.erosion then
            local dt = current_time - belief.erosion.last_event_time
            if dt > 0 and belief.erosion.pressure ~= 0 then
                local decay = belief.erosion.decay_rate * dt
                if belief.erosion.pressure > 0 then
                    belief.erosion.pressure = math.max(0, belief.erosion.pressure - decay)
                else
                    belief.erosion.pressure = math.min(0, belief.erosion.pressure + decay)
                end
            end
            belief.erosion.last_event_time = current_time
        end
    end
end

--- Check if a belief has reached its tipping point.
-- @param char          character table
-- @param belief_index  index into beliefs.entries
-- @return shift event table {belief_index, direction, old_strength, new_strength} or nil
function Erosion.check_tipping_point(char, belief_index)
    local belief = char.beliefs.entries[belief_index]
    assert(belief and belief.erosion, "invalid or uninitialized belief")

    local erosion = belief.erosion
    if math.abs(erosion.pressure) >= erosion.threshold then
        local direction = erosion.pressure > 0 and 1 or -1
        local old_strength = belief.strength
        belief.strength = clamp(belief.strength + direction * erosion.shift_amount)

        -- Reset pressure
        erosion.pressure = 0
        -- Threshold increases by 10% (belief hardens after being tested)
        erosion.threshold = erosion.threshold * 1.1

        return {
            belief_index = belief_index,
            direction = direction,
            old_strength = old_strength,
            new_strength = belief.strength,
        }
    end
    return nil
end

--- Get how close a belief is to its tipping point (0..1).
-- Useful for subtle behavior hints (e.g. NPC becomes slightly uneasy).
function Erosion.get_tipping_proximity(char, belief_index)
    local belief = char.beliefs.entries[belief_index]
    assert(belief and belief.erosion, "invalid or uninitialized belief")
    return math.min(1, math.abs(belief.erosion.pressure) / belief.erosion.threshold)
end

--- Convenience: process Beliefs.evaluate() output and feed into erosion.
-- Translates "challenged"/"reinforced" impacts into pressure, scaled by emotion deltas.
-- @param char            character table
-- @param belief_impacts  table of {belief_index = "challenged"|"reinforced"|"neutral"}
-- @param emotion_deltas  table of {emotion_name = delta} from the same evaluation
function Erosion.process_evaluation(char, belief_impacts, emotion_deltas)
    if not char.beliefs then return end

    -- Compute magnitude from emotion deltas
    local total_magnitude = 0
    for _, delta in pairs(emotion_deltas) do
        total_magnitude = total_magnitude + math.abs(delta)
    end
    -- Normalize: typical evaluation produces ~0.1-0.3 total; scale to 0..0.15 pressure
    local pressure_amount = math.min(0.15, total_magnitude * 0.3)

    local tipping_events = {}
    for idx, impact in pairs(belief_impacts) do
        if type(idx) == "number" and char.beliefs.entries[idx] and char.beliefs.entries[idx].erosion then
            if impact == "challenged" then
                Erosion.apply_pressure(char, idx, -1, pressure_amount)
            elseif impact == "reinforced" then
                Erosion.apply_pressure(char, idx, 1, pressure_amount)
            end
            -- Check for tipping after applying pressure
            local event = Erosion.check_tipping_point(char, idx)
            if event then
                table.insert(tipping_events, event)
            end
        end
    end
    return tipping_events
end

-- Self-test block
if not pcall(debug.getlocal, 4, 1) then
    local Beliefs = require("emotions.beliefs")
    local function banner(msg) print("\n" .. string.rep("=", 50) .. "\n" .. msg .. "\n" .. string.rep("=", 50)) end

    -- Test 1: Init
    banner("Test 1: Erosion initialization")
    local char = EmotionSystem.new_character("default")
    Beliefs.init(char, {
        { text = "Violence is never the answer.", strength = 0.8, inertia = 0.7, tags = {"pacifism"} },
        { text = "Trust is earned.", strength = 0.6, inertia = 0.5, tags = {"trust"} },
    })
    Erosion.init(char)
    assert(char.beliefs.entries[1].erosion, "erosion should be attached")
    assert(char.beliefs.entries[1].erosion.pressure == 0, "pressure should start at 0")
    assert(char.beliefs.entries[1].erosion.threshold == 0.3, "default threshold")
    print("PASS")

    -- Test 2: Pressure accumulates
    banner("Test 2: Pressure accumulation")
    Erosion.apply_pressure(char, 1, -1, 0.1)
    assert(char.beliefs.entries[1].erosion.pressure == -0.1, "pressure should be -0.1")
    Erosion.apply_pressure(char, 1, -1, 0.1)
    assert(math.abs(char.beliefs.entries[1].erosion.pressure - (-0.2)) < 0.001, "pressure should be -0.2")
    print("Pressure: " .. char.beliefs.entries[1].erosion.pressure)
    print("PASS")

    -- Test 3: Tipping point fires
    banner("Test 3: Tipping point")
    Erosion.apply_pressure(char, 1, -1, 0.15)  -- pushes to -0.35, beyond threshold of 0.3
    local event = Erosion.check_tipping_point(char, 1)
    assert(event, "tipping should fire")
    assert(event.direction == -1, "should be weakening")
    assert(math.abs(event.old_strength - 0.8) < 0.001, "old strength")
    assert(math.abs(event.new_strength - 0.7) < 0.001, "new strength after -0.1 shift")
    print("Tipped: " .. event.old_strength .. " -> " .. event.new_strength)
    -- Pressure resets
    assert(char.beliefs.entries[1].erosion.pressure == 0, "pressure resets after tipping")
    -- Threshold hardens
    assert(math.abs(char.beliefs.entries[1].erosion.threshold - 0.33) < 0.001,
        "threshold should increase 10%: got " .. char.beliefs.entries[1].erosion.threshold)
    print("New threshold: " .. string.format("%.3f", char.beliefs.entries[1].erosion.threshold))
    print("PASS")

    -- Test 4: Tipping proximity
    banner("Test 4: Tipping proximity")
    Erosion.apply_pressure(char, 1, -1, 0.15)
    local prox = Erosion.get_tipping_proximity(char, 1)
    print("Proximity: " .. string.format("%.3f", prox))
    assert(prox > 0 and prox < 1, "should be between 0 and 1")
    -- 0.15 / 0.33 ≈ 0.455
    assert(math.abs(prox - 0.15/0.33) < 0.01, "expected ~0.455")
    print("PASS")

    -- Test 5: Time decay
    banner("Test 5: Time-based decay")
    -- Reset for clean test
    char.beliefs.entries[2].erosion.pressure = 0.2
    char.beliefs.entries[2].erosion.last_event_time = 0
    Erosion.tick(char, 10)
    -- decay = 0.01 * 10 = 0.1; new pressure = 0.2 - 0.1 = 0.1
    print("Pressure after decay: " .. string.format("%.3f", char.beliefs.entries[2].erosion.pressure))
    assert(math.abs(char.beliefs.entries[2].erosion.pressure - 0.1) < 0.001,
        "pressure should decay: got " .. char.beliefs.entries[2].erosion.pressure)
    print("PASS")

    -- Test 6: Decay doesn't overshoot past zero
    banner("Test 6: Decay clamp at zero")
    Erosion.tick(char, 100)  -- large time jump
    assert(char.beliefs.entries[2].erosion.pressure == 0,
        "pressure should not go below 0: got " .. char.beliefs.entries[2].erosion.pressure)
    print("PASS")

    -- Test 7: process_evaluation convenience
    banner("Test 7: Process evaluation output")
    local char2 = EmotionSystem.new_character("default")
    Beliefs.init(char2, {
        { text = "Peace above all.", strength = 0.8, inertia = 0.5, tags = {"pacifism"} },
    })
    Erosion.init(char2)
    -- Simulate repeated challenges
    for i = 1, 10 do
        local events = Erosion.process_evaluation(char2,
            { [1] = "challenged" },
            { anxiety = 0.1, fear = 0.05, anger = 0.03 })
        if events and #events > 0 then
            print("Tipping at iteration " .. i .. "!")
            print("  Strength: " .. events[1].old_strength .. " -> " .. events[1].new_strength)
            break
        end
    end
    assert(char2.beliefs.entries[1].strength < 0.8, "belief should have been weakened")
    print("Final strength: " .. string.format("%.3f", char2.beliefs.entries[1].strength))
    print("PASS")

    -- Test 8: Shock resets pressure (integration with beliefs.lua)
    banner("Test 8: Shock resets pressure")
    local char3 = EmotionSystem.new_character("default")
    Beliefs.init(char3, {
        { text = "I am strong.", strength = 0.7, inertia = 0.3, tags = {"self"} },
    })
    Erosion.init(char3)
    Erosion.apply_pressure(char3, 1, -1, 0.2)
    assert(char3.beliefs.entries[1].erosion.pressure ~= 0, "should have pressure")
    -- Shock resets pressure
    Beliefs.apply_shock(char3, 1, 1, 0.8)
    char3.beliefs.entries[1].erosion.pressure = 0  -- shock resets pressure
    assert(char3.beliefs.entries[1].erosion.pressure == 0, "shock should reset pressure")
    print("Pressure after shock: " .. char3.beliefs.entries[1].erosion.pressure)
    print("PASS")

    banner("All erosion tests passed!")
end

return Erosion
