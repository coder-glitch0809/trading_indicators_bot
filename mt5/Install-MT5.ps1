param(
    [string]$TerminalDataPath,
    [string[]]$LegacyEnv = @(
        (Join-Path $PSScriptRoot '..\.private\legacy-server.env'),
        (Join-Path $PSScriptRoot '..\server\.env'))
)
# Installs AI Zone Trader into MetaTrader 5:
#   MQL5\Experts\AI_Zone_Trader\  <- EA (.ex5) and its source modules
#   MQL5\Files\AZT_Config.ini     <- Telegram token/chat and Claude/Gemini API keys (private)
# Old copies (Experts root, AZT_Telegram.ini, old preset) are moved to MQL5\Files\AZT_Backup_*.
# Secret values are never printed.
$ErrorActionPreference = 'Stop'
if (-not $TerminalDataPath) {
    $project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'MetaQuotes\Terminal') -Directory |
        Where-Object {
            $origin = Join-Path $_.FullName 'origin.txt'
            (Test-Path -LiteralPath $origin) -and
            -not ([IO.File]::ReadAllText($origin).Trim([char]0xFEFF, ' ', "`r", "`n").StartsWith($project))
        })
    if ($candidates.Count -ne 1) { throw 'Several MT5 terminals: pass -TerminalDataPath (MT5 > File > Open Data Folder).' }
    $TerminalDataPath = $candidates[0].FullName
}
$resolved = (Resolve-Path -LiteralPath $TerminalDataPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $resolved 'MQL5') -PathType Container)) {
    throw 'Target must be an existing MT5 data folder containing MQL5.'
}
$artifacts = @('AI_Zone_Trader_EA.ex5','AI_Zone_Trader_EA.mq5','AZT_Structure.mqh','AZT_History.mqh',
               'AZT_Telegram.mqh','AZT_Json.mqh','AZT_AI.mqh','AZT_Journal.mqh','AZT_Confluence.mqh')
foreach ($file in $artifacts) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { throw "Missing file: $file" }
}
$expertsRoot = Join-Path $resolved 'MQL5\Experts'
$experts = Join-Path $expertsRoot 'AI_Zone_Trader'
$files = Join-Path $resolved 'MQL5\Files'
foreach ($directory in @($experts,$files)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$backup = Join-Path $files ('AZT_Backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backup | Out-Null

# 1. Remove old copies so Navigator shows exactly one AI_Zone_Trader_EA.
$old = @('AI_Zone_Trader_EA.ex5','AI_Zone_Trader_EA.mq5','AI_Zone_Trader_Server_EA.ex5','AI_Zone_Trader_Server_EA.mq5',
         'AZT_Structure.mqh','AZT_History.mqh','AZT_Telegram.mqh','AZT_Json.mqh','AZT_AI.mqh','AZT_Journal.mqh','AZT_Confluence.mqh')
foreach ($file in $old) {
    $path = Join-Path $expertsRoot $file
    if (Test-Path -LiteralPath $path) { Move-Item -LiteralPath $path -Destination (Join-Path $backup $file) -Force }
}
$preset = Join-Path $resolved 'MQL5\Profiles\Presets\AZT_MT5_ONLY.set'
if (Test-Path -LiteralPath $preset) { Move-Item -LiteralPath $preset -Destination (Join-Path $backup 'AZT_MT5_ONLY.set') -Force }

# 2. Copy the EA into its own folder.
foreach ($file in $artifacts) {
    $target = Join-Path $experts $file
    if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination (Join-Path $backup $file) -Force }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $target -Force
}

# 3. Build AZT_Config.ini. Priority: existing AZT_Config.ini > old AZT_Telegram.ini > legacy .env files.
function Read-Settings([string]$path) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $path))) {
        if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$') {
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            if ($value) { $result[$Matches[1]] = $value }
        }
    }
    return $result
}
$config = Join-Path $files 'AZT_Config.ini'
$oldTelegram = Join-Path $files 'AZT_Telegram.ini'
# A filled AZT_Config.ini placed next to this script (e.g. copied to a VPS) is imported too.
$sources = @($config, (Join-Path $PSScriptRoot 'AZT_Config.ini'), $oldTelegram) + $LegacyEnv
$aliases = @{ 'ANTHROPIC_API_KEY' = 'CLAUDE_API_KEY'; 'BOT_TOKEN' = 'TELEGRAM_BOT_TOKEN'; 'CHAT_ID' = 'TELEGRAM_CHAT_ID' }
$keys = @('TELEGRAM_BOT_TOKEN','TELEGRAM_CHAT_ID','TELEGRAM_ADMIN_ID','CLAUDE_API_KEY','GEMINI_API_KEY','CLAUDE_MODEL','GEMINI_MODEL')
$values = @{}
foreach ($source in $sources) {
    $settings = Read-Settings $source
    foreach ($name in @($settings.Keys)) {
        $key = if ($aliases.ContainsKey($name)) { $aliases[$name] } else { $name }
        # Old server model names are outdated; models come only from AZT_Config.ini itself.
        if ($key -like '*_MODEL' -and $source -ne $config) { continue }
        if ($keys -contains $key -and -not $values.ContainsKey($key)) { $values[$key] = $settings[$name] }
    }
}
if (Test-Path -LiteralPath $config) { Copy-Item -LiteralPath $config -Destination (Join-Path $backup 'AZT_Config.ini') }
$text = @"
# AI Zone Trader - the ONLY settings file with secrets. Never share it.
# Location: MT5 > File > Open Data Folder > MQL5 > Files > AZT_Config.ini
# Format: NAME=value (no quotes, no spaces). Restart the EA after editing.

# Telegram: token from @BotFather, chat id of the chat that receives signals.
TELEGRAM_BOT_TOKEN=$($values['TELEGRAM_BOT_TOKEN'])
TELEGRAM_CHAT_ID=$($values['TELEGRAM_CHAT_ID'])
# Optional: only this Telegram user id may press KIRISH/BEKOR (needed in groups).
TELEGRAM_ADMIN_ID=$($values['TELEGRAM_ADMIN_ID'])

# Claude: https://console.anthropic.com/settings/keys
CLAUDE_API_KEY=$($values['CLAUDE_API_KEY'])
# Gemini: https://aistudio.google.com/apikey
GEMINI_API_KEY=$($values['GEMINI_API_KEY'])

# Optional model names (empty = claude-sonnet-5-5 / gemini-2.5-flash).
CLAUDE_MODEL=$($values['CLAUDE_MODEL'])
GEMINI_MODEL=$($values['GEMINI_MODEL'])
"@
[IO.File]::WriteAllText($config, $text, [Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $oldTelegram) { Move-Item -LiteralPath $oldTelegram -Destination (Join-Path $backup 'AZT_Telegram.ini') -Force }

Write-Output "EA installed:     $experts"
Write-Output "Settings file:    $config"
foreach ($key in @('TELEGRAM_BOT_TOKEN','TELEGRAM_CHAT_ID','CLAUDE_API_KEY','GEMINI_API_KEY')) {
    $state = if ($values.ContainsKey($key)) { 'filled' } else { 'EMPTY - fill it in' }
    Write-Output ("  {0,-19} {1}" -f $key, $state)
}
Write-Output "Old copies moved: $backup"
Write-Output 'Next in MT5: Tools > Options > Expert Advisors > Allow WebRequest for:'
Write-Output '  https://api.telegram.org   https://api.anthropic.com   https://generativelanguage.googleapis.com'
Write-Output 'Then: Navigator > Expert Advisors > Refresh > AI_Zone_Trader > AI_Zone_Trader_EA onto a chart.'
