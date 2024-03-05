local globals = require 'imports.globals'
local Vehicles = require '@ox_inventory.data.vehicles'
local dui = require 'imports.dui'
local DuiObject, updateMenu in dui
local ox = GetResourceState('ox_inventory'):find('start')
local Groups

local utils = {}
---@param action string
---@param data any
utils.sendReactMessage = function(action, data)
    while not DuiObject do Wait(1) end
    SendDuiMessage(DuiObject, json.encode({
        action = action,
        data = data
    }))
end

RegisterNetEvent('sleepless_interact:updateGroups', function(update)
    Groups = update
end)

utils.checkGroups = function(interactionGroups)
    if not interactionGroups then return true end

    for group, grade in pairs(Groups) do
        if interactionGroups[group] and grade >= interactionGroups[group] then
            return true
        end
    end

    return false
end

utils.loadInteractionData = function(data)
    data.renderDistance = data.renderDistance or 5.0
    data.activeDistance = data.activeDistance or 1.0
    data.cooldown = data.cooldown or 1000
    return data
end

local function processEntity(entity, entType)
    if entType == 'player' then
        if next(globals.playerInteractions) then
            local player = NetworkGetPlayerIndex(entity)
            local serverid = GetPlayerServerId(player)
            if globals.cachedPlayers[serverid] then return end

            globals.cachedPlayers[serverid] = true
            for i = 1, #globals.playerInteractions do
                local interaction = lib.table.deepclone(globals.playerInteractions[i])
                interaction.options = globals.playerInteractions[i].options
                interaction.id = string.format('%s:%s', interaction.id, serverid)
                interaction.netId = NetworkGetNetworkIdFromEntity(entity)
                interact.addEntity(interaction)
            end
        end
    end

    if entType == 'ped' then
        if next(globals.pedInteractions) then
            local isNet = NetworkGetEntityIsNetworked(entity)
            local key = isNet and PedToNet(entity) or entity
            if globals.cachedPeds[key] then return end

            globals.cachedPeds[key] = true
            for i = 1, #globals.pedInteractions do
                local interaction = lib.table.deepclone(globals.pedInteractions[i])
                interaction.options = globals.pedInteractions[i].options
                interaction.id = string.format('%s:%s', interaction.id, key)
                if isNet then
                    interaction.netId = key
                    interact.addEntity(interaction)
                else
                    interaction.entity = entity
                    interact.addLocalEntity(interaction)
                end
            end
        end
    end

    if entType == 'vehicle' then
        local isVehicle = IsEntityAVehicle(entity)
        if isVehicle and next(globals.vehicleInteractions) then
            local netId = NetworkGetNetworkIdFromEntity(entity)
            if globals.cachedVehicles[netId] then return end

            globals.cachedVehicles[netId] = true
            for i = 1, #globals.vehicleInteractions do
                local interaction = lib.table.deepclone(globals.vehicleInteractions[i])
                interaction.options = globals.vehicleInteractions[i].options
                if ox and interaction.bone == 'boot' then
                    if utils.getTrunkPosition(NetworkGetEntityFromNetworkId(netId)) then
                        interaction.netId = netId
                        interaction.id = interaction.id .. netId
                        interact.addEntity(interaction)
                    end
                else
                    interaction.netId = netId
                    interaction.id = string.format('%s:%s', interaction.id, netId)
                    interact.addEntity(interaction)
                end
            end
        end
    end

    local model = GetEntityModel(entity)
    if globals.Models[model] then
        local isNet = NetworkGetEntityIsNetworked(entity)
        local key = isNet and NetworkGetNetworkIdFromEntity(entity) or entity
        if globals.cachedModelEntities[key] then return end

        globals.cachedModelEntities[key] = true
        for i = 1, #globals.Models[model] do
            local modelInteraction = lib.table.deepclone(globals.Models[model][i])
            modelInteraction.options = globals.Models[model][i].options
            modelInteraction.model = model
            modelInteraction.id = string.format('%s:%s', model, key)
            if isNet then
                modelInteraction.netId = key
                interact.addEntity(modelInteraction)
            else
                modelInteraction.entity = key
                interact.addLocalEntity(modelInteraction)
            end
        end
    end
end

utils.checkEntities = function () --0.01-0.02ms overhead. not sure how to do it better.
    local coords = cache.coords or GetEntityCoords(cache.ped)

    CreateThread(function()
        local objects = lib.getNearbyObjects(coords, 15.0)
        if #objects > 0 then
            for i = 1, #objects do
                ---@diagnostic disable-next-line: undefined-field
                local entity = objects[i].object
                processEntity(entity)
            end
        end
    end)

    CreateThread(function()
        local vehicles = lib.getNearbyVehicles(coords, 4.0)
        if #vehicles > 0 then
            for i = 1, #vehicles do
                ---@diagnostic disable-next-line: undefined-field
                local entity = vehicles[i].vehicle
                processEntity(entity, 'vehicle')
            end
        end
    end)

    CreateThread(function()
        local players = lib.getNearbyPlayers(coords, 4.0, false)
        if #players > 0 then
            for i = 1, #players do
                ---@diagnostic disable-next-line: undefined-field
                local entity = players[i].ped
                processEntity(entity, 'player')
            end
        end
    end)

    CreateThread(function()
        local peds = lib.getNearbyPeds(coords, 4.0)
        if #peds > 0 then
            for i = 1, #peds do
                ---@diagnostic disable-next-line: undefined-field
                local entity = peds[i].ped
                processEntity(entity, 'ped')
            end
        end
    end)
end

utils.checkOptions = function (interaction)
    local disabledOptionsCount = 0
    local optionsLength = #interaction.options
    local shouldUpdateUI = false

    for i = 1, optionsLength do
        local option = interaction.options[i]
        local disabled = false
        if option.canInteract then
            local success, response = pcall(option.canInteract, interaction.getEntity and interaction:getEntity(), interaction.currentDistance, interaction.coords, interaction.id)
            disabled = not success or not response
        end
        if not disabled and option.groups then
            disabled = not utils.checkGroups(option.groups)
        end

        if disabled ~= interaction.textOptions[i].disable then
            interaction.textOptions[i].disable = disabled
            shouldUpdateUI = true
        end
        
        if disabled then
            disabledOptionsCount = disabledOptionsCount + 1
        end
    end

    if shouldUpdateUI then
        updateMenu('updateInteraction', {
            id = interaction.id,
            options = interaction.action and {} or interaction.textOptions
        })
    end

    return disabledOptionsCount < optionsLength
end



local backDoorIds = { 2, 3 }
utils.getTrunkPosition = function(entity)
    local vehicleHash = GetEntityModel(entity)
    local vehicleClass = GetVehicleClass(entity)
    local checkVehicle = Vehicles.Storage[vehicleHash]

    if (checkVehicle == 0 or checkVehicle == 1) or (not Vehicles.trunk[vehicleClass] and not Vehicles.trunk.models[vehicleHash]) then return end

    ---@type number | number[]
    local doorId = checkVehicle and 4 or 5

    if not Vehicles.trunk.boneIndex?[vehicleHash] and not GetIsDoorValid(entity, doorId --[[@as number]]) then
        if vehicleClass ~= 11 and (doorId ~= 5 or GetEntityBoneIndexByName(entity, 'boot') ~= -1 or not GetIsDoorValid(entity, 2)) then
            return
        end

        if vehicleClass ~= 11 then
            doorId = backDoorIds
        end
    end

    local min, max = GetModelDimensions(vehicleHash)
    local offset = (max - min) * (not checkVehicle and vec3(0.5, 0, 0.5) or vec3(0.5, 1, 0.5)) + min
    return GetOffsetFromEntityInWorldCoords(entity, offset.x, offset.y, offset.z)
end

return utils
