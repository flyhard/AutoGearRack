-- AutoGearRack: glue between AutoGear, Pawn and ItemRack on WoW Forever.
--  * points AutoGear at a Pawn scale chosen per spec slot
--  * when AutoGear equips an upgrade, writes it into the ItemRack sets that held the old item
--  * pauses AutoGear while a situational ItemRack set is worn or a spec switch is in progress
-- It never equips anything itself. See docs/spec.md.

local ADDON = ...
local AGR = {}
_G.AutoGearRack = AGR

local PREFIX = "|cff33ccffAutoGearRack|r: "
local MAIN_SET_MIN_SLOTS = 10
local TOUCH_WINDOW = 5       -- seconds an AutoGear equip call marks a slot
local FLUSH_DELAY = 1        -- seconds after the last change before sets are written
local SPEC_SETTLE = 2        -- seconds a spec switch keeps AutoGear paused at minimum

local db
local touched, snapshot, queue = {}, {}, {}
local warnedNoScale = {}
local specSwitchStart
local flushPending, pauseCheckPending, specPollPending

-- clock and timers are looked up at call time so tests can stub them
local function now() return GetTime() end
local function after(sec, fn)
  if C_Timer and C_Timer.After then C_Timer.After(sec, fn) else fn() end
end

local function print_(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end
local function debug(msg) if db and db.debug then print_("|cff999999" .. msg .. "|r") end end
AGR.Print = print_

---------------------------------------------------------------------------------------------
-- Detection
---------------------------------------------------------------------------------------------

local function hasAutoGear() return type(AutoGearDB) == "table" end
local function hasItemRack()
  return type(ItemRack) == "table" and type(ItemRack.GetID) == "function"
    and type(ItemRackUser) == "table" and type(ItemRackUser.Sets) == "table"
end
local function pawnReady() return type(PawnIsReady) == "function" and PawnIsReady() and type(PawnCommon) == "table" end
AGR.HasAutoGear, AGR.HasItemRack, AGR.PawnReady = hasAutoGear, hasItemRack, pawnReady

function AGR.GetSpecSlot()
  local fns = {
    C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup,
    GetActiveSpecGroup, GetActiveTalentGroup,
    type(ItemRack) == "table" and ItemRack.GetActiveSpec or nil,
  }
  for i = 1, 4 do -- not ipairs: the list has holes for APIs this client lacks
    local fn = fns[i]
    if type(fn) == "function" then
      local ok, v = pcall(fn)
      if ok and tonumber(v) then return tonumber(v) end
    end
  end
  return 1
end

---------------------------------------------------------------------------------------------
-- ItemRack sets
---------------------------------------------------------------------------------------------

local function isInternal(name) return type(name) ~= "string" or name:sub(1, 1) == "~" end

-- spec slot a set is tied to: ItemRack Universal uses AssociatedSpec, ItemRack (Forever) uses spec
function AGR.SetSpec(set)
  local s = tonumber(set.AssociatedSpec) or tonumber(set.spec)
  if s and s > 0 then return s end
end

function AGR.SavedSlotCount(set)
  local n = 0
  if type(set.equip) == "table" then
    for slot in pairs(set.equip) do
      if type(slot) == "number" and slot >= 1 and slot <= 19 then n = n + 1 end
    end
  end
  return n
end

function AGR.IsMainSet(name)
  local set = hasItemRack() and ItemRackUser.Sets[name]
  return set and not isInternal(name) and AGR.SavedSlotCount(set) >= MAIN_SET_MIN_SLOTS or false
end

local function explicitList()
  return db and db.sets and next(db.sets) and db.sets or nil
end

-- returns ordered list of {name, set} that receive AutoGear upgrades, plus skipped {name, reason}
function AGR.TargetSets()
  local targets, skipped = {}, {}
  if not hasItemRack() then return targets, skipped end
  local spec = AGR.GetSpecSlot()
  local explicit = explicitList()
  local names = {}
  for name in pairs(ItemRackUser.Sets) do if not isInternal(name) then names[#names + 1] = name end end
  table.sort(names)
  for _, name in ipairs(names) do
    local set = ItemRackUser.Sets[name]
    local setSpec = AGR.SetSpec(set)
    if explicit and not explicit[name] then
      skipped[#skipped + 1] = { name, "not in your /agr list" }
    elseif not explicit and AGR.SavedSlotCount(set) < MAIN_SET_MIN_SLOTS then
      skipped[#skipped + 1] = { name, "situational (fewer than " .. MAIN_SET_MIN_SLOTS .. " slots)" }
    elseif setSpec and setSpec ~= spec then
      skipped[#skipped + 1] = { name, "tied to spec " .. setSpec }
    else
      targets[#targets + 1] = { name, set }
    end
  end
  return targets, skipped
end

local function sameItem(a, b)
  if a == nil or b == nil then return false end
  if tostring(a) == tostring(b) then return true end
  if type(ItemRack.SameID) == "function" then
    local ok, same = pcall(ItemRack.SameID, a, b)
    if ok then return same and true or false end
  end
  return false
end
AGR.SameItem = sameItem

local function linkFor(id)
  if id == nil or tostring(id) == "0" then return "(empty)" end
  if type(GetItemInfo) == "function" then
    local _, link = GetItemInfo("item:" .. tostring(id))
    if link then return link end
  end
  return "item:" .. tostring(id)
end

-- apply queued {slot, old, new} changes; returns table of changed set names
function AGR.ApplyChanges(changes)
  local changed = {}
  local targets = AGR.TargetSets()
  for _, c in ipairs(changes) do
    for _, t in ipairs(targets) do
      local name, set = t[1], t[2]
      local saved = set.equip and set.equip[c.slot]
      if saved ~= nil and sameItem(saved, c.old) and not sameItem(saved, c.new) then
        set.equip[c.slot] = c.new
        changed[name] = changed[name] or {}
        table.insert(changed[name], c)
      end
    end
  end
  for name, list in pairs(changed) do
    for _, c in ipairs(list) do
      print_("updated " .. name .. ": " .. linkFor(c.old) .. " -> " .. linkFor(c.new))
    end
    if type(ItemRack.FireItemRackEvent) == "function" then
      pcall(ItemRack.FireItemRackEvent, ItemRack, "ITEMRACK_SET_SAVED", name)
    end
  end
  if next(changed) and type(ItemRack.UpdateCurrentSet) == "function" then pcall(ItemRack.UpdateCurrentSet) end
  return changed
end

---------------------------------------------------------------------------------------------
-- Watching AutoGear's equips
---------------------------------------------------------------------------------------------

function AGR.CalledByAutoGear()
  local stack = debugstack and debugstack(2, 30, 0) or ""
  return stack:find("AddOns[/\\]AutoGear[/\\]") ~= nil
end

local function markSlot(slot)
  slot = tonumber(slot)
  if slot and slot >= 1 and slot <= 19 and AGR.CalledByAutoGear() then
    touched[slot] = now()
    debug("AutoGear is equipping slot " .. slot)
  end
end

local function readSlot(slot)
  local ok, id = pcall(ItemRack.GetID, slot)
  if ok then return id end
end

function AGR.TakeSnapshot()
  if not hasItemRack() then return end
  for slot = 1, 19 do snapshot[slot] = readSlot(slot) end
end

local function recentlyTouched(slot)
  return touched[slot] and now() - touched[slot] <= TOUCH_WINDOW
end

local function mainHandIsFishingPole()
  local id = GetInventoryItemID and GetInventoryItemID("player", 16)
  if not id then return false end
  local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not getInfo then return false end
  local _, _, _, _, _, classID, subclassID = getInfo(id)
  return classID == 2 and subclassID == 20
end

function AGR.CanFlush()
  if InCombatLockdown and InCombatLockdown() then return false, "in combat" end
  if ItemRack.SetSwapping then return false, "ItemRack is swapping" end
  if mainHandIsFishingPole() then return false, "fishing pole equipped" end
  return true
end

function AGR.Flush()
  flushPending = nil
  if #queue == 0 or not hasItemRack() then return end
  local ok, why = AGR.CanFlush()
  if not ok then
    debug("waiting to update sets: " .. why)
    AGR.ScheduleFlush(2)
    return
  end
  local changes = queue
  queue = {}
  if db.enabled then AGR.ApplyChanges(changes) end
end

function AGR.ScheduleFlush(delay)
  if flushPending then return end
  flushPending = true
  after(delay or FLUSH_DELAY, AGR.Flush)
end

function AGR.OnEquipmentChanged(slot)
  slot = tonumber(slot)
  if not slot or slot < 1 or slot > 19 or not hasItemRack() then return end
  local old, new = snapshot[slot], readSlot(slot)
  snapshot[slot] = new
  if ItemRack.SetSwapping then return end
  local byAutoGear = recentlyTouched(slot) or (slot == 17 and recentlyTouched(16))
  if byAutoGear and old ~= nil and new ~= nil and not sameItem(old, new) then
    queue[#queue + 1] = { slot = slot, old = old, new = new }
    debug("queued slot " .. slot)
    AGR.ScheduleFlush()
  end
end

---------------------------------------------------------------------------------------------
-- Pawn scale per spec
---------------------------------------------------------------------------------------------

-- returns the true scale key for a user-typed name (key or localized name), or nil
function AGR.ResolveScale(name)
  if not pawnReady() or type(name) ~= "string" then return end
  local lower = name:lower()
  for key, scale in pairs(PawnCommon.Scales) do
    if key == name or (scale.LocalizedName and scale.LocalizedName == name) then return key end
  end
  for key, scale in pairs(PawnCommon.Scales) do
    if key:lower() == lower or (scale.LocalizedName and scale.LocalizedName:lower() == lower) then return key end
  end
end

function AGR.ApplyScale()
  if not db or not db.enabled or not hasAutoGear() or not pawnReady() then return end
  if not AutoGearDB.UsePawn then
    if db.pawnEnabledOnce then return end -- Per turned it off: respect that
    AutoGearDB.UsePawn = true
    print_("turned on AutoGear's \"Use Pawn to evaluate upgrades\".")
  end
  db.pawnEnabledOnce = true
  local slot = AGR.GetSpecSlot()
  local key = db.scales[slot] and AGR.ResolveScale(db.scales[slot])
  if key then
    if AutoGearDB.PawnScale ~= key or not AutoGearDB.OverridePawnScale then
      AutoGearDB.OverridePawnScale = true
      AutoGearDB.PawnScale = key
      print_("spec " .. slot .. ": AutoGear now uses Pawn scale \"" .. key .. "\".")
    end
  else
    AutoGearDB.OverridePawnScale = false
    if not warnedNoScale[slot] then
      warnedNoScale[slot] = true
      if db.scales[slot] then
        print_("Pawn scale \"" .. db.scales[slot] .. "\" for spec " .. slot .. " no longer exists. AutoGear is using its class profile.")
      else
        print_("no Pawn scale for spec " .. slot .. ": AutoGear is using its class profile. Use /agr scale " .. slot .. " <name>.")
      end
    end
  end
end

---------------------------------------------------------------------------------------------
-- Pausing AutoGear
---------------------------------------------------------------------------------------------

function AGR.SituationalSetWorn()
  if not hasItemRack() then return end
  local name = ItemRackUser.CurrentSet
  if isInternal(name) or not ItemRackUser.Sets[name] or AGR.IsMainSet(name) then return end
  if type(ItemRack.IsSetEquipped) == "function" then
    local ok, worn = pcall(ItemRack.IsSetEquipped, name)
    if ok and worn then return name end
  end
end

function AGR.PauseReason()
  if specSwitchStart then return "switching spec" end
  local set = AGR.SituationalSetWorn()
  if set then return "situational set \"" .. set .. "\" is on" end
end

local function pause(reason)
  if db.pausedByUs then return end
  if not AutoGearDB.Enabled then return end -- already off by Per's choice
  AutoGearDB.Enabled = false
  db.pausedByUs = true
  print_("paused AutoGear: " .. reason .. ".")
end

local function resume()
  if not db.pausedByUs then return end
  db.pausedByUs = false
  AutoGearDB.Enabled = true
  print_("resumed AutoGear.")
  if type(AutoGearQueueScan) == "function" then pcall(AutoGearQueueScan) end
end

function AGR.UpdatePause()
  pauseCheckPending = nil
  if not hasAutoGear() then return end
  if type(ItemRack) == "table" and ItemRack.SetSwapping then return AGR.SchedulePauseCheck() end
  local reason = db.enabled and AGR.PauseReason()
  if reason then pause(reason) else resume() end
end

function AGR.SchedulePauseCheck()
  if pauseCheckPending then return end
  pauseCheckPending = true
  after(0.5, AGR.UpdatePause)
end

local function pollSpecSwitch()
  specPollPending = nil
  if not specSwitchStart then return end
  if (type(ItemRack) == "table" and ItemRack.SetSwapping) or now() - specSwitchStart < SPEC_SETTLE then
    specPollPending = true
    after(0.5, pollSpecSwitch)
    return
  end
  specSwitchStart = nil
  AGR.TakeSnapshot()
  AGR.ApplyScale()
  AGR.UpdatePause()
end

local lastSpec
function AGR.OnSpecEvent()
  local spec = AGR.GetSpecSlot()
  if spec == lastSpec then return end
  lastSpec = spec
  debug("spec slot is now " .. spec)
  specSwitchStart = now()
  if hasAutoGear() and db.enabled then pause("switching spec") end
  AGR.ApplyScale()
  if not specPollPending then
    specPollPending = true
    after(0.5, pollSpecSwitch)
  end
end

---------------------------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------------------------

local function status()
  print_("v" .. (AGR.version or "?") .. (db.enabled and "" or " |cffff5555(off)|r"))
  print_("AutoGear: " .. (hasAutoGear() and "found" or "|cffff5555missing|r")
    .. ", ItemRack: " .. (hasItemRack() and "found" or "|cffff5555missing|r")
    .. ", Pawn: " .. (pawnReady() and "ready" or "not ready"))
  local slot = AGR.GetSpecSlot()
  print_("active spec slot: " .. slot)
  for s = 1, 2 do
    print_("  spec " .. s .. " scale: " .. (db.scales[s] or "(none, class profile)"))
  end
  if hasAutoGear() then
    print_("AutoGear Use Pawn: " .. (AutoGearDB.UsePawn and "on" or "off")
      .. ", scale: " .. (AutoGearDB.OverridePawnScale and tostring(AutoGearDB.PawnScale) or "auto")
      .. ", AutoGear " .. (AutoGearDB.Enabled and "on" or (db.pausedByUs and "paused by AutoGearRack" or "off")))
  end
  if pawnReady() then
    local names = {}
    for key, scale in pairs(PawnCommon.Scales) do
      if type(PawnIsScaleVisible) ~= "function" or PawnIsScaleVisible(key) then names[#names + 1] = scale.LocalizedName or key end
    end
    table.sort(names)
    print_("visible Pawn scales: " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
  end
  if hasItemRack() then
    local targets, skipped = AGR.TargetSets()
    local t = {}
    for _, v in ipairs(targets) do t[#t + 1] = v[1] end
    print_("sets that follow AutoGear" .. (explicitList() and " (your list)" or " (auto)") .. ": "
      .. (#t > 0 and table.concat(t, ", ") or "(none)"))
    for _, v in ipairs(skipped) do print_("  skipped " .. v[1] .. ": " .. v[2]) end
  end
  local reason = AGR.PauseReason()
  if reason then print_("pause reason: " .. reason) end
end

local function help()
  print_("/agr status | scale <1|2> <name> | scale <1|2> clear | add <set> | remove <set> | auto | on | off | debug")
end

function AGR.Slash(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "" or cmd == "status" then
    status()
  elseif cmd == "scale" then
    local s, name = rest:match("^(%d)%s+(.+)$")
    s = tonumber(s)
    if not s or s < 1 or s > 2 then return help() end
    if name:lower() == "clear" then
      db.scales[s] = nil
      warnedNoScale[s] = nil
      print_("spec " .. s .. " scale cleared.")
    else
      if not pawnReady() then return print_("Pawn isn't ready yet.") end
      local key = AGR.ResolveScale(name)
      if not key then return print_("Pawn has no scale named \"" .. name .. "\". /agr status lists them.") end
      db.scales[s] = key
      warnedNoScale[s] = nil
      print_("spec " .. s .. " will use Pawn scale \"" .. key .. "\".")
    end
    AGR.ApplyScale()
  elseif cmd == "add" or cmd == "remove" then
    if rest == "" then return help() end
    if cmd == "add" then
      if not (hasItemRack() and ItemRackUser.Sets[rest]) or isInternal(rest) then
        return print_("ItemRack has no set named \"" .. rest .. "\".")
      end
      db.sets[rest] = true
      print_("\"" .. rest .. "\" will follow AutoGear. Only listed sets do now; /agr auto undoes that.")
    else
      db.sets[rest] = nil
      print_("\"" .. rest .. "\" removed from your list" .. (next(db.sets) and "." or "; back to automatic."))
    end
  elseif cmd == "auto" then
    wipe(db.sets)
    print_("automatic: every main set of your active spec follows AutoGear.")
  elseif cmd == "on" or cmd == "off" then
    db.enabled = (cmd == "on")
    print_(db.enabled and "on." or "off.")
    if db.enabled then AGR.ApplyScale() end
    AGR.UpdatePause()
  elseif cmd == "debug" then
    db.debug = not db.debug
    print_("debug " .. (db.debug and "on." or "off."))
  else
    help()
  end
end

---------------------------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------------------------

local function initDB()
  AutoGearRackDB = AutoGearRackDB or {}
  db = AutoGearRackDB
  if db.enabled == nil then db.enabled = true end
  db.scales = db.scales or {}
  db.sets = db.sets or {}
  AGR.db = db
end

local function waitForPawn(tries)
  if pawnReady() then return AGR.ApplyScale() end
  if (tries or 0) < 10 then after(1, function() waitForPawn((tries or 0) + 1) end) end
end

function AGR.OnLogin()
  initDB()
  AGR.version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata or function() end)(ADDON or "AutoGearRack", "Version")
  local missing = {}
  if not hasAutoGear() then missing[#missing + 1] = "AutoGear" end
  if not hasItemRack() then missing[#missing + 1] = "ItemRack" end
  if #missing > 0 then print_("missing " .. table.concat(missing, " and ") .. "; those parts are off.") end
  lastSpec = AGR.GetSpecSlot()
  AGR.TakeSnapshot()
  waitForPawn(0)
  after(2, AGR.UpdatePause) -- also resumes a pause left over from before a /reload
end

local frame = CreateFrame("Frame")
AGR.frame = frame
local handlers = {
  PLAYER_LOGIN = AGR.OnLogin,
  PLAYER_ENTERING_WORLD = function() AGR.TakeSnapshot() end,
  PLAYER_EQUIPMENT_CHANGED = function(slot)
    AGR.OnEquipmentChanged(slot)
    AGR.SchedulePauseCheck()
  end,
  PLAYER_REGEN_ENABLED = function() if #queue > 0 then AGR.ScheduleFlush() end end,
  ACTIVE_TALENT_GROUP_CHANGED = AGR.OnSpecEvent,
  PLAYER_SPECIALIZATION_CHANGED = function(unit) if unit == nil or unit == "player" then AGR.OnSpecEvent() end end,
  PLAYER_TALENT_UPDATE = AGR.OnSpecEvent,
}
for event in pairs(handlers) do pcall(frame.RegisterEvent, frame, event) end
frame:SetScript("OnEvent", function(_, event, ...)
  if event ~= "PLAYER_LOGIN" and not db then return end
  handlers[event](...)
end)

hooksecurefunc("EquipCursorItem", markSlot)
hooksecurefunc("PickupInventoryItem", markSlot)

SLASH_AUTOGEARRACK1 = "/agr"
SLASH_AUTOGEARRACK2 = "/autogearrack"
SlashCmdList.AUTOGEARRACK = AGR.Slash
