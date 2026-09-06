-- Optionnel : les tables sont creees automatiquement au demarrage de la ressource.
-- Conserve ici pour reference / installation manuelle.
-- Schema FreshBan

CREATE TABLE IF NOT EXISTS `freshban_bans` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `ban_id` VARCHAR(16) NOT NULL UNIQUE,

    -- Joueur banni
    `target_name` VARCHAR(128) NOT NULL,
    `target_license` VARCHAR(128) NOT NULL,
    `target_steam` VARCHAR(64) DEFAULT NULL,
    `target_discord` VARCHAR(64) DEFAULT NULL,
    `target_xbl` VARCHAR(64) DEFAULT NULL,
    `target_live` VARCHAR(64) DEFAULT NULL,
    `target_fivem` VARCHAR(64) DEFAULT NULL,
    `target_ip` VARCHAR(64) DEFAULT NULL,
    `target_tokens` TEXT DEFAULT NULL,

    -- Staff
    `staff_name` VARCHAR(128) NOT NULL,
    `staff_license` VARCHAR(128) DEFAULT NULL,
    `staff_source` INT DEFAULT NULL,

    -- Ban info
    `reason` TEXT NOT NULL,
    `duration` INT NOT NULL DEFAULT 0,
    `expire_at` DATETIME DEFAULT NULL,
    `server_name` VARCHAR(128) DEFAULT NULL,

    -- Status
    `is_active` TINYINT(1) NOT NULL DEFAULT 1,
    `unbanned_by` VARCHAR(128) DEFAULT NULL,
    `unbanned_at` DATETIME DEFAULT NULL,

    -- Timestamps
    `banned_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    INDEX `idx_ban_id` (`ban_id`),
    INDEX `idx_license` (`target_license`),
    INDEX `idx_steam` (`target_steam`),
    INDEX `idx_discord` (`target_discord`),
    INDEX `idx_fivem` (`target_fivem`),
    INDEX `idx_ip` (`target_ip`),
    INDEX `idx_active` (`is_active`),
    INDEX `idx_expire` (`expire_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `freshban_logs` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `ban_id` VARCHAR(16) DEFAULT NULL,
    `action` VARCHAR(32) NOT NULL,
    `staff_name` VARCHAR(128) DEFAULT NULL,
    `staff_license` VARCHAR(128) DEFAULT NULL,
    `target_name` VARCHAR(128) DEFAULT NULL,
    `target_license` VARCHAR(128) DEFAULT NULL,
    `details` TEXT DEFAULT NULL,
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    INDEX `idx_ban_id` (`ban_id`),
    INDEX `idx_action` (`action`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `freshban_settings` (
    `setting_key` VARCHAR(64) NOT NULL PRIMARY KEY,
    `setting_value` LONGTEXT NOT NULL,
    `updated_by` VARCHAR(128) DEFAULT NULL,
    `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `freshban_staff` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `identifier` VARCHAR(128) NOT NULL UNIQUE,
    `grade_key` VARCHAR(64) NOT NULL,
    `display_name` VARCHAR(128) DEFAULT NULL,
    `added_by` VARCHAR(128) DEFAULT NULL,
    `added_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    INDEX `idx_identifier` (`identifier`),
    INDEX `idx_grade` (`grade_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
