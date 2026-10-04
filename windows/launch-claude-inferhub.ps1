$ErrorActionPreference = "Stop"

# InferHub Claude Code launcher via the UNIFIED local LiteLLM proxy
# (CKFF + InferHub groups), run from this repository's shared\litellm folder.
# Picks main + advisor from IRE Top 20, seats aliases (sonnet/opus), points
# Claude at 127.0.0.1:4000. The proxy is keyless and bound to 127.0.0.1 only.
# Never sets CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1.
# Source of truth: Pukujan/claude-code-launcher windows\ (see SOURCES.md).

$Root = "D:\development"   # default project root (listed first in folder picker)
$SecondaryRoot = "C:\work" # secondary project root, listed after the default root
$RepoRoot = Split-Path -Parent $PSScriptRoot           # this repository
$LiteLLMRoot = Join-Path $RepoRoot "shared\litellm"     # proxy config + scripts
$LiteLLMOps = Join-Path $PSScriptRoot "litellm"         # start/stop scripts
$ProxyPort = 4000
$ProxyBase = "http://127.0.0.1:$ProxyPort"
$DefaultModelId = "cb/deepseek-v4.1-flash"
$CkffEnvFile = "C:\Users\pujan\OneDrive\Desktop\configs\.env"
# InferHub env: first existing file wins (IRE .env, then repo .env, then user config).
$InferHubEnvCandidates = @(
  "D:\development\inference-recommendation-engine\.env",
  (Join-Path $RepoRoot ".env"),
  (Join-Path $env:USERPROFILE ".config\inferhub\.env")
)
$InferHubEnvFile = $InferHubEnvCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $InferHubEnvFile) { $InferHubEnvFile = $InferHubEnvCandidates[0] }

# HOOK(ire-models): the picker table. It matches shared\litellm\config\top20-builtin.csv
# (tests\test_top20_tables.py checks that). An IRE fetch can replace these rows.
$Models = @(
  @{ Rank = 1;  Name = "DeepSeek V4.1 Flash";        Id = "cb/deepseek-v4.1-flash";              Eligible = $true;  Cost = "0.022" }
  @{ Rank = 2;  Name = "GLM 5.3 Flash";              Id = "cbcn/glm-5.3-flash";                  Eligible = $true;  Cost = "0.033" }
  @{ Rank = 3;  Name = "Gemini 3.8 Flash";           Id = "ag/gemini-3.8-flash-high";            Eligible = $false; Cost = "0.066" }
  @{ Rank = 4;  Name = "DeepSeek V4 Flash";          Id = "cbcn/deepseek-v4-flash";              Eligible = $true;  Cost = "0.047" }
  @{ Rank = 5;  Name = "DeepSeek V4 Pro 0813";       Id = "ali/deepseek-v4-pro-0813";            Eligible = $false; Cost = "0.083" }
  @{ Rank = 6;  Name = "Qwen3.8 Max 0902";           Id = "ali/qwen3.8-max-0902";                Eligible = $false; Cost = "0.078" }
  @{ Rank = 7;  Name = "Qwen3.8 Flash";              Id = "ali/qwen3.8-flash";                   Eligible = $true;  Cost = "0.008" }
  @{ Rank = 8;  Name = "Muse Spark 1.3 Contributor"; Id = "cmc/meta/muse-spark-1.3-contributor"; Eligible = $false; Cost = "0.040" }
  @{ Rank = 9;  Name = "GPT 5.6 Luna";               Id = "cx/gpt-5.6-luna";                     Eligible = $false; Cost = "0.040" }
  @{ Rank = 10; Name = "MiniMax M3";                 Id = "cbcn/minimax-m3";                     Eligible = $true;  Cost = "0.052" }
  @{ Rank = 11; Name = "DeepSeek V4 Flash 0731";     Id = "ali/deepseek-v4-flash-0731";          Eligible = $false; Cost = "0.091" }
  @{ Rank = 12; Name = "Gemini 3.7 Flash";           Id = "ag/gemini-3.7-flash-high";            Eligible = $false; Cost = "0.077" }
  @{ Rank = 13; Name = "Gemini 3.6 Flash";           Id = "ag/gemini-3.6-flash-high";            Eligible = $false; Cost = "0.081" }
  @{ Rank = 14; Name = "DeepSeek V4 Pro";            Id = "cbcn/deepseek-v4-pro";                Eligible = $true;  Cost = "0.138" }
  @{ Rank = 15; Name = "GLM 5.2";                    Id = "ali/glm-5.2";                         Eligible = $true;  Cost = "0.181" }
  @{ Rank = 16; Name = "Hy4 Preview";                Id = "cb/hy4-preview";                      Eligible = $false; Cost = "0.077" }
  @{ Rank = 17; Name = "Muse Spark 1.2 Contributor"; Id = "cmc/meta/muse-spark-1.2-contributor"; Eligible = $false; Cost = "0.029" }
  @{ Rank = 18; Name = "Qwen 3.8 Max";               Id = "ali/qwen3.8-max";                     Eligible = $true;  Cost = "0.170" }
  @{ Rank = 19; Name = "GLM 5.3";                    Id = "cbcn/glm-5.3";                        Eligible = $true;  Cost = "0.267" }
  @{ Rank = 20; Name = "Kimi K2.7 Code";             Id = "ali/kimi-k2.7-code";                  Eligible = $true;  Cost = "0.156" }
)

function Read-EnvValue {
  param([string]$Path, [string]$Name)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match ("^\s*" + [regex]::Escape($Name) + "\s*=") } | Select-Object -First 1
  if (-not $line) { return $null }
  return ($line -replace ("^\s*" + [regex]::Escape($Name) + "\s*=\s*"), "").Trim().Trim('"').Trim("'")
}

function Read-LiteLLMMasterKey {
  # The proxy is keyless by default. If a LITELLM_MASTER_KEY is set, pass it
  # through; otherwise Claude Code still needs some key value, so use "local".
  foreach ($f in @($CkffEnvFile, $InferHubEnvFile)) {
    $key = Read-EnvValue -Path $f -Name "LITELLM_MASTER_KEY"
    if ($key) { return $key }
  }
  return "local"
}

function Read-MenuKey {
  if (-not $host.UI -or -not $host.UI.RawUI) {
    throw "This window has no console. Run it in PowerShell, not ISE."
  }
  return $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Clip-Line {
  param([string]$Text, [int]$Width)
  if ($null -eq $Text) { $Text = "" }
  if ($Width -lt 4) { $Width = 4 }
  if ($Text.Length -le $Width) { return $Text }
  return $Text.Substring(0, $Width - 3) + "..."
}

function Get-ConsoleLayout {
  param([int]$HelpCount = 2)
  $rows = 30
  $cols = 120
  try {
    if ([Console]::WindowHeight -gt 0) { $rows = [Console]::WindowHeight }
    if ([Console]::WindowWidth -gt 0) { $cols = [Console]::WindowWidth }
  } catch {}
  $used = 6 + $HelpCount
  $maxItems = $rows - $used
  if ($maxItems -lt 3) { $maxItems = 3 }
  if ($cols -lt 20) { $cols = 80 }
  return @{ Rows = $rows; Cols = $cols; MaxItems = $maxItems }
}

function Show-Picker {
  param(
    [string]$Title,
    [string[]]$Lines,
    [int]$Index,
    [string[]]$Help
  )
  if (-not $Help) { $Help = @() }
  if (-not $Lines) { $Lines = @() }
  $layout = Get-ConsoleLayout -HelpCount $Help.Count
  $width = $layout.Cols - 1
  $max = $layout.MaxItems
  if ($Lines.Count -gt 0 -and $max -gt $Lines.Count) { $max = $Lines.Count }
  if ($Lines.Count -gt 0 -and $max -lt 1) { $max = 1 }

  $start = 0
  if ($Lines.Count -gt $max) {
    $start = $Index - [Math]::Floor(($max - 1) / 2)
    if ($start -lt 0) { $start = 0 }
    $maxStart = $Lines.Count - $max
    if ($start -gt $maxStart) { $start = $maxStart }
  }

  $above = ""
  if ($start -gt 0) { $above = "  ... " + $start + " more above" }
  $shown = 0
  if ($Lines.Count -gt 0) { $shown = [Math]::Min($max, $Lines.Count - $start) }
  $belowCount = $Lines.Count - ($start + $shown)
  $below = ""
  if ($belowCount -gt 0) { $below = "  ... " + $belowCount + " more below" }

  Clear-Host
  try { [Console]::SetCursorPosition(0, 0) } catch {}
  Write-Host (Clip-Line $Title $width)
  Write-Host ""
  Write-Host (Clip-Line $above $width) -ForegroundColor DarkGray
  if ($Lines.Count -eq 0) {
    Write-Host "  (nothing to choose)"
  } else {
    for ($i = $start; $i -lt ($start + $shown); $i++) {
      $prefix = "  "
      if ($i -eq $Index) { $prefix = "> " }
      $text = Clip-Line ($prefix + $Lines[$i]) $width
      if ($i -eq $Index) {
        Write-Host $text -ForegroundColor Cyan
      } else {
        Write-Host $text
      }
    }
  }
  Write-Host (Clip-Line $below $width) -ForegroundColor DarkGray
  Write-Host ""
  foreach ($line in $Help) {
    Write-Host (Clip-Line $line $width)
  }
}

function Move-MenuIndex {
  param(
    [int]$Index,
    [int]$Count,
    [int]$KeyCode,
    [int]$PageSize
  )
  if ($Count -le 0) { return 0 }
  if ($PageSize -lt 1) { $PageSize = 1 }
  switch ($KeyCode) {
    38 { if ($Index -gt 0) { $Index-- } }
    40 { if ($Index -lt ($Count - 1)) { $Index++ } }
    33 { $Index = [Math]::Max(0, $Index - $PageSize) }
    34 { $Index = [Math]::Min($Count - 1, $Index + $PageSize) }
    36 { $Index = 0 }
    35 { $Index = $Count - 1 }
  }
  return $Index
}

function Get-ProjectDirs([string]$Path) {
  return @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike ".*" } |
    Sort-Object Name)
}

function Select-MainModel {
  $lines = @(foreach ($m in $Models) {
    $tag = $(if ($m.Eligible) { "eligible" } else { "gated" })
    $star = $(if ($m.Id -eq $DefaultModelId) { "*" } else { " " })
    "{0}{1,2}  {2,-28} {3,-42} {4}  ~{5}/Mtok" -f $star, $m.Rank, $m.Name, $m.Id, $tag, $m.Cost
  })
  $help = @(
    "MAIN executor (maps to alias sonnet/main). Up/Down/PgUp/PgDn/Home/End. Enter. Esc quits.",
    "gated = ranked but not currently recommendation-eligible."
  )
  $index = 0
  while ($true) {
    Show-Picker -Title "Choose MAIN model (IRE Top 20). Default DeepSeek V4.1 Flash." -Lines $lines -Index $index -Help $help
    $key = Read-MenuKey
    $page = (Get-ConsoleLayout -HelpCount $help.Count).MaxItems
    if ($key.VirtualKeyCode -eq 13) { return $Models[$index] }
    if ($key.VirtualKeyCode -eq 27) { throw "Cancelled." }
    $index = Move-MenuIndex -Index $index -Count $lines.Count -KeyCode $key.VirtualKeyCode -PageSize $page
  }
}

function Select-AdvisorModel {
  $off = @{ Rank = 0; Name = "OFF (no advisor)"; Id = ""; Eligible = $true; Cost = "-" }
  $choices = @($off) + $Models
  $lines = @(foreach ($m in $choices) {
    if ($m.Id -eq "") { "   OFF  (disable advisor tool / seat aliases fall back to main)" }
    else {
      $tag = $(if ($m.Eligible) { "eligible" } else { "gated" })
      "{0,2}  {1,-28} {2,-42} {3}  ~{4}/Mtok" -f $m.Rank, $m.Name, $m.Id, $tag, $m.Cost
    }
  })
  $help = @(
    "ADVISOR model (maps to alias opus/advisor) or OFF. Enter selects. Esc quits.",
    "Mid-session use /advisor opus or /advisor sonnet (aliases), not raw InferHub ids."
  )
  $index = 0
  while ($true) {
    Show-Picker -Title "Choose ADVISOR model (IRE Top 20) or OFF." -Lines $lines -Index $index -Help $help
    $key = Read-MenuKey
    $page = (Get-ConsoleLayout -HelpCount $help.Count).MaxItems
    if ($key.VirtualKeyCode -eq 13) { return $choices[$index] }
    if ($key.VirtualKeyCode -eq 27) { throw "Cancelled." }
    $index = Move-MenuIndex -Index $index -Count $lines.Count -KeyCode $key.VirtualKeyCode -PageSize $page
  }
}

function Confirm-Launch {
  param([string]$Folder)
  $lines = @(
    "Yes, launch Claude here",
    "No, pick a different folder"
  )
  $help = @("Up and Down move. Enter confirms. Esc quits.")
  $index = 0
  while ($true) {
    Show-Picker -Title ("Launch Claude Code in " + $Folder + " ?") -Lines $lines -Index $index -Help $help
    $key = Read-MenuKey
    if ($key.VirtualKeyCode -eq 13) { return ($index -eq 0) }
    if ($key.VirtualKeyCode -eq 27) { throw "Cancelled." }
    $index = Move-MenuIndex -Index $index -Count $lines.Count -KeyCode $key.VirtualKeyCode -PageSize 1
  }
}

function Get-ProjectEntries {
  # Default root ($Root = D:\development) first: the root itself, then its subfolders.
  # Then the secondary root ($SecondaryRoot = C:\work): the root itself, then its
  # subfolders. Get-ProjectDirs skips hidden/dot folders (.backups, .scratch, .tmp).
  $entries = @()
  if (Test-Path -LiteralPath $Root) {
    $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $entries += [pscustomobject]@{ Label = ($rootFull + "  (default root)"); FullName = $rootFull }
    foreach ($d in @(Get-ProjectDirs $rootFull)) {
      $entries += [pscustomobject]@{ Label = $d.FullName; FullName = $d.FullName }
    }
  }
  if ($SecondaryRoot -and (Test-Path -LiteralPath $SecondaryRoot)) {
    $secFull = (Resolve-Path -LiteralPath $SecondaryRoot).Path.TrimEnd('\')
    $entries += [pscustomobject]@{ Label = ("[C:\work] " + $secFull + "  (secondary root)"); FullName = $secFull }
    foreach ($d in @(Get-ProjectDirs $secFull)) {
      $entries += [pscustomobject]@{ Label = ("[C:\work] " + $d.FullName); FullName = $d.FullName }
    }
  }
  return $entries
}

function Select-ProjectFolder {
  $entries = @(Get-ProjectEntries)
  if ($entries.Count -eq 0) { throw "No project folders: neither $Root nor $SecondaryRoot exists" }
  $dirs = $entries
  $lines = @($entries | ForEach-Object { $_.Label })
  $help = @(
    "Up, Down, Page Up, Page Down, Home, End. Enter chooses this folder. Esc quits.",
    "Default root $Root first, then [C:\work] folders under $SecondaryRoot. Confirm before launch."
  )
  $index = 0
  while ($true) {
    Show-Picker -Title ("Choose a project folder (default root " + $Root + ")") -Lines $lines -Index $index -Help $help
    $key = Read-MenuKey
    $page = (Get-ConsoleLayout -HelpCount $help.Count).MaxItems
    if ($key.VirtualKeyCode -eq 27) { throw "Cancelled." }
    if ($key.VirtualKeyCode -eq 13) {
      $chosen = $dirs[$index].FullName
      if (Confirm-Launch -Folder $chosen) { return $chosen }
      continue
    }
    $index = Move-MenuIndex -Index $index -Count $lines.Count -KeyCode $key.VirtualKeyCode -PageSize $page
  }
}

function Sync-ModelPicker {
  param([string]$MainId, [string]$SeatAlias)
  $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
  if (-not (Test-Path -LiteralPath $settingsPath)) { return }
  $options = @(
    [ordered]@{
      model = $SeatAlias
      label = "InferHub seat (sonnet alias)"
      description = "Maps to seated Top 20 main via local LiteLLM"
      behavesAs = "claude-sonnet-5"
    }
    [ordered]@{
      model = "opus"
      label = "InferHub seat (opus/advisor alias)"
      description = "Maps to seated Top 20 advisor via local LiteLLM"
      behavesAs = "claude-opus-4-6"
    }
  )
  foreach ($m in $Models) {
    $options += [ordered]@{
      model = ("ih/" + $m.Id)
      label = ($m.Name + " (InferHub ih/)")
      description = ("IRE Top 20 #" + $m.Rank + "; " + $(if ($m.Eligible) { "eligible" } else { "gated" }) + " - prefer sonnet/opus seats for advisor")
      behavesAs = "claude-sonnet-5"
    }
  }
  try {
    $json = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.modelPicker) {
      $json | Add-Member -NotePropertyName modelPicker -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $json.modelPicker = [pscustomobject]@{ options = $options }
    $json.model = $SeatAlias
    # Advisor must use InferHub seat alias (opus), not a raw Anthropic id that
    # could resolve via CKFF if BASE_URL ever leaked.
    $json.advisorModel = "opus"
    $out = $json | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($settingsPath, $out + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  } catch {
    Write-Host ("warning: could not sync model picker: " + $_.Exception.Message)
  }
}

function Test-ProxyHealth {
  # Prefer /health/liveliness: /health can 500 on local setups without prisma,
  # and unauthenticated /v1/models also 500s when a master key is set.
  foreach ($path in @("/health/liveliness", "/health/readiness", "/health/liveness")) {
    try {
      $r = Invoke-WebRequest -Uri ($ProxyBase + $path) -UseBasicParsing -TimeoutSec 2
      if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
    } catch { }
  }
  return $false
}

function Ensure-LiteLLMProxy {
  if (Test-ProxyHealth) {
    Write-Host "LiteLLM proxy already up at $ProxyBase"
    return
  }
  $starter = Join-Path $LiteLLMOps "start-litellm.ps1"
  if (-not (Test-Path -LiteralPath $starter)) {
    throw "Missing $starter - this launcher must run from a claude-code-launcher checkout"
  }
  Write-Host "Starting unified LiteLLM proxy (background)..."
  $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$starter`" -Background -SkipSync -Port $ProxyPort -CkffEnvFile `"$CkffEnvFile`" -InferHubEnvFile `"$InferHubEnvFile`""
  $starterProc = Start-Process -FilePath "powershell.exe" -ArgumentList $arg -WindowStyle Hidden -PassThru
  $null = $starterProc.Handle   # cache handle so ExitCode is readable after exit (PS 5.1)
  $deadline = (Get-Date).AddSeconds(300)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-ProxyHealth) {
      Write-Host "LiteLLM proxy is healthy at $ProxyBase"
      return
    }
    if ($starterProc.HasExited -and $starterProc.ExitCode -ne 0) {
      throw "start-litellm.ps1 failed (exit $($starterProc.ExitCode)); run it in a visible window to see why: cd $LiteLLMOps; .\start-litellm.ps1 -SkipSync"
    }
  }
  throw "LiteLLM proxy did not become healthy at $ProxyBase within 300s. Check $LiteLLMRoot\logs"
}

function Apply-InferHubSeat {
  param([string]$MainId, [string]$AdvisorId)
  $py = Join-Path $LiteLLMRoot ".litellm-venv\Scripts\python.exe"
  if (-not (Test-Path -LiteralPath $py)) {
    # venv may not exist yet; start script creates it. Write seat JSON for start script.
    $seatPath = Join-Path $LiteLLMRoot "config\inferhub_seat.json"
    $seat = @{
      main_inferhub_id = $MainId
      advisor_inferhub_id = $(if ($AdvisorId) { $AdvisorId } else { $null })
      updated_at = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json
    New-Item -ItemType Directory -Force -Path (Split-Path $seatPath) | Out-Null
    # UTF-8 without a BOM: PS 5.1's -Encoding UTF8 adds one and json.loads rejects it.
    [System.IO.File]::WriteAllText($seatPath, $seat, [System.Text.UTF8Encoding]::new($false))
    Write-Host "wrote seat file (venv not ready yet); proxy start will apply aliases"
    return
  }
  # reload_runtime.py reads an optional LITELLM_MASTER_KEY from these files.
  $env:CLAUDE_IH_ENV_FILES = (@($CkffEnvFile, $InferHubEnvFile) -join ";")
  $apply = Join-Path $LiteLLMRoot "scripts\apply_inferhub_seat.py"
  $merge = Join-Path $LiteLLMRoot "scripts\merge_litellm_config.py"
  $advArg = @()
  if ($AdvisorId) { $advArg = @("--advisor", $AdvisorId) } else { $advArg = @("--advisor", "") }
  & $py $apply --main $MainId @advArg
  if ($LASTEXITCODE -ne 0) { throw "apply_inferhub_seat.py failed" }
  if (Test-Path -LiteralPath (Join-Path $LiteLLMRoot "config\config.yaml")) {
    & $py $merge
    if ($LASTEXITCODE -ne 0) { throw "merge_litellm_config.py failed" }
  }
}

function Get-IreRecommendations {
  # HOOK(ire): shared\ire\ire_fetch.py pulls IRE's Top 20, price policy and any
  # fallback picks from GitHub (5 s budget), then falls back to the last good
  # copy and then built-in defaults. Never fatal. The JSON path goes into
  # $env:CCL_IRE_JSON for the ladder picker; schema in shared\ire\README.md.
  $helper = Join-Path $RepoRoot "shared\ire\ire_fetch.py"
  $base = $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME "AppData\Local" })
  $out = Join-Path $base "claude-code-launcher\ire.json"
  $pyArgs = @()
  $py = Join-Path $LiteLLMRoot ".litellm-venv\Scripts\python.exe"
  if (-not (Test-Path -LiteralPath $py)) {
    $cmd = Get-Command py -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source; $pyArgs = @("-3") }
    else {
      $cmd = Get-Command python -ErrorAction SilentlyContinue
      if (-not $cmd) { Write-Host "IRE: no Python found; using the built-in model table"; return }
      $py = $cmd.Source
    }
  }
  $ErrorActionPreference = "Continue"   # the helper reports on stderr; that is not a failure
  try {
    & $py @pyArgs $helper --out $out 2>&1 | ForEach-Object {
      $line = "$_"
      if ($line) { Write-Host ("IRE: " + ($line -replace '^\[ire\] ', '')) }
    }
  } catch {
    Write-Host "IRE: helper did not run; using the built-in model table"
  }
  if (Test-Path -LiteralPath $out) { $env:CCL_IRE_JSON = $out }
}

# ---- interactive flow ----
Get-IreRecommendations
$main = Select-MainModel
$advisor = Select-AdvisorModel
# HOOK(fallback-ladder): a ladder picker goes here, after the seats are chosen
# and before Apply-InferHubSeat. Today the ladders come from
# shared\litellm\config\inferhub_fallbacks.yaml unchanged.
$folder = Select-ProjectFolder

$advisorId = $advisor.Id
$advisorLabel = $(if ($advisorId) { $advisor.Name + " (" + $advisorId + ")" } else { "OFF" })

Apply-InferHubSeat -MainId $main.Id -AdvisorId $advisorId
Ensure-LiteLLMProxy

# Re-apply seat after proxy/venv exists, then ask for config reload by restarting if needed.
Apply-InferHubSeat -MainId $main.Id -AdvisorId $advisorId
# Soft note: LiteLLM may need restart to pick runtime.yaml changes if already running with old seat.
Write-Host "Seat applied. If proxy was already running with an old seat, restart it:"
Write-Host "  cd $LiteLLMOps; .\stop-litellm.ps1; .\start-litellm.ps1 -Background -InferHubEnvFile `"$InferHubEnvFile`""

$seatAlias = "sonnet"
Sync-ModelPicker -MainId $main.Id -SeatAlias $seatAlias
$master = Read-LiteLLMMasterKey

# Clear conflicting Anthropic / OAuth / CKFF / cortex tokens so the Claude
# child process cannot inherit User/Process CKFF BASE_URL or keys.
# Claude Code prefers ANTHROPIC_AUTH_TOKEN over ANTHROPIC_API_KEY when both exist.
$clearExact = @(
  "ANTHROPIC_AUTH_TOKEN",
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_BASE_URL",
  "ANTHROPIC_MODEL",
  "ANTHROPIC_SMALL_FAST_MODEL",
  "ANTHROPIC_DEFAULT_SONNET_MODEL",
  "ANTHROPIC_DEFAULT_OPUS_MODEL",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
  "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
  "CKFF_KIMI_KEY",
  "CKFF_API_KEY",
  "CKFF_DEFAULT_KEY",
  "ckff_access_token",
  "ckff_api_url",
  "ckff_alternate_api_url",
  "ckff_nonstream_api_url",
  "ckff_cortex_kimi_token_",
  "ckff_cortex_kimi_token_model",
  "ckff_cortex_embedder_rerank"
)
foreach ($n in $clearExact) {
  Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue
}
# Sweep any remaining ANTHROPIC_* / CLAUDE_CODE_* / ckff* leftovers
Get-ChildItem Env: | Where-Object {
  $_.Name -match '^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)'
} | ForEach-Object {
  Remove-Item ("Env:" + $_.Name) -ErrorAction SilentlyContinue
}

# Force InferHub-via-local-LiteLLM for this Claude child only.
# Key = optional LiteLLM master key, else the dummy "local" (keyless proxy). NEVER CKFF.
$env:ANTHROPIC_API_KEY = $master
$env:ANTHROPIC_BASE_URL = $ProxyBase   # always http://127.0.0.1:4000
$env:ANTHROPIC_MODEL = $seatAlias      # sonnet seat -> InferHub main
$env:ANTHROPIC_SMALL_FAST_MODEL = "ih/ali/qwen3.8-flash"
# Do NOT set ANTHROPIC_AUTH_TOKEN (would win over API_KEY and risk CKFF).
# Keep experimental betas ON - do not set CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS

Set-Location -LiteralPath $folder

Clear-Host
Write-Host ("cwd=" + (Get-Location))
Write-Host ("proxy=" + $env:ANTHROPIC_BASE_URL + "  (unified CKFF+InferHub LiteLLM)")
Write-Host ("small_fast=" + $env:ANTHROPIC_SMALL_FAST_MODEL + "  (InferHub cheap side model for search/hooks)")
Write-Host ("seat_alias=" + $seatAlias + "  behavesAs=claude-sonnet-5")
Write-Host ("main=" + $main.Id + "  (" + $main.Name + ")")
Write-Host ("advisor=" + $advisorLabel)
Write-Host "permission=bypassPermissions (auto mode is Anthropic-only)"
Write-Host "betas=experimental ON (advisor_20260301 via LiteLLM orchestration)"
Write-Host "Starting Claude Code..."
& claude --model $seatAlias --permission-mode bypassPermissions
Write-Host ("claude exited " + $LASTEXITCODE)
pause
