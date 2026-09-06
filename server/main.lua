-- FreshBan - Serveur
-- Toute la logique : bans, permissions, intégration Discord et paramètres du panel.
-- Chaque action venant de la NUI est revérifiée ici ; le client n'est jamais de confiance.

local cachedBanCount = 0

local function Notify(source, msg, type)
    if not source or source == 0 then
        print("[FreshBan] " .. (msg or ""))
        return
    end
    TriggerClientEvent('freshban:notify', source, msg, type or 'info')
end

local function GetIdentifiers(source)
    local ids = {
        license = nil, steam = nil, discord = nil,
        xbl = nil, live = nil, fivem = nil, ip = nil, tokens = {}
    }
    for i = 0, GetNumPlayerIdentifiers(source) - 1 do
        local id = GetPlayerIdentifier(source, i)
        if string.find(id, "license:") and not string.find(id, "license2:") then ids.license = id
        elseif string.find(id, "steam:") then ids.steam = id
        elseif string.find(id, "discord:") then ids.discord = id
        elseif string.find(id, "xbl:") then ids.xbl = id
        elseif string.find(id, "live:") then ids.live = id
        elseif string.find(id, "fivem:") then ids.fivem = id
        elseif string.find(id, "ip:") then ids.ip = id
        end
    end
    for i = 0, GetNumPlayerTokens(source) - 1 do
        table.insert(ids.tokens, GetPlayerToken(source, i))
    end
    return ids
end

-- cache runtime des paramètres modifiables en jeu
FreshBan.Runtime = {
    GradeOverrides = {},   -- [gradeKey] = { CanUnban=true, ... } (overrides BDD)
    CustomGrades   = {},   -- grades ajoutés via le panel
    Webhooks       = nil,  -- overrides webhooks BDD
    Appearance     = nil,  -- overrides apparence BDD
    StaffMap       = {},   -- [identifier] = gradeKey (assignation BDD)
    DiscordRoles   = {},   -- [roleId] = gradeKey (overrides BDD, fusionnés au config)
}

-- cache des profils Discord (rempli par le bot, jamais depuis le client)
-- [source] = { id, username, displayName, avatar (url), roles = {roleId,...} }
local DiscordCache = {}

-- état de la première configuration (bootstrap propriétaire sans ace)
local SetupState = { code = nil, claimed = false }

-- Retourne l'ID Discord brut (sans le préfixe) d'un joueur
local function GetDiscordId(source)
    for i = 0, GetNumPlayerIdentifiers(source) - 1 do
        local id = GetPlayerIdentifier(source, i)
        if id and id:sub(1, 8) == "discord:" then return id:sub(9) end
    end
    return nil
end

-- Fusionne les liaisons rôle→grade (config + BDD)
local function GetRoleGradeMap()
    local map = {}
    if FreshBan.DiscordBot and FreshBan.DiscordBot.RoleGrades then
        for roleId, gradeKey in pairs(FreshBan.DiscordBot.RoleGrades) do map[roleId] = gradeKey end
    end
    for roleId, gradeKey in pairs(FreshBan.Runtime.DiscordRoles) do map[roleId] = gradeKey end
    return map
end

-- À partir des rôles Discord en cache, renvoie la clé de grade correspondante (si liaison)
local function GradeKeyFromDiscord(source)
    local cached = DiscordCache[source]
    if not cached or not cached.roles then return nil end
    local map = GetRoleGradeMap()
    local found = nil
    -- On respecte l'ordre de priorité : on prend le grade le plus élevé trouvé
    local priority = {}
    for i, k in ipairs(FreshBan.Permissions.Priority) do priority[k] = i end
    for k in pairs(FreshBan.Runtime.CustomGrades) do if not priority[k] then priority[k] = 999 end end
    local bestRank = math.huge
    for _, roleId in ipairs(cached.roles) do
        local gk = map[roleId]
        if gk then
            local rank = priority[gk] or 500
            if rank < bestRank then bestRank = rank; found = gk end
        end
    end
    return found
end

-- Retourne la table de grade effective (config + overrides BDD fusionnés)
local function ResolveGrade(gradeKey)
    local base = FreshBan.Permissions.Grades[gradeKey] or FreshBan.Runtime.CustomGrades[gradeKey]
    if not base then return nil end
    local g = {}
    for k, v in pairs(base) do g[k] = v end
    -- Appliquer overrides BDD
    local ov = FreshBan.Runtime.GradeOverrides[gradeKey]
    if ov then for k, v in pairs(ov) do g[k] = v end end
    g.GradeKey = gradeKey
    return g
end

local function GetPlayerGrade(source)
    if not FreshBan.Permissions.Enabled then
        return {
            Label = "Staff", MaxDuration = 0, CanPermBan = true, CanKick = true,
            CanUnban = true, CanUnbanAll = true, CanUseFMenu = true,
            CanViewBanList = true, CanEditBan = true, CanManagePanel = true, GradeKey = "all"
        }
    end

    -- On collecte tous les grades candidats (BDD, rôle Discord, ace) puis on garde le plus élevé.
    local priority = {}
    for i, k in ipairs(FreshBan.Permissions.Priority) do priority[k] = i end
    for k in pairs(FreshBan.Runtime.CustomGrades) do if not priority[k] then priority[k] = 999 end end

    local best, bestRank = nil, math.huge
    local function consider(gradeKey)
        if not gradeKey then return end
        local rank = priority[gradeKey] or 500
        if rank < bestRank then
            local g = ResolveGrade(gradeKey)
            if g then best = g; bestRank = rank end
        end
    end

    if source and source ~= 0 then
        -- 1) Assignation BDD par identifiant
        local ids = GetIdentifiers(source)
        local checkIds = { ids.license, ids.discord, ids.steam, ids.fivem }
        for _, idf in ipairs(checkIds) do
            if idf and FreshBan.Runtime.StaffMap[idf] then consider(FreshBan.Runtime.StaffMap[idf]) end
        end
        -- 2) Rôle Discord (via cache du bot)
        consider(GradeKeyFromDiscord(source))
    end

    -- 3) Permissions ACE (server.cfg) — désactivé par défaut
    if FreshBan.Permissions.UseAce then
        for gradeKey, _ in pairs(priority) do
            local g = ResolveGrade(gradeKey)
            if g and g.AcePermission and IsPlayerAceAllowed(source, g.AcePermission) then
                consider(gradeKey)
            end
        end
    end

    return best
end

-- Récupération du profil Discord (API bot). Le token reste côté serveur.
local function BuildAvatarUrl(userId, avatarHash)
    if not avatarHash then
        local idx = 0
        if userId then idx = (tonumber(userId) or 0) % 5 end
        return "https://cdn.discordapp.com/embed/avatars/" .. idx .. ".png"
    end
    local ext = (tostring(avatarHash):sub(1, 2) == "a_") and "gif" or "png"
    return "https://cdn.discordapp.com/avatars/" .. userId .. "/" .. avatarHash .. "." .. ext .. "?size=128"
end

-- Récupère le profil Discord d'un joueur et le met en cache, puis appelle cb(profile|nil)
local function FetchDiscordProfile(source, cb)
    if not (FreshBan.DiscordBot and FreshBan.DiscordBot.Enabled) then cb(nil); return end
    local token = FreshBan.DiscordBot.BotToken
    local guild = FreshBan.DiscordBot.GuildId
    if not token or token == "" or token == "VOTRE_TOKEN_BOT_ICI" or not guild or guild == "" then
        print("^3[FreshBan]^0 Discord activé mais token/guild non configuré"); cb(nil); return
    end
    local userId = GetDiscordId(source)
    if not userId then cb(nil); return end

    local url = "https://discord.com/api/v10/guilds/" .. guild .. "/members/" .. userId
    PerformHttpRequest(url, function(status, text, headers)
        if status == 200 and text then
            local ok, data = pcall(json.decode, text)
            if ok and data and data.user then
                local profile = {
                    id = data.user.id,
                    username = data.user.global_name or data.user.username or "Discord",
                    tag = data.user.username,
                    displayName = data.nick or data.user.global_name or data.user.username,
                    avatar = BuildAvatarUrl(data.user.id, data.user.avatar),
                    roles = data.roles or {},
                }
                DiscordCache[source] = profile
                cb(profile)
                return
            end
        end
        print("^3[FreshBan]^0 Discord : membre introuvable " .. tostring(userId) .. " (statut " .. tostring(status) .. ")")
        cb(nil)
    end, "GET", "", {
        ["Authorization"] = "Bot " .. token,
        ["Content-Type"] = "application/json",
    })
end

local function ParseDuration(input)
    if not input then return nil end
    input = tostring(input):lower():gsub("%s", "")
    if input == "0" or input == "perm" or input == "permanent" then return 0 end
    local num, unit = input:match("^(%d+)(%a+)$")
    if not num then return nil end
    num = tonumber(num)
    if not num or num <= 0 then return nil end
    local multipliers = {
        ["min"] = 1, ["minute"] = 1, ["minutes"] = 1,
        ["h"] = 60, ["hr"] = 60, ["heure"] = 60, ["heures"] = 60, ["hour"] = 60, ["hours"] = 60,
        ["j"] = 1440, ["d"] = 1440, ["jour"] = 1440, ["jours"] = 1440, ["day"] = 1440, ["days"] = 1440,
        ["s"] = 10080, ["sem"] = 10080, ["semaine"] = 10080, ["semaines"] = 10080, ["w"] = 10080, ["week"] = 10080,
        ["mo"] = 43200, ["mois"] = 43200, ["month"] = 43200, ["months"] = 43200,
    }
    if unit == "m" then return num * 43200 end
    local mult = multipliers[unit]
    if not mult then return nil end
    return num * mult
end

local function FormatDuration(minutes)
    if minutes == 0 then return "PERMANENT" end
    if minutes < 60 then return minutes .. " minute(s)" end
    if minutes < 1440 then return math.floor(minutes / 60) .. "h " .. (minutes % 60) .. "min" end
    if minutes < 10080 then return math.floor(minutes / 1440) .. " jour(s)" end
    if minutes < 43200 then return math.floor(minutes / 10080) .. " semaine(s)" end
    return math.floor(minutes / 43200) .. " mois"
end

local function FormatTimeLeft(expireTimestamp)
    if not expireTimestamp then return "PERMANENT" end
    local now = os.time()
    local diff = expireTimestamp - now
    if diff <= 0 then return "Expiré" end
    local days = math.floor(diff / 86400)
    local hours = math.floor((diff % 86400) / 3600)
    local mins = math.floor((diff % 3600) / 60)
    if days > 0 then return days .. "j " .. hours .. "h " .. mins .. "min"
    elseif hours > 0 then return hours .. "h " .. mins .. "min"
    else return mins .. "min" end
end

local function DateToTimestamp(value)
    if not value then return nil end
    if type(value) == "number" then
        if value > 1e12 then return math.floor(value / 1000) end -- ms to s
        return value
    end
    local str = tostring(value)
    local y, mo, d, h, mi, sec = str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    if y then
        return os.time({year=tonumber(y), month=tonumber(mo), day=tonumber(d), hour=tonumber(h), min=tonumber(mi), sec=tonumber(sec)})
    end
    return nil
end

local function DateToString(value)
    if not value then return nil end
    if type(value) == "number" then
        local ts = value > 1e12 and math.floor(value / 1000) or value
        return os.date("%Y-%m-%d %H:%M:%S", ts)
    end
    return tostring(value)
end

local function GenerateBanID()
    local result = MySQL.scalar.await('SELECT MAX(id) FROM ' .. FreshBan.Database.TableName)
    local nextNum = (result or 0) + 1
    return FreshBan.BanPrefix .. string.format("%04d", nextNum)
end


local function SendWebhook(data)
    -- sélection de l'URL selon le type d'action (data.kind)
    -- Priorité : webhook spécifique BDD > webhook global BDD > config.lua
    local url = FreshBan.Webhook.URL
    local rt = FreshBan.Runtime.Webhooks
    if rt then
        if data.kind and rt[data.kind] and rt[data.kind] ~= "" then
            url = rt[data.kind]
        elseif rt.global and rt.global ~= "" then
            url = rt.global
        end
    end

    if not FreshBan.Webhook.Enabled then return end
    if not url or url == "" then return end
    if url:find("VOTRE_WEBHOOK_ICI") then return end
    local embed = {
        title = data.title or "FreshBan",
        description = data.description or "",
        color = data.color or FreshBan.Webhook.Color,
        fields = data.fields or {},
        footer = { text = FreshBan.ServerName .. " • FreshBan v2.0" },
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local payload = json.encode({
        username = FreshBan.Webhook.BotName,
        avatar_url = FreshBan.Webhook.AvatarURL,
        embeds = { embed },
    })
    PerformHttpRequest(url, function(err, text, headers) end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

local function LogAction(banId, action, staffName, staffLicense, targetName, targetLicense, details)
    local detailsStr = details and json.encode(details) or ""
    MySQL.insert.await(
        'INSERT INTO ' .. FreshBan.Database.LogTable .. ' (ban_id, action, staff_name, staff_license, target_name, target_license, details) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { banId or "", action or "", staffName or "", staffLicense or "", targetName or "", targetLicense or "", detailsStr }
    )
end


local function BuildPlayerList(requestSource)
    local players = {}
    for _, playerId in ipairs(GetPlayers()) do
        local pid = tonumber(playerId)
        if pid then
            local isSelf = (pid == requestSource)
            table.insert(players, {
                id = pid,
                name = GetPlayerName(pid) or "Inconnu",
                ping = GetPlayerPing(pid),
                isSelf = isSelf,
            })
        end
    end
    return players
end

local function BanPlayer(staffSource, targetSource, durationMinutes, reason)
    local staffName = GetPlayerName(staffSource) or "Console"
    local staffIds = GetIdentifiers(staffSource)
    local targetName = GetPlayerName(targetSource)
    local targetIds = GetIdentifiers(targetSource)

    if not targetName then Notify(staffSource, "^1[FreshBan] Joueur introuvable.", "error"); return false end
    if not targetIds.license then Notify(staffSource, "^1[FreshBan] Impossible de récupérer la license du joueur.", "error"); return false end

    -- Vérif auto-ban (autorisé uniquement en DevMode)
    if targetSource == staffSource and not FreshBan.DevMode then
        Notify(staffSource, "^1[FreshBan] Vous ne pouvez pas vous bannir vous-même.", "error")
        return false
    end

    local grade = GetPlayerGrade(staffSource)
    if not grade then Notify(staffSource, "^1[FreshBan] Vous n'avez pas la permission de bannir.", "error"); return false end
    if durationMinutes == 0 and not grade.CanPermBan then Notify(staffSource, "^1[FreshBan] Vous n'avez pas la permission de ban permanent.", "error"); return false end
    if grade.MaxDuration > 0 and durationMinutes > grade.MaxDuration and durationMinutes ~= 0 then Notify(staffSource, "^1[FreshBan] Durée max autorisée : " .. FormatDuration(grade.MaxDuration), "error"); return false end

    local banId = GenerateBanID()
    local expireAt = nil
    if durationMinutes > 0 then expireAt = os.date("%Y-%m-%d %H:%M:%S", os.time() + (durationMinutes * 60)) end

    local cols = { "ban_id", "target_name", "target_license", "staff_name", "staff_source", "reason", "duration", "server_name" }
    local vals = { "?", "?", "?", "?", "?", "?", "?", "?" }
    local params = { banId, targetName, targetIds.license, staffName, staffSource, reason, durationMinutes, FreshBan.ServerName }

    local optionals = {
        { col = "target_steam",   val = targetIds.steam },
        { col = "target_discord", val = targetIds.discord },
        { col = "target_xbl",    val = targetIds.xbl },
        { col = "target_live",   val = targetIds.live },
        { col = "target_fivem",  val = targetIds.fivem },
        { col = "target_ip",     val = targetIds.ip },
        { col = "target_tokens", val = json.encode(targetIds.tokens or {}) },
        { col = "staff_license", val = staffIds.license },
        { col = "expire_at",     val = expireAt },
    }
    for _, opt in ipairs(optionals) do
        if opt.val ~= nil then
            table.insert(cols, opt.col)
            table.insert(vals, "?")
            table.insert(params, opt.val)
        end
    end

    local query = 'INSERT INTO ' .. FreshBan.Database.TableName .. ' (' .. table.concat(cols, ", ") .. ') VALUES (' .. table.concat(vals, ", ") .. ')'
    MySQL.insert.await(query, params)

    LogAction(banId, 'BAN', staffName, staffIds.license, targetName, targetIds.license, { duration = durationMinutes, reason = reason })

    if FreshBan.Webhook.LogBan then
        local durationText = durationMinutes == 0 and "🔴 PERMANENT" or FormatDuration(durationMinutes)
        SendWebhook({ kind = "ban",
            title = "🚫 Nouveau Ban", color = 16711680,
            fields = {
                { name = "🆔 Ban ID", value = "`" .. banId .. "`", inline = true },
                { name = "👤 Joueur", value = targetName, inline = true },
                { name = "👮 Staff", value = staffName, inline = true },
                { name = "⏱️ Durée", value = durationText, inline = true },
                { name = "📅 Expire", value = expireAt or "Jamais", inline = true },
                { name = "📝 Raison", value = reason, inline = false },
                { name = "🔑 License", value = "||" .. (targetIds.license or "N/A") .. "||", inline = false },
            }
        })
    end

    local banMsg = FreshBan.BanMessage
    banMsg = banMsg:gsub("{server_name}", FreshBan.ServerName)
    banMsg = banMsg:gsub("{ban_id}", banId)
    banMsg = banMsg:gsub("{reason}", reason)
    banMsg = banMsg:gsub("{staff}", staffName)
    banMsg = banMsg:gsub("{expire_date}", expireAt or "Jamais (Permanent)")
    banMsg = banMsg:gsub("{time_left}", durationMinutes == 0 and "PERMANENT" or FormatDuration(durationMinutes))
    banMsg = banMsg:gsub("{discord}", FreshBan.Discord)

    DropPlayer(targetSource, banMsg)
    Notify(staffSource, "^2[FreshBan] " .. targetName .. " a été banni ! Ban ID: " .. banId .. " | Durée: " .. FormatDuration(durationMinutes), "success")

    -- Notify other staff
    for _, playerId in ipairs(GetPlayers()) do
        local pid = tonumber(playerId)
        if pid ~= staffSource and GetPlayerGrade(pid) then
            Notify(pid, "^3[FreshBan] " .. staffName .. " a banni " .. targetName .. " (" .. banId .. ") - " .. reason, "info")
        end
    end
    return banId
end


AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
    local source = source
    deferrals.defer()
    Wait(0)
    deferrals.update("🔍 FreshBan - Vérification en cours...")
    Wait(500)

    local ids = GetIdentifiers(source)

    if not ids.license then
        deferrals.done("❌ FreshBan - Impossible de vérifier votre identité.")
        return
    end

    local conditions = {}
    local params = {}
    local function addCond(col, val)
        if val then
            conditions[#conditions + 1] = col .. " = ?"
            params[#params + 1] = val
        end
    end
    addCond("target_license", ids.license)
    addCond("target_steam", ids.steam)
    addCond("target_discord", ids.discord)
    addCond("target_fivem", ids.fivem)
    addCond("target_ip", ids.ip)

    if #conditions == 0 then
        deferrals.done()
        return
    end

    local query = 'SELECT * FROM ' .. FreshBan.Database.TableName .. ' WHERE is_active = 1 AND (' .. table.concat(conditions, " OR ") .. ') ORDER BY id DESC LIMIT 1'

    local result = MySQL.query.await(query, params)

    if not result or #result == 0 then
        deferrals.done()
        return
    end

    local ban = result[1]

    if ban.expire_at then
        local expireTimestamp = DateToTimestamp(ban.expire_at)

        if expireTimestamp and os.time() >= expireTimestamp then
            MySQL.update.await('UPDATE ' .. FreshBan.Database.TableName .. ' SET is_active = 0 WHERE ban_id = ?', { ban.ban_id })
            deferrals.done()
            return
        end

        local timeLeft = expireTimestamp and FormatTimeLeft(expireTimestamp) or "PERMANENT"
        local expireStr = DateToString(ban.expire_at) or "Inconnu"
        local banMsg = FreshBan.BanMessage
        banMsg = banMsg:gsub("{server_name}", FreshBan.ServerName)
        banMsg = banMsg:gsub("{ban_id}", ban.ban_id)
        banMsg = banMsg:gsub("{reason}", ban.reason or "Non spécifiée")
        banMsg = banMsg:gsub("{staff}", ban.staff_name or "Système")
        banMsg = banMsg:gsub("{expire_date}", expireStr)
        banMsg = banMsg:gsub("{time_left}", timeLeft)
        banMsg = banMsg:gsub("{discord}", FreshBan.Discord)

        print("^1[FreshBan]^0 connexion refusée : " .. name .. " (ban " .. ban.ban_id .. ", reste " .. timeLeft .. ")")
        deferrals.done(banMsg)
        return
    end

    -- Permanent ban (expire_at = NULL, duration = 0)
    local banMsg = FreshBan.BanMessage
    banMsg = banMsg:gsub("{server_name}", FreshBan.ServerName)
    banMsg = banMsg:gsub("{ban_id}", ban.ban_id)
    banMsg = banMsg:gsub("{reason}", ban.reason or "Non spécifiée")
    banMsg = banMsg:gsub("{staff}", ban.staff_name or "Système")
    banMsg = banMsg:gsub("{expire_date}", "Jamais (Permanent)")
    banMsg = banMsg:gsub("{time_left}", "PERMANENT")
    banMsg = banMsg:gsub("{discord}", FreshBan.Discord)

    print("^1[FreshBan]^0 connexion refusée : " .. name .. " (ban permanent " .. ban.ban_id .. ")")
    deferrals.done(banMsg)
end)

RegisterCommand(FreshBan.Commands.Ban, function(source, args, rawCommand)
    if source == 0 then print("[FreshBan] Usage console : freshban [serverID] [durée] [raison]"); return end
    local grade = GetPlayerGrade(source)
    if not grade then Notify(source, "^1[FreshBan] Permission refusée.", "error"); return end
    if #args < 3 then
        Notify(source, "^3[FreshBan] Usage: /" .. FreshBan.Commands.Ban .. " [ID] [temps] [raison]", "info")
        Notify(source, "^3[FreshBan] Temps: 30min, 2h, 1j, 1s, 1m, 0 (perm)", "info")
        return
    end
    local targetId = tonumber(args[1])
    local timeStr = args[2]
    local reason = table.concat(args, " ", 3)
    if not targetId then Notify(source, "^1[FreshBan] ID joueur invalide.", "error"); return end
    if not GetPlayerName(targetId) then Notify(source, "^1[FreshBan] Joueur ID " .. targetId .. " introuvable.", "error"); return end
    local duration = ParseDuration(timeStr)
    if duration == nil then Notify(source, "^1[FreshBan] Format de temps invalide. Ex: 30min, 2h, 1j, 1s, 1m, 0", "error"); return end
    BanPlayer(source, targetId, duration, reason)
end, false)


RegisterCommand(FreshBan.Commands.Unban, function(source, args, rawCommand)
    if source == 0 then print("[FreshBan] Usage console : funban [banID] ou funban all") end
    local grade = source ~= 0 and GetPlayerGrade(source) or { CanUnban = true, CanUnbanAll = true }
    if not grade then Notify(source, "^1[FreshBan] Permission refusée.", "error"); return end
    if #args < 1 then Notify(source, "^3[FreshBan] Usage: /" .. FreshBan.Commands.Unban .. " [BanID ou 'all']", "info"); return end
    local input = args[1]:lower()

    if input == "all" then
        if not grade.CanUnbanAll then Notify(source, "^1[FreshBan] Vous n'avez pas la permission d'unban all.", "error"); return end
        if not FreshBan.UnbanAll.Enabled then Notify(source, "^1[FreshBan] La commande unban all est désactivée.", "error"); return end
        if FreshBan.UnbanAll.RequireWhitelist and source ~= 0 then
            local ids = GetIdentifiers(source)
            local whitelisted = false
            for _, wlId in ipairs(FreshBan.UnbanAll.WhitelistedIdentifiers) do
                if ids.license == wlId or ids.steam == wlId then whitelisted = true; break end
            end
            if not whitelisted then Notify(source, "^1[FreshBan] Vous n'êtes pas whitelisté pour unban all.", "error"); return end
        end
        local staffName = source ~= 0 and GetPlayerName(source) or "Console"
        local staffLicense = source ~= 0 and (GetIdentifiers(source).license or "console") or "console"
        local count = MySQL.scalar.await('SELECT COUNT(*) FROM ' .. FreshBan.Database.TableName .. ' WHERE is_active = 1')
        MySQL.update.await('UPDATE ' .. FreshBan.Database.TableName .. ' SET is_active = 0, unbanned_by = ?, unbanned_at = NOW() WHERE is_active = 1', { staffName })
        LogAction(nil, 'UNBAN_ALL', staffName, staffLicense, nil, nil, { count = count })
        if FreshBan.Webhook.LogUnbanAll then
            SendWebhook({ kind = "unban", title = "⚠️ UNBAN ALL", color = 16776960, fields = { { name = "👮 Staff", value = staffName, inline = true }, { name = "📊 Bans supprimés", value = tostring(count), inline = true } } })
        end
        Notify(source, "^2[FreshBan] " .. count .. " ban(s) ont été levés.", "success")
        return
    end

    if not grade.CanUnban then Notify(source, "^1[FreshBan] Vous n'avez pas la permission d'unban.", "error"); return end
    local banId = input:upper()
    local ban = MySQL.query.await('SELECT * FROM ' .. FreshBan.Database.TableName .. ' WHERE ban_id = ? AND is_active = 1', { banId })
    if not ban or #ban == 0 then Notify(source, "^1[FreshBan] Ban ID '" .. banId .. "' introuvable ou déjà inactif.", "error"); return end
    ban = ban[1]
    local staffName = source ~= 0 and GetPlayerName(source) or "Console"
    local staffLicense = source ~= 0 and (GetIdentifiers(source).license or "console") or "console"
    MySQL.update.await('UPDATE ' .. FreshBan.Database.TableName .. ' SET is_active = 0, unbanned_by = ?, unbanned_at = NOW() WHERE ban_id = ?', { staffName, banId })
    LogAction(banId, 'UNBAN', staffName, staffLicense, ban.target_name, ban.target_license, nil)
    if FreshBan.Webhook.LogUnban then
        SendWebhook({ kind = "unban", title = "✅ Unban", color = 65280, fields = { { name = "🆔 Ban ID", value = "`" .. banId .. "`", inline = true }, { name = "👤 Joueur", value = ban.target_name, inline = true }, { name = "👮 Unban par", value = staffName, inline = true } } })
    end
    Notify(source, "^2[FreshBan] " .. ban.target_name .. " (" .. banId .. ") a été unban.", "success")
end, false)


RegisterCommand(FreshBan.Commands.PermBan, function(source, args, rawCommand)
    if source == 0 then return end
    local grade = GetPlayerGrade(source)
    if not grade then Notify(source, "^1[FreshBan] Vous n'avez aucune permission FreshBan.", "error"); return end
    Notify(source, "^3[FreshBan] Vos permissions", "info")
    Notify(source, "^2 Grade: " .. (grade.Label or grade.GradeKey), "info")
    Notify(source, "^2 Durée max: " .. (grade.MaxDuration == 0 and "Illimitée" or FormatDuration(grade.MaxDuration)), "info")
    Notify(source, "^2 Ban Perm: " .. (grade.CanPermBan and "✅ Oui" or "❌ Non"), "info")
    Notify(source, "^2 Unban: " .. (grade.CanUnban and "✅ Oui" or "❌ Non"), "info")
    Notify(source, "^2 Unban All: " .. (grade.CanUnbanAll and "✅ Oui" or "❌ Non"), "info")
    Notify(source, "^2 Menu Ban: " .. (grade.CanUseFMenu and "✅ Oui" or "❌ Non"), "info")
    if FreshBan.Permissions.Enabled then
        Notify(source, "^3[FreshBan] Grades disponibles", "info")
        for _, gradeKey in ipairs(FreshBan.Permissions.Priority) do
            local g = FreshBan.Permissions.Grades[gradeKey]
            Notify(source, "^5 " .. g.Label .. " | Max: " .. (g.MaxDuration == 0 and "Illimité" or FormatDuration(g.MaxDuration)) .. " | Perm: " .. (g.CanPermBan and "Oui" or "Non"), "info")
        end
    end
end, false)


-- Construit le payload complet envoyé à la NUI (grade + apparence + capacités)
function BuildMenuPayload(source, grade, tab)
    local appearance = FreshBan.Runtime.Appearance or FreshBan.Appearance
    local dc = DiscordCache[source]
    return {
        players = BuildPlayerList(source),
        grade = {
            label = grade.Label or grade.GradeKey,
            gradeKey = grade.GradeKey,
            playerName = GetPlayerName(source) or "Staff",
            maxDuration = grade.MaxDuration,
            canPermBan = grade.CanPermBan or false,
            canKick = grade.CanKick or false,
            canUnban = grade.CanUnban or false,
            canUnbanAll = grade.CanUnbanAll or false,
            canViewBanList = grade.CanViewBanList or false,
            canEditBan = grade.CanEditBan or false,
            canManagePanel = grade.CanManagePanel or false,
            color = grade.Color or "#ffffff",
        },
        discord = dc and {
            username = dc.displayName or dc.username,
            avatar = dc.avatar,
            id = dc.id,
        } or nil,
        config = {
            newPlayerThreshold = FreshBan.Menu.NewPlayerThreshold,
            nearbyRadius = FreshBan.Menu.NearbyRadius,
            devMode = FreshBan.DevMode,
            serverName = FreshBan.ServerName,
            discordEnabled = (FreshBan.DiscordBot and FreshBan.DiscordBot.Enabled) or false,
        },
        appearance = {
            primary = appearance.PrimaryColor,
            accent = appearance.AccentColor,
            bgMode = appearance.BackgroundMode or FreshBan.Appearance.BackgroundMode,
            bgColor = appearance.BackgroundColor or FreshBan.Appearance.BackgroundColor,
            glassAlpha = appearance.GlassAlpha or FreshBan.Appearance.GlassAlpha,
            presets = FreshBan.Appearance.Presets,
        },
        durations = FreshBan.QuickDurations,
        tab = tab or "players",
    }
end

-- Ouvre le menu de façon asynchrone (Discord d'abord, puis grade, puis payload)
local function OpenPanel(source, wantedTab)
    FetchDiscordProfile(source, function(_)
        -- On recalcule le grade après la récupération Discord (un rôle peut l'accorder)
        local grade = GetPlayerGrade(source)
        if not grade then Notify(source, "^1[FreshBan] Permission refusée.", "error"); return end
        local tab = wantedTab or "players"
        if tab == "bans" and not grade.CanViewBanList then
            Notify(source, "^1[FreshBan] Vous n'avez pas accès à la liste des bans.", "error"); return
        end
        if tab == "players" and not grade.CanUseFMenu then
            Notify(source, "^1[FreshBan] Vous n'avez pas accès au menu ban.", "error"); return
        end
        TriggerClientEvent('freshban:openMenu', source, BuildMenuPayload(source, grade, tab))
    end)
end

RegisterCommand(FreshBan.Commands.MenuBan, function(source, args, rawCommand)
    if source == 0 then return end
    local grade = GetPlayerGrade(source)
    if not grade or not grade.CanUseFMenu then Notify(source, "^1[FreshBan] Permission refusée.", "error"); return end
    OpenPanel(source, "players")
end, false)



RegisterCommand(FreshBan.Commands.BanList, function(source, args, rawCommand)
    if source == 0 then return end
    local grade = GetPlayerGrade(source)
    if not grade then Notify(source, "^1[FreshBan] Permission refusée.", "error"); return end
    if not grade.CanViewBanList then Notify(source, "^1[FreshBan] Vous n'avez pas accès à la liste des bans.", "error"); return end
    OpenPanel(source, "bans")
end, false)


RegisterNetEvent('freshban:requestBan', function(data)
    local source = source
    if not data or not data.targetId or not data.duration or not data.reason then return end
    local grade = GetPlayerGrade(source)
    if not grade then return end
    local duration = ParseDuration(data.duration)
    if duration == nil then Notify(source, "^1[FreshBan] Format de temps invalide.", "error"); return end
    BanPlayer(source, tonumber(data.targetId), duration, data.reason)
end)

-- Kick — sécurisé par grade.CanKick
RegisterNetEvent('freshban:requestKick', function(data)
    local source = source
    if not data or not data.targetId then return end
    local grade = GetPlayerGrade(source)
    if not grade or not grade.CanKick then
        Notify(source, "^1[FreshBan] Vous n'avez pas la permission de kick.", "error"); return
    end
    local targetSource = tonumber(data.targetId)
    if not targetSource or not GetPlayerName(targetSource) then
        Notify(source, "^1[FreshBan] Joueur introuvable.", "error"); return
    end
    if not FreshBan.DevMode and targetSource == source then
        Notify(source, "^1[FreshBan] Vous ne pouvez pas vous kick vous-même.", "error"); return
    end
    local reason = (type(data.reason) == "string" and data.reason ~= "") and data.reason:sub(1, 256) or "Expulsé par un administrateur"
    local staffName = GetPlayerName(source) or "Console"
    local targetName = GetPlayerName(targetSource)

    DropPlayer(targetSource, "[" .. FreshBan.ServerName .. "] Kick: " .. reason)
    LogAction(nil, 'KICK', staffName, GetIdentifiers(source).license, targetName, GetIdentifiers(targetSource).license, { reason = reason })
    SendWebhook({ kind = "kick", title = "👢 Kick", color = 16776960, fields = {
        { name = "👤 Joueur", value = targetName, inline = true },
        { name = "👮 Staff", value = staffName, inline = true },
        { name = "📝 Raison", value = reason, inline = false },
    }})
    Notify(source, "^2[FreshBan] " .. targetName .. " a été expulsé.", "success")
end)

RegisterNetEvent('freshban:requestPlayerList', function()
    local source = source
    local grade = GetPlayerGrade(source)
    if not grade or not grade.CanUseFMenu then return end
    local players = BuildPlayerList(source)
    TriggerClientEvent('freshban:updatePlayerList', source, players)
end)


RegisterNetEvent('freshban:requestBanList', function()
    local source = source
    local grade = GetPlayerGrade(source)
    if not grade or not grade.CanViewBanList then return end

    local bans = MySQL.query.await(
        'SELECT ban_id, target_name, target_license, staff_name, reason, duration, expire_at, banned_at, is_active, server_name FROM ' .. FreshBan.Database.TableName .. ' ORDER BY banned_at DESC LIMIT 200'
    )

    local banList = {}
    if bans then
        for _, ban in ipairs(bans) do
            local timeLeft = nil
            if ban.is_active == 1 and ban.expire_at then
                local ts = DateToTimestamp(ban.expire_at)
                if ts then timeLeft = FormatTimeLeft(ts) end
            end

            table.insert(banList, {
                banId = ban.ban_id,
                playerName = ban.target_name,
                playerLicense = ban.target_license,
                staffName = ban.staff_name,
                reason = ban.reason,
                duration = ban.duration,
                durationLabel = FormatDuration(ban.duration),
                expireAt = DateToString(ban.expire_at),
                bannedAt = DateToString(ban.banned_at),
                isActive = ban.is_active == 1,
                isPermanent = ban.duration == 0,
                timeLeft = timeLeft,
                serverName = ban.server_name,
            })
        end
    end

    TriggerClientEvent('freshban:receiveBanList', source, banList)
end)

RegisterNetEvent('freshban:editBan', function(data)
    local source = source
    if not data or not data.banId then return end
    local grade = GetPlayerGrade(source)
    if not grade or not grade.CanEditBan then
        Notify(source, "^1[FreshBan] Vous n'avez pas la permission de modifier un ban.", "error")
        return
    end

    local ban = MySQL.query.await('SELECT * FROM ' .. FreshBan.Database.TableName .. ' WHERE ban_id = ? AND is_active = 1', { data.banId })
    if not ban or #ban == 0 then
        Notify(source, "^1[FreshBan] Ban ID '" .. data.banId .. "' introuvable ou inactif.", "error")
        return
    end
    ban = ban[1]

    local staffName = GetPlayerName(source) or "Console"
    local staffLicense = GetIdentifiers(source).license or "console"
    local updates = {}
    local params = {}
    local logDetails = {}

    -- Update reason
    if data.newReason and data.newReason ~= "" then
        table.insert(updates, "reason = ?")
        table.insert(params, data.newReason)
        logDetails.oldReason = ban.reason
        logDetails.newReason = data.newReason
    end

    -- Update duration
    if data.newDuration then
        local newMinutes = ParseDuration(data.newDuration)
        if newMinutes == nil then
            Notify(source, "^1[FreshBan] Format de durée invalide.", "error")
            return
        end

        if newMinutes == 0 and not grade.CanPermBan then
            Notify(source, "^1[FreshBan] Vous n'avez pas la permission de ban permanent.", "error")
            return
        end
        if grade.MaxDuration > 0 and newMinutes > grade.MaxDuration and newMinutes ~= 0 then
            Notify(source, "^1[FreshBan] Durée max autorisée : " .. FormatDuration(grade.MaxDuration), "error")
            return
        end

        local newExpireAt = nil
        if newMinutes > 0 then
            local banTimestamp = DateToTimestamp(ban.banned_at) or os.time()
            newExpireAt = os.date("%Y-%m-%d %H:%M:%S", banTimestamp + (newMinutes * 60))
        end

        table.insert(updates, "duration = ?")
        table.insert(params, newMinutes)
        table.insert(updates, "expire_at = ?")
        table.insert(params, newExpireAt)

        logDetails.oldDuration = FormatDuration(ban.duration)
        logDetails.newDuration = FormatDuration(newMinutes)
    end

    if #updates == 0 then
        Notify(source, "^3[FreshBan] Rien à modifier.", "info")
        return
    end

    table.insert(params, data.banId)
    MySQL.update.await('UPDATE ' .. FreshBan.Database.TableName .. ' SET ' .. table.concat(updates, ", ") .. ' WHERE ban_id = ?', params)

    LogAction(data.banId, 'EDIT', staffName, staffLicense, ban.target_name, ban.target_license, logDetails)

    if FreshBan.Webhook.LogBan then
        local fields = {
            { name = "🆔 Ban ID", value = "`" .. data.banId .. "`", inline = true },
            { name = "👤 Joueur", value = ban.target_name, inline = true },
            { name = "👮 Modifié par", value = staffName, inline = true },
        }
        if logDetails.newReason then
            table.insert(fields, { name = "📝 Nouvelle raison", value = logDetails.newReason, inline = false })
        end
        if logDetails.newDuration then
            table.insert(fields, { name = "⏱️ Nouvelle durée", value = logDetails.newDuration, inline = true })
        end
        SendWebhook({ kind = "ban", title = "✏️ Ban Modifié", color = 3447003, fields = fields })
    end

    Notify(source, "^2[FreshBan] Ban " .. data.banId .. " modifié avec succès.", "success")

    TriggerEvent('freshban:requestBanList')
end)

RegisterNetEvent('freshban:unbanFromPanel', function(banId)
    local source = source
    if not banId then return end
    local grade = GetPlayerGrade(source)
    if not grade or not grade.CanUnban then
        Notify(source, "^1[FreshBan] Vous n'avez pas la permission d'unban.", "error")
        return
    end

    local ban = MySQL.query.await('SELECT * FROM ' .. FreshBan.Database.TableName .. ' WHERE ban_id = ? AND is_active = 1', { banId })
    if not ban or #ban == 0 then
        Notify(source, "^1[FreshBan] Ban '" .. banId .. "' introuvable ou déjà inactif.", "error")
        return
    end
    ban = ban[1]
    local staffName = GetPlayerName(source) or "Console"
    local staffLicense = GetIdentifiers(source).license or "console"

    MySQL.update.await('UPDATE ' .. FreshBan.Database.TableName .. ' SET is_active = 0, unbanned_by = ?, unbanned_at = NOW() WHERE ban_id = ?', { staffName, banId })
    LogAction(banId, 'UNBAN', staffName, staffLicense, ban.target_name, ban.target_license, nil)

    if FreshBan.Webhook.LogUnban then
        SendWebhook({ kind = "unban", title = "✅ Unban (Panel)", color = 65280, fields = { { name = "🆔 Ban ID", value = "`" .. banId .. "`", inline = true }, { name = "👤 Joueur", value = ban.target_name, inline = true }, { name = "👮 Unban par", value = staffName, inline = true } } })
    end

    Notify(source, "^2[FreshBan] " .. ban.target_name .. " (" .. banId .. ") a été unban.", "success")
end)


AddEventHandler('playerJoining', function()
    local src = source
    TriggerClientEvent('freshban:playerJoined', -1, src)
    -- pré-charge le profil Discord en cache (pour que les rôles soient dispo tôt)
    if FreshBan.DiscordBot and FreshBan.DiscordBot.Enabled then
        FetchDiscordProfile(src, function(_) end)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    TriggerClientEvent('freshban:playerLeft', -1, src)
    DiscordCache[src] = nil
end)

-- Schéma SQL auto-installé (plus besoin d'importer le .sql à la main)
local function InstallSchema()
    local T = FreshBan.Database.TableName
    local L = FreshBan.Database.LogTable
    local stmts = {
        [[CREATE TABLE IF NOT EXISTS `]] .. T .. [[` (
            `id` INT AUTO_INCREMENT PRIMARY KEY, `ban_id` VARCHAR(16) NOT NULL UNIQUE,
            `target_name` VARCHAR(128) NOT NULL, `target_license` VARCHAR(128) NOT NULL,
            `target_steam` VARCHAR(64) DEFAULT NULL, `target_discord` VARCHAR(64) DEFAULT NULL,
            `target_xbl` VARCHAR(64) DEFAULT NULL, `target_live` VARCHAR(64) DEFAULT NULL,
            `target_fivem` VARCHAR(64) DEFAULT NULL, `target_ip` VARCHAR(64) DEFAULT NULL,
            `target_tokens` TEXT DEFAULT NULL, `staff_name` VARCHAR(128) NOT NULL,
            `staff_license` VARCHAR(128) DEFAULT NULL, `staff_source` INT DEFAULT NULL,
            `reason` TEXT NOT NULL, `duration` INT NOT NULL DEFAULT 0, `expire_at` DATETIME DEFAULT NULL,
            `server_name` VARCHAR(128) DEFAULT NULL, `is_active` TINYINT(1) NOT NULL DEFAULT 1,
            `unbanned_by` VARCHAR(128) DEFAULT NULL, `unbanned_at` DATETIME DEFAULT NULL,
            `banned_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_ban_id` (`ban_id`), INDEX `idx_license` (`target_license`),
            INDEX `idx_discord` (`target_discord`), INDEX `idx_active` (`is_active`), INDEX `idx_expire` (`expire_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]],
        [[CREATE TABLE IF NOT EXISTS `]] .. L .. [[` (
            `id` INT AUTO_INCREMENT PRIMARY KEY, `ban_id` VARCHAR(16) DEFAULT NULL, `action` VARCHAR(32) NOT NULL,
            `staff_name` VARCHAR(128) DEFAULT NULL, `staff_license` VARCHAR(128) DEFAULT NULL,
            `target_name` VARCHAR(128) DEFAULT NULL, `target_license` VARCHAR(128) DEFAULT NULL,
            `details` TEXT DEFAULT NULL, `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_ban_id` (`ban_id`), INDEX `idx_action` (`action`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]],
        [[CREATE TABLE IF NOT EXISTS `freshban_settings` (
            `setting_key` VARCHAR(64) NOT NULL PRIMARY KEY, `setting_value` LONGTEXT NOT NULL,
            `updated_by` VARCHAR(128) DEFAULT NULL, `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]],
        [[CREATE TABLE IF NOT EXISTS `freshban_staff` (
            `id` INT AUTO_INCREMENT PRIMARY KEY, `identifier` VARCHAR(128) NOT NULL UNIQUE,
            `grade_key` VARCHAR(64) NOT NULL, `display_name` VARCHAR(128) DEFAULT NULL,
            `added_by` VARCHAR(128) DEFAULT NULL, `added_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_identifier` (`identifier`), INDEX `idx_grade` (`grade_key`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]],
    }
    for _, sql in ipairs(stmts) do MySQL.query.await(sql) end
    print("^2[FreshBan]^0 base de données vérifiée")
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    MySQL.ready(function()
        InstallSchema()
        print("^2[FreshBan]^0 v2.0.0 chargé")
        if FreshBan.DevMode then
            print("^3[FreshBan]^0 mode dev activé (auto-ban autorisé)")
        end
        local count = MySQL.scalar.await('SELECT COUNT(*) FROM ' .. FreshBan.Database.TableName .. ' WHERE is_active = 1')
        if count then print("^2[FreshBan]^0 " .. count .. " ban(s) actif(s)") end
    end)
end)


-- Gestion du panel (grades, webhooks, apparence, staff)
-- Chaque handler revérifie le grade de l'appelant et valide ses données.

-- ─── Anti-spam : throttle par joueur sur les actions sensibles ───
local _fbLastAction = {}
local function IsRateLimited(src, cooldownMs)
    local now = GetGameTimer()
    local last = _fbLastAction[src] or 0
    if now - last < (cooldownMs or 400) then return true end
    _fbLastAction[src] = now
    return false
end

-- ─── Validation : la clé de permission doit être whitelistée ───
local _permWhitelist = {}
for _, p in ipairs(FreshBan.PermissionKeys) do _permWhitelist[p.key] = true end

local function IsValidHexColor(str)
    return type(str) == "string" and str:match("^#%x%x%x%x%x%x$") ~= nil
end

local function IsValidWebhookURL(str)
    if str == "" then return true end -- vide = autorisé (désactive)
    if type(str) ~= "string" then return false end
    return str:match("^https://discord%.com/api/webhooks/") ~= nil
        or str:match("^https://discordapp%.com/api/webhooks/") ~= nil
        or str:match("^https://ptb%.discord%.com/api/webhooks/") ~= nil
        or str:match("^https://canary%.discord%.com/api/webhooks/") ~= nil
end

-- ─── Persistance : lecture/écriture de la table freshban_settings ───
local function SaveSetting(key, valueTable, updatedBy)
    local encoded = json.encode(valueTable)
    MySQL.query.await(
        'INSERT INTO freshban_settings (setting_key, setting_value, updated_by) VALUES (?, ?, ?) '
        .. 'ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value), updated_by = VALUES(updated_by)',
        { key, encoded, updatedBy or "console" }
    )
end

local function LoadSetting(key)
    local rows = MySQL.query.await('SELECT setting_value FROM freshban_settings WHERE setting_key = ?', { key })
    if rows and rows[1] and rows[1].setting_value then
        local ok, decoded = pcall(json.decode, rows[1].setting_value)
        if ok then return decoded end
    end
    return nil
end

-- ─── Chargement initial du runtime au démarrage ───
local function LoadRuntimeSettings()
    local overrides = LoadSetting("grade_overrides")
    if overrides then FreshBan.Runtime.GradeOverrides = overrides end

    local custom = LoadSetting("custom_grades")
    if custom then FreshBan.Runtime.CustomGrades = custom end

    local webhooks = LoadSetting("webhooks")
    if webhooks then FreshBan.Runtime.Webhooks = webhooks end

    local appearance = LoadSetting("appearance")
    if appearance then FreshBan.Runtime.Appearance = appearance end

    local discordRoles = LoadSetting("discord_roles")
    if discordRoles then FreshBan.Runtime.DiscordRoles = discordRoles end

    -- Assignations de staff (BDD)
    local staff = MySQL.query.await('SELECT identifier, grade_key FROM freshban_staff')
    if staff then
        FreshBan.Runtime.StaffMap = {}
        for _, row in ipairs(staff) do
            FreshBan.Runtime.StaffMap[row.identifier] = row.grade_key
        end
    end

    print("^2[FreshBan]^0 paramètres chargés")
end

-- Wrapper de sécurité : renvoie le grade si le joueur a CanManagePanel, sinon nil + notif
local function RequireManager(src)
    if IsRateLimited(src, 400) then return nil end
    local grade = GetPlayerGrade(src)
    if not grade or not grade.CanManagePanel then
        Notify(src, "^1[FreshBan] Accès refusé (gestion du panel).", "error")
        print("^1[FreshBan]^0 tentative de gestion non autorisée par " .. tostring(src) .. " (" .. (GetPlayerName(src) or "?") .. ")")
        return nil
    end
    return grade
end

-- Envoi de l'état complet des settings au manager
local function PushSettingsToClient(src)
    -- Construit la liste des grades (config + custom) avec permissions effectives
    local grades = {}
    local function addGrade(key)
        local g = ResolveGrade(key)
        if not g then return end
        local perms = {}
        for _, p in ipairs(FreshBan.PermissionKeys) do
            perms[p.key] = g[p.key] or false
        end
        grades[#grades+1] = {
            key = key,
            label = g.Label or key,
            color = g.Color or "#888888",
            acePermission = g.AcePermission or "",
            maxDuration = g.MaxDuration or 0,
            isCustom = FreshBan.Runtime.CustomGrades[key] ~= nil,
            permissions = perms,
        }
    end
    for _, key in ipairs(FreshBan.Permissions.Priority) do addGrade(key) end
    for key in pairs(FreshBan.Runtime.CustomGrades) do addGrade(key) end

    -- Webhooks effectifs
    local wh = FreshBan.Runtime.Webhooks or {
        global = FreshBan.Webhook.URL, ban = "", unban = "", kick = "", admin = ""
    }

    -- Staff BDD
    local staffList = {}
    local rows = MySQL.query.await('SELECT identifier, grade_key, display_name, added_by, added_at FROM freshban_staff ORDER BY added_at DESC')
    if rows then
        for _, r in ipairs(rows) do
            staffList[#staffList+1] = {
                identifier = r.identifier, gradeKey = r.grade_key,
                displayName = r.display_name, addedBy = r.added_by,
            }
        end
    end

    -- Liaisons rôles Discord → grades
    local discordRolesList = {}
    for roleId, gradeKey in pairs(GetRoleGradeMap()) do
        discordRolesList[#discordRolesList+1] = {
            roleId = roleId, gradeKey = gradeKey,
            fromConfig = (FreshBan.DiscordBot and FreshBan.DiscordBot.RoleGrades and FreshBan.DiscordBot.RoleGrades[roleId] ~= nil) or false,
        }
    end

    TriggerClientEvent('freshban:receiveSettings', src, {
        grades = grades,
        permissionKeys = FreshBan.PermissionKeys,
        webhooks = wh,
        appearance = FreshBan.Runtime.Appearance or FreshBan.Appearance,
        presets = FreshBan.Appearance.Presets,
        staff = staffList,
        discordRoles = discordRolesList,
        discordEnabled = (FreshBan.DiscordBot and FreshBan.DiscordBot.Enabled) or false,
    })
end

RegisterNetEvent('freshban:requestSettings', function()
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    PushSettingsToClient(src)
end)

-- Sauvegarde des permissions d'un grade
RegisterNetEvent('freshban:saveGradePermissions', function(data)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(data) ~= "table" or type(data.gradeKey) ~= "string" or type(data.permissions) ~= "table" then
        Notify(src, "^1[FreshBan] Données invalides.", "error"); return
    end

    -- Le grade doit exister
    if not (FreshBan.Permissions.Grades[data.gradeKey] or FreshBan.Runtime.CustomGrades[data.gradeKey]) then
        Notify(src, "^1[FreshBan] Grade introuvable.", "error"); return
    end

    -- Filtrer : seules les clés whitelistées sont acceptées
    local cleanPerms = {}
    for k, v in pairs(data.permissions) do
        if _permWhitelist[k] then
            cleanPerms[k] = (v == true)
        end
    end

    -- MaxDuration optionnel (validé : nombre >= 0)
    local ov = FreshBan.Runtime.GradeOverrides[data.gradeKey] or {}
    for k, v in pairs(cleanPerms) do ov[k] = v end
    if data.maxDuration ~= nil then
        local md = tonumber(data.maxDuration)
        if md and md >= 0 then ov.MaxDuration = math.floor(md) end
    end

    FreshBan.Runtime.GradeOverrides[data.gradeKey] = ov
    SaveSetting("grade_overrides", FreshBan.Runtime.GradeOverrides, GetPlayerName(src))

    LogAction(nil, 'CONFIG_GRADE', GetPlayerName(src), GetIdentifiers(src).license, data.gradeKey, nil, { permissions = cleanPerms })
    SendWebhook({ kind = "admin", title = "⚙️ Permissions modifiées", color = 3447003, fields = {
        { name = "Grade", value = data.gradeKey, inline = true },
        { name = "Par", value = GetPlayerName(src), inline = true },
    }})

    Notify(src, "^2[FreshBan] Permissions du grade '" .. data.gradeKey .. "' sauvegardées.", "success")
    PushSettingsToClient(src)
end)

-- Ajout d'un grade custom
RegisterNetEvent('freshban:addGrade', function(data)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(data) ~= "table" or type(data.key) ~= "string" or type(data.label) ~= "string" then
        Notify(src, "^1[FreshBan] Données invalides.", "error"); return
    end

    -- Sanitize la clé : minuscules, alphanumériques + underscore, max 32
    local key = data.key:lower():gsub("[^%a%d_]", ""):sub(1, 32)
    if key == "" then Notify(src, "^1[FreshBan] Clé de grade invalide.", "error"); return end
    if FreshBan.Permissions.Grades[key] or FreshBan.Runtime.CustomGrades[key] then
        Notify(src, "^1[FreshBan] Ce grade existe déjà.", "error"); return
    end

    local label = data.label:sub(1, 48)
    local color = IsValidHexColor(data.color) and data.color or "#888888"
    local ace = type(data.acePermission) == "string" and data.acePermission:gsub("[^%a%d%._]", ""):sub(1, 64) or ("freshban." .. key)

    FreshBan.Runtime.CustomGrades[key] = {
        Label = label, Color = color, AcePermission = ace, MaxDuration = 1440,
        CanUseFMenu = true, CanViewBanList = false, CanPermBan = false,
        CanUnban = false, CanUnbanAll = false, CanEditBan = false, CanManagePanel = false,
    }
    SaveSetting("custom_grades", FreshBan.Runtime.CustomGrades, GetPlayerName(src))
    LogAction(nil, 'CONFIG_ADD_GRADE', GetPlayerName(src), GetIdentifiers(src).license, key, nil, { label = label })
    Notify(src, "^2[FreshBan] Grade '" .. label .. "' créé. Ace: " .. ace, "success")
    PushSettingsToClient(src)
end)

-- Suppression d'un grade custom
RegisterNetEvent('freshban:deleteGrade', function(gradeKey)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(gradeKey) ~= "string" then return end

    -- On ne supprime QUE les grades custom (jamais ceux du config.lua)
    if not FreshBan.Runtime.CustomGrades[gradeKey] then
        Notify(src, "^1[FreshBan] Seuls les grades personnalisés peuvent être supprimés.", "error"); return
    end

    FreshBan.Runtime.CustomGrades[gradeKey] = nil
    FreshBan.Runtime.GradeOverrides[gradeKey] = nil
    SaveSetting("custom_grades", FreshBan.Runtime.CustomGrades, GetPlayerName(src))
    SaveSetting("grade_overrides", FreshBan.Runtime.GradeOverrides, GetPlayerName(src))

    -- Retirer les assignations de staff sur ce grade
    MySQL.update.await('DELETE FROM freshban_staff WHERE grade_key = ?', { gradeKey })
    LoadRuntimeSettings()

    LogAction(nil, 'CONFIG_DEL_GRADE', GetPlayerName(src), GetIdentifiers(src).license, gradeKey, nil, nil)
    Notify(src, "^2[FreshBan] Grade supprimé.", "success")
    PushSettingsToClient(src)
end)

-- Sauvegarde des webhooks
RegisterNetEvent('freshban:saveWebhooks', function(data)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(data) ~= "table" then return end

    local fields = { "global", "ban", "unban", "kick", "admin" }
    local clean = {}
    for _, f in ipairs(fields) do
        local v = data[f]
        if v == nil then v = "" end
        if type(v) ~= "string" then Notify(src, "^1[FreshBan] Webhook invalide.", "error"); return end
        v = v:sub(1, 256)
        if not IsValidWebhookURL(v) then
            Notify(src, "^1[FreshBan] URL webhook invalide (" .. f .. "). Doit être un webhook Discord.", "error"); return
        end
        clean[f] = v
    end

    FreshBan.Runtime.Webhooks = clean
    SaveSetting("webhooks", clean, GetPlayerName(src))
    LogAction(nil, 'CONFIG_WEBHOOKS', GetPlayerName(src), GetIdentifiers(src).license, nil, nil, nil)
    Notify(src, "^2[FreshBan] Webhooks sauvegardés.", "success")

    -- Test optionnel du webhook global
    if data.test and clean.global ~= "" then
        SendWebhook({ kind = "admin", title = "✅ Test Webhook FreshBan", color = 65280, description = "Configuration réussie par " .. GetPlayerName(src) })
    end
    PushSettingsToClient(src)
end)

-- Sauvegarde de l'apparence
RegisterNetEvent('freshban:saveAppearance', function(data)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(data) ~= "table" then return end

    local prev = FreshBan.Runtime.Appearance or FreshBan.Appearance
    local primary = IsValidHexColor(data.primary) and data.primary or nil
    local accent = IsValidHexColor(data.accent) and data.accent or nil
    if not primary then Notify(src, "^1[FreshBan] Couleur primaire invalide.", "error"); return end

    -- Fond : mode glass/solid, couleur, opacité
    local bgMode = (data.bgMode == "solid" or data.bgMode == "glass") and data.bgMode or (prev.BackgroundMode or "glass")
    local bgColor = IsValidHexColor(data.bgColor) and data.bgColor or (prev.BackgroundColor or FreshBan.Appearance.BackgroundColor)
    local glassAlpha = tonumber(data.glassAlpha)
    if not glassAlpha then glassAlpha = prev.GlassAlpha or FreshBan.Appearance.GlassAlpha end
    if glassAlpha < 0.05 then glassAlpha = 0.05 elseif glassAlpha > 0.95 then glassAlpha = 0.95 end

    FreshBan.Runtime.Appearance = {
        PrimaryColor = primary,
        AccentColor = accent or prev.AccentColor or FreshBan.Appearance.AccentColor,
        BackgroundMode = bgMode,
        BackgroundColor = bgColor,
        GlassAlpha = glassAlpha,
    }
    SaveSetting("appearance", FreshBan.Runtime.Appearance, GetPlayerName(src))
    LogAction(nil, 'CONFIG_APPEARANCE', GetPlayerName(src), GetIdentifiers(src).license, nil, nil, { primary = primary, bgMode = bgMode })
    Notify(src, "^2[FreshBan] Apparence sauvegardée pour tout le staff.", "success")

    -- Diffuse à tous les staff connectés qui ont le menu
    for _, pid in ipairs(GetPlayers()) do
        local p = tonumber(pid)
        local g = GetPlayerGrade(p)
        if g and g.CanUseFMenu then
            TriggerClientEvent('freshban:updateAppearance', p, {
                primary = FreshBan.Runtime.Appearance.PrimaryColor,
                accent = FreshBan.Runtime.Appearance.AccentColor,
                bgMode = FreshBan.Runtime.Appearance.BackgroundMode,
                bgColor = FreshBan.Runtime.Appearance.BackgroundColor,
                glassAlpha = FreshBan.Runtime.Appearance.GlassAlpha,
            })
        end
    end
    PushSettingsToClient(src)
end)

-- Ajout d'un staff (assignation grade par identifiant)
RegisterNetEvent('freshban:addStaff', function(data)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(data) ~= "table" or type(data.identifier) ~= "string" or type(data.gradeKey) ~= "string" then
        Notify(src, "^1[FreshBan] Données invalides.", "error"); return
    end

    -- Le grade doit exister
    if not (FreshBan.Permissions.Grades[data.gradeKey] or FreshBan.Runtime.CustomGrades[data.gradeKey]) then
        Notify(src, "^1[FreshBan] Grade introuvable.", "error"); return
    end

    -- Valider le format de l'identifiant
    local idf = data.identifier:gsub("%s", "")
    if not (idf:match("^license:%x+$") or idf:match("^discord:%d+$") or idf:match("^steam:%x+$") or idf:match("^fivem:%d+$")) then
        Notify(src, "^1[FreshBan] Identifiant invalide (license:, discord:, steam: ou fivem:).", "error"); return
    end

    local displayName = type(data.displayName) == "string" and data.displayName:sub(1, 64) or idf
    MySQL.query.await(
        'INSERT INTO freshban_staff (identifier, grade_key, display_name, added_by) VALUES (?, ?, ?, ?) '
        .. 'ON DUPLICATE KEY UPDATE grade_key = VALUES(grade_key), display_name = VALUES(display_name), added_by = VALUES(added_by)',
        { idf, data.gradeKey, displayName, GetPlayerName(src) }
    )
    FreshBan.Runtime.StaffMap[idf] = data.gradeKey
    LogAction(nil, 'CONFIG_ADD_STAFF', GetPlayerName(src), GetIdentifiers(src).license, displayName, idf, { grade = data.gradeKey })
    SendWebhook({ kind = "admin", title = "👮 Staff ajouté", color = 3447003, fields = {
        { name = "Identifiant", value = "||" .. idf .. "||", inline = false },
        { name = "Grade", value = data.gradeKey, inline = true },
        { name = "Par", value = GetPlayerName(src), inline = true },
    }})
    Notify(src, "^2[FreshBan] Staff ajouté au grade '" .. data.gradeKey .. "'.", "success")
    PushSettingsToClient(src)
end)

-- Retrait d'un staff
RegisterNetEvent('freshban:removeStaff', function(identifier)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(identifier) ~= "string" then return end

    MySQL.update.await('DELETE FROM freshban_staff WHERE identifier = ?', { identifier })
    FreshBan.Runtime.StaffMap[identifier] = nil
    LogAction(nil, 'CONFIG_DEL_STAFF', GetPlayerName(src), GetIdentifiers(src).license, nil, identifier, nil)
    Notify(src, "^2[FreshBan] Staff retiré.", "success")
    PushSettingsToClient(src)
end)

-- Liaison RÔLE DISCORD → GRADE (ajout)
RegisterNetEvent('freshban:addDiscordRole', function(data)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(data) ~= "table" or type(data.roleId) ~= "string" or type(data.gradeKey) ~= "string" then
        Notify(src, "^1[FreshBan] Données invalides.", "error"); return
    end
    -- roleId = suite de chiffres (snowflake Discord)
    local roleId = data.roleId:gsub("%s", "")
    if not roleId:match("^%d+$") then
        Notify(src, "^1[FreshBan] ID de rôle invalide (chiffres uniquement).", "error"); return
    end
    if not (FreshBan.Permissions.Grades[data.gradeKey] or FreshBan.Runtime.CustomGrades[data.gradeKey]) then
        Notify(src, "^1[FreshBan] Grade introuvable.", "error"); return
    end
    FreshBan.Runtime.DiscordRoles[roleId] = data.gradeKey
    SaveSetting("discord_roles", FreshBan.Runtime.DiscordRoles, GetPlayerName(src))
    LogAction(nil, 'CONFIG_ADD_DROLE', GetPlayerName(src), GetIdentifiers(src).license, data.gradeKey, roleId, nil)
    Notify(src, "^2[FreshBan] Rôle Discord lié au grade '" .. data.gradeKey .. "'.", "success")
    PushSettingsToClient(src)
end)

-- Liaison RÔLE DISCORD → GRADE (retrait)
RegisterNetEvent('freshban:removeDiscordRole', function(roleId)
    local src = source
    local grade = RequireManager(src)
    if not grade then return end
    if type(roleId) ~= "string" then return end
    if FreshBan.DiscordBot and FreshBan.DiscordBot.RoleGrades and FreshBan.DiscordBot.RoleGrades[roleId] then
        Notify(src, "^1[FreshBan] Cette liaison vient du config.lua, retirez-la du fichier.", "error"); return
    end
    FreshBan.Runtime.DiscordRoles[roleId] = nil
    SaveSetting("discord_roles", FreshBan.Runtime.DiscordRoles, GetPlayerName(src))
    LogAction(nil, 'CONFIG_DEL_DROLE', GetPlayerName(src), GetIdentifiers(src).license, nil, roleId, nil)
    Notify(src, "^2[FreshBan] Liaison de rôle retirée.", "success")
    PushSettingsToClient(src)
end)

-- PREMIÈRE CONFIGURATION (bootstrap propriétaire, sans ace)
local function InitSetup()
    -- Déjà configuré ? (un superadmin existe en BDD ou setting claimed)
    local claimed = LoadSetting("owner_claimed")
    local superCount = MySQL.scalar.await("SELECT COUNT(*) FROM freshban_staff WHERE grade_key = 'superadmin'")
    if claimed or (superCount and superCount > 0) then
        SetupState.claimed = true
        return
    end
    -- Génère un code de setup à usage unique
    math.randomseed(os.time())
    SetupState.code = tostring(math.random(1000, 9999))
    SetupState.claimed = false
    print("^3[FreshBan]^0 Première configuration : tapez ^5/fbsetup " .. SetupState.code .. "^0 en jeu pour devenir propriétaire.")
end

RegisterCommand("fbsetup", function(source, args)
    if source == 0 then
        print("^3[FreshBan]^0 /fbsetup doit être utilisé en jeu"); return
    end
    if SetupState.claimed then
        Notify(source, "^1[FreshBan] La configuration a déjà été faite.", "error"); return
    end
    if not SetupState.code then
        Notify(source, "^1[FreshBan] Aucun code de setup actif (redémarre la ressource).", "error"); return
    end
    if not args[1] or tostring(args[1]) ~= SetupState.code then
        Notify(source, "^1[FreshBan] Code incorrect. Regarde la console serveur.", "error")
        print("^3[FreshBan]^0 /fbsetup : mauvais code de " .. (GetPlayerName(source) or "?"))
        return
    end
    -- Devient propriétaire (superadmin) via son identifiant (license prioritaire)
    local ids = GetIdentifiers(source)
    local idf = ids.license or ids.discord or ids.steam or ids.fivem
    if not idf then Notify(source, "^1[FreshBan] Aucun identifiant valide trouvé.", "error"); return end

    MySQL.query.await(
        'INSERT INTO freshban_staff (identifier, grade_key, display_name, added_by) VALUES (?, ?, ?, ?) '
        .. 'ON DUPLICATE KEY UPDATE grade_key = VALUES(grade_key)',
        { idf, "superadmin", GetPlayerName(source) or "Owner", "SETUP" }
    )
    SaveSetting("owner_claimed", { at = os.time(), by = GetPlayerName(source) }, "SETUP")
    FreshBan.Runtime.StaffMap[idf] = "superadmin"
    SetupState.claimed = true
    SetupState.code = nil

    Notify(source, "^2[FreshBan] ✅ Tu es maintenant PROPRIÉTAIRE (Super Admin) ! Tape /" .. FreshBan.Commands.MenuBan .. " puis configure tout dans Paramètres.", "success")
    print("^2[FreshBan]^0 propriétaire défini : " .. (GetPlayerName(source) or "?") .. " (" .. idf .. ")")
end, false)

-- Chargement des settings au démarrage de la ressource
CreateThread(function()
    Wait(1500) -- laisse oxmysql + schéma s'initialiser
    LoadRuntimeSettings()
    InitSetup()
end)
