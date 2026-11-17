-- AutoGearRack options panel, under Options > AddOns (Settings canvas category, with a
-- fallback to the old Interface Options for clients without the Settings API).

local AGR = AutoGearRack
local panel, controls, rows = nil, {}, {}
local category

local useModernDropdowns = MenuUtil ~= nil and WowStyle1DropdownMixin ~= nil

local function label(parent, text, template)
  local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
  fs:SetText(text or "")
  fs:SetJustifyH("LEFT")
  return fs
end

local function checkbox(parent, text, onClick)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(26, 26)
  cb.label = label(parent, text)
  cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
  cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
  return cb
end

---------------------------------------------------------------------------------------------
-- Pawn scale dropdowns
---------------------------------------------------------------------------------------------

local CLASS_PROFILE = "AutoGear class profile (no Pawn scale)"

local function scaleLabel(key)
  if not key then return CLASS_PROFILE end
  for _, c in ipairs(AGR.ScaleChoices()) do if c.key == key then return c.label end end
  return key .. " (missing in Pawn)"
end

local function chooseScale(slot, key)
  AGR.SetScale(slot, key)
  AGR.Changed()
end

local function scaleDropdown(parent, slot)
  local dd
  if useModernDropdowns then
    dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dd:SetWidth(300)
    dd:SetupMenu(function(_, root)
      local current = AGR.db.scales[slot]
      root:CreateRadio(CLASS_PROFILE, function() return AGR.db.scales[slot] == nil end, function() chooseScale(slot, nil) end)
      for _, c in ipairs(AGR.ScaleChoices()) do
        root:CreateRadio(c.label, function() return AGR.db.scales[slot] == c.key end, function() chooseScale(slot, c.key) end)
      end
      if current and not AGR.ResolveScale(current) then
        root:CreateRadio(scaleLabel(current), function() return true end, function() end)
      end
    end)
    dd.Refresh = function(self) self:GenerateMenu() end
  else
    dd = CreateFrame("Frame", "AutoGearRackScaleDropdown" .. slot, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dd, 280)
    UIDropDownMenu_Initialize(dd, function()
      local function add(text, key)
        local info = UIDropDownMenu_CreateInfo()
        info.text = text
        info.checked = AGR.db.scales[slot] == key
        info.func = function() chooseScale(slot, key) end
        UIDropDownMenu_AddButton(info)
      end
      add(CLASS_PROFILE, nil)
      for _, c in ipairs(AGR.ScaleChoices()) do add(c.label, c.key) end
    end)
    dd.Refresh = function(self) UIDropDownMenu_SetText(self, scaleLabel(AGR.db.scales[slot])) end
  end
  return dd
end

---------------------------------------------------------------------------------------------
-- Set list
---------------------------------------------------------------------------------------------

local ROW_HEIGHT = 24

local function getRow(i)
  if rows[i] then return rows[i] end
  local content = controls.setContent
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(540, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
  row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.check:SetSize(24, 24)
  row.check:SetPoint("LEFT")
  row.name = label(row, "")
  row.name:SetPoint("LEFT", row.check, "RIGHT", 2, 1)
  row.name:SetWidth(210)
  row.info = label(row, "", "GameFontHighlightSmall")
  row.info:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
  row.info:SetWidth(290)
  row.check:SetScript("OnClick", function(self)
    AGR.SetPicked(row.setName, self:GetChecked() and true or nil)
    AGR.Changed()
  end)
  rows[i] = row
  return row
end

local function refreshSets()
  local targets, skipped = AGR.TargetSets()
  local isTarget, why = {}, {}
  for _, t in ipairs(targets) do isTarget[t[1]] = true end
  for _, s in ipairs(skipped) do why[s[1]] = s[2] end
  local manual = AGR.ExplicitList() ~= nil
  local sets = AGR.SetInfo()
  for i, s in ipairs(sets) do
    local row = getRow(i)
    row.setName = s.name
    row.name:SetText(s.name)
    row.check:SetChecked(manual and AGR.db.sets[s.name] or (not manual and isTarget[s.name]) or false)
    local details = s.slots .. " slots" .. (s.spec and (", spec " .. s.spec) or "") .. (s.main and "" or ", situational")
    local state = isTarget[s.name] and "|cff55ff55follows AutoGear|r" or ("|cff999999" .. (why[s.name] or "") .. "|r")
    row.info:SetText("|cffbbbbbb" .. details .. "|r  " .. state)
    row:Show()
  end
  for i = #sets + 1, #rows do rows[i]:Hide() end
  controls.setContent:SetHeight(math.max(1, #sets * ROW_HEIGHT))
  if #sets == 0 then
    controls.noSets:SetText(AGR.HasItemRack() and "ItemRack has no sets yet. Save one in ItemRack first." or "ItemRack isn't loaded.")
    controls.noSets:Show()
  else
    controls.noSets:Hide()
  end
  controls.manual:SetChecked(manual)
end

---------------------------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------------------------

local function yesNo(ok, yes, no) return ok and ("|cff55ff55" .. yes .. "|r") or ("|cffff5555" .. no .. "|r") end

local function refreshStatus()
  local lines = {}
  lines[1] = "AutoGear " .. yesNo(AGR.HasAutoGear(), "found", "missing")
    .. "   ItemRack " .. yesNo(AGR.HasItemRack(), "found", "missing")
    .. "   Pawn " .. yesNo(AGR.PawnReady(), "ready", "not ready")
  local spec = AGR.GetSpecSlot()
  local agState = ""
  if AGR.HasAutoGear() then
    agState = "   AutoGear is " .. (AutoGearDB.Enabled and "|cff55ff55on|r"
      or (AGR.db.pausedByUs and "|cffffcc00paused|r" or "|cffff5555off|r"))
      .. ", Use Pawn " .. (AutoGearDB.UsePawn and "on" or "|cffff5555off|r")
  end
  lines[2] = "Active spec: " .. spec .. agState
  local reason = AGR.PauseReason()
  if reason and AGR.db.pausedByUs then lines[3] = "Paused because " .. reason .. "." end
  controls.status:SetText(table.concat(lines, "\n"))
end

function AGR.RefreshOptions()
  if not panel or not panel:IsVisible() then return end
  controls.enabled:SetChecked(AGR.db.enabled)
  controls.debug:SetChecked(AGR.db.debug and true or false)
  controls.scale1:Refresh()
  controls.scale2:Refresh()
  controls.activeMark1:SetShown(AGR.GetSpecSlot() == 1)
  controls.activeMark2:SetShown(AGR.GetSpecSlot() == 2)
  refreshStatus()
  refreshSets()
end

---------------------------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------------------------

function AGR.CreateOptions()
  if panel then return end
  panel = CreateFrame("Frame")
  panel.name = "AutoGearRack"
  AGR.optionsPanel = panel

  local title = label(panel, "AutoGearRack " .. (AGR.version or ""), "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  local sub = label(panel, "Lets AutoGear score gear with your Pawn scale for each spec, and writes its upgrades into your ItemRack sets.", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetWidth(600)

  controls.status = label(panel, "", "GameFontHighlightSmall")
  controls.status:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -10)
  controls.status:SetWidth(600)
  controls.status:SetSpacing(3)

  controls.enabled = checkbox(panel, "Enabled", function(on) AGR.SetEnabled(on); AGR.Changed() end)
  controls.enabled:SetPoint("TOPLEFT", controls.status, "BOTTOMLEFT", -4, -28)
  controls.debug = checkbox(panel, "Verbose chat messages", function(on) AGR.db.debug = on end)
  controls.debug:SetPoint("LEFT", controls.enabled, "RIGHT", 160, 0)

  local h1 = label(panel, "Pawn scale per spec", "GameFontNormal")
  h1:SetPoint("TOPLEFT", controls.enabled, "BOTTOMLEFT", 4, -14)
  for slot = 1, 2 do
    local l = label(panel, "Spec " .. slot)
    l:SetPoint("TOPLEFT", h1, "BOTTOMLEFT", 0, -16 - (slot - 1) * 34)
    local dd = scaleDropdown(panel, slot)
    dd:SetPoint("LEFT", l, "LEFT", useModernDropdowns and 60 or 44, useModernDropdowns and 0 or -2)
    controls["scale" .. slot] = dd
    local mark = label(panel, "|cff55ff55active|r", "GameFontHighlightSmall")
    mark:SetPoint("LEFT", dd, "RIGHT", useModernDropdowns and 8 or -8, useModernDropdowns and 0 or 2)
    controls["activeMark" .. slot] = mark
  end

  local h2 = label(panel, "ItemRack sets that follow AutoGear", "GameFontNormal")
  h2:SetPoint("TOPLEFT", h1, "BOTTOMLEFT", 0, -90)
  local help = label(panel, "Automatic: every set that saves 10 or more slots and is tied to your active spec, or to no spec. A set only changes in a slot that held the item AutoGear replaced.", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", h2, "BOTTOMLEFT", 0, -6)
  help:SetWidth(600)
  controls.manual = checkbox(panel, "Pick the sets myself", function(on) AGR.SetManual(on); AGR.Changed() end)
  controls.manual:SetPoint("TOPLEFT", help, "BOTTOMLEFT", -4, -6)

  local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", controls.manual, "BOTTOMLEFT", 4, -6)
  scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 16)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(540, 1)
  scroll:SetScrollChild(content)
  controls.setContent = content
  controls.noSets = label(content, "", "GameFontDisableSmall")
  controls.noSets:SetPoint("TOPLEFT", 4, -4)

  panel:SetScript("OnShow", function() AGR.RefreshOptions() end)

  if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name, panel.name)
    Settings.RegisterAddOnCategory(category)
    AGR.OpenOptions = function()
      local id = category.GetID and category:GetID() or category.ID
      Settings.OpenToCategory(id)
    end
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
    AGR.OpenOptions = function()
      InterfaceOptionsFrame_OpenToCategory(panel)
      InterfaceOptionsFrame_OpenToCategory(panel) -- the old frame needs it twice
    end
  end
end
