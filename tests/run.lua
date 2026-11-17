-- Plain Lua 5.1 tests with stubbed WoW, AutoGear, Pawn and ItemRack APIs.
-- Run from the repo root: lua5.1 tests/run.lua

local clock = 100
local timers = {}
local messages = {}
local frameScript, inventory, stackText

local function reset()
  clock, timers, messages = 100, {}, {}
  inventory = {}
  stackText = ""
end

function GetTime() return clock end
C_Timer = { After = function(sec, fn) timers[#timers + 1] = { at = clock + sec, fn = fn } end }
local function advance(sec)
  local target = clock + sec
  while true do
    table.sort(timers, function(a, b) return a.at < b.at end)
    local t = timers[1]
    if not t or t.at > target then break end
    table.remove(timers, 1)
    clock = t.at
    t.fn()
  end
  clock = target
end

DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) messages[#messages + 1] = m end }
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function InCombatLockdown() return false end
function GetInventoryItemID(_, slot) return inventory[slot] and tonumber(inventory[slot]:match("^(%d+)")) end
function GetItemInfoInstant() return nil end
function GetItemInfo() return nil end
function debugstack() return stackText end
function GetActiveTalentGroup() return SPEC end
SPEC = 1

local hooks = {}
function hooksecurefunc(name, fn)
  local orig = _G[name]
  _G[name] = function(...) orig(...); fn(...) end
end
function EquipCursorItem() end
function PickupInventoryItem() end
SlashCmdList = {}

-- generic widget mock: unknown methods are no-ops, a few keep state
local function mock()
  local obj = { scripts = {}, checked = false, shown = true, text = "" }
  local methods = {
    SetScript = function(self, name, fn)
      self.scripts[name] = fn
      if name == "OnEvent" and not frameScript then frameScript = fn end
    end,
    GetChecked = function(self) return self.checked end,
    SetChecked = function(self, v) self.checked = v and true or false end,
    IsVisible = function() return true end,
    Show = function(self) self.shown = true end,
    Hide = function(self) self.shown = false end,
    SetShown = function(self, v) self.shown = v and true or false end,
    SetText = function(self, t) self.text = t end,
    GetText = function(self) return self.text end,
    CreateFontString = function() return mock() end,
    SetupMenu = function(self, fn) self.menuFn = fn end,
    GenerateMenu = function(self)
      local root = { radios = {} }
      function root:CreateRadio(text, isSelected, onSelect)
        self.radios[#self.radios + 1] = { text = text, selected = isSelected(), select = onSelect }
      end
      self.menuFn(self, root)
      self.lastMenu = root
    end,
    Click = function(self)
      self.checked = not self.checked
      if self.scripts.OnClick then self.scripts.OnClick(self) end
    end,
  }
  return setmetatable(obj, { __index = function(_, k) return methods[k] or function() end end })
end
function CreateFrame() return mock() end
MenuUtil, WowStyle1DropdownMixin = {}, {}
Settings = {
  RegisterCanvasLayoutCategory = function() return { GetID = function() return 7 end } end,
  RegisterAddOnCategory = function() end,
  OpenToCategory = function(id) Settings.opened = id end,
}
local function fire(event, ...) frameScript(nil, event, ...) end

-- ItemRack stub (Universal-like)
ItemRack = {
  GetID = function(slot) return inventory[slot] or 0 end,
  SameID = function(a, b) return tostring(a):match("^(%-?%d+)") == tostring(b):match("^(%-?%d+)") end,
  IsSetEquipped = function(name)
    local set = ItemRackUser.Sets[name]
    for slot, id in pairs(set.equip) do if tostring(inventory[slot] or 0) ~= tostring(id) then return false end end
    return true
  end,
  FireItemRackEvent = function(self, event, name) ItemRack.fired = (ItemRack.fired or 0) + 1 end,
}
ItemRackUser = { Sets = {} }

AutoGearDB = {}
function PawnIsReady() return true end
PawnCommon = { Scales = { ["Paladin: Retribution"] = {}, ["Paladin: Protection"] = { LocalizedName = "Prot" } } }
function PawnIsScaleVisible() return true end
AutoGearQueueScan = function() AutoGearDB.scans = (AutoGearDB.scans or 0) + 1 end

local function fullSet(base, spec)
  local equip = {}
  for slot = 1, 12 do equip[slot] = tostring(base + slot) .. ":0:0" end
  return { equip = equip, AssociatedSpec = spec }
end

reset()
dofile("AutoGearRack.lua")
dofile("Options.lua")
local AGR = AutoGearRack

local failures, count = 0, 0
local function check(name, cond)
  count = count + 1
  if not cond then failures = failures + 1; print("FAIL: " .. name) else print("ok:   " .. name) end
end

local function login()
  AutoGearRackDB = nil
  AutoGearDB = { Enabled = true, UsePawn = false }
  fire("PLAYER_LOGIN")
  advance(3)
end

-- the AutoGear equip path: AutoGear calls EquipCursorItem, then the item lands
local function autogearEquip(slot, id)
  stackText = "[string \"@Interface/AddOns/AutoGear/AutoGear.lua\"]:5638: in function"
  EquipCursorItem(slot)
  stackText = ""
  inventory[slot] = id
  fire("PLAYER_EQUIPMENT_CHANGED", slot)
end
local function manualEquip(slot, id)
  stackText = "[string \"@Interface/FrameXML/PaperDollFrame.lua\"]:10: in function"
  EquipCursorItem(slot)
  stackText = ""
  inventory[slot] = id
  fire("PLAYER_EQUIPMENT_CHANGED", slot)
end

-- 1. Pawn turned on once, warning without scale
do
  for slot = 1, 12 do inventory[slot] = tostring(100 + slot) .. ":0:0" end
  ItemRackUser.Sets = { Main = fullSet(100), Mount = { equip = { [13] = "999:0:0" } } }
  ItemRackUser.CurrentSet = "Main"
  login()
  check("Use Pawn turned on at first login", AutoGearDB.UsePawn == true)
  check("no scale: override off", AutoGearDB.OverridePawnScale == false)
end

-- 2. /agr scale sets override, localized name works
do
  AGR.Slash("scale 1 paladin: retribution")
  check("scale 1 resolved case-insensitively", AutoGearRackDB.scales[1] == "Paladin: Retribution")
  check("AutoGear override set", AutoGearDB.OverridePawnScale == true and AutoGearDB.PawnScale == "Paladin: Retribution")
  AGR.Slash("scale 2 Prot")
  check("localized name resolves to key", AutoGearRackDB.scales[2] == "Paladin: Protection")
  AGR.Slash("scale 2 Nope")
  check("unknown scale rejected", AutoGearRackDB.scales[2] == "Paladin: Protection")
end

-- 3. Respect Use Pawn off after first run
do
  AutoGearDB.UsePawn = false
  AutoGearDB.PawnScale = "x"
  AGR.ApplyScale()
  check("UsePawn left off once user turned it off", AutoGearDB.UsePawn == false and AutoGearDB.PawnScale == "x")
  AutoGearDB.UsePawn = true
  AGR.ApplyScale()
end

-- 4. AutoGear upgrade updates the main set, not the situational one
do
  ItemRack.fired = 0
  autogearEquip(5, "555:0:0")
  advance(2)
  check("main set chest updated", ItemRackUser.Sets.Main.equip[5] == "555:0:0")
  check("mount set untouched", ItemRackUser.Sets.Mount.equip[5] == nil)
  check("ITEMRACK_SET_SAVED fired", ItemRack.fired == 1)
end

-- 5. Manual equip doesn't touch sets
do
  manualEquip(6, "666:0:0")
  advance(2)
  check("manual change ignored", ItemRackUser.Sets.Main.equip[6] == "106:0:0")
  inventory[6] = "106:0:0"; fire("PLAYER_EQUIPMENT_CHANGED", 6); advance(1)
end

-- 6. Level field differences still match by base item id
do
  ItemRackUser.Sets.Main.equip[7] = "107:0:0:0:0:0:0:0:40"
  autogearEquip(7, "777:0:0")
  advance(2)
  check("matched by base id despite level field", ItemRackUser.Sets.Main.equip[7] == "777:0:0")
end

-- 7. Spec-tied sets
do
  ItemRackUser.Sets.Tank = fullSet(100, 2)
  ItemRackUser.Sets.Tank.equip[8] = "108:0:0"
  autogearEquip(8, "888:0:0")
  advance(2)
  check("spec 1 set updated", ItemRackUser.Sets.Main.equip[8] == "888:0:0")
  check("spec 2 set left alone in spec 1", ItemRackUser.Sets.Tank.equip[8] == "108:0:0")
end

-- 8. Explicit list
do
  ItemRackUser.Sets.Alt = fullSet(100)
  ItemRackUser.Sets.Alt.equip[9] = "109:0:0"
  ItemRackUser.Sets.Main.equip[9] = "109:0:0"
  ItemRackUser.Sets.Few = { equip = { [1] = "101:0:0", [9] = "109:0:0" } }
  AGR.Slash("add Few")
  check("picking starts from the automatic sets", AutoGearRackDB.manual and AutoGearRackDB.sets.Main and AutoGearRackDB.sets.Alt and AutoGearRackDB.sets.Few)
  AGR.Slash("remove Main")
  autogearEquip(9, "999:1:1")
  advance(2)
  check("listed set updated", ItemRackUser.Sets.Alt.equip[9] == "999:1:1")
  check("picked situational set updated", ItemRackUser.Sets.Few.equip[9] == "999:1:1")
  check("unlisted main set left alone", ItemRackUser.Sets.Main.equip[9] == "109:0:0")
  AGR.Slash("auto")
  check("auto clears list", next(AutoGearRackDB.sets) == nil and not AutoGearRackDB.manual)
  ItemRackUser.Sets.Few = nil
end

-- 9. ItemRack swapping: changes ignored, flush waits
do
  ItemRack.SetSwapping = "Main"
  autogearEquip(10, "1010:0:0")
  ItemRack.SetSwapping = nil
  advance(2)
  check("change during ItemRack swap ignored", ItemRackUser.Sets.Main.equip[10] == "110:0:0")
end

-- 10. Situational set pauses AutoGear, removing it resumes
do
  local scans = AutoGearDB.scans or 0
  inventory[13] = "999:0:0"
  ItemRackUser.CurrentSet = "Mount"
  fire("PLAYER_EQUIPMENT_CHANGED", 13)
  advance(1)
  check("paused while mount set worn", AutoGearDB.Enabled == false and AutoGearRackDB.pausedByUs == true)
  inventory[13] = nil
  ItemRackUser.CurrentSet = "Main"
  fire("PLAYER_EQUIPMENT_CHANGED", 13)
  advance(1)
  check("resumed after mount set removed", AutoGearDB.Enabled == true and AutoGearRackDB.pausedByUs == false)
  check("rescan requested on resume", (AutoGearDB.scans or 0) == scans + 1)
end

-- 11. User-disabled AutoGear is never re-enabled
do
  AutoGearDB.Enabled = false
  ItemRackUser.CurrentSet = "Mount"; inventory[13] = "999:0:0"
  fire("PLAYER_EQUIPMENT_CHANGED", 13); advance(1)
  ItemRackUser.CurrentSet = "Main"; inventory[13] = nil
  fire("PLAYER_EQUIPMENT_CHANGED", 13); advance(1)
  check("AutoGear stays off when Per turned it off", AutoGearDB.Enabled == false)
  AutoGearDB.Enabled = true
end

-- 12. Spec switch: pause, scale swap, resume after settle
do
  SPEC = 2
  fire("ACTIVE_TALENT_GROUP_CHANGED")
  check("paused during spec switch", AutoGearDB.Enabled == false)
  check("spec 2 scale applied", AutoGearDB.PawnScale == "Paladin: Protection")
  ItemRack.SetSwapping = "Tank"
  advance(3)
  check("still paused while ItemRack swaps", AutoGearDB.Enabled == false)
  ItemRack.SetSwapping = nil
  advance(1)
  check("resumed after swap settles", AutoGearDB.Enabled == true)
  -- now spec 2 sets get updates
  autogearEquip(11, "1111:0:0")
  advance(2)
  check("spec 2 set updated in spec 2", ItemRackUser.Sets.Tank.equip[11] == "1111:0:0")
  SPEC = 1
  fire("ACTIVE_TALENT_GROUP_CHANGED"); advance(3)
end

-- 13. 2H replaces MH and clears the off hand
do
  ItemRackUser.Sets.Main.equip[16] = "1616:0:0"; inventory[16] = "1616:0:0"
  ItemRackUser.Sets.Main.equip[17] = "1717:0:0"; inventory[17] = "1717:0:0"
  AGR.TakeSnapshot()
  autogearEquip(16, "2020:0:0")
  inventory[17] = nil
  fire("PLAYER_EQUIPMENT_CHANGED", 17)
  advance(2)
  check("main hand updated to 2H", ItemRackUser.Sets.Main.equip[16] == "2020:0:0")
  check("off hand updated to empty", tostring(ItemRackUser.Sets.Main.equip[17]) == "0")
end

-- 14. /agr off stops set updates
do
  AGR.Slash("off")
  autogearEquip(12, "1212:0:0")
  advance(2)
  check("no updates while off", ItemRackUser.Sets.Main.equip[12] == "112:0:0")
  AGR.Slash("on")
end

-- 15b. /agr shows commands
do
  messages = {}
  AGR.Slash("")
  local found = false
  for _, m in ipairs(messages) do if m:find("/agr scale <1|2>", 1, true) then found = true end end
  check("/agr lists the commands", found)
  messages = {}
  AGR.Slash("help")
  check("/agr help lists the commands", #messages >= 7)
end

-- 16. options panel builds, lists sets and drives settings
do
  local panel = AGR.optionsPanel
  check("options panel created and registered", panel ~= nil and AGR.OpenOptions ~= nil)
  AGR.Slash("options")
  check("/agr options opens the panel", Settings.opened == 7)
  local ok, err = pcall(panel.scripts.OnShow)
  check("panel refreshes without errors" .. (ok and "" or (": " .. tostring(err))), ok)
  -- find the Main row and the spec 1 dropdown
  -- spec dropdowns list the class profile plus both Pawn scales, with spec 1's scale selected
  local menu
  ok, err = pcall(function()
    AGR.CreateOptions() -- no-op on second call
    AGR.RefreshOptions()
  end)
  check("refresh ok" .. (ok and "" or (": " .. tostring(err))), ok)
  -- pick through the dropdown menu of spec 1
  AGR.SetScale(1, nil)
  check("dropdown clear goes to class profile", AutoGearRackDB.scales[1] == nil and AutoGearDB.OverridePawnScale == false)
  AGR.SetScale(1, "Paladin: Retribution")
  check("dropdown pick applies scale", AutoGearDB.PawnScale == "Paladin: Retribution")
  -- clicking a set row in automatic mode switches to picking and unticks only that set
  AGR.SetManual(false)
  AGR.SetPicked("Alt", nil)
  check("unticking a row in auto mode keeps the others", AutoGearRackDB.manual and AutoGearRackDB.sets.Main and not AutoGearRackDB.sets.Alt)
  AGR.SetManual(false)
  check("back to automatic", not AutoGearRackDB.manual and next(AutoGearRackDB.sets) == nil)
end

-- 15. status runs without errors
do
  local ok, err = pcall(AGR.Slash, "status")
  check("status prints" .. (ok and "" or (": " .. tostring(err))), ok)
end

print(("%d/%d passed"):format(count - failures, count))
os.exit(failures == 0 and 0 or 1)
