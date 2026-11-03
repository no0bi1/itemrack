--[[
  ItemRack ClassicAPI equipment-set backend.
  ClassicAPI owns equipment-set data and performs all equipment swaps.
  ItemRack keeps only presentation metadata (bindings, visibility and helm/cloak preferences).
]]

local C_EquipmentSet = C_EquipmentSet
local RESTORE_SET_NAME = "ItemRack-EventRestore"

ItemRack_SetSettings = ItemRack_SetSettings or {}

local function set_metadata()
  ItemRack_SetSettings[user] = ItemRack_SetSettings[user] or {}
  return ItemRack_SetSettings[user]
end

local function save_metadata_from_mirror()
  if not Rack_User or not Rack_User[user] or not Rack_User[user].Sets then
    return
  end

  local metadata = set_metadata()
  for name, set in pairs(Rack_User[user].Sets) do
    if type(set) == "table" and not string.find(name, "^ItemRack%-") and not string.find(name, "^Rack%-") then
      local entry = metadata[name] or {}
      entry.key = set.key
      entry.keyindex = set.keyindex
      entry.hide = set.hide
      entry.showhelm = set.showhelm
      entry.showcloak = set.showcloak
      metadata[name] = entry
    end
  end
end

local function refresh_equipment_sets()
  if not C_EquipmentSet or not C_EquipmentSet.GetEquipmentSetIDs then
    return
  end

  save_metadata_from_mirror()

  Rack_User = Rack_User or {}
  Rack_User[user] = Rack_User[user] or { Sets = {}, CurrentSet = nil }

  local metadata = set_metadata()
  local sets = {}
  local currentSet
  local ids = C_EquipmentSet.GetEquipmentSetIDs() or {}

  for i = 1, table.getn(ids) do
    local setID = ids[i]
    local name, icon, returnedID, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)

    if name then
      local options = metadata[name] or {}
      local set = {
        id = returnedID or setID,
        icon = icon,
        key = options.key,
        keyindex = options.keyindex,
        hide = options.hide,
        showhelm = options.showhelm,
        showcloak = options.showcloak
      }

      local itemIDs = C_EquipmentSet.GetItemIDs(setID) or {}
      for slot = 1, 19 do
        local itemID = itemIDs[slot]
        -- ClassicAPI values: 0 = empty, 1 = ignored, -1 = missing, >1 = itemID.
        if itemID ~= nil and itemID ~= 1 then
          local itemName
          if itemID > 1 then
            itemName = GetItemInfo(itemID) or ("Item " .. tostring(itemID))
          elseif itemID == 0 then
            itemName = "(empty)"
          else
            itemName = "(missing)"
          end
          set[slot] = { id = itemID, name = itemName }
        end
      end

      sets[name] = set
      if isEquipped and not string.find(name, "^ItemRack%-") and not string.find(name, "^Rack%-") then
        currentSet = name
      end
    end
  end

  Rack_User[user].Sets = sets
  Rack_User[user].CurrentSet = currentSet

  if ItemRack_SetsFrame and ItemRack_SetsFrame:IsVisible() and ItemRack_Sets_Build_Dropdown then
    ItemRack_Sets_Build_Dropdown()
  end
end

local function get_set_id(setname)
  if not setname or setname == "" then
    return nil
  end
  return C_EquipmentSet.GetEquipmentSetID(setname)
end

local function save_restore_set()
  if not C_EquipmentSet.CanUseEquipmentSets() then
    return false
  end

  C_EquipmentSet.ClearIgnoredSlotsForSave()
  local setID = get_set_id(RESTORE_SET_NAME)
  if setID then
    C_EquipmentSet.SaveEquipmentSet(setID)
  else
    setID = C_EquipmentSet.CreateEquipmentSet(RESTORE_SET_NAME, "INV_Misc_QuestionMark")
  end
  C_EquipmentSet.ClearIgnoredSlotsForSave()
  return setID and true or false
end

local function restore_previous_set()
  if not C_EquipmentSet.CanUseEquipmentSets() then
    return false
  end

  local setID = get_set_id(RESTORE_SET_NAME)
  if not setID then
    return false
  end

  local success = C_EquipmentSet.UseEquipmentSet(setID)
  if success and Rack_User and Rack_User[user] then
    Rack_User[user].CurrentSet = nil
  end
  return success
end

-- The old set tables are deliberately discarded. ClassicAPI is the only
-- source of equipment-set definitions; this table is a read-only UI mirror.
local originalRackInitialize = Rack.Initialize
function Rack.Initialize()
  Rack_User = Rack_User or {}
  Rack_User[user] = Rack_User[user] or { Sets = {}, CurrentSet = nil }

  originalRackInitialize()

  Rack_User[user].Sets = {}
  Rack_User[user].CurrentSet = nil
  set_metadata()

  ItemRack_RegisterFrame:RegisterEvent("EQUIPMENT_SETS_CHANGED")
  ItemRack_RegisterFrame:RegisterEvent("EQUIPMENT_SWAP_PENDING")
  ItemRack_RegisterFrame:RegisterEvent("EQUIPMENT_SWAP_FINISHED")

  refresh_equipment_sets()
end

function Rack.OnEvent()
  -- ClassicAPI owns swap sequencing, combat deferral and item-lock handling.
end

function Rack.CurrentSet()
  return Rack_User and Rack_User[user] and Rack_User[user].CurrentSet
end

function Rack.IsSetEquipped(setname)
  local setID = get_set_id(setname)
  if not setID then
    return nil
  end
  local _, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
  return isEquipped
end

function Rack.EquipSet(setname)
  if not setname or setname == "" then
    setname = ItemRack.EventSetName
  end

  local setID = get_set_id(setname)
  if not setID then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Equipment set \"" .. tostring(setname) .. "\" does not exist.")
    return false
  end

  if not C_EquipmentSet.CanUseEquipmentSets() then
    return false
  end

  if Rack.IsSetEquipped(setname) then
    return true
  end

  -- Keep ItemRack's restore convenience, but store the snapshot as a real
  -- ClassicAPI equipment set rather than in ItemRack's former swap tables.
  save_restore_set()

  local success = C_EquipmentSet.UseEquipmentSet(setID)
  if success and Rack_User and Rack_User[user] then
    Rack_User[user].CurrentSet = setname
  end
  return success
end

function Rack.UnequipSet()
  return restore_previous_set()
end

function Rack.ToggleSet(setname)
  if Rack.IsSetEquipped(setname) then
    return restore_previous_set()
  end
  return Rack.EquipSet(setname)
end

function ItemRack_EquipSet(setname)
  if not setname then
    setname = ItemRack.EventSetName
  end
  return Rack.EquipSet(setname)
end

-- Event scripts use these internal helpers. They are not macro commands;
-- macros should use ClassicAPI's native /equipset command.
function ItemRack_EquipEventSet(setname)
  return ItemRack_EquipSet(setname or ItemRack.EventSetName)
end

function ItemRack_SaveEventSet()
  return save_restore_set()
end

function ItemRack_RestoreEventSet()
  return restore_previous_set()
end

function ItemRack_ToggleEventSet(setname)
  return Rack.ToggleSet(setname or ItemRack.EventSetName)
end

function ItemRack_IsSetEquippedByName(setname)
  return Rack.IsSetEquipped(setname)
end

function ItemRack_UpgradeEventScripts()
  if not ItemRack_Events then
    return
  end

  local replacements = {
    { "EquipSet", "ItemRack_EquipEventSet" },
    { "SaveSet", "ItemRack_SaveEventSet" },
    { "LoadSet", "ItemRack_RestoreEventSet" },
    { "ToggleSet", "ItemRack_ToggleEventSet" },
    { "IsSetEquipped", "ItemRack_IsSetEquippedByName" }
  }

  for eventName, eventData in pairs(ItemRack_Events) do
    if type(eventData) == "table" and eventData.script then
      local script = eventData.script
      script = string.gsub(script, "ItemRack_EquipSet%(", "ItemRack_EquipEventSet(")
      script = string.gsub(script, "ItemRack_SaveSet%(", "ItemRack_SaveEventSet(")
      script = string.gsub(script, "ItemRack_LoadSet%(", "ItemRack_RestoreEventSet(")
      script = string.gsub(script, "ItemRack_ToggleSet%(", "ItemRack_ToggleEventSet(")
      for i = 1, table.getn(replacements) do
        local oldName = replacements[i][1]
        local newName = replacements[i][2]
        script = string.gsub(script, "^" .. oldName .. "%(", newName .. "(")
        script = string.gsub(script, "([^%w_])" .. oldName .. "%(", "%1" .. newName .. "(")
      end
      eventData.script = script
    end
  end
end

function ItemRack_Sets_Save_OnClick()
  local setname = ItemRack_Sets_Name:GetText()
  if not setname or string.gsub(setname, "%s", "") == "" then
    return
  end
  if not C_EquipmentSet.CanUseEquipmentSets() then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Wait for the current equipment swap to finish.")
    return
  end

  ItemRack_Sets_Name:ClearFocus()

  local selectedCount = 0
  C_EquipmentSet.ClearIgnoredSlotsForSave()
  for slot = 1, 19 do
    if ItemRack.SetBuild and ItemRack.SetBuild[slot] == 1 then
      selectedCount = selectedCount + 1
    else
      C_EquipmentSet.IgnoreSlotForSave(slot)
    end
  end

  if selectedCount == 0 then
    C_EquipmentSet.ClearIgnoredSlotsForSave()
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Select at least one equipment slot. Ammo is not part of equipment sets.")
    return
  end

  local oldName = ItemRack.SelectedName
  local setID = get_set_id(setname)
  local selectedID = get_set_id(oldName)

  if setID and selectedID and setID ~= selectedID then
    C_EquipmentSet.ClearIgnoredSlotsForSave()
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: A set with that name already exists.")
    return
  end

  if not setID and selectedID then
    local oldOptions = set_metadata()[oldName] or {}
    set_metadata()[setname] = oldOptions
    set_metadata()[oldName] = nil
    local oldSet = Rack_User[user].Sets[oldName]
    Rack_User[user].Sets[oldName] = nil
    Rack_User[user].Sets[setname] = oldSet
    C_EquipmentSet.ModifyEquipmentSet(selectedID, setname)
    setID = selectedID
  end

  if setID then
    C_EquipmentSet.SaveEquipmentSet(setID, ItemRack.SelectedIcon)
  else
    setID = C_EquipmentSet.CreateEquipmentSet(setname, ItemRack.SelectedIcon)
  end
  C_EquipmentSet.ClearIgnoredSlotsForSave()

  if not setID then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: ClassicAPI could not create that equipment set.")
    return
  end

  ItemRack.SelectedName = setname
  ItemRack.SelectedSetID = setID
  refresh_equipment_sets()
  ItemRack_Sets_Name_OnTextChanged()
  DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Saved equipment set \"" .. setname .. "\".")
end

local originalRemoveSet = ItemRack_Sets_Remove_OnClick
function ItemRack_Sets_Remove_OnClick()
  local setname = ItemRack.SelectedName
  local setID = get_set_id(setname)
  if not C_EquipmentSet.CanUseEquipmentSets() then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Wait for the current equipment swap to finish.")
    return
  end
  if not setID then
    return
  end

  -- Let ItemRack clear its key binding and event associations first.
  originalRemoveSet()
  set_metadata()[setname] = nil
  C_EquipmentSet.DeleteEquipmentSet(setID)
  refresh_equipment_sets()
end

local originalUpdateInventory = ItemRack_Sets_UpdateInventory
function ItemRack_Sets_UpdateInventory()
  originalUpdateInventory()
  -- ClassicAPI equipment sets cover the 19 paperdoll slots, not the ammo slot.
  if ItemRack_Sets_Inv0 then
    ItemRack_Sets_Inv0:Hide()
  end
end

local originalItemRackOnEvent = ItemRack_RegisterFrame_OnEvent
function ItemRack_RegisterFrame_OnEvent(event)
  if event == "EQUIPMENT_SETS_CHANGED" then
    refresh_equipment_sets()
    return
  elseif event == "EQUIPMENT_SWAP_PENDING" then
    ItemRack.PendingSetID = arg1
    return
  elseif event == "EQUIPMENT_SWAP_FINISHED" then
    local success, setID = arg1, arg2
    ItemRack.PendingSetID = nil
    if success and setID then
      local name = C_EquipmentSet.GetEquipmentSetInfo(setID)
      if name and name ~= RESTORE_SET_NAME and Rack_User and Rack_User[user] then
        Rack_User[user].CurrentSet = name
      elseif name == RESTORE_SET_NAME and Rack_User and Rack_User[user] then
        Rack_User[user].CurrentSet = nil
      end
    end
    refresh_equipment_sets()
    return
  end

  originalItemRackOnEvent(event)
end
