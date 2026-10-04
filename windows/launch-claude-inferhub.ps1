$ErrorActionPreference = "Stop"

# InferHub Claude Code launcher via the local LiteLLM proxy (InferHub only;
# CKFF is off), run from this repository's shared\litellm folder. Claude Code's
# own model slots (sonnet, opus, fable, haiku) each get a chain of InferHub
# routes in the proxy (issue #53); the picks are saved and reused, so the picker
# only shows when you choose to change them. Points Claude at 127.0.0.1:4000 (packaged installs: the port in install.json).
# The proxy is keyless and bound to 127.0.0.1 only.
# Never sets CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1.
# Source of truth: Pukujan/claude-code-launcher windows\ (see SOURCES.md).

$RepoRoot = Split-Path -Parent $PSScriptRoot           # this repository
$LiteLLMRoot = Join-Path $RepoRoot "shared\litellm"     # proxy config + scripts
$LiteLLMOps = Join-Path $PSScriptRoot "litellm"         # start/stop scripts
$DefaultModelId = "cb/deepseek-v4.1-flash"

# ---- packaged mode (issue #61, docs/specs/windows-package.md) ----
# On when CCL_HOME is set (the claude-inferhub shim sets it) or install.json sits in
# the folder above this repository (install.ps1's layout). Then everything comes from
# the install folder: the key in secrets\inferhub.env, optional state\local.env, the
# port and instance id in install.json, the venv, logs and picks. None of the
# PC-specific lookups below are used.
function Get-CclHomeDir {
  if ($env:CCL_HOME) { return $env:CCL_HOME }
  $up = Split-Path -Parent $RepoRoot
  if ($up -and (Test-Path -LiteralPath (Join-Path $up "install.json"))) { return $up }
  return $null
}
$CclHome = Get-CclHomeDir
$Packaged = [bool]$CclHome
$CclState = $null
if ($Packaged) {
  try { $CclState = Get-Content -LiteralPath (Join-Path $CclHome "install.json") -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
# The installer's port and identity helpers (Get-CclPortState, Select-CclPort, ...).
$CclInstaller = Join-Path $PSScriptRoot "install.ps1"
if (Test-Path -LiteralPath $CclInstaller) {
  $cclPrevLib = $env:CCL_INSTALL_LIBRARY_ONLY
  $env:CCL_INSTALL_LIBRARY_ONLY = "1"
  . $CclInstaller
  if ($null -eq $cclPrevLib) { Remove-Item Env:CCL_INSTALL_LIBRARY_ONLY -ErrorAction SilentlyContinue } else { $env:CCL_INSTALL_LIBRARY_ONLY = $cclPrevLib }
  $ErrorActionPreference = "Stop"
}

if ($Packaged) {
  $Root = $HOME
  $SecondaryRoot = $null
  $ProxyPort = $(if ($CclState -and $CclState.port) { [int]$CclState.port } else { 4000 })
  $InstanceId = $(if ($CclState) { [string]$CclState.instance_id } else { "" })
  $VenvDir = Join-Path $CclHome "venv"
  $LogDir = Join-Path $CclHome "logs"
  $InferHubEnvFile = Join-Path $CclHome "secrets\inferhub.env"
  # The "other keys" file of the packaged install (e.g. TINYFISH_API_KEY); optional.
  $DesktopEnvFile = Join-Path $CclHome "state\local.env"
  $LocalEnvFile = $DesktopEnvFile
} else {
$Root = "D:\development"   # default project root (listed first in folder picker)
$SecondaryRoot = "C:\work" # secondary project root, listed after the default root
$ProxyPort = 4000
$InstanceId = ""
$VenvDir = Join-Path $LiteLLMRoot ".litellm-venv"
$LogDir = Join-Path $LiteLLMRoot "logs"
$LocalEnvFile = Join-Path $LiteLLMRoot ".env.local"
# Desktop env (other keys, e.g. web search; its ckff* names are never loaded
# while CKFF is off): first existing file wins. The real Desktop known
# folder comes first (it may or may not be redirected into OneDrive), then
# %USERPROFILE%\Desktop, then %OneDrive%\Desktop. No user name is hardcoded.
$DesktopDir = [Environment]::GetFolderPath('Desktop')
if (-not $DesktopDir) { $DesktopDir = Join-Path $env:USERPROFILE "Desktop" }
$DesktopEnvCandidates = @(
  (Join-Path $DesktopDir "configs\.env"),
  (Join-Path $env:USERPROFILE "Desktop\configs\.env")
)
if ($env:OneDrive) { $DesktopEnvCandidates += (Join-Path $env:OneDrive "Desktop\configs\.env") }
$DesktopEnvFile = $DesktopEnvCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $DesktopEnvFile) { $DesktopEnvFile = $DesktopEnvCandidates[0] }
# InferHub env: first existing file wins (IRE .env next to this repo, IRE .env
# under the project root, repo .env, then user config).
$InferHubEnvCandidates = @(
  (Join-Path (Split-Path -Parent $RepoRoot) "inference-recommendation-engine\.env"),
  (Join-Path $Root "inference-recommendation-engine\.env"),
  (Join-Path $RepoRoot ".env"),
  (Join-Path $env:USERPROFILE ".config\inferhub\.env")
)
$InferHubEnvFile = $InferHubEnvCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $InferHubEnvFile) { $InferHubEnvFile = $InferHubEnvCandidates[0] }
}
$ProxyBase = "http://127.0.0.1:$ProxyPort"
$VenvPy = Join-Path $VenvDir "Scripts\python.exe"

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
# Frontier picks (IRE frontier list, InferHub routes, not CKFF) offered under the
# Top 20 in the slot steps. Cost is the input price per 1M tokens.
$FrontierModels = @(
  @{ Rank = "F1"; Name = "GPT 6 Astra (272K ctx)";     Id = "cb/gpt-6-astra";                      Eligible = $true;  Cost = "0.050 in/0.25 out" }
  @{ Rank = "F2"; Name = "GPT 6.1 Sol";                Id = "cx/gpt-6.1-sol";                      Eligible = $true;  Cost = "0.018 in/0.09 out" }
)

# ---- Claude Code slots (issue #53) ----
# Same defaults as `slots:` in shared\litellm\config\inferhub_fallbacks.yaml
# (tests\test_slots.py checks that). Each chain is first model, then fallbacks.
$SlotOrder = @("sonnet", "opus", "fable", "haiku")
$SlotDefaults = [ordered]@{
  sonnet = @("cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/glm-5.3-flash")
  opus   = @("cb/gpt-6-astra", "cx/gpt-6.1-sol", "ali/qwen3.8-max-0902")
  fable  = @("cbcn/glm-5.3-flash", "ali/qwen3.8-flash", "cb/deepseek-v4.1-flash")
  haiku  = @("cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/glm-5.3-flash")
}
$SlotInfo = @{
  sonnet = "SONNET (main chat; the launcher model)"
  opus   = "OPUS (planning: the planner sub-agent runs here)"
  fable  = "FABLE (the advisor)"
  haiku  = "HAIKU (background calls and cheap sub-agents; must handle tools)"
}
# Claude Code's auto-compact window: GPT 6 Astra (the opus slot's first model) has 272K.
$AutoCompactWindow = "272000"

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
  foreach ($f in @($DesktopEnvFile, $InferHubEnvFile)) {
    $key = Read-EnvValue -Path $f -Name "LITELLM_MASTER_KEY"
    if ($key) { return $key }
  }
  return "local"
}

function Test-ClaudeAiLogin {
  # True when Claude Code is signed in with a claude.ai account (/login). Call it
  # after the Anthropic variables are cleared, so a key cannot mask the login.
  try {
    $raw = & claude auth status --json 2>$null | Out-String
    $st = $raw | ConvertFrom-Json
    return ($st.loggedIn -eq $true -and $st.authMethod -eq "claude.ai")
  } catch {
    return $false
  }
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

# ---- launch wizard (no typing) ----
# Steps: slots (use saved / change), then per slot (sonnet, opus, fable, haiku)
# its first, 2nd and 3rd model, then the folder and "launch with". Up/Down move,
# Enter picks and goes on, Left goes back a step (picks are remembered), Right
# goes on keeping the highlighted pick. Esc quits. Tests fill $script:NavKeys.
$script:NavKeys = $null
$script:NavQuiet = $false
$script:NavTrace = New-Object System.Collections.ArrayList

function Read-NavKey {
  if ($null -ne $script:NavKeys) {
    if ($script:NavKeys.Count -eq 0) { throw "test keys ran out" }
    $k = $script:NavKeys[0]; $script:NavKeys.RemoveAt(0)
    return [ConsoleKey]$k
  }
  return [Console]::ReadKey($true).Key
}

function Select-FromList {
  # One pointer list. Returns @{ Action = "pick"|"forward"|"back"; Index = n }.
  param([string]$Title, [string[]]$Lines, [int]$Index, [string[]]$Help)
  if ($Index -lt 0 -or $Index -ge $Lines.Count) { $Index = 0 }
  while ($true) {
    if (-not $script:NavQuiet) { Show-Picker -Title $Title -Lines $Lines -Index $Index -Help $Help }
    $k = Read-NavKey
    $page = (Get-ConsoleLayout -HelpCount $Help.Count).MaxItems
    switch ($k) {
      ([ConsoleKey]::Enter)      { return @{ Action = "pick"; Index = $Index } }
      ([ConsoleKey]::RightArrow) { return @{ Action = "forward"; Index = $Index } }
      ([ConsoleKey]::LeftArrow)  { return @{ Action = "back"; Index = $Index } }
      ([ConsoleKey]::Escape)     { throw "Cancelled." }
      default { $Index = Move-MenuIndex -Index $Index -Count $Lines.Count -KeyCode ([int]$k) -PageSize $page }
    }
  }
}

function Format-OldModelLine {
  param($m, [string]$Star = " ")
  $tag = $(if ($m.Eligible) { "eligible" } else { "gated" })
  "{0}{1,2}  {2,-28} {3,-42} {4}  ~{5}/Mtok" -f $Star, $m.Rank, $m.Name, $m.Id, $tag, $m.Cost
}

function Get-LastPicksPath {
  # Next to this script (windows\last-picks.json, git-ignored); in packaged mode
  # state\last-picks.json in the install folder. CCL_LAST_PICKS overrides (tests).
  if ($env:CCL_LAST_PICKS) { return $env:CCL_LAST_PICKS }
  if ($Packaged) { return (Join-Path $CclHome "state\last-picks.json") }
  return (Join-Path $PSScriptRoot "last-picks.json")
}

function Test-CkffModel {
  # CKFF is off (2026-10-04). Only ids with "ckff" in them are CKFF (ckff_astra,
  # claude-ckff-*, ckff/...). InferHub's cb/gpt-6-astra is an InferHub route.
  param([string]$Id)
  return ($Id -match 'ckff')
}

function Read-LastPicks {
  # The cache file's plain values (start_dir, launch, uc_orch, uc_worker). Empty when missing or unreadable.
  # The slot picks live in the same file under "slots" (Read-SlotPicks). The old
  # main/advisor seat keys (main, main1, adv, ...) are ignored and dropped on the next write.
  $out = @{}
  $p = Get-LastPicksPath
  if (-not (Test-Path -LiteralPath $p)) { return $out }
  # A saved CKFF model (any id with "ckff") is dropped, so that step falls back to its default.
  $modelSlots = @("main", "main1", "main2", "adv", "adv1", "adv2", "uc_orch", "uc_worker")
  try {
    $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $j.PSObject.Properties) {
      if ($null -eq $prop.Value -or -not ($prop.Value -is [string] -or $prop.Value -is [ValueType])) { continue }
      if ($modelSlots -contains $prop.Name -and (Test-CkffModel ([string]$prop.Value))) { continue }
      $out[$prop.Name] = [string]$prop.Value
    }
  } catch {}
  return $out
}

function Read-SlotPicks {
  # The saved slot chains: @{ sonnet = @(ids); opus; fable; haiku; haiku_same = $bool }, or $null
  # when nothing is saved yet (first run, or a file from before issue #53).
  $p = Get-LastPicksPath
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  if (-not $j -or -not $j.slots) { return $null }
  $out = @{ haiku_same = ($j.slots.haiku_same -eq $true) }
  foreach ($slot in $SlotOrder) {
    $chain = @($j.slots.$slot | Where-Object { $_ -and -not (Test-CkffModel ([string]$_)) } | ForEach-Object { [string]$_ })
    if ($chain.Count -eq 0) { $chain = @($SlotDefaults[$slot]) }
    $out[$slot] = $chain
  }
  if ($out.haiku_same) { $out.haiku = @($out.sonnet) }
  return $out
}

function Write-LastPicks {
  # Merge $Values into the cache file and write it back. $Slots (from the slot steps) replaces the saved slots.
  param($Values, $Slots = $null)
  $p = Get-LastPicksPath
  $c = Read-LastPicks
  foreach ($k in @($Values.Keys)) { $c[$k] = $Values[$k] }
  if ($null -eq $Slots) { $Slots = Read-SlotPicks }
  $o = [ordered]@{ version = 2 }
  if ($null -ne $Slots) {
    $so = [ordered]@{}
    foreach ($slot in $SlotOrder) { $so[$slot] = @($Slots[$slot]) }
    $so["haiku_same"] = [bool]$Slots.haiku_same
    $o["slots"] = $so
  }
  foreach ($k in @("start_dir", "launch", "uc_orch", "uc_worker")) { if ($c.ContainsKey($k)) { $o[$k] = $c[$k] } }
  try { [IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false)) } catch {}
}

function Get-DefaultSlots {
  $out = @{ haiku_same = $true }
  foreach ($slot in $SlotOrder) { $out[$slot] = @($SlotDefaults[$slot]) }
  if (-not @($out.sonnet)[0]) { $out.sonnet = @($DefaultModelId) }   # rank 1 if the table is ever emptied
  return $out
}

function Format-SlotChain {
  param($Chain)
  return (@($Chain) -join " -> ")
}

function Get-SlotSummary {
  param($Slots)
  return @(foreach ($slot in $SlotOrder) {
    $tag = $(if ($slot -eq "haiku" -and $Slots.haiku_same) { "  (same as sonnet)" } else { "" })
    ("{0,-7} {1}{2}" -f $slot, (Format-SlotChain $Slots[$slot]), $tag)
  })
}

function Get-StartPick {
  # Highlight for a step: this session's pick, else last session's (if still listed), else the default.
  param($S, $Last, [string]$Slot, $Choices, [string]$Default)
  $ids = @($Choices | ForEach-Object { $_.Id })
  if ($null -ne $S[$Slot] -and $ids -contains $S[$Slot]) { return $S[$Slot] }
  if ($null -ne $Last -and $Last.ContainsKey($Slot) -and $ids -contains $Last[$Slot]) { return $Last[$Slot] }
  return $Default
}

function Get-SlotChoices {
  return @(@($Models) + @($FrontierModels) | Where-Object { -not (Test-CkffModel $_.Id) })
}

function Invoke-SlotsChoiceStep {
  # Step 1 when slots are saved: use them (Enter) or change them. Returns @{ Action; Change = $bool }.
  param($Saved, [bool]$Change = $false)
  $lines = @("Use the saved slots") + @(Get-SlotSummary $Saved | ForEach-Object { "      " + $_ }) + @("Change the slots")
  $index = $(if ($Change) { $lines.Count - 1 } else { 0 })
  $help = @("Up/Down move. Enter picks. Right = next step (keeps the highlighted pick). Esc quits.",
            "The saved slots are used by every launch, Paseo included. Change them here any time.")
  $r = Select-FromList -Title "Step 1: model slots (sonnet = main, opus = planning, fable = advisor, haiku = background)" -Lines $lines -Index $index -Help $help
  $change = ($r.Index -eq ($lines.Count - 1))
  $script:NavTrace.Add(("  step slots  {0,-7} -> {1}" -f $r.Action, $(if ($r.Action -eq "back") { "(back)" } elseif ($change) { "change" } else { "use saved" }))) | Out-Null
  return @{ Action = $r.Action; Change = $change }
}

function Invoke-SlotStep {
  # One slot model step. $Rung 0 = first model, 1 = 2nd (fallback 1), 2 = 3rd (fallback 2).
  # Writes into $S.slots[$Slot] (and $S.slots.haiku_same). Returns the action.
  param([string]$Slot, [int]$Rung, $S)
  $chain = @($S.slots[$Slot])
  $dflt = $(if ($Rung -lt $chain.Count) { $chain[$Rung] } else { "" })
  $help = @("Up/Down move. Enter picks. Left = previous step, Right = next step (keeps the highlighted pick). Esc quits.",
            "F rows are frontier picks (InferHub, not CKFF). gated = ranked but not currently recommendation-eligible.")
  $all = @(Get-SlotChoices)
  if ($Rung -eq 0) {
    $choices = @($all)
    if ($Slot -eq "haiku") { $same = @{ Rank = 0; Name = "same"; Eligible = $true; Cost = "-" }; $same.Id = "@sonnet"; $choices = @($same) + $choices }
    $want = $(if ($Slot -eq "haiku" -and $S.slots.haiku_same) { "@sonnet" } else { $dflt })
    $title = "Slot " + $SlotInfo[$Slot] + ": first model.   now: " + (Format-SlotChain $chain)
  } else {
    $taken = @($chain[0..($Rung - 1)])
    $choices = @($all | Where-Object { $taken -notcontains $_.Id }) + @(@{ Rank = 0; Name = "none"; Id = ""; Eligible = $true; Cost = "-" })
    $want = $dflt
    $n = $(if ($Rung -eq 1) { "2nd" } else { "3rd" })
    $title = "Slot " + $SlotInfo[$Slot] + ": " + $n + " model (fallback " + $Rung + ") after " + $chain[$Rung - 1] + "   default: " + $(if ($dflt) { $dflt } else { "none" })
  }
  $lines = @(foreach ($m in $choices) {
    if ($m.Id -eq "@sonnet") { "   same chain as sonnet: " + (Format-SlotChain $S.slots.sonnet) }
    elseif ($m.Id -eq "") { "   none (no further fallback)" }
    else { Format-OldModelLine $m $(if ($m.Id -eq $dflt) { "*" } else { " " }) }
  })
  $index = 0
  for ($i = 0; $i -lt $choices.Count; $i++) { if ($choices[$i].Id -eq $want) { $index = $i; break } }
  $r = Select-FromList -Title $title -Lines $lines -Index $index -Help $help
  if ($r.Action -ne "back") {
    $pick = $choices[$r.Index].Id
    if ($pick -eq "@sonnet") {
      $S.slots.haiku_same = $true
      $S.slots.haiku = @($S.slots.sonnet)
    } else {
      if ($Slot -eq "haiku" -and $Rung -eq 0) { $S.slots.haiku_same = $false }
      $new = @($chain | Select-Object -First $Rung)
      if ($pick) {
        $new += $pick
        # keep the rest of the old chain after the pick, minus repeats
        $new += @($chain | Select-Object -Skip ($Rung + 1) | Where-Object { $new -notcontains $_ })
      }
      $S.slots[$Slot] = @($new | Select-Object -First 3)
      if ($Slot -eq "sonnet" -and $S.slots.haiku_same) { $S.slots.haiku = @($S.slots.sonnet) }
    }
  }
  $script:NavTrace.Add(("  step {0}{1} {2,-7} -> {3}" -f $Slot, $Rung, $r.Action, $(if ($r.Action -eq "back") { "(back)" } else { Format-SlotChain $S.slots[$Slot] }))) | Out-Null
  return $r.Action
}

function Get-StartDir {
  # Folder step start: start_dir saved with the D key (cache file), else D:\development
  # (not in packaged mode), else home.
  $c = Read-LastPicks
  $candidates = $(if ($Packaged) { @($c["start_dir"], $HOME) } else { @($c["start_dir"], "D:\development", $HOME) })
  foreach ($d in $candidates) {
    if ($d -and (Test-Path -LiteralPath $d -PathType Container)) { return (Resolve-Path -LiteralPath $d).Path }
  }
  return ""
}

function Get-FolderView {
  # Entries for one level: the drive list when $Path is empty, else the
  # (non-dot) subfolders of $Path.
  param([string]$Path)
  if (-not $Path) {
    return @(foreach ($d in [IO.DriveInfo]::GetDrives()) {
      if ($d.IsReady -and ($d.DriveType -eq "Fixed" -or $d.DriveType -eq "Network" -or $d.DriveType -eq "Removable")) {
        [pscustomobject]@{ Label = $d.Name; FullName = $d.RootDirectory.FullName }
      }
    })
  }
  return @(foreach ($d in @(Get-ProjectDirs $Path)) {
    [pscustomobject]@{ Label = ($d.Name + "\"); FullName = $d.FullName }
  })
}

function Step-FolderNav {
  # One key of the folder step. $State = @{ Path; Index }; Path "" = drive list.
  # Returns @{ Done = $false }, @{ Done = $true; Path = <dir> } for a pick, or
  # @{ Done = $true; Back = $true } for Backspace (back to the model steps).
  param($State, [ConsoleKey]$Key, [int]$PageSize = 10)
  $view = @(Get-FolderView -Path $State.Path)
  switch ($Key) {
    ([ConsoleKey]::RightArrow) {
      if ($view.Count -gt 0) { $State.Path = $view[$State.Index].FullName; $State.Index = 0 }
    }
    ([ConsoleKey]::Backspace) { return @{ Done = $true; Back = $true } }   # back to the last model step
    ([ConsoleKey]::D) {
      # Highlighted folder (or this one) becomes this PC's default start folder.
      $d = $(if ($view.Count -gt 0) { $view[$State.Index].FullName } else { $State.Path })
      if ($d) { Write-LastPicks @{ start_dir = $d }; $State.Message = "Default start folder set: " + $d }
    }
    ([ConsoleKey]::LeftArrow) {
      if (-not $State.Path) { return @{ Done = $false } }                  # drive list: nothing above
      $child = $State.Path.TrimEnd('\')
      if ($child -match '^[A-Za-z]:$') { $parent = "" }          # D:\ -> drive list
      else { $parent = [IO.Path]::GetDirectoryName($child) }       # D:\development -> D:\
      $State.Path = $parent
      $State.Index = 0
      $up = @(Get-FolderView -Path $parent)
      for ($i = 0; $i -lt $up.Count; $i++) { if ($up[$i].FullName.TrimEnd('\') -eq $child) { $State.Index = $i; break } }
    }
    ([ConsoleKey]::Enter) {
      if ($view.Count -gt 0) { return @{ Done = $true; Path = $view[$State.Index].FullName } }
      if ($State.Path) { return @{ Done = $true; Path = $State.Path } }
    }
    ([ConsoleKey]::Escape) { throw "Cancelled." }
    default {
      # ConsoleKey values are virtual key codes: Up/Down/PgUp/PgDn/Home/End.
      $State.Index = Move-MenuIndex -Index $State.Index -Count $view.Count -KeyCode ([int]$Key) -PageSize $PageSize
    }
  }
  return @{ Done = $false }
}

function Invoke-FolderStep {
  # Folder step. Returns the folder, or $null when Backspace goes back to the models.
  param($State)
  $help = @(
    "Up/Down move. Right opens the highlighted folder. Left goes up a folder. Backspace: back to models. D: set default.",
    "Enter picks the highlighted folder (this folder when it has no subfolders). Esc quits."
  )
  while ($true) {
    $view = @(Get-FolderView -Path $State.Path)
    $page = (Get-ConsoleLayout -HelpCount $help.Count).MaxItems
    if ($State.Index -ge $view.Count) { $State.Index = 0 }
    if (-not $script:NavQuiet) {
      $title = "Step 7: choose a project folder.   " + $(if ($State.Path) { $State.Path } else { "(drives)" })
      $lines = @($view | ForEach-Object { $_.Label })
      if ($lines.Count -eq 0) { $lines = @() }
      $h = $(if ($State.Message) { @($help) + $State.Message } else { $help })
      Show-Picker -Title $title -Lines $lines -Index $State.Index -Help $h
    }
    $k = Read-NavKey
    $r = Step-FolderNav -State $State -Key $k -PageSize $page
    $script:NavTrace.Add(("  folder key={0,-10} at {1}{2}" -f $k, $(if ($State.Path) { $State.Path } else { "(drives)" }), $(if ($k -eq [ConsoleKey]::D) { "   [" + $State.Message + "]" } else { "" }))) | Out-Null
    if ($r.Done) {
      if ($r.Back) { return $null }
      return $r.Path
    }
  }
}

function Invoke-LaunchStep {
  # Launch with Claude Code (default) or UltraCode (then Steps 9 and 10).
  # Returns "claude", "ultracode", or $null when Left goes back to the folder.
  param($Last = @{})
  $ids = @("claude", "ultracode")
  $index = $(if ($Last["launch"] -eq "ultracode") { 1 } else { 0 })
  $r = Select-FromList -Title "Step 8: launch with" -Lines @("Claude Code", "UltraCode (pick an orchestrator and a worker next)") -Index $index `
    -Help @("Up/Down move. Enter launches. Left = back to the folder. Esc quits.")
  $script:NavTrace.Add(("  step launch  {0,-7} -> {1}" -f $r.Action, $(if ($r.Action -eq "back") { "(back)" } else { $ids[$r.Index] }))) | Out-Null
  if ($r.Action -eq "back") { return $null }
  return $ids[$r.Index]
}

function Invoke-LaunchWizard {
  # Returns @{ Slots; Folder; Launch; UcOrch; UcWorker }. With saved slots, Step 1
  # offers them (Enter keeps them); otherwise the slot steps run with the defaults
  # highlighted, so Enter all the way through takes Alex's default chains.
  $saved = Read-SlotPicks
  $S = @{ slots = $(if ($saved) { $saved } else { Get-DefaultSlots }); uc_orch = $null; uc_worker = $null; change = ($null -eq $saved) }
  $last = Read-LastPicks
  $folderState = @{ Path = (Get-StartDir); Index = 0; Message = "" }
  $steps = @("slots")
  foreach ($slot in $SlotOrder) { foreach ($r in 0, 1, 2) { $steps += ($slot + ":" + $r) } }
  $steps += @("folder", "launch", "uc_orch", "uc_worker")
  $i = 0; $dir = 1; $folder = $null; $launch = $null
  while ($i -lt $steps.Count) {
    if ($i -lt 0) { $i = 0 }
    $step = $steps[$i]
    if ($step -eq "slots") {
      if (-not $saved) { $S.change = $true; $i += 1; $dir = 1; continue }   # first run: straight to the slot steps
      $r = Invoke-SlotsChoiceStep -Saved $S.slots -Change $S.change
      $S.change = $r.Change
      $i++; $dir = 1; continue
    }
    if ($step -match '^(\w+):(\d)$') {
      $slot = $matches[1]; $rung = [int]$matches[2]
      $chain = @($S.slots[$slot])
      $skip = (-not $S.change) -or ($rung -gt 0 -and $chain.Count -lt $rung) -or ($slot -eq "haiku" -and $rung -gt 0 -and $S.slots.haiku_same)
      if ($skip) { $i += $dir; continue }
      $action = Invoke-SlotStep -Slot $slot -Rung $rung -S $S
      if ($action -eq "back") { $dir = -1; $i-- } else { $dir = 1; $i++ }
      continue
    }
    if ($step -eq "folder") {
      $folder = Invoke-FolderStep -State $folderState
      if ($folder) { $dir = 1; $i++; continue }
      $dir = -1; $i--; $folderState = @{ Path = (Get-StartDir); Index = 0; Message = "" }; continue
    }
    if ($step -eq "launch") {
      # Coming back from Step 9 highlights this session's pick, not last time's.
      $launch = Invoke-LaunchStep -Last $(if ($launch) { @{ launch = $launch } } else { $last })
      if (-not $launch) { $dir = -1; $i--; continue }
      if ($launch -ne "ultracode") { break }
      $dir = 1; $i++; continue
    }
    if ($step -eq "uc_orch" -or $step -eq "uc_worker") {
      $action = Invoke-UltraCodeStep -Slot $step -S $S -Last $last
      if ($action -eq "back") { $dir = -1; $i-- } else { $dir = 1; $i++ }
      continue
    }
  }
  $picks = @{ launch = $launch }
  if ($launch -eq "ultracode") { $picks["uc_orch"] = $S.uc_orch; $picks["uc_worker"] = $(if ($S.uc_worker) { $S.uc_worker } else { "" }) }
  Write-LastPicks $picks -Slots $S.slots
  return @{ Slots = $S.slots; Folder = $folder; Launch = $launch; UcOrch = $S.uc_orch; UcWorker = $S.uc_worker }
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

function Select-ProjectFolderNumbered {
  # Input is redirected (no console keys): plain numbered list.
  $entries = @(Get-ProjectEntries)
  if ($entries.Count -eq 0) { throw "No project folders: neither $Root nor $SecondaryRoot exists" }
  for ($i = 0; $i -lt $entries.Count; $i++) { Write-Host ("{0,3}. {1}" -f ($i + 1), $entries[$i].Label) }
  $ans = Read-Host "Folder number"
  $n = 0
  if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 1 -or $n -gt $entries.Count) { throw "Cancelled." }
  return $entries[$n - 1].FullName
}

function Sync-ModelPicker {
  # Claude Code's settings.json ($CLAUDE_CONFIG_DIR or ~/.claude): the /model picker lists
  # the four slots (then the direct ih/ models), the model stays sonnet, and the advisor is
  # the fable slot. shared\claude\settings_sync.py creates the file when it is missing and
  # keeps every other key (issue #61). Nothing here touches plan mode or permissions.
  # Its notes go to stderr only, so --print-env output stays clean. Never fatal.
  param([string]$SeatAlias)
  $options = @(
    [ordered]@{ model = $SeatAlias; label = "Sonnet slot (main)"; description = "Main chat chain via local LiteLLM"; behavesAs = "claude-sonnet-5" }
    [ordered]@{ model = "opus"; label = "Opus slot (planning)"; description = "Planning chain via local LiteLLM"; behavesAs = "claude-opus-5-5" }
    [ordered]@{ model = "fable"; label = "Fable slot (advisor)"; description = "Advisor chain via local LiteLLM"; behavesAs = "claude-fable-5" }
    [ordered]@{ model = "haiku"; label = "Haiku slot (background)"; description = "Background chain via local LiteLLM"; behavesAs = "claude-haiku-4-5-20251001" }
  )
  foreach ($m in $Models) {
    $options += [ordered]@{
      model = ("ih/" + $m.Id)
      label = ($m.Name + " (InferHub ih/)")
      description = ("IRE Top 20 #" + $m.Rank + "; " + $(if ($m.Eligible) { "eligible" } else { "gated" }) + " - direct, no slot chain")
      behavesAs = "claude-sonnet-5"
    }
  }
  $py = Get-LadderPython
  if (-not $py) { [Console]::Error.WriteLine("warning: no Python found; settings.json not synced"); return }
  $helper = Join-Path $RepoRoot "shared\claude\settings_sync.py"
  $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "ccl-picker-" + [guid]::NewGuid().ToString("N") + ".json")
  $prev = $ErrorActionPreference
  try {
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject @($options) -Depth 5), [Text.UTF8Encoding]::new($false))
    $ErrorActionPreference = "Continue"
    $out = & $py $helper sync ("--options-file=" + $tmp) 2>&1
    foreach ($line in @($out)) { if ("$line".Trim()) { [Console]::Error.WriteLine([string]$line) } }
  } catch {
    [Console]::Error.WriteLine("warning: could not sync model picker: " + $_.Exception.Message)
  } finally {
    $ErrorActionPreference = $prev
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
}

function Invoke-PlannerInstall {
  # The planner sub-agent (~/.claude/agents/planner.md, model opus, read-only) and
  # the CLAUDE.md line that hands planning to it (shared\claude\install_planner.py).
  # Idempotent; never fatal. CCL_PLANNER=off skips it. Action: install or uninstall.
  param([string]$Action = "install", [switch]$Quiet)
  if ($Action -eq "install" -and $env:CCL_PLANNER -eq "off") { return 0 }
  $py = Get-LadderPython
  if (-not $py) { [Console]::Error.WriteLine("planner: no Python found; planner sub-agent not " + $Action + "ed"); return 1 }
  $helper = Join-Path $RepoRoot "shared\claude\install_planner.py"
  $a = @($Action); if ($Quiet) { $a += "--quiet" }
  $ErrorActionPreference = "Continue"
  $out = & $py $helper @a 2>&1
  $rc = $LASTEXITCODE
  foreach ($line in @($out)) { if ($line) { [Console]::Error.WriteLine([string]$line) } }
  return $rc
}

# ---- UltraCode (optional "launch with" target) ----
# OnlyTerp/UltraCode-Shim (MIT, standard-library Python) runs Claude Code with
# two models: the ORCHESTRATOR (the main loop) and the WORKER (every parallel
# sub-agent and background call). It is fetched on demand at a pinned commit
# into a per-user cache (never vendored here) and run from there with its own
# bin\ultracode.cmd. The global `ultracode` command is never installed or
# changed. shared\ultracode\uc_models.py writes the cache's config.json (the
# InferHub seats, UltraCode's own usable options without CKFF, and the IRE Top
# 20, all through LiteLLM) and preselects the two picks from Steps 9 and 10.
$UltraCodeCommit = "1870e58e2622c8946c9c7cd45483aa47d7bd5867"

function Get-UltraCodeShim {
  $base = $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME "AppData\Local" })
  $dir = Join-Path $base "claude-code-launcher\ultracode-shim"
  $stamp = Join-Path $dir ".commit"
  if ((Test-Path -LiteralPath (Join-Path $dir "proxy.py")) -and (Get-Content -LiteralPath $stamp -ErrorAction SilentlyContinue) -eq $UltraCodeCommit) { return $dir }
  Write-Host ("Fetching UltraCode-Shim " + $UltraCodeCommit.Substring(0, 7) + " ...")
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ultracode-" + [guid]::NewGuid().ToString("N"))
  $zip = $tmp + ".zip"
  Invoke-WebRequest -UseBasicParsing -Uri ("https://github.com/OnlyTerp/UltraCode-Shim/archive/" + $UltraCodeCommit + ".zip") -OutFile $zip
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path (Split-Path $dir) | Out-Null
  Move-Item -LiteralPath (Join-Path $tmp ("UltraCode-Shim-" + $UltraCodeCommit)) -Destination $dir
  Set-Content -LiteralPath $stamp -Value $UltraCodeCommit -Encoding ASCII
  Remove-Item -LiteralPath $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
  return $dir
}

function Get-UltraCodePort {
  # The shim's own proxy port: 4241 + the LiteLLM port (8241 for 4000). Not the
  # shim's default 8141, so a standalone ultracode on that port is never reused.
  return (4241 + $ProxyPort)
}

function Invoke-UcModels {
  # Runs shared\ultracode\uc_models.py with uv (stdlib only, no project). Its
  # notes go to stderr; stdout is returned. Values go as --name=value so
  # Windows PowerShell 5.1 does not drop empty arguments.
  param([string[]]$UcArgs)
  $uv = Get-Command uv -ErrorAction SilentlyContinue
  if (-not $uv) { throw "UltraCode needs uv (https://docs.astral.sh/uv/) to run shared\ultracode\uc_models.py" }
  $helper = Join-Path $RepoRoot "shared\ultracode\uc_models.py"
  $ErrorActionPreference = "Continue"   # the helper reports on stderr; that is not a failure
  $out = & $uv.Source run --no-project python $helper @UcArgs
  if ($LASTEXITCODE -ne 0) { throw "uc_models.py $($UcArgs[0]) failed (exit $LASTEXITCODE)" }
  return $out
}

function Get-UltraCodeChoices {
  # Writes the cache's config.json and returns the choices (@{ Id; Label }) for
  # Steps 9 and 10. Rebuilt only when the sonnet or fable slot's first model changes.
  param($S)
  $mainId = "" + @($S.slots.sonnet)[0]
  $advId = "" + @($S.slots.fable)[0]
  $key = $mainId + "|" + $advId
  if ($script:UcChoices -and $script:UcChoicesKey -eq $key) { return $script:UcChoices }
  $dir = Get-UltraCodeShim
  $mainName = "" + (@(Get-SlotChoices) | Where-Object { $_.Id -eq $mainId } | Select-Object -First 1).Name
  $advName = $(if ($advId) { "" + (@(Get-SlotChoices) | Where-Object { $_.Id -eq $advId } | Select-Object -First 1).Name } else { "" })
  $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "ccl-uc-" + [guid]::NewGuid().ToString("N"))
  $top = $tmp + "-top20.txt"
  $list = $tmp + "-choices.tsv"
  $rows = @(foreach ($m in $Models) { "{0}|{1}|{2}|{3}|{4}" -f $m.Rank, $m.Name, $m.Id, $(if ($m.Eligible) { "true" } else { "false" }), $m.Cost })
  [IO.File]::WriteAllLines($top, [string[]]$rows, [Text.UTF8Encoding]::new($false))
  try {
    $null = Invoke-UcModels @("build", ("--example=" + (Join-Path $dir "config.example.json")), ("--top20=" + $top),
      ("--proxy-base=" + $ProxyBase), ("--port=" + (Get-UltraCodePort)), ("--main-name=" + $mainName),
      ("--advisor-name=" + $advName), ("--config-out=" + (Join-Path $dir "config.json")), ("--list-out=" + $list))
    $choices = @(foreach ($line in [IO.File]::ReadAllLines($list, [Text.Encoding]::UTF8)) {
      $parts = $line.Split([char]9, 2)
      if ($parts.Count -eq 2 -and $parts[0]) { [pscustomobject]@{ Id = $parts[0]; Label = $parts[1] } }
    })
  } finally {
    Remove-Item -LiteralPath $top, $list -ErrorAction SilentlyContinue
  }
  if ($choices.Count -eq 0) { throw "uc_models.py offered no UltraCode models" }
  $script:UcChoices = $choices
  $script:UcChoicesKey = $key
  return $choices
}

function Invoke-UltraCodeStep {
  # Step 9 (uc_orch) or Step 10 (uc_worker), after "launch with" = UltraCode.
  # Writes the pick to $S ("" = worker same as orchestrator).
  param([string]$Slot, $S, $Last = @{})
  $choices = @(Get-UltraCodeChoices -S $S)
  if ($Slot -eq "uc_worker") {
    $choices = @([pscustomobject]@{ Id = ""; Label = "Same as orchestrator" }) + $choices
    $title = "Step 10: UltraCode WORKER (runs every parallel sub-agent and background call)."
    $dflt = ""
  } else {
    $title = "Step 9: UltraCode ORCHESTRATOR (runs the main loop)."
    $dflt = "claude-ih-main"
  }
  $lines = @($choices | ForEach-Object { $_.Label })
  $help = @("Up/Down move. Enter picks. Left = previous step, Right = next step (keeps the highlighted pick). Esc quits.",
            "Orchestrator = the main loop, worker = every parallel sub-agent. Everything goes through the local LiteLLM; CKFF is never offered.")
  $want = Get-StartPick -S $S -Last $Last -Slot $Slot -Choices $choices -Default $dflt
  $index = 0
  for ($i = 0; $i -lt $choices.Count; $i++) { if ($choices[$i].Id -eq $want) { $index = $i; break } }
  $r = Select-FromList -Title $title -Lines $lines -Index $index -Help $help
  if ($r.Action -ne "back") { $S[$Slot] = $choices[$r.Index].Id }
  $script:NavTrace.Add(("  step {0,-9} {1,-7} -> {2}" -f $Slot, $r.Action, $(if ($r.Action -eq "back") { "(back)" } elseif ($S[$Slot]) { $S[$Slot] } else { "(same)" }))) | Out-Null
  return $r.Action
}

function Invoke-UltraCode {
  # Preselects the orchestrator/worker pick (POST /uc/select when a shim with
  # this config already runs, else the shim's selection.json, read when its
  # proxy starts), then runs the cache's own bin\ultracode.cmd in the current
  # folder with the shim's TUI off and --model <orchestrator>. The shim starts,
  # reuses and stops its own proxy; its upstream is the local LiteLLM.
  param([string]$Orch, [string]$Worker, [string[]]$ClaudeArgs = @())
  if (-not $Orch) { throw "no UltraCode orchestrator picked" }
  $dir = Get-UltraCodeShim
  $config = Join-Path $dir "config.json"
  if (-not (Test-Path -LiteralPath $config)) { throw "UltraCode config.json missing; run the wizard again" }
  $state = Join-Path $env:LOCALAPPDATA "UltraCode-Shim\selection.json"
  $port = Invoke-UcModels @("preselect", ("--config=" + $config), ("--state-file=" + $state), ("--orch=" + $Orch), ("--worker=" + $Worker)) | Select-Object -Last 1
  Remove-Item Env:UC_UPSTREAM, Env:UC_LISTEN_PORT -ErrorAction SilentlyContinue   # config.json decides both
  $env:UC_SELECTOR = "0"   # Steps 9 and 10 replace the shim's own picker
  $uc = Join-Path $dir "bin\ultracode.cmd"
  Write-Host ("ultracode=" + $uc + "  (shim http://127.0.0.1:" + $port + " -> " + $ProxyBase + ")")
  Write-Host "Starting UltraCode..."
  & $uc --model $Orch @ClaudeArgs
}

function Test-ProxyHealth {
  # Packaged mode (issue #61): only this install's proxy counts (/ccl/identity names
  # our instance), so a LiteLLM someone else runs on the port is never used.
  # Prefer /health/liveliness: /health can 500 on local setups without prisma,
  # and unauthenticated /v1/models also 500s when a master key is set.
  if ($Packaged) { return ((Get-CclPortState -Port $ProxyPort -InstanceId $InstanceId) -eq "ours") }
  foreach ($path in @("/health/liveliness", "/health/readiness", "/health/liveness")) {
    try {
      $r = Invoke-WebRequest -Uri ($ProxyBase + $path) -UseBasicParsing -TimeoutSec 2
      if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
    } catch { }
  }
  return $false
}

function Resolve-CclPackagedPort {
  # Packaged mode: keep the saved port while it is free or ours; when another program
  # took it, move to the lowest free port from 4000, save it and re-register the task.
  if (-not $Packaged) { return }
  $probe = { param($p) Get-CclPortState -Port $p -InstanceId $InstanceId }
  $port = Select-CclPort -Start 4000 -Saved $ProxyPort -Probe $probe
  if ($port -ne $ProxyPort) {
    Write-Host ("Port " + $ProxyPort + " is taken by another program; moving the proxy to " + $port)
    $state = @{ ref = $CclState.ref; port = $port; instance_id = $InstanceId; claude_settings_created = [bool]$CclState.claude_settings_created }
    Write-CclInstallState -InstallDir $CclHome -State $state
    if (Test-CclTaskRegistered) { $null = Register-CclProxyTask -InstallDir $CclHome -Port $port }
    $script:ProxyPort = $port
    $script:ProxyBase = "http://127.0.0.1:$port"
  }
}

function Ensure-LiteLLMProxy {
  if ($Packaged) {
    if (Test-ProxyHealth) { Write-Host "LiteLLM proxy already up at $ProxyBase"; return }
    Write-Host "Starting the LiteLLM proxy (hidden)..."
    if (Start-CclProxy -InstallDir $CclHome -Port $ProxyPort -InstanceId $InstanceId) {
      Write-Host "LiteLLM proxy is healthy at $ProxyBase"
      return
    }
    throw "LiteLLM proxy did not come up at $ProxyBase. Check $LogDir"
  }
  if (Test-ProxyHealth) {
    Write-Host "LiteLLM proxy already up at $ProxyBase"
    return
  }
  $starter = Join-Path $LiteLLMOps "start-litellm.ps1"
  if (-not (Test-Path -LiteralPath $starter)) {
    throw "Missing $starter - this launcher must run from a claude-code-launcher checkout"
  }
  Write-Host "Starting unified LiteLLM proxy (background)..."
  $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$starter`" -Background -SkipSync -Port $ProxyPort -DesktopEnvFile `"$DesktopEnvFile`" -InferHubEnvFile `"$InferHubEnvFile`""
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
  # Writes the slot chains to the seat file and regenerates the proxy config
  # (apply_inferhub_seat.py + merge_litellm_config.py), then hot-reloads the
  # running proxy so the chains apply without a restart.
  param($Slots)
  $py = $VenvPy
  if (-not (Test-Path -LiteralPath $py)) {
    # venv may not exist yet; start script creates it. Write seat JSON for start script.
    $seatPath = Join-Path $LiteLLMRoot "config\inferhub_seat.json"
    $so = [ordered]@{}
    foreach ($slot in $SlotOrder) { $so[$slot] = @($Slots[$slot]) }
    $seat = [ordered]@{ version = 2; slots = $so; updated_at = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json -Depth 5
    New-Item -ItemType Directory -Force -Path (Split-Path $seatPath) | Out-Null
    # UTF-8 without a BOM: PS 5.1's -Encoding UTF8 adds one and json.loads rejects it.
    [System.IO.File]::WriteAllText($seatPath, $seat, [System.Text.UTF8Encoding]::new($false))
    Write-Host "wrote seat file (venv not ready yet); proxy start will apply the slots"
    return
  }
  # reload_runtime.py reads an optional LITELLM_MASTER_KEY from these files.
  $env:CLAUDE_IH_ENV_FILES = (@($DesktopEnvFile, $InferHubEnvFile) -join ";")
  $apply = Join-Path $LiteLLMRoot "scripts\apply_inferhub_seat.py"
  # --slot=name=a,b,c as one argument so Windows PowerShell 5.1 keeps it whole.
  $slotArgs = @(foreach ($slot in $SlotOrder) { "--slot=" + $slot + "=" + (@($Slots[$slot]) -join ",") })
  & $py $apply @slotArgs ("--base-url=" + $ProxyBase)
  if ($LASTEXITCODE -ne 0) { throw "apply_inferhub_seat.py failed" }
}

function Get-IreRecommendations {
  # HOOK(ire): shared\ire\ire_fetch.py pulls IRE's Top 20, price policy and any
  # fallback picks from GitHub (5 s budget), then falls back to the last good
  # copy and then built-in defaults. Never fatal. The JSON path goes into
  # $env:CCL_IRE_JSON for the ladder picker; schema in shared\ire\README.md.
  $helper = Join-Path $RepoRoot "shared\ire\ire_fetch.py"
  $base = $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME "AppData\Local" })
  $out = Join-Path $base "claude-code-launcher\ire.json"
  if ($Packaged) {
    $out = Join-Path $CclHome "state\ire.json"
    $env:CCL_IRE_CACHE_DIR = Join-Path $CclHome "state\ire"
  }
  $pyArgs = @()
  $py = $VenvPy
  if (-not (Test-Path -LiteralPath $py)) {
    $cmd = Get-Command py -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source; $pyArgs = @("-3") }
    else {
      $cmd = Get-Command python -ErrorAction SilentlyContinue
      if (-not $cmd) { return }
      $py = $cmd.Source
    }
  }
  $ErrorActionPreference = "Continue"   # the helper reports on stderr; that is not a failure
  try {
    $null = & $py @pyArgs $helper --out $out 2>&1   # silent: defaults are used quietly
  } catch {
  }
  if (Test-Path -LiteralPath $out) { $env:CCL_IRE_JSON = $out }
}

# ---- Python for the helpers ----
# (The per-seat fallback ladders of issue #5 are gone: every slot's chain is now
# generated into runtime.yaml by apply_inferhub_seat.py, issue #53.)
function Get-LadderPython {
  if (Test-Path -LiteralPath $VenvPy) { return $VenvPy }
  foreach ($name in @("python", "python3", "py")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

# ---- Claude Code environment ----
# One place for the variables the launcher hands to Claude Code, used by the
# interactive flow and by the non-interactive mode below.
# Clear conflicting Anthropic / OAuth / CKFF / cortex tokens so the Claude
# child process cannot inherit User/Process CKFF BASE_URL or keys.
# Claude Code prefers ANTHROPIC_AUTH_TOKEN over ANTHROPIC_API_KEY when both exist.
$ClaudeEnvClearNames = @(
  "ANTHROPIC_AUTH_TOKEN",
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_BASE_URL",
  "ANTHROPIC_MODEL",
  "ANTHROPIC_SMALL_FAST_MODEL",
  "ANTHROPIC_DEFAULT_SONNET_MODEL",
  "ANTHROPIC_DEFAULT_OPUS_MODEL",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  "ANTHROPIC_DEFAULT_FABLE_MODEL",
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
# Any remaining ANTHROPIC_* / CLAUDE_CODE_* / ckff* leftovers are swept too.
$ClaudeEnvSweepPrefixes = @("ANTHROPIC_", "CLAUDE_CODE_", "CKFF_", "ckff_")
$ClaudeEnvSweepPattern = '^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)'

function Initialize-ClaudeLaunchEnv {
  # Clears the inherited Anthropic/CKFF variables in this process and sets the
  # ones Claude Code needs for the local LiteLLM. Returns the auth line.
  param([string]$master, [string]$SeatAlias)
  foreach ($n in $ClaudeEnvClearNames) {
    Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue
  }
  Get-ChildItem Env: | Where-Object {
    $_.Name -match $ClaudeEnvSweepPattern
  } | ForEach-Object {
    Remove-Item ("Env:" + $_.Name) -ErrorAction SilentlyContinue
  }

  # Force InferHub-via-local-LiteLLM for this Claude child only.
  $env:ANTHROPIC_BASE_URL = $ProxyBase   # http://127.0.0.1:<port>; 4000 unless packaged or CCL_PROXY_PORT
  # Key = optional LiteLLM master key, else the dummy "local" (keyless proxy). NEVER CKFF.
  # Any key (ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN or apiKeyHelper) outranks the
  # claude.ai login, and Artifacts refuse to run without that login. So with a
  # keyless proxy and a claude.ai login, set no key: model traffic still goes to
  # ANTHROPIC_BASE_URL and the login rides along as the bearer the proxy ignores.
  if ($master -eq "local" -and (Test-ClaudeAiLogin)) {
    $authLine = "auth=claude.ai login (no API key, so Artifacts work)"
  } else {
    $env:ANTHROPIC_API_KEY = $master
    $authLine = $(if ($master -eq "local") { "auth=dummy API key (run /login with your claude.ai account to use Artifacts)" } else { "auth=LiteLLM master key (Artifacts need a keyless proxy)" })
  }
  $env:ANTHROPIC_MODEL = $SeatAlias      # sonnet: the main chat (never opusplan)
  # Pin every slot to a Claude-style name the proxy serves (scripts\slots.py maps
  # each to its chain). The pins keep the slots working when a Claude Code update
  # renames its defaults, and a sub-agent with "model: haiku" or "model: opus"
  # lands on its own slot. The deprecated ANTHROPIC_SMALL_FAST_MODEL is not set:
  # background calls use the haiku pin.
  $env:ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-5"            # sonnet slot (main)
  $env:ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-5-5"              # opus slot (planning)
  $env:ANTHROPIC_DEFAULT_FABLE_MODEL = "claude-fable-5"              # fable slot (the advisor)
  $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5-20251001"   # haiku slot (an id Claude Code knows)
  $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $AutoCompactWindow          # GPT 6 Astra's 272K window
  $env:CLAUDE_CODE_WORKFLOWS = "1"
  # Do NOT set ANTHROPIC_AUTH_TOKEN (would win over API_KEY and risk CKFF).
  # Keep experimental betas ON - do not set CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS
  return $authLine
}

# ---- non-interactive mode (issue: see README "Non-interactive mode") ----
# For tools that start Claude Code themselves (Paseo, scripts). No menus, no
# prompts, and the proxy is never started, restarted or reloaded: the seat the
# running proxy already has stays as it is. Turn it on with -NonInteractive /
# --non-interactive or CCL_NONINTERACTIVE=1. Then either
#   -PrintEnv json|dotenv (or CCL_PRINT_ENV)  prints the variables and exits, or
#   anything else                               runs claude with the remaining args.
# -Folder <dir> runs claude there (default: the current folder). Launcher options
# come first; "--" ends them. Exit codes: 2 bad option, 3 proxy not healthy.

function Read-LauncherOptions {
  param([string[]]$ArgList)
  $o = @{ NonInteractive = ($env:CCL_NONINTERACTIVE -eq "1"); PrintEnv = ""; Folder = ""; Rest = @(); Error = ""; Planner = "" }
  if ($env:CCL_PRINT_ENV) { $o.NonInteractive = $true; $o.PrintEnv = $env:CCL_PRINT_ENV }
  if (-not $ArgList) { $ArgList = @() }
  $i = 0
  while ($i -lt $ArgList.Count) {
    $a = $ArgList[$i]
    if ($a -eq "-NonInteractive" -or $a -eq "--non-interactive") { $o.NonInteractive = $true; $i++; continue }
    if ($a -eq "-UninstallPlanner" -or $a -eq "--uninstall-planner") { $o.Planner = "uninstall"; $i++; continue }
    if ($a -eq "-InstallPlanner" -or $a -eq "--install-planner") { $o.Planner = "install"; $i++; continue }
    if ($a -eq "-PrintEnv" -or $a -eq "--print-env") {
      if ($i + 1 -ge $ArgList.Count) { $o.Error = "$a needs json or dotenv"; break }
      $o.NonInteractive = $true; $o.PrintEnv = $ArgList[$i + 1]; $i += 2; continue
    }
    if ($a -eq "-Folder" -or $a -eq "--folder") {
      if ($i + 1 -ge $ArgList.Count) { $o.Error = "$a needs a folder"; break }
      $o.Folder = $ArgList[$i + 1]; $i += 2; continue
    }
    if ($a -eq "--") { $i++ }
    break
  }
  if ($i -lt $ArgList.Count) { $o.Rest = @($ArgList[$i..($ArgList.Count - 1)]) }
  if ($o.PrintEnv -and @("json", "dotenv") -notcontains $o.PrintEnv) { $o.Error = "print format must be json or dotenv, not '" + $o.PrintEnv + "'" }
  return $o
}

function Get-SeatInfo {
  # What the running proxy is seated with (shared\litellm\config\inferhub_seat.json,
  # written by the last interactive launch) and the saved slot picks. Read only.
  $seatPath = $(if ($env:CCL_SEAT_FILE) { $env:CCL_SEAT_FILE } else { Join-Path $LiteLLMRoot "config\inferhub_seat.json" })
  $seat = $null
  if (Test-Path -LiteralPath $seatPath) { try { $seat = Get-Content -LiteralPath $seatPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  $picks = Read-SlotPicks
  $proxySlots = [ordered]@{}
  $pickSlots = [ordered]@{}
  foreach ($slot in $SlotOrder) {
    $proxySlots[$slot] = $(if ($seat -and $seat.slots -and $seat.slots.$slot) { (@($seat.slots.$slot) -join ",") } else { "" })
    $pickSlots[$slot] = $(if ($picks) { (@($picks[$slot]) -join ",") } else { "" })
  }
  $info = [ordered]@{
    main = $(if ($proxySlots.sonnet) { $proxySlots.sonnet.Split(",")[0] } elseif ($seat -and $seat.main_inferhub_id) { [string]$seat.main_inferhub_id } elseif ($pickSlots.sonnet) { $pickSlots.sonnet.Split(",")[0] } else { "" })
    advisor = $(if ($proxySlots.fable) { $proxySlots.fable.Split(",")[0] } elseif ($seat) { [string]$seat.advisor_inferhub_id } else { "" })
    seat_source = $(if ($seat) { "seat file" } elseif ($picks) { "saved picks" } else { "none" })
    slots = $proxySlots
    picks = $pickSlots
  }
  return $info
}

function Format-ClaudeEnv {
  # The Claude Code variables now in this process, as json or dotenv text.
  param([string]$Format, $Info)
  $set = [ordered]@{}
  foreach ($e in @(Get-ChildItem Env: | Where-Object { $_.Name -match $ClaudeEnvSweepPattern } | Sort-Object Name)) { $set[$e.Name] = $e.Value }
  if ($Format -eq "dotenv") {
    $lines = @("# claude-code-launcher non-interactive env. Unset these first: " + ($ClaudeEnvClearNames -join " "),
               "# and every other name starting with " + ($ClaudeEnvSweepPrefixes -join ", "))
    foreach ($k in $Info.Keys) { $lines += ("# " + $k + "=" + $Info[$k]) }
    foreach ($k in $set.Keys) { $lines += ($k + "=" + $set[$k]) }
    return ($lines -join "`n")
  }
  $doc = [ordered]@{ set = $set; unset = @($ClaudeEnvClearNames); unset_prefixes = @($ClaudeEnvSweepPrefixes); info = $Info }
  return ($doc | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-NonInteractive {
  # Returns an exit code, or "exec" when claude should run with $Options.Rest.
  param($Options)
  $ProgressPreference = "SilentlyContinue"
  if ($Options.Error) { [Console]::Error.WriteLine("launch-claude-inferhub: " + $Options.Error); return 2 }
  if ($env:CCL_PROXY_PORT) { $script:ProxyPort = [int]$env:CCL_PROXY_PORT; $script:ProxyBase = "http://127.0.0.1:" + $script:ProxyPort }
  $healthy = Test-ProxyHealth
  if (-not $healthy -and $env:CCL_ALLOW_PROXY_DOWN -ne "1") {
    [Console]::Error.WriteLine("launch-claude-inferhub: the LiteLLM proxy at " + $ProxyBase + " is not answering. Non-interactive mode never starts it; run the launcher once or start it with windows\litellm\start-litellm.ps1.")
    return 3
  }
  $info = Get-SeatInfo
  if ($info.seat_source -eq "seat file") {
    foreach ($slot in $SlotOrder) {
      if ($info.picks[$slot] -and $info.slots[$slot] -and $info.picks[$slot] -ne $info.slots[$slot]) {
        [Console]::Error.WriteLine("launch-claude-inferhub: note: the saved " + $slot + " slot is " + $info.picks[$slot] + " but the proxy has " + $info.slots[$slot] + ". Non-interactive mode keeps the proxy's chains; run the launcher once to apply the saved picks.")
      }
    }
  }
  if (-not $Options.PrintEnv) { $null = Invoke-PlannerInstall -Quiet }
  # advisorModel=fable in settings.json for Paseo and other non-interactive callers too (issue #61).
  Sync-ModelPicker -SeatAlias "sonnet"
  $authLine = Initialize-ClaudeLaunchEnv -Master (Read-LiteLLMMasterKey) -SeatAlias "sonnet"
  $info["proxy_healthy"] = [bool]$healthy
  $info["auth"] = $authLine
  if ($Options.PrintEnv) {
    [Console]::Out.WriteLine((Format-ClaudeEnv -Format $Options.PrintEnv -Info $info))
    return 0
  }
  if ($Options.Folder) { Set-Location -LiteralPath $Options.Folder }
  return "exec"   # the caller runs claude at script level, so its console stays attached
}

function Get-CclLaunchConfig {
  # The resolved configuration (docs/specs/windows-package.md). Read only.
  $roots = @(@($Root, $SecondaryRoot) | Where-Object { $_ })
  $envFiles = $(if ($Packaged) { @($InferHubEnvFile, $LocalEnvFile) } else { @($DesktopEnvFile, $InferHubEnvFile, $LocalEnvFile) })
  return [ordered]@{
    Packaged = [bool]$Packaged
    Home = $CclHome
    Port = [int]$ProxyPort
    EnvFiles = @($envFiles | Where-Object { $_ } | Select-Object -Unique)
    ProjectRoots = $roots
    StartDir = (Get-StartDir)
    LastPicks = (Get-LastPicksPath)
    VenvDir = $VenvDir
    LogDir = $LogDir
    InstanceId = $InstanceId
  }
}

# ---- interactive flow ----
if ($env:CCL_LAUNCHER_LIBRARY_ONLY -eq "1") { return }   # tests dot-source the functions only
$LauncherOptions = Read-LauncherOptions -ArgList $args
if ($LauncherOptions.Planner) { exit (Invoke-PlannerInstall -Action $LauncherOptions.Planner) }
if ($LauncherOptions.NonInteractive -or $LauncherOptions.Error) {
  $niResult = Invoke-NonInteractive -Options $LauncherOptions
  if ($niResult -ne "exec") { exit $niResult }
  $claudeArgs = @($LauncherOptions.Rest)
  & claude @claudeArgs
  exit $LASTEXITCODE
}
Resolve-CclPackagedPort
Get-IreRecommendations
if ([Console]::IsInputRedirected) {
  # No console keys: the saved slots (or the defaults), numbered folder list.
  $saved = Read-SlotPicks
  $w = @{ Slots = $(if ($saved) { $saved } else { Get-DefaultSlots }); Launch = "claude" }
  $w.Folder = Select-ProjectFolderNumbered
} else {
  $w = Invoke-LaunchWizard
}
$folder = $w.Folder

Apply-InferHubSeat -Slots $w.Slots
Ensure-LiteLLMProxy

# Re-apply after the proxy/venv exists (the first apply may only have written the seat file).
Apply-InferHubSeat -Slots $w.Slots

$seatAlias = "sonnet"
Sync-ModelPicker -SeatAlias $seatAlias
$null = Invoke-PlannerInstall -Quiet
$master = Read-LiteLLMMasterKey

$authLine = Initialize-ClaudeLaunchEnv -Master $master -SeatAlias $seatAlias

Set-Location -LiteralPath $folder

Clear-Host
Write-Host ("cwd=" + (Get-Location))
Write-Host ("proxy=" + $env:ANTHROPIC_BASE_URL + "  (local LiteLLM, InferHub only; CKFF off)")
Write-Host "slots (Claude Code name -> chain):"
foreach ($line in @(Get-SlotSummary $w.Slots)) { Write-Host ("  " + $line) }
Write-Host "pins=sonnet:claude-sonnet-5 opus:claude-opus-5-5 fable:claude-fable-5 haiku:claude-haiku-4-5-20251001  advisor=fable  auto-compact=$AutoCompactWindow"
Write-Host $authLine
Write-Host "permission=bypassPermissions (auto mode is Anthropic-only)"
Write-Host "betas=experimental ON (advisor_20260301 via LiteLLM orchestration)"
if ($w.Launch -eq "ultracode") {
  Write-Host ("ultracode orchestrator=" + $w.UcOrch + "  worker=" + $(if ($w.UcWorker) { $w.UcWorker } else { "(same as orchestrator)" }))
  Invoke-UltraCode -Orch $w.UcOrch -Worker $w.UcWorker -ClaudeArgs @("--permission-mode", "bypassPermissions")
} else {
  Write-Host "Starting Claude Code..."
  & claude --model $seatAlias --permission-mode bypassPermissions
}
Write-Host ("claude exited " + $LASTEXITCODE)
pause
