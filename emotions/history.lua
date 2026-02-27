-- emotions/history.lua — Layer B: Emotional History & Baselines
-- Tracks significant emotional shifts so NPCs can reference their past.
local History = {}

local EmotionSystem = require("emotions.core")
local EMOTIONS = EmotionSystem.EMOTIONS

-- Time provider (injected at init, avoidig global dependency)
local _get_time = nil

--- Initialize history tracking on a character.
-- @param char       character table
-- @param get_time   function() -> number, returns current timestamp
-- @param ema_alpha  optional smoothing factor (default 0.05)
function History.init(char, get_time, ema_alpha)
    assert(get_time, "History.init requires a get_time function")
    _get_time = get_time

    local baselines = {}
    for _, e in ipairs(EMOTIONS) do
        baselines[e] = char.emotions[e]
    end

    char.history = {
        baselines = baselines,
        shifts = {},
        snapshots = {},
        _ema_alpha = ema_alpha or 0.05,
        -- Store the baseline at last shift per emotion (for shift detection)
        _shift_baselines = {},
    }
    -- Initialize shift baselines to current values
    for _, e in ipairs(EMOTIONS) do
        char.history._shift_baselines[e] = char.emotions[e]
    end
end

--- Update baselines via EMA and detect shifts. Intended as a post-hook.
-- @param char             character table
-- @param interaction_name interaction that was applied (for cause labeling)
-- @param applied_deltas   the deltas that were applied (from apply_interaction)
function History.update(char, interaction_name, applied_deltas)
    if not char.history then return end

    local alpha = char.history._ema_alpha
    local timestamp = _get_time and _get_time() or 0
    local shift_threshold = 0.3

    for _, e in ipairs(EMOTIONS) do
        local old_baseline = char.history.baselines[e]
        local current = char.emotions[e]

        -- EMA update: baseline = alpha * current + (1 - alpha) * old_baseline
        local new_baseline = alpha * current + (1 - alpha) * old_baseline
        char.history.baselines[e] = new_baseline

        -- Shift detection: compare against the baseline at last recorded shift
        local shift_ref = char.history._shift_baselines[e]
        if math.abs(new_baseline - shift_ref) > shift_threshold then
            table.insert(char.history.shifts, {
                timestamp = timestamp,
                emotion = e,
                from = shift_ref,
                to = new_baseline,
                cause = interaction_name,
            })
            char.history._shift_baselines[e] = new_baseline
        end
    end
end

--- Take an explicit snapshot of all emotions at a point in time.
-- @param char       character table
-- @param timestamp  number
-- @param label      string label for this snapshot (e.g. "after_quest_1")
function History.take_snapshot(char, timestamp, label)
    assert(char.history, "History not initialized")
    local snap = {}
    for _, e in ipairs(EMOTIONS) do
        snap[e] = char.emotions[e]
    end
    table.insert(char.history.snapshots, {
        timestamp = timestamp,
        emotions = snap,
        label = label,
    })
end

--- Find the most recent shift for a specific emotion.
-- @param char    character table
-- @param emotion emotion name
-- @return shift table or nil
function History.find_shift(char, emotion)
    if not char.history then return nil end
    for i = #char.history.shifts, 1, -1 do
        if char.history.shifts[i].emotion == emotion then
            return char.history.shifts[i]
        end
    end
    return nil
end

--- Get all shifts exceeding a threshold magnitude.
-- Useful for building LLM prompts about a character's emotional journey.
-- @param char       character table
-- @param threshold  minimum |from - to| to include (default 0.3)
-- @return list of shift tables
function History.get_narrative_shifts(char, threshold)
    threshold = threshold or 0.3
    if not char.history then return {} end
    local result = {}
    for _, shift in ipairs(char.history.shifts) do
        if math.abs(shift.to - shift.from) >= threshold then
            table.insert(result, shift)
        end
    end
    return result
end

--- Create a post-hook function for use with EmotionSystem.register_hook.
-- @return function suitable for register_hook
function History.make_post_hook()
    return function(char, interaction_name, applied_deltas)
        History.update(char, interaction_name, applied_deltas)
    end
end

-- Self-test block
if not pcall(debug.getlocal, 4, 1) then
    local function banner(msg) print("\n" .. string.rep("=", 50) .. "\n" .. msg .. "\n" .. string.rep("=", 50)) end

    local time = 0
    local function get_time() return time end

    -- Test 1: Init creates proper structure
    banner("Test 1: History initialization")
    local char = EmotionSystem.new_character("default")
    History.init(char, get_time)
    assert(char.history, "history should exist")
    assert(char.history.baselines.happiness == 0, "baseline should start at current emotion")
    assert(char.history._ema_alpha == 0.05, "default alpha should be 0.05")
    print("PASS")

    -- Test 2: Baseline moves slowly with EMA
    banner("Test 2: EMA baseline tracking")
    char.emotions.happiness = 0.8
    time = 10
    History.update(char, "test", {})
    -- After one update: 0.05 * 0.8 + 0.95 * 0 = 0.04
    assert(math.abs(char.history.baselines.happiness - 0.04) < 0.001,
        "baseline should move slowly: got " .. char.history.baselines.happiness)
    print("Baseline after 1 update: " .. char.history.baselines.happiness)
    print("PASS")

    -- Test 3: Sustained high emotion eventually causes shift
    banner("Test 3: Shift detection after sustained emotion")
    local char2 = EmotionSystem.new_character("default")
    History.init(char2, get_time, 0.05)
    char2.emotions.fear = 0.9
    -- Simulate many updates to build up baseline
    for i = 1, 100 do
        time = i
        History.update(char2, "repeated_threat", {})
    end
    print("Fear baseline after 100 updates at 0.9: " .. char2.history.baselines.fear)
    local shift = History.find_shift(char2, "fear")
    assert(shift, "should detect a fear shift after sustained high fear")
    print("Shift detected: from=" .. string.format("%.3f", shift.from)
        .. " to=" .. string.format("%.3f", shift.to)
        .. " cause=" .. shift.cause)
    print("PASS")

    -- Test 4: Short spike does NOT cause shift
    banner("Test 4: Short spike does not trigger shift")
    local char3 = EmotionSystem.new_character("default")
    History.init(char3, get_time, 0.05)
    char3.emotions.anger = 0.9
    time = 1
    History.update(char3, "flash_anger", {})
    char3.emotions.anger = 0  -- anger subsides immediately
    for i = 2, 5 do
        time = i
        History.update(char3, "calm", {})
    end
    local anger_shift = History.find_shift(char3, "anger")
    assert(anger_shift == nil, "short spike should NOT cause a shift")
    print("No shift detected for brief anger spike")
    print("PASS")

    -- Test 5: Snapshots
    banner("Test 5: Snapshot mechanism")
    History.take_snapshot(char2, 200, "after_quest_1")
    assert(#char2.history.snapshots == 1, "should have 1 snapshot")
    assert(char2.history.snapshots[1].label == "after_quest_1", "snapshot label should match")
    assert(char2.history.snapshots[1].emotions.fear == char2.emotions.fear,
        "snapshot should capture current emotions")
    print("Snapshot taken and verified")
    print("PASS")

    -- Test 6: get_narrative_shifts filters by threshold
    banner("Test 6: Narrative shifts filtering")
    local shifts = History.get_narrative_shifts(char2, 0.3)
    assert(#shifts > 0, "should find narrative shifts")
    for _, s in ipairs(shifts) do
        assert(math.abs(s.to - s.from) >= 0.3,
            "all narrative shifts should meet threshold")
    end
    print("Found " .. #shifts .. " narrative shifts meeting threshold")
    print("PASS")

    -- Test 7: Integration with hooks
    banner("Test 7: Works as a post-hook")
    EmotionSystem._post_interaction_hooks = {}
    EmotionSystem._pre_interaction_hooks = {}
    local char4 = EmotionSystem.new_character("default")
    History.init(char4, get_time, 0.1)  -- higher alpha for faster test
    EmotionSystem.register_hook(History.make_post_hook())
    -- Apply many threats to build up fear baseline
    for i = 1, 50 do
        time = 100 + i
        EmotionSystem.apply_interaction(char4, "threat", 1.0)
    end
    local fear_shift = History.find_shift(char4, "fear")
    assert(fear_shift, "hook-driven updates should detect fear shift")
    print("Hook integration works — detected shift via post-hook")
    print("PASS")

    EmotionSystem._post_interaction_hooks = {}
    EmotionSystem._pre_interaction_hooks = {}
    banner("All history tests passed!")
end

return History
