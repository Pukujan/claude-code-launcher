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
# Desktop env (CKFF keys): first existing file wins. The real Desktop known
# folder comes first (it may or may not be redirected into OneDrive), then
# %USERPROFILE%\Desktop, then %OneDrive%\Desktop. No user name is hardcoded.
$DesktopDir = [Environment]::GetFolderPath('Desktop')
if (-not $DesktopDir) { $DesktopDir = Join-Path $env:USERPROFILE "Desktop" }
$CkffEnvCandidates = @(
  (Join-Path $DesktopDir "configs\.env"),
  (Join-Path $env:USERPROFILE "Desktop\configs\.env")
)
if ($env:OneDrive) { $CkffEnvCandidates += (Join-Path $env:OneDrive "Desktop\configs\.env") }
$CkffEnvFile = $CkffEnvCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $CkffEnvFile) { $CkffEnvFile = $CkffEnvCandidates[0] }
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
# Steps: MAIN model, MAIN 2nd (fallback 1), MAIN 3rd (fallback 2), ADVISOR model
# (or OFF), ADVISOR 2nd, ADVISOR 3rd, folder. Up/Down move, Enter picks and
# goes on, Left goes back a step (picks are remembered), Right goes on keeping
# the highlighted pick. Esc quits. Tests fill $script:NavKeys with key names.
$script:NavKeys = $null
$script:NavQuiet = $false
$script:NavTrace = New-Object System.Collections.ArrayList
$script:ChainCache = @{}

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

function Get-DefaultChain {
  # Default fallbacks for a seat primary, from shared\ladder (cached). Falls
  # back to the next Top 20 rows when Python is missing.
  param([string]$Role, [string]$PrimaryId)
  $ck = $Role + "|" + $PrimaryId
  if ($script:ChainCache.ContainsKey($ck)) { return $script:ChainCache[$ck] }
  $chain = @()
  $py = Get-LadderPython
  if ($py) {
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "ccl-chain-" + [guid]::NewGuid().ToString("N") + ".json")
    $extra = @(); if (-not $env:CCL_IRE_JSON) { $extra = @("--no-ire") }
    $ErrorActionPreference = "Continue"
    $null = & $py $LadderCli choose @extra --state $tmp --role $Role ("--primary=" + $PrimaryId) --non-interactive 2>&1
    try { $chain = @((Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json).$Role.fallbacks) } catch {}
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
  if ($chain.Count -eq 0) { $chain = @($Models | Where-Object { $_.Id -ne $PrimaryId -and $_.Eligible } | Select-Object -First 2 | ForEach-Object { $_.Id }) }
  $script:ChainCache[$ck] = $chain
  return $chain
}

function Get-LastPicksPath {
  # Next to this script (windows\last-picks.json, git-ignored). CCL_LAST_PICKS overrides (tests).
  if ($env:CCL_LAST_PICKS) { return $env:CCL_LAST_PICKS }
  return (Join-Path $PSScriptRoot "last-picks.json")
}

function Read-LastPicks {
  # The cache file (model picks by slot, "" = OFF/none, plus start_dir). Empty when missing or unreadable.
  $out = @{}
  $p = Get-LastPicksPath
  if (-not (Test-Path -LiteralPath $p)) { return $out }
  try {
    $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $j.PSObject.Properties) { if ($null -ne $prop.Value) { $out[$prop.Name] = [string]$prop.Value } }
  } catch {}
  return $out
}

function Write-LastPicks {
  # Merge $Values into the cache file and write it back.
  param($Values)
  $p = Get-LastPicksPath
  $c = Read-LastPicks
  foreach ($k in @($Values.Keys)) { $c[$k] = $Values[$k] }
  $o = [ordered]@{}
  foreach ($k in @("main", "main1", "main2", "adv", "adv1", "adv2", "start_dir", "launch", "uc_orch", "uc_worker")) { if ($c.ContainsKey($k)) { $o[$k] = $c[$k] } }
  try { [IO.File]::WriteAllText($p, ($o | ConvertTo-Json), [Text.UTF8Encoding]::new($false)) } catch {}
}

function Save-LastPicks {
  param($S)
  $v = @{}
  foreach ($k in @("main", "main1", "main2", "adv", "adv1", "adv2")) { $v[$k] = $(if ($null -ne $S[$k]) { $S[$k] } else { "" }) }
  Write-LastPicks $v
}

function Get-StartPick {
  # Highlight for a step: this session's pick, else last session's (if still listed), else the default.
  param($S, $Last, [string]$Slot, $Choices, [string]$Default)
  $ids = @($Choices | ForEach-Object { $_.Id })
  if ($null -ne $S[$Slot] -and $ids -contains $S[$Slot]) { return $S[$Slot] }
  if ($null -ne $Last -and $Last.ContainsKey($Slot) -and $ids -contains $Last[$Slot]) { return $Last[$Slot] }
  return $Default
}

function Invoke-ModelStep {
  # A model step. $Slot: main, main1, main2, adv, adv1, adv2. Writes the pick to $S.
  param([string]$Slot, $S, $Last = @{})
  $role = $(if ($Slot -like "main*") { "main" } else { "advisor" })
  $seat = $(if ($role -eq "main") { "MAIN" } else { "ADVISOR" })
  $help = @("Up/Down move. Enter picks. Left = previous step, Right = next step (keeps the highlighted pick). Esc quits.")
  if ($Slot -eq "main") {
    $choices = @($Models)
    $lines = @(foreach ($m in $choices) { Format-OldModelLine $m $(if ($m.Id -eq $DefaultModelId) { "*" } else { " " }) })
    $want = Get-StartPick -S $S -Last $Last -Slot $Slot -Choices $choices -Default $DefaultModelId
    $title = "Step 1: choose MAIN model (IRE Top 20). Default DeepSeek V4.1 Flash."
    $help += "MAIN executor (maps to alias sonnet/main). gated = ranked but not currently recommendation-eligible."
  } elseif ($Slot -eq "adv") {
    $choices = @(@{ Rank = 0; Name = "OFF (no advisor)"; Id = ""; Eligible = $true; Cost = "-" }) + $Models
    $lines = @(foreach ($m in $choices) {
      if ($m.Id -eq "") { "   OFF  (disable advisor tool / seat aliases fall back to main)" } else { Format-OldModelLine $m }
    })
    $want = Get-StartPick -S $S -Last $Last -Slot $Slot -Choices $choices -Default ""
    $title = "Step 4: choose ADVISOR model (IRE Top 20) or OFF."
    $help += "Mid-session use /advisor opus or /advisor sonnet (aliases), not raw InferHub ids."
  } else {
    $base = $(if ($role -eq "main") { "main" } else { "adv" })
    $primary = $S[$base]
    $isSecond = $Slot.EndsWith("1")
    $taken = @($primary); if (-not $isSecond) { $taken += $S[$base + "1"] }
    $choices = @($Models | Where-Object { $taken -notcontains $_.Id }) + @(@{ Rank = 0; Name = "none"; Id = ""; Eligible = $true; Cost = "-" })
    $lines = @(foreach ($m in $choices) {
      if ($m.Id -eq "") { "   none (no further fallback)" } else { Format-OldModelLine $m }
    })
    $chain = @(Get-DefaultChain -Role $role -PrimaryId $primary | Where-Object { $taken -notcontains $_ })
    $dflt = $(if ($chain.Count -gt 0) { $chain[0] } else { "" })
    $want = Get-StartPick -S $S -Last $Last -Slot $Slot -Choices $choices -Default $dflt
    $n = $(if ($isSecond) { "2nd" } else { "3rd" })
    $step = @{ main1 = 2; main2 = 3; adv1 = 5; adv2 = 6 }[$Slot]
    $title = "Step " + $step + ": " + $seat + " " + $n + " model (fallback " + $(if ($isSecond) { 1 } else { 2 }) + ") after " + $primary + "   default: " + $(if ($dflt) { $dflt } else { "none" })
  }
  $index = 0
  for ($i = 0; $i -lt $choices.Count; $i++) { if ($choices[$i].Id -eq $want) { $index = $i; break } }
  $r = Select-FromList -Title $title -Lines $lines -Index $index -Help $help
  if ($r.Action -ne "back") { $S[$Slot] = $choices[$r.Index].Id }
  $script:NavTrace.Add(("  step {0,-6} {1,-7} -> {2}" -f $Slot, $r.Action, $(if ($r.Action -eq "back") { "(back)" } elseif ($S[$Slot]) { $S[$Slot] } else { "OFF/none" }))) | Out-Null
  return $r.Action
}

function Get-StartDir {
  # Folder step start: start_dir saved with the D key (cache file), else D:\development, else home.
  $c = Read-LastPicks
  foreach ($d in @($c["start_dir"], "D:\development", $HOME)) {
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
  # Returns @{ Main; Advisor; MainFallbacks; AdvisorFallbacks; Folder; Launch; UcOrch; UcWorker }.
  $S = @{ main = $null; main1 = $null; main2 = $null; adv = $null; adv1 = $null; adv2 = $null; uc_orch = $null; uc_worker = $null }
  $last = Read-LastPicks
  $folderState = @{ Path = (Get-StartDir); Index = 0; Message = "" }
  $steps = @("main", "main1", "main2", "adv", "adv1", "adv2", "folder", "launch", "uc_orch", "uc_worker")
  $i = 0; $dir = 1; $folder = $null; $launch = $null
  while ($i -lt $steps.Count) {
    if ($i -lt 0) { $i = 0 }
    $slot = $steps[$i]
    if (($slot -eq "adv1" -or $slot -eq "adv2") -and -not $S.adv) { $i += $dir; continue }   # advisor OFF
    if ($slot -eq "main2" -and -not $S.main1) { $i += $dir; continue }   # no 2nd, no 3rd
    if ($slot -eq "adv2" -and -not $S.adv1) { $i += $dir; continue }
    if ($slot -eq "folder") {
      $folder = Invoke-FolderStep -State $folderState
      if ($folder) { $dir = 1; $i++; continue }
      $dir = -1; $i--; $folderState = @{ Path = (Get-StartDir); Index = 0; Message = "" }; continue
    }
    if ($slot -eq "launch") {
      # Coming back from Step 9 highlights this session's pick, not last time's.
      $launch = Invoke-LaunchStep -Last $(if ($launch) { @{ launch = $launch } } else { $last })
      if (-not $launch) { $dir = -1; $i--; continue }
      if ($launch -ne "ultracode") { break }
      $dir = 1; $i++; continue
    }
    if ($slot -eq "uc_orch" -or $slot -eq "uc_worker") {
      $action = Invoke-UltraCodeStep -Slot $slot -S $S -Last $last
      if ($action -eq "back") { $dir = -1; $i-- } else { $dir = 1; $i++ }
      continue
    }
    $action = Invoke-ModelStep -Slot $slot -S $S -Last $last
    if ($action -eq "back") { $dir = -1; $i-- } else { $dir = 1; $i++ }
  }
  Save-LastPicks -S $S
  $picks = @{ launch = $launch }
  if ($launch -eq "ultracode") { $picks["uc_orch"] = $S.uc_orch; $picks["uc_worker"] = $(if ($S.uc_worker) { $S.uc_worker } else { "" }) }
  Write-LastPicks $picks
  $main = $Models | Where-Object { $_.Id -eq $S.main } | Select-Object -First 1
  $adv = $(if ($S.adv) { $Models | Where-Object { $_.Id -eq $S.adv } | Select-Object -First 1 } else { @{ Rank = 0; Name = "OFF (no advisor)"; Id = ""; Eligible = $true; Cost = "-" } })
  return @{
    Main = $main; Advisor = $adv; Folder = $folder; Launch = $launch; UcOrch = $S.uc_orch; UcWorker = $S.uc_worker
    MainFallbacks = @($(if ($S.main1) { @($S.main1, $S.main2) }) | Where-Object { $_ })
    AdvisorFallbacks = @($(if ($S.adv -and $S.adv1) { @($S.adv1, $S.adv2) }) | Where-Object { $_ })
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
  # Steps 9 and 10. Rebuilt only when the main or advisor seat changes.
  param($S)
  $key = "" + $S.main + "|" + $S.adv
  if ($script:UcChoices -and $script:UcChoicesKey -eq $key) { return $script:UcChoices }
  $dir = Get-UltraCodeShim
  $mainName = "" + ($Models | Where-Object { $_.Id -eq $S.main } | Select-Object -First 1).Name
  $advName = $(if ($S.adv) { "" + ($Models | Where-Object { $_.Id -eq $S.adv } | Select-Object -First 1).Name } else { "" })
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

# ---- fallback ladders (issue #5) ----
# After each seat is picked, show its default fallback ladder and let Alex
# accept it (Enter) or pick up to 3 rungs. Applied to the running proxy after
# the last Apply-InferHubSeat through /workbench/reload_runtime (scope ladder),
# with no restart. CLAUDE_IH_LADDER=default takes the defaults without asking;
# =off skips the step (the stock inferhub_fallbacks.yaml chains stay).
$LadderCli = Join-Path $RepoRoot "shared\ladder\ladder_cli.py"
$LadderState = Join-Path $LiteLLMRoot "config\ladder_state.json"

function Get-LadderPython {
  $venvPy = Join-Path $LiteLLMRoot ".litellm-venv\Scripts\python.exe"
  if (Test-Path -LiteralPath $venvPy) { return $venvPy }
  foreach ($name in @("python", "py")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Save-Ladders {
  # Record the picked 2nd/3rd models as each seat's fallback ladder.
  param($W)
  if ($env:CLAUDE_IH_LADDER -eq "off") { return }
  $py = Get-LadderPython
  if (-not $py) { return }
  Remove-Item -LiteralPath $LadderState -ErrorAction SilentlyContinue
  $ErrorActionPreference = "Continue"   # the helper logs on stderr; that is not a failure
  $null = & $py $LadderCli choose --state $LadderState --role main ("--primary=" + $W.Main.Id) ("--picks=" + ($W.MainFallbacks -join ",")) 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Host "warning: main fallbacks not accepted; the stock chains stay" }
  $null = & $py $LadderCli choose --state $LadderState --role advisor ("--primary=" + $W.Advisor.Id) ("--picks=" + ($W.AdvisorFallbacks -join ",")) 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Host "warning: advisor fallbacks not accepted; the stock chains stay" }
}

function Apply-Ladder {
  if ($env:CLAUDE_IH_LADDER -eq "off") { return }
  if (-not (Test-Path -LiteralPath $LadderState)) { return }
  $py = Get-LadderPython
  if (-not $py) { return }
  $ErrorActionPreference = "Continue"
  $null = & $py $LadderCli apply --state $LadderState --base-url $ProxyBase 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Host "warning: could not apply the fallback ladders; the stock chains stay" }
}

# ---- interactive flow ----
if ($env:CCL_LAUNCHER_LIBRARY_ONLY -eq "1") { return }   # tests dot-source the functions only
Get-IreRecommendations
if ([Console]::IsInputRedirected) {
  # No console keys: default seats, advisor OFF, default chains, numbered folder list.
  $w = @{ Main = ($Models | Where-Object { $_.Id -eq $DefaultModelId } | Select-Object -First 1)
          Advisor = @{ Rank = 0; Name = "OFF (no advisor)"; Id = ""; Eligible = $true; Cost = "-" } }
  $w.MainFallbacks = @(Get-DefaultChain -Role main -PrimaryId $DefaultModelId | Select-Object -First 2)
  $w.AdvisorFallbacks = @()
  $w.Folder = Select-ProjectFolderNumbered
  $w.Launch = "claude"
} else {
  $w = Invoke-LaunchWizard
}
$main = $w.Main
$advisor = $w.Advisor
$folder = $w.Folder
Save-Ladders -W $w

$advisorId = $advisor.Id
$advisorLabel = $(if ($advisorId) { $advisor.Name + " (" + $advisorId + ")" } else { "OFF" })

Apply-InferHubSeat -MainId $main.Id -AdvisorId $advisorId
Ensure-LiteLLMProxy

# Re-apply seat after proxy/venv exists, then ask for config reload by restarting if needed.
Apply-InferHubSeat -MainId $main.Id -AdvisorId $advisorId
# The seat's merge step reloads the stock chains, so the picked ladders go on top.
Apply-Ladder
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
$env:ANTHROPIC_BASE_URL = $ProxyBase   # always http://127.0.0.1:4000
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
$env:ANTHROPIC_MODEL = $seatAlias      # sonnet seat -> InferHub main
# small-fast is the fast seat alias (cb/deepseek-v4.1-flash unless the seat file says otherwise).
$env:ANTHROPIC_SMALL_FAST_MODEL = "small-fast"
# Pin every model tier to a name the proxy serves. Without these, a subagent or
# skill with "model: haiku" asks for Claude Code's built-in haiku id
# (claude-haiku-4-5-20251001), which the proxy does not have, and gets a 400.
# The pins also keep sonnet/opus working when a Claude Code update renames them.
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-5"   # main seat
$env:ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-5-5"     # advisor seat (main when advisor is OFF)
$env:ANTHROPIC_DEFAULT_FABLE_MODEL = "claude-fable-5"     # advisor seat
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5-20251001"  # fast seat (an id Claude Code knows, so no "unrecognized model" warning)
$env:CLAUDE_CODE_WORKFLOWS = "1"
# Do NOT set ANTHROPIC_AUTH_TOKEN (would win over API_KEY and risk CKFF).
# Keep experimental betas ON - do not set CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS

Set-Location -LiteralPath $folder

Clear-Host
Write-Host ("cwd=" + (Get-Location))
Write-Host ("proxy=" + $env:ANTHROPIC_BASE_URL + "  (unified CKFF+InferHub LiteLLM)")
Write-Host ("small_fast=" + $env:ANTHROPIC_SMALL_FAST_MODEL + "  (fast seat alias, InferHub cheap side model for search/hooks)")
Write-Host ("seat_alias=" + $seatAlias + "  behavesAs=claude-sonnet-5")
Write-Host "tiers=sonnet:claude-sonnet-5 opus:claude-opus-5-5 fable:claude-fable-5 haiku:claude-haiku-4-5-20251001 (all proxy seat aliases)"
Write-Host ("main=" + $main.Id + "  (" + $main.Name + ")")
Write-Host ("advisor=" + $advisorLabel)
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
