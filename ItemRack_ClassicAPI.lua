--[[
  ItemRack ClassicAPI equipment-set backend.
  ClassicAPI owns saved equipment sets and performs equipment-set swaps.
  ItemRack keeps presentation metadata and its separate per-slot inventory queue.
]]

local C_EquipmentSet = C_EquipmentSet
ItemRack_SetSettings = ItemRack_SetSettings or {}

local function set_metadata()
  ItemRack_SetSettings[user] = ItemRack_SetSettings[user] or {}
  return ItemRack_SetSettings[user]
end

local function get_set_id(setname)
  if not setname or setname == "" then
    return nil
  end
  return C_EquipmentSet.GetEquipmentSetID(setname)
end

local function save_metadata_from_mirror()
  if not Rack_User or not Rack_User[user] or not Rack_User[user].Sets then
    return
  end

  local metadata = set_metadata()
  for name, set in pairs(Rack_User[user].Sets) do
    if type(set) == "table" and name ~= "restoreSetName" and name ~= "restoreSetID" and not string.find(name, "^ItemRack%-") and not string.find(name, "^Rack%-") then
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
  local combatQueueSet = Rack_User[user].Sets and Rack_User[user].Sets[Rack.CombatQueueSetName]
  local sets = {}
  local currentSet
  local ids = C_EquipmentSet.GetEquipmentSetIDs() or {}

  for i = 1, table.getn(ids) do
    local setID = ids[i]
    local name, icon, returnedID, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)

    if name and name ~= Rack.CombatQueueSetName then
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

  -- This synthetic set is still used by ItemRack's per-slot combat queue.
  -- It is not a ClassicAPI set and must survive refreshes of the API-backed list.
  if Rack.CombatQueueSetName then
    combatQueueSet = combatQueueSet or {}
    for slot = 0, 19 do
      combatQueueSet[slot] = combatQueueSet[slot] or {}
    end
    sets[Rack.CombatQueueSetName] = combatQueueSet
  end

  Rack_User[user].Sets = sets
  Rack_User[user].CurrentSet = currentSet

  if ItemRack_SetsFrame and ItemRack_SetsFrame:IsVisible() and ItemRack_Sets_Build_Dropdown then
    ItemRack_Sets_Build_Dropdown()
  end
end

local function restore_map(create)
  local metadata = set_metadata()
  if not metadata.restoreSets and create then
    metadata.restoreSets = {}
  end
  return metadata.restoreSets or {}
end

local function get_restore_entry(targetSetID, create)
  if not targetSetID then
    return nil
  end
  local restores = restore_map(create)
  local entry = restores[targetSetID]
  if not entry and create then
    entry = {}
    restores[targetSetID] = entry
  end
  return entry
end

local function get_restore_set_name(targetSetID, entry)
  local baseName = "ItemRack-R-" .. tostring(targetSetID)
  local name = entry.name or baseName
  local existingID = get_set_id(name)

  -- Never overwrite a ClassicAPI set that is not the restore set we own.
  if existingID and entry.id ~= existingID then
    local suffix = 1
    repeat
      name = baseName .. "-" .. suffix
      existingID = get_set_id(name)
      suffix = suffix + 1
    until not existingID
    entry.name = name
    entry.id = nil
  elseif not entry.name then
    entry.name = name
  end

  return name
end

local function get_restore_set_id(targetSetID)
  local entry = get_restore_entry(targetSetID)
  if not entry then
    return nil
  end
  local name = get_restore_set_name(targetSetID, entry)
  local setID = get_set_id(name)
  if setID and entry.id == setID then
    return setID
  end
  return nil
end

local function find_restore_target(setID, name)
  if not setID then
    return nil
  end
  local restores = restore_map()
  for targetSetID, entry in pairs(restores) do
    if entry.id == setID and entry.name == name then
      return targetSetID, entry
    end
  end
  return nil
end

local function is_restore_set(setID, name)
  return find_restore_target(setID, name)
end

local function equipment_swap_allowed(setID)
  if Rack.IsPlayerReallyDead() or Rack.SetSwapping or not C_EquipmentSet.CanUseEquipmentSets() then
    return false
  end

  local casting = C_Spell and C_Spell.UnitCastingInfo and C_Spell.UnitCastingInfo("player")
  if C_EquipmentSet.EquipmentSetContainsLockedItems(setID) or casting then
    if UIErrorsFrame then
      UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT or "You can't do that right now.", 1.0, 0.1, 0.1, 1.0)
    end
    return false
  end
  return true
end

local function apply_set_display_options(setID)
  local setName = C_EquipmentSet.GetEquipmentSetInfo(setID)
  local set = setName and Rack_User and Rack_User[user] and Rack_User[user].Sets and Rack_User[user].Sets[setName]
  if set then
    if set.showhelm then
      ShowHelm(set.showhelm)
    end
    if set.showcloak then
      ShowCloak(set.showcloak)
    end
  end
end

local function save_restore_set(targetSetID)
  if not targetSetID or Rack.SetSwapping or not C_EquipmentSet.CanUseEquipmentSets() then
    return false
  end

  C_EquipmentSet.ClearIgnoredSlotsForSave()
  -- Restore only the slots this target set manages. A weapon-only or
  -- trinket-only event must not overwrite unrelated gear when it ends.
  local ignoredSlots = C_EquipmentSet.GetIgnoredSlots(targetSetID) or {}
  for i = 1, table.getn(ignoredSlots) do
    C_EquipmentSet.IgnoreSlotForSave(ignoredSlots[i])
  end

  local entry = get_restore_entry(targetSetID, true)
  local name = get_restore_set_name(targetSetID, entry)
  local restoreID = get_restore_set_id(targetSetID)
  entry.previousSetName = Rack_User and Rack_User[user] and Rack_User[user].CurrentSet or nil

  if restoreID then
    C_EquipmentSet.SaveEquipmentSet(restoreID)
  else
    restoreID = C_EquipmentSet.CreateEquipmentSet(name, "INV_Misc_QuestionMark")
    if restoreID then
      entry.id = restoreID
    end
  end
  C_EquipmentSet.ClearIgnoredSlotsForSave()
  return restoreID and true or false
end

local function retry_combat_pending_set()
  local setID = ItemRack.CombatPendingSetID
  if not setID or Rack.IsPlayerReallyDead() or UnitAffectingCombat("player") or Rack.SetSwapping then
    return
  end

  local name = C_EquipmentSet.GetEquipmentSetInfo(setID)
  if not name then
    ItemRack.CombatPendingSetID = nil
    ItemRack.CombatPendingSetNeedsRestore = nil
    return
  end
  if not equipment_swap_allowed(setID) then
    return
  end

  local needsRestore = ItemRack.CombatPendingSetNeedsRestore
  ItemRack.CombatPendingSetID = nil
  ItemRack.CombatPendingSetNeedsRestore = nil
  if needsRestore then
    save_restore_set(setID)
  end
  if not find_restore_target(setID, name) then
    apply_set_display_options(setID)
  end
  if not C_EquipmentSet.UseEquipmentSet(setID) then
    ItemRack.CombatPendingSetID = setID
    ItemRack.CombatPendingSetNeedsRestore = needsRestore
  end
end

local function use_restore_set(targetSetID)
  local restoreID = get_restore_set_id(targetSetID)
  local entry = get_restore_entry(targetSetID)
  if not restoreID or not entry then
    -- A set requested while dead has not been applied yet. Toggling it
    -- cancels that deferred request because there is no previous snapshot.
    if ItemRack.CombatPendingSetID == targetSetID and ItemRack.CombatPendingSetNeedsRestore then
      ItemRack.CombatPendingSetID = nil
      ItemRack.CombatPendingSetNeedsRestore = nil
      return true
    end
    return false
  end

  local restoreName = C_EquipmentSet.GetEquipmentSetInfo(restoreID)
  if not restoreName then
    return false
  end

  if ItemRack.CombatPendingSetID and ItemRack.CombatPendingSetID ~= restoreID then
    ItemRack.CombatPendingSetID = nil
    ItemRack.CombatPendingSetNeedsRestore = nil
  end

  if ItemRack.PendingSetID == restoreID and not Rack.SetSwapping then
    return true
  end
  if Rack.SetSwapping == restoreName then
    Rack.OnItemLockChanged()
    return true
  end
  if Rack.SetSwapping or ItemRack.PendingSetID then
    local queueIndex = Rack.GetFreeQueueEntry()
    if not queueIndex then
      DEFAULT_CHAT_FRAME:AddMessage("ItemRack: The item swap queue is full.")
      return false
    end
    Rack.AddQueueEntry(queueIndex)
    Rack.SwapQueue[queueIndex].direction = "NEWSET"
    Rack.SwapQueue[queueIndex].setname = restoreName
    return true
  end

  if Rack.IsPlayerReallyDead() then
    ItemRack.CombatPendingSetID = restoreID
    ItemRack.CombatPendingSetNeedsRestore = nil
    return true
  end
  if not equipment_swap_allowed(restoreID) then
    return false
  end

  ItemRack.CombatPendingSetID = nil
  ItemRack.CombatPendingSetNeedsRestore = nil
  return C_EquipmentSet.UseEquipmentSet(restoreID)
end

local function delete_restore_set(targetSetID)
  local entry = get_restore_entry(targetSetID)
  if not entry then
    return
  end
  local restoreID = get_restore_set_id(targetSetID)
  if restoreID then
    C_EquipmentSet.DeleteEquipmentSet(restoreID)
    if ItemRack.CombatPendingSetID == restoreID then
      ItemRack.CombatPendingSetID = nil
      ItemRack.CombatPendingSetNeedsRestore = nil
    end
  end
  restore_map()[targetSetID] = nil
end

function ItemRack_DeleteRestoreSet()
  local restores = restore_map()
  local targets = {}
  for targetSetID in pairs(restores) do
    table.insert(targets, targetSetID)
  end
  for i = 1, table.getn(targets) do
    delete_restore_set(targets[i])
  end

  -- Clean up the single-snapshot metadata used by early development builds.
  local metadata = set_metadata()
  if metadata.restoreSetID and get_set_id(metadata.restoreSetName) == metadata.restoreSetID then
    C_EquipmentSet.DeleteEquipmentSet(metadata.restoreSetID)
  end
  metadata.restoreSetID = nil
  metadata.restoreSetName = nil
end

-- The old set tables are deliberately discarded. ClassicAPI is the only
-- source of equipment-set definitions; this table is a read-only UI mirror.
local originalRackInitialize = Rack.Initialize
local originalRackEquipSet = Rack.EquipSet
local originalRackOnEvent = Rack.OnEvent
local originalRackOnItemLockChanged = Rack.OnItemLockChanged
local originalRackIterateSwapQueue = Rack.IterateSwapQueue
function Rack.Initialize()
  Rack_User = Rack_User or {}
  Rack_User[user] = Rack_User[user] or { Sets = {}, CurrentSet = nil }
  Rack_User[user].Sets = Rack_User[user].Sets or {}

  -- Avoid colliding with a real ClassicAPI set if someone used the old
  -- internal queue name in the Blizzard equipment manager.
  local queueName = "Rack-CombatQueue"
  local suffix = 1
  while C_EquipmentSet.GetEquipmentSetID(queueName) do
    queueName = "Rack-CombatQueue-" .. suffix
    suffix = suffix + 1
  end
  Rack.CombatQueueSetName = queueName

  originalRackInitialize()

  local combatQueueSet = Rack_User[user].Sets[Rack.CombatQueueSetName]
  Rack_User[user].Sets = {}
  combatQueueSet = combatQueueSet or {}
  for slot = 0, 19 do
    combatQueueSet[slot] = combatQueueSet[slot] or {}
  end
  Rack_User[user].Sets[Rack.CombatQueueSetName] = combatQueueSet
  Rack_User[user].CurrentSet = nil
  set_metadata()

  -- Restore snapshots are session-only; discard leftovers from a prior login.
  ItemRack_DeleteRestoreSet()

  ItemRack_RegisterFrame:RegisterEvent("EQUIPMENT_SETS_CHANGED")
  ItemRack_RegisterFrame:RegisterEvent("EQUIPMENT_SWAP_PENDING")
  ItemRack_RegisterFrame:RegisterEvent("EQUIPMENT_SWAP_FINISHED")
  ItemRack_RegisterFrame:RegisterEvent("PLAYER_LOGOUT")
  ItemRack_RegisterFrame:RegisterEvent("SPELLCAST_STOP")

  refresh_equipment_sets()
end

function Rack.OnEvent()
  originalRackOnEvent()
  if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_UNGHOST" or event == "PLAYER_ALIVE" then
    Rack.IterateSwapQueue()
  end
end

function Rack.OnItemLockChanged()
  originalRackOnItemLockChanged()
  retry_combat_pending_set()
end

function Rack.IterateSwapQueue()
  if ItemRack.PendingSetID then
    return
  end
  originalRackIterateSwapQueue()
  retry_combat_pending_set()
end

function Rack.CurrentSet()
  return Rack_User and Rack_User[user] and Rack_User[user].CurrentSet
end

function Rack.IsSetEquipped(setname)
  if setname == Rack.CombatQueueSetName then
    return nil
  end
  local setID = get_set_id(setname)
  if not setID then
    return nil
  end
  local _, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
  return isEquipped
end

function Rack.EquipSet(setname)
  -- Preserve ItemRack's separate per-slot combat queue. It is not an
  -- equipment set and still needs the original bag/inventory swap engine.
  if Rack.CombatQueueSetName and setname == Rack.CombatQueueSetName then
    -- The synthetic per-slot queue still uses ItemRack's original engine,
    -- but it must wait if a ClassicAPI set swap is already in flight.
    if ItemRack.PendingSetID then
      local queueIndex = Rack.GetFreeQueueEntry()
      if not queueIndex then
        DEFAULT_CHAT_FRAME:AddMessage("ItemRack: The item swap queue is full.")
        return false
      end
      Rack.AddQueueEntry(queueIndex)
      Rack.SwapQueue[queueIndex].direction = "NEWSET"
      Rack.SwapQueue[queueIndex].setname = setname
      return true
    end
    return originalRackEquipSet(setname)
  end

  if not setname or setname == "" then
    setname = ItemRack.EventSetName
  end

  local setID = get_set_id(setname)
  if not setID then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Equipment set \"" .. tostring(setname) .. "\" does not exist.")
    return false
  end

  local restoreTargetSetID = find_restore_target(setID, setname)
  if restoreTargetSetID then
    return use_restore_set(restoreTargetSetID)
  end

  -- A newer request supersedes a set that was only partially applied in
  -- combat. Clear that deferred request even if this request must wait in
  -- the ItemRack queue behind an already-running swap.
  if ItemRack.CombatPendingSetID and ItemRack.CombatPendingSetID ~= setID then
    ItemRack.CombatPendingSetID = nil
    ItemRack.CombatPendingSetNeedsRestore = nil
  end

  -- Serialize ClassicAPI set swaps behind ItemRack's still-active
  -- per-slot inventory queue so the two swap engines never touch the
  -- paperdoll at the same time.
  if ItemRack.PendingSetID == setID and not Rack.SetSwapping then
    return true
  end
  if Rack.SetSwapping or ItemRack.PendingSetID then
    if Rack.SetSwapping == setname then
      Rack.OnItemLockChanged()
      return true
    end
    local queueIndex = Rack.GetFreeQueueEntry()
    if not queueIndex then
      DEFAULT_CHAT_FRAME:AddMessage("ItemRack: The item swap queue is full.")
      return false
    end
    Rack.AddQueueEntry(queueIndex)
    Rack.SwapQueue[queueIndex].direction = "NEWSET"
    Rack.SwapQueue[queueIndex].setname = setname
    return true
  end

  local samePendingSet = ItemRack.CombatPendingSetID == setID
  if ItemRack.CombatPendingSetID and not samePendingSet then
    ItemRack.CombatPendingSetID = nil
    ItemRack.CombatPendingSetNeedsRestore = nil
  end

  if Rack.IsSetEquipped(setname) then
    if Rack_User and Rack_User[user] then
      Rack_User[user].CurrentSet = setname
    end
    return true
  end

  -- The old ItemRack engine queued individual items while dead, but its
  -- saved-set tables are no longer authoritative. Defer the whole ClassicAPI
  -- set instead and execute it after PLAYER_ALIVE / PLAYER_UNGHOST.
  if Rack.IsPlayerReallyDead() then
    ItemRack.CombatPendingSetID = setID
    if not samePendingSet then
      ItemRack.CombatPendingSetNeedsRestore = true
    end
    return true
  end

  if not equipment_swap_allowed(setID) then
    return false
  end

  -- Keep ItemRack's restore convenience, but store the snapshot as a real
  -- ClassicAPI equipment set rather than in ItemRack's former swap tables.
  if not samePendingSet then
    save_restore_set(setID)
  end
  apply_set_display_options(setID)

  local success = C_EquipmentSet.UseEquipmentSet(setID)
  if success and Rack_User and Rack_User[user] then
    Rack_User[user].CurrentSet = setname
  end
  return success
end

function Rack.UnequipSet(setname)
  return use_restore_set(get_set_id(setname or ItemRack.EventSetName))
end

function Rack.ToggleSet(setname)
  local setID = get_set_id(setname)
  if setID and ItemRack.CombatPendingSetID == setID then
    return use_restore_set(setID)
  end
  if Rack.IsSetEquipped(setname) then
    return use_restore_set(setID)
  end
  return Rack.EquipSet(setname)
end

-- Event scripts use these internal helpers. They are not macro commands;
-- macros should use ClassicAPI's native /equipset command.
function ItemRack_EquipEventSet(setname)
  return Rack.EquipSet(setname or ItemRack.EventSetName)
end

function ItemRack_SaveEventSet(setname)
  return save_restore_set(get_set_id(setname or ItemRack.EventSetName))
end

function ItemRack_RestoreEventSet(setname)
  return use_restore_set(get_set_id(setname or ItemRack.EventSetName))
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
        script = string.gsub(script, "([^%w_%.:])" .. oldName .. "%(", "%1" .. newName .. "(")
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
  if setname == "restoreSetName" or setname == "restoreSetID" or string.find(setname, "^ItemRack%-") or string.find(setname, "^Rack%-") then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: That name is reserved for internal equipment sets.")
    return
  end
  if Rack.SetSwapping or not C_EquipmentSet.CanUseEquipmentSets() then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Wait for the current equipment swap to finish.")
    return
  end

  ItemRack_Sets_Name:ClearFocus()

  local selectedCount = 0
  local mainHandTexture, mainHandID, mainHandName, mainHandType = Rack.GetItemInfo(16)
  local ignoreOffhand = mainHandType == "INVTYPE_2HWEAPON"

  C_EquipmentSet.ClearIgnoredSlotsForSave()
  for slot = 1, 19 do
    if slot == 17 and ignoreOffhand then
      C_EquipmentSet.IgnoreSlotForSave(slot)
    elseif ItemRack.SetBuild and ItemRack.SetBuild[slot] == 1 then
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

  local oldName = ItemRack.SelectedOriginalName or ItemRack.SelectedName
  local setID = get_set_id(setname)
  local selectedID = ItemRack.SelectedSetID or get_set_id(oldName)

  if setID and selectedID and setID ~= selectedID then
    C_EquipmentSet.ClearIgnoredSlotsForSave()
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: A set with that name already exists.")
    return
  end

  if not setID and selectedID then
    local metadata = set_metadata()
    local oldOptions = metadata[oldName] or {}
    local oldSet = Rack_User[user].Sets[oldName]
    metadata[setname] = oldOptions
    metadata[oldName] = nil
    Rack_User[user].Sets[oldName] = nil
    Rack_User[user].Sets[setname] = oldSet

    local renamed, renameError = pcall(C_EquipmentSet.ModifyEquipmentSet, selectedID, setname)
    if not renamed or not get_set_id(setname) then
      metadata[setname] = nil
      metadata[oldName] = oldOptions
      Rack_User[user].Sets[setname] = nil
      Rack_User[user].Sets[oldName] = oldSet
      C_EquipmentSet.ClearIgnoredSlotsForSave()
      DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Could not rename that equipment set: " .. tostring(renameError or "invalid name"))
      return
    end
    if ItemRack_Users and ItemRack_Users[user] and ItemRack_Users[user].Events then
      for eventName, eventData in pairs(ItemRack_Users[user].Events) do
        if type(eventData) == "table" and eventData.setname == oldName then
          eventData.setname = setname
        end
      end
      if ItemRack_Build_eventList then
        ItemRack_Build_eventList()
      end
    end
    if oldOptions.keyindex then
      setglobal("BINDING_NAME_EQUIPSET" .. oldOptions.keyindex, string.format(ItemRackText.BINDINGFORMAT, setname))
    end
    setID = selectedID
  end

  local callOK, result
  if setID then
    callOK = pcall(C_EquipmentSet.SaveEquipmentSet, setID, ItemRack.SelectedIcon)
  else
    callOK, result = pcall(C_EquipmentSet.CreateEquipmentSet, setname, ItemRack.SelectedIcon)
    if callOK then
      setID = result
    end
  end
  C_EquipmentSet.ClearIgnoredSlotsForSave()

  local verifiedID = get_set_id(setname)
  if not callOK or not verifiedID then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Could not save that equipment set: " .. tostring(result or "ClassicAPI rejected the set"))
    return
  end
  setID = verifiedID

  local options = set_metadata()[setname] or {}
  options.hide = ItemRack_Sets_HideSet:GetChecked()
  options.showhelm = ItemRack_ShowHelm.tristate
  options.showcloak = ItemRack_ShowCloak.tristate
  set_metadata()[setname] = options
  if Rack_User[user].Sets[setname] then
    Rack_User[user].Sets[setname].hide = options.hide
    Rack_User[user].Sets[setname].showhelm = options.showhelm
    Rack_User[user].Sets[setname].showcloak = options.showcloak
  end

  ItemRack.SelectedName = setname
  ItemRack.SelectedOriginalName = setname
  ItemRack.SelectedSetID = setID
  refresh_equipment_sets()
  ItemRack_Sets_Name_OnTextChanged()
  DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Saved equipment set \"" .. setname .. "\".")
end

local originalRemoveSet = ItemRack_Sets_Remove_OnClick
function ItemRack_Sets_Remove_OnClick()
  local setname = ItemRack.SelectedName
  local setID = get_set_id(setname)
  if Rack.SetSwapping or not C_EquipmentSet.CanUseEquipmentSets() then
    DEFAULT_CHAT_FRAME:AddMessage("ItemRack: Wait for the current equipment swap to finish.")
    return
  end
  if not setID then
    return
  end

  -- Remove the matching temporary restore snapshot as well.
  delete_restore_set(setID)

  -- Let ItemRack clear its key binding and event associations first.
  originalRemoveSet()
  ItemRack.SelectedSetID = nil
  ItemRack.SelectedOriginalName = nil
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
  if event == "PLAYER_LOGOUT" then
    save_metadata_from_mirror()
    if C_EquipmentSet.CanUseEquipmentSets() then
      ItemRack_DeleteRestoreSet()
    end
    originalItemRackOnEvent(event)
    return
  elseif event == "EQUIPMENT_SETS_CHANGED" then
    refresh_equipment_sets()
    originalItemRackOnEvent(event)
    return
  elseif event == "EQUIPMENT_SWAP_PENDING" then
    ItemRack.PendingSetID = arg1
    ItemRack.PendingSetStartedInCombat = UnitAffectingCombat("player") and true or nil
    local pendingName = C_EquipmentSet.GetEquipmentSetInfo(arg1)
    if pendingName and not find_restore_target(arg1, pendingName) then
      apply_set_display_options(arg1)
    end
    if ItemRack.CombatPendingSetID and ItemRack.CombatPendingSetID ~= arg1 then
      ItemRack.CombatPendingSetID = nil
      ItemRack.CombatPendingSetNeedsRestore = nil
    end
    originalItemRackOnEvent(event)
    return
  elseif event == "SPELLCAST_STOP" then
    originalItemRackOnEvent(event)
    retry_combat_pending_set()
    return
  elseif event == "EQUIPMENT_SWAP_FINISHED" then
    local success, setID = arg1, arg2
    local startedInCombat = ItemRack.PendingSetStartedInCombat
    local name, icon, returnedID, isEquipped
    local restoreTargetSetID, restoreEntry
    local wasRestoreSet = false
    ItemRack.PendingSetID = nil
    ItemRack.PendingSetStartedInCombat = nil
    if setID then
      name, icon, returnedID, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
      restoreTargetSetID, restoreEntry = is_restore_set(setID, name)
      wasRestoreSet = restoreTargetSetID ~= nil
      if ItemRack.CombatPendingSetID == setID and (not UnitAffectingCombat("player") or isEquipped) then
        ItemRack.CombatPendingSetID = nil
        ItemRack.CombatPendingSetNeedsRestore = nil
      end
      if wasRestoreSet and isEquipped then
        delete_restore_set(restoreTargetSetID)
      elseif startedInCombat and success and not isEquipped then
        -- ClassicAPI snapshots combat state when UseEquipmentSet begins.
        -- Retry after combat even if the finish event arrives after combat ends.
        ItemRack.CombatPendingSetID = setID
        ItemRack.CombatPendingSetNeedsRestore = nil
      end
    end
    refresh_equipment_sets()
    if success and name and Rack_User and Rack_User[user] then
      if wasRestoreSet then
        local previousSetName = restoreEntry and restoreEntry.previousSetName
        Rack_User[user].CurrentSet = previousSetName and get_set_id(previousSetName) and previousSetName or nil
      else
        Rack_User[user].CurrentSet = name
      end
    end
    originalItemRackOnEvent(event)
    Rack.IterateSwapQueue()
    return
  end

  originalItemRackOnEvent(event)
end
