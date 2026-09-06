--[[
    FreshBan - Configuration
    La plupart des réglages (grades, webhooks, apparence, staff) sont aussi
    modifiables en jeu depuis le panel ; ce fichier ne sert que de valeurs par
    défaut au premier lancement.
]]

FreshBan = {}

-- ---------------------------------------------------------------------------
-- Général
-- ---------------------------------------------------------------------------

FreshBan.ServerName = "Mon Serveur"                       -- Nom affiché dans les bans, logs et webhooks
FreshBan.BanPrefix  = "F"                                 -- Préfixe des Ban IDs (ex : F0001)
FreshBan.Discord    = "https://discord.gg/votre-invite"   -- Lien affiché au joueur banni
FreshBan.Framework  = "standalone"                        -- "standalone" | "esx" | "qbcore"

-- Mode développeur : vous apparaissez dans votre propre liste et pouvez vous
-- auto-bannir pour tester. À désactiver en production.
FreshBan.DevMode = true

-- ---------------------------------------------------------------------------
-- Commandes
-- ---------------------------------------------------------------------------

FreshBan.Commands = {
    Ban     = "freshban",   -- /freshban [id] [durée] [raison]
    Unban   = "funban",     -- /funban [banId] | /funban all
    PermBan = "fpermban",   -- /fpermban  (affiche vos permissions)
    MenuBan = "fmenuban",   -- /fmenuban  (ouvre le panel)
    BanList = "fbanlist",   -- /fbanlist  (ouvre le panel sur l'onglet bans)
}

-- ---------------------------------------------------------------------------
-- Base de données
-- ---------------------------------------------------------------------------
-- Les tables sont créées automatiquement au démarrage (oxmysql requis).

FreshBan.Database = {
    TableName = "freshban_bans",
    LogTable  = "freshban_logs",
}

-- ---------------------------------------------------------------------------
-- Permissions & grades
-- ---------------------------------------------------------------------------
-- Attribution recommandée (sans ACE) :
--   1. Un code s'affiche dans la console au premier démarrage.
--   2. En jeu : /fbsetup <code>  ->  vous devenez propriétaire (superadmin).
--   3. Panel > Paramètres : liez vos rôles Discord aux grades.
--
-- Les grades ci-dessous définissent uniquement les permissions de chaque rang.

FreshBan.Permissions = {
    Enabled = true,   -- false = accès complet pour tous (déconseillé)
    UseAce  = false,  -- true = accepter aussi les add_ace du server.cfg

    BasePermission = "freshban.use", -- utilisé seulement si UseAce = true

    -- Ordre de priorité, du plus haut au plus bas
    Priority = { "superadmin", "admin", "moderator" },

    Grades = {
        moderator = {
            Label          = "Modérateur",
            AcePermission  = "freshban.moderator",
            Color          = "#60a5fa",
            MaxDuration    = 1440,   -- minutes (24h). 0 = illimité
            CanUseFMenu    = true,
            CanKick        = true,
            CanViewBanList = false,
            CanPermBan     = false,
            CanUnban       = false,
            CanUnbanAll    = false,
            CanEditBan     = false,
            CanManagePanel = false,
        },
        admin = {
            Label          = "Administrateur",
            AcePermission  = "freshban.admin",
            Color          = "#f59e0b",
            MaxDuration    = 43200,  -- 30 jours
            CanUseFMenu    = true,
            CanKick        = true,
            CanViewBanList = true,
            CanPermBan     = false,
            CanUnban       = true,
            CanUnbanAll    = false,
            CanEditBan     = true,
            CanManagePanel = false,
        },
        superadmin = {
            Label          = "Super Admin",
            AcePermission  = "freshban.superadmin",
            Color          = "#ef4444",
            MaxDuration    = 0,       -- illimité
            CanUseFMenu    = true,
            CanKick        = true,
            CanViewBanList = true,
            CanPermBan     = true,
            CanUnban       = true,
            CanUnbanAll    = true,
            CanEditBan     = true,
            CanManagePanel = true,
        },
    },
}

-- Clés de permission éditables depuis le panel (liste blanche anti-injection).
-- Toute clé absente de cette liste est refusée côté serveur.
FreshBan.PermissionKeys = {
    { key = "CanUseFMenu",    label = "Ouvrir le menu",  desc = "Accès au menu /fmenuban" },
    { key = "CanViewBanList", label = "Voir les bans",   desc = "Accès à l'onglet Bannissements" },
    { key = "CanKick",        label = "Expulser",        desc = "Peut kick un joueur" },
    { key = "CanPermBan",     label = "Ban permanent",   desc = "Autorise les bans définitifs" },
    { key = "CanUnban",       label = "Débannir",        desc = "Peut lever un ban" },
    { key = "CanUnbanAll",    label = "Unban global",    desc = "Peut tout débannir (/funban all)" },
    { key = "CanEditBan",     label = "Éditer un ban",   desc = "Modifier durée / raison" },
    { key = "CanManagePanel", label = "Gérer le panel",  desc = "Grades, webhooks, apparence" },
}

-- ---------------------------------------------------------------------------
-- Intégration Discord (optionnelle)
-- ---------------------------------------------------------------------------
-- Affiche le pseudo + l'avatar Discord du staff et permet de lier des rôles
-- Discord à des grades. Le token reste côté serveur, jamais envoyé au client.
--
-- Mise en place :
--   1. https://discord.com/developers/applications  (New Application > Bot)
--   2. Onglet Bot : Reset Token, puis activez "Server Members Intent"
--   3. Invitez le bot sur votre serveur (scope : bot)
--   4. Mode développeur Discord > clic droit sur le serveur > Copier l'ID

FreshBan.DiscordBot = {
    Enabled  = false,
    BotToken = "",   -- token du bot (secret)
    GuildId  = "",   -- id du serveur Discord

    -- Liaison rôle Discord -> grade. Également gérable depuis le panel.
    RoleGrades = {
        -- ["000000000000000000"] = "superadmin",
        -- ["000000000000000000"] = "admin",
    },
}

-- ---------------------------------------------------------------------------
-- Webhook Discord (logs)
-- ---------------------------------------------------------------------------
-- Webhook par défaut. Vous pouvez définir une URL par type d'action
-- (ban / unban / kick / admin) directement dans le panel.

FreshBan.Webhook = {
    Enabled   = true,
    URL       = "",              -- webhook global par défaut
    BotName   = "FreshBan",      -- nom du bot affiché dans Discord
    AvatarURL = "",              -- avatar du bot (laisser vide pour l'avatar par défaut)
    Color     = 16711680,        -- couleur des embeds (décimal)

    LogBan      = true,
    LogUnban    = true,
    LogUnbanAll = true,
    LogKick     = true,
}

-- ---------------------------------------------------------------------------
-- Message de ban (affiché au joueur refusé)
-- ---------------------------------------------------------------------------
-- Variables : {server_name} {ban_id} {reason} {staff} {expire_date} {time_left} {discord}

FreshBan.BanMessage = [[

====================================
            VOUS ETES BANNI
====================================

  Serveur    : {server_name}
  ID de ban  : {ban_id}

  Raison     : {reason}
  Banni par  : {staff}

  Expire     : {expire_date}
  Restant    : {time_left}

  Contester  : {discord}

====================================
]]

-- ---------------------------------------------------------------------------
-- Panel & durées
-- ---------------------------------------------------------------------------

FreshBan.Menu = {
    NewPlayerThreshold = 60,     -- minutes avant de perdre le tag NEW . En Minutes donc la 60 pour 60 minute 
    NearbyRadius       = 500.0,  -- mètres pour le filtre "Proches"
}

FreshBan.QuickDurations = {
    { label = "30min",    value = "30min" },
    { label = "1h",       value = "1h" },
    { label = "6h",       value = "6h" },
    { label = "12h",      value = "12h" },
    { label = "1 jour",   value = "1j" },
    { label = "3 jours",  value = "3j" },
    { label = "7 jours",  value = "7j" },
    { label = "14 jours", value = "14j" },
    { label = "1 mois",   value = "1m" },
    { label = "PERM",     value = "0" },
}

-- ---------------------------------------------------------------------------
-- Apparence par défaut (modifiable en jeu)
-- ---------------------------------------------------------------------------

FreshBan.Appearance = {
    PrimaryColor = "#e85d75",    -- couleur d'accent
    AccentColor  = "#f0a050",    -- couleur secondaire

    BackgroundMode  = "glass",   -- "glass" (transparent) | "solid" (couleur unie)
    BackgroundColor = "#14161e", -- fond en mode solid
    GlassAlpha      = 0.30,      -- opacité du verre (0.10 = très transparent)
    BlurGame        = true,      -- floute le jeu derrière le panel en mode glass

    Presets = {
        "#e85d75", "#f0a050", "#4ade80", "#60a5fa",
        "#a78bfa", "#ef4444", "#14b8a6", "#ec4899",
    },
}

-- ---------------------------------------------------------------------------
-- Unban global (/funban all)
-- ---------------------------------------------------------------------------

FreshBan.UnbanAll = {
    Enabled          = true,
    RequireWhitelist = true,   -- limite /funban all aux identifiants ci-dessous
    WhitelistedIdentifiers = {
        -- "license:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    },
}
