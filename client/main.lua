-- FreshBan - Client
-- Pont NUI : relaie les actions du panel vers le serveur et gère l'affichage.
-- Toutes les actions sensibles sont revérifiées côté serveur ; ce fichier ne fait que l'affichage.

local menuOpen = false
local connectTimes = {}
local gameBlurActive = false

-- En mode "glass", on floute le jeu avec la native GTA plutôt que le backdrop-filter
-- CSS (qui s'affiche en carré noir dans la NUI de FiveM).
local function setGameBlur(enable)
    if not (FreshBan.Appearance and FreshBan.Appearance.BlurGame ~= false) then return end
    if enable and not gameBlurActive then
        gameBlurActive = true
        TriggerScreenblurFadeIn(350.0)
    elseif not enable and gameBlurActive then
        gameBlurActive = false
        TriggerScreenblurFadeOut(350.0)
    end
end

-- Complète la liste des joueurs avec les données côté client (distance, temps de session).
local function computePlayerMeta(list)
    local myCoords = GetEntityCoords(PlayerPedId())
    for _, player in ipairs(list) do
        if player.isSelf then
            player.distance = 0
        else
            local ped = GetPlayerPed(GetPlayerFromServerId(player.id))
            player.distance = (ped and DoesEntityExist(ped)) and #(myCoords - GetEntityCoords(ped)) or -1
        end

        local joined = connectTimes[player.id]
        if joined then
            local minutes = (GetGameTimer() - joined) / 60000
            player.isNew = minutes <= (FreshBan.Menu.NewPlayerThreshold or 60)
            player.minutesSinceJoin = math.floor(minutes)
        else
            player.isNew = false
            player.minutesSinceJoin = -1
        end
    end
end

-- Serveur -> NUI

RegisterNetEvent('freshban:openMenu', function(data)
    if menuOpen then return end
    menuOpen = true

    computePlayerMeta(data.players)
    SetNuiFocus(true, true)

    local mode = (data.appearance and data.appearance.bgMode) or "glass"
    setGameBlur(mode == "glass")

    SendNUIMessage({
        action     = "openMenu",
        players    = data.players,
        grade      = data.grade,
        config     = data.config,
        appearance = data.appearance,
        discord    = data.discord,
        durations  = data.durations,
        tab        = data.tab or "players",
    })

    if data.tab == "bans" then
        TriggerServerEvent('freshban:requestBanList')
    end
end)

RegisterNetEvent('freshban:updatePlayerList', function(players)
    if not menuOpen then return end
    computePlayerMeta(players)
    SendNUIMessage({ action = "updatePlayers", players = players })
end)

RegisterNetEvent('freshban:receiveBanList', function(bans)
    if not menuOpen then return end
    SendNUIMessage({ action = "updateBanList", bans = bans })
end)

RegisterNetEvent('freshban:receiveSettings', function(settings)
    if not menuOpen then return end
    SendNUIMessage({ action = "updateSettings", settings = settings })
end)

RegisterNetEvent('freshban:updateAppearance', function(appearance)
    if menuOpen and appearance and appearance.bgMode then
        setGameBlur(appearance.bgMode == "glass")
    end
    SendNUIMessage({ action = "updateAppearance", appearance = appearance })
end)

RegisterNetEvent('freshban:notify', function(msg, kind)
    if menuOpen then
        SendNUIMessage({ action = "notification", notifType = kind or "info", message = msg })
    end
    TriggerEvent('chat:addMessage', {
        color = kind == "error" and { 255, 50, 50 }
             or kind == "success" and { 50, 255, 50 }
             or { 255, 200, 50 },
        multiline = true,
        args = { msg },
    })
end)

-- NUI -> Serveur
-- Simples relais. Le serveur reste seul juge des permissions.

local function relay(event)
    return function(data, cb)
        TriggerServerEvent(event, data)
        cb('ok')
    end
end

RegisterNUICallback('closeFreshBan', function(_, cb)
    menuOpen = false
    SetNuiFocus(false, false)
    setGameBlur(false)
    cb('ok')
end)

RegisterNUICallback('previewBgMode', function(data, cb)
    if menuOpen and data and data.bgMode then
        setGameBlur(data.bgMode == "glass")
    end
    cb('ok')
end)

RegisterNUICallback('banPlayer', function(data, cb)
    if data and data.targetId and data.duration and data.reason then
        TriggerServerEvent('freshban:requestBan', data)
    end
    cb('ok')
end)

RegisterNUICallback('kickPlayer', function(data, cb)
    if data and data.targetId then
        TriggerServerEvent('freshban:requestKick', data)
    end
    cb('ok')
end)

RegisterNUICallback('refreshPlayers', function(_, cb)
    TriggerServerEvent('freshban:requestPlayerList')
    cb('ok')
end)

RegisterNUICallback('fetchBanList', function(_, cb)
    TriggerServerEvent('freshban:requestBanList')
    cb('ok')
end)

RegisterNUICallback('editBan', function(data, cb)
    if data and data.banId then TriggerServerEvent('freshban:editBan', data) end
    cb('ok')
end)

RegisterNUICallback('unbanFromPanel', function(data, cb)
    if data and data.banId then
        TriggerServerEvent('freshban:unbanFromPanel', data.banId)
        SetTimeout(500, function()
            if menuOpen then TriggerServerEvent('freshban:requestBanList') end
        end)
    end
    cb('ok')
end)

RegisterNUICallback('fetchSettings',        relay('freshban:requestSettings'))
RegisterNUICallback('saveGradePermissions', relay('freshban:saveGradePermissions'))
RegisterNUICallback('addGrade',             relay('freshban:addGrade'))
RegisterNUICallback('saveWebhooks',         relay('freshban:saveWebhooks'))
RegisterNUICallback('saveAppearance',       relay('freshban:saveAppearance'))
RegisterNUICallback('addStaff',             relay('freshban:addStaff'))
RegisterNUICallback('addDiscordRole',       relay('freshban:addDiscordRole'))

RegisterNUICallback('deleteGrade', function(data, cb)
    if data and data.gradeKey then TriggerServerEvent('freshban:deleteGrade', data.gradeKey) end
    cb('ok')
end)

RegisterNUICallback('removeStaff', function(data, cb)
    if data and data.identifier then TriggerServerEvent('freshban:removeStaff', data.identifier) end
    cb('ok')
end)

RegisterNUICallback('removeDiscordRole', function(data, cb)
    if data and data.roleId then TriggerServerEvent('freshban:removeDiscordRole', data.roleId) end
    cb('ok')
end)

-- Suivi de session (pour le tag NEW et le temps de connexion)

AddEventHandler('playerSpawned', function()
    local id = GetPlayerServerId(PlayerId())
    connectTimes[id] = connectTimes[id] or GetGameTimer()
end)

RegisterNetEvent('freshban:playerJoined', function(serverId)
    connectTimes[serverId] = GetGameTimer()
end)

RegisterNetEvent('freshban:playerLeft', function(serverId)
    connectTimes[serverId] = nil
end)

-- Bloque les contrôles de déplacement/tir pendant que le panel est ouvert

CreateThread(function()
    local controls = { 1, 2, 18, 142, 199, 322 }
    while true do
        if menuOpen then
            for i = 1, #controls do
                DisableControlAction(0, controls[i], true)
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)
