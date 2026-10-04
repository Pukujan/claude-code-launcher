# Fault-injection run against the keyless test proxy. Never touches port 4000.
# 1. a request to the broken primary fails (no ladder yet)
# 2. the launcher's ladder is applied live through /workbench/reload_runtime
# 3. requests to sonnet (main) and opus (advisor) now land on the next rung
# 3. each broken primary gets 1 try + 3 retries, then the request lands on the next rung
# 4. a repeat request skips the benched primary; after the cooldown it is tried again
# Requests are tiny (max_tokens 8) and every rung is under $0.10 per 1M tokens.
# -CooldownS sets CCL_COOLDOWN_S for the apply (default 20 so the test can prove
# the primary comes back); -Retries sets CCL_RETRIES (default 3, the real default).
param([int]$Port = 4012, [string]$Python = "python", [int]$CooldownS = 20, [int]$Retries = 3)
if ($Port -eq 4000) { throw "Port 4000 is the live proxy." }
# Native tools write progress to stderr; PowerShell 5.1 must not treat that as failure.
$ErrorActionPreference = "Continue"
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..")).Path
$base = "http://127.0.0.1:$Port"
$tmp = Join-Path $env:TEMP "ccl-t46-run"; New-Item -ItemType Directory -Force $tmp | Out-Null
Remove-Item Env:LITELLM_MASTER_KEY -ErrorAction SilentlyContinue

# Run python through cmd so its stderr lines come back as plain text in PS 5.1.
function Py([string]$cmdline, [string]$stdin = $null) {
  if ($null -ne $stdin) { $stdin | cmd /c "$Python $cmdline 2>&1" } else { cmd /c "$Python $cmdline 2>&1" }
}
function PrimaryDelta($a, $b, [string]$k) { [int]($b.$k) - [int]($a.$k) }
function Hits { (Invoke-RestMethod "http://127.0.0.1:4019/hits") | ConvertTo-Json -Compress }
function Ask([string]$model) {
  $body = @{ model = $model; max_tokens = 8; messages = @(@{ role = "user"; content = "Reply with the word ok." }) } | ConvertTo-Json -Depth 5
  $t = Get-Date
  try {
    $r = Invoke-WebRequest "$base/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 120
    $j = $r.Content | ConvertFrom-Json
    $ms = [int]((Get-Date) - $t).TotalMilliseconds
    "  asked=$model  HTTP $($r.StatusCode)  answered_by=$($j.model)  model_group=$($r.Headers['x-litellm-model-group'])  attempted_fallbacks=$($r.Headers['x-litellm-attempted-fallbacks'])  attempted_retries=$($r.Headers['x-litellm-attempted-retries'])  ${ms}ms  text='$($j.choices[0].message.content)'"
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    "  asked=$model  FAILED HTTP $code  ($([int]((Get-Date) - $t).TotalMilliseconds)ms)"
  }
}

"== 1. broken primary, no ladder yet"
"  fault hits before: $(Hits)"
Ask "sonnet"
"  fault hits after:  $(Hits)"
"== 2. choose ladders (Enter = default) and apply live, no key sent"
Remove-Item "$tmp\state.json" -ErrorAction SilentlyContinue
Py "`"$repo\shared\ladder\ladder_cli.py`" choose --state `"$tmp\state.json`" --role main --primary cb/deepseek-v4.1-flash" "" | Select-String -Pattern "seat:|ladder:|Note:|kept out" | ForEach-Object { "  $_" }
Py "`"$repo\shared\ladder\ladder_cli.py`" choose --state `"$tmp\state.json`" --role advisor --primary cbcn/glm-5.3-flash" "" | Select-String -Pattern "seat:|ladder:|Note:|kept out" | ForEach-Object { "  $_" }
$env:CCL_COOLDOWN_S = "$CooldownS"; $env:CCL_RETRIES = "$Retries"
Py "`"$repo\shared\ladder\ladder_cli.py`" apply --state `"$tmp\state.json`" --base-url $base" | ForEach-Object { "  $_" }
"== 3. same broken primaries, ladder live: each primary gets 1 try + $Retries retries, then the next rung"
$h0 = Invoke-RestMethod "http://127.0.0.1:4019/hits"
Ask "sonnet"
$h1 = Invoke-RestMethod "http://127.0.0.1:4019/hits"
"  primary hits this request: $(PrimaryDelta $h0 $h1 'cb/deepseek-v4.1-flash')  (want $(1 + $Retries))"
Ask "opus"
$h2 = Invoke-RestMethod "http://127.0.0.1:4019/hits"
"  primary hits this request: $(PrimaryDelta $h1 $h2 'cbcn/glm-5.3-flash')  (want $(1 + $Retries))"
"== 4. benched: repeat requests skip the primary ($CooldownS s cooldown)"
Ask "sonnet"
Ask "opus"
$h3 = Invoke-RestMethod "http://127.0.0.1:4019/hits"
"  primary hits for these two requests: main $(PrimaryDelta $h2 $h3 'cb/deepseek-v4.1-flash'), advisor $(PrimaryDelta $h2 $h3 'cbcn/glm-5.3-flash')  (want 0)"
"== 4b. wait out the cooldown; the primary is tried again (and benched again)"
Start-Sleep -Seconds ($CooldownS + 5)
Ask "sonnet"
$h4 = Invoke-RestMethod "http://127.0.0.1:4019/hits"
"  primary hits after the cooldown: $(PrimaryDelta $h3 $h4 'cb/deepseek-v4.1-flash')  (want $(1 + $Retries))"
Ask "sonnet"
$h5 = Invoke-RestMethod "http://127.0.0.1:4019/hits"
"  and benched again right after: $(PrimaryDelta $h4 $h5 'cb/deepseek-v4.1-flash')  (want 0)"
"== 4d. what the proxy reports now (read back through the same endpoint)"
$st = Invoke-RestMethod "$base/workbench/reload_runtime" -Method Post -Body '{"scope":"ladder"}' -ContentType "application/json"
"  cooldown seconds: $($st.state.cooldown | ConvertTo-Json -Compress)"
"  retry policy sonnet: $($st.state.retry_policy.sonnet | ConvertTo-Json -Compress)"
"== 5. non-loopback check: reload endpoint refuses a LAN address"
$lan = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254*" } | Select-Object -First 1).IPAddress
"  proxy is bound to 127.0.0.1 only; connecting via $lan :"
try { Invoke-WebRequest "http://${lan}:$Port/workbench/reload_runtime" -Method Post -Body '{"scope":"ladder"}' -ContentType "application/json" -UseBasicParsing -TimeoutSec 5 | Out-Null; "  UNEXPECTED: reachable" } catch { "  refused as expected: $($_.Exception.Message)" }
