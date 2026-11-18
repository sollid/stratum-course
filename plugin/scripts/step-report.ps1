# Step mark sent to the site, Windows (PowerShell 5.1). Same behaviour and output as step-report.sh.
#   step-report.ps1 --module m1 --step s2 --passed true|false [--reason <code>] [--check-version 1] [--data <dir>] [--soft]
#   step-report.ps1 --module m1 --step s2 --rules <rules.json> --dir <folder> [--data <dir>] [--soft]
#     (second form: runs the unchanged check.ps1, takes the verdict from its output; passed = verdict "accepted")
# The site gets only a reason CODE (^[a-z0-9_]{1,40}$), never text: the first failed rule's code from <step>.reasons.txt next to the rules file.
# The human text of the reason is shown to the learner by the check itself.
# Exit codes: 0 sent (also "already marked"); 10 not sent (no network, site busy or odd answer); 11 pair again (no token or the site refused it);
#   12 the site does not know the step; 13 the check did not run; 14 the site address in the settings is not the one the token belongs to; 20 bad site address in the token file; 22 off at this site; 23 site in preview mode; 2 usage.
# --soft: always exit 0 (for a skill's inline command). The verdict is never lost: it is checked on this machine before anything is sent.
# The token is read from the token file, sent only in the Authorization header to the address stored with it, and never printed.
. (Join-Path $PSScriptRoot 'lib.ps1')

$o = Get-Opts $args
function Finish([int]$code) { if ($o.soft) { exit 0 } else { exit $code } }
function Fail([string]$key, [hashtable]$vars, [int]$code) { Say $key $vars; Finish $code }
function Usage { [Console]::Error.WriteLine('usage: step-report.ps1 --module <m> --step <s> (--passed true|false [--reason <code>] | --rules <file> --dir <folder>) [--data <dir>] [--soft]'); exit 2 }

$module = [string]$o['module']
$step = [string]$o['step']
if (-not ($module -match '^[A-Za-z0-9_-]{1,20}$') -or -not ($step -match '^[A-Za-z0-9_-]{1,20}$')) { Usage }

$dataDir = Get-DataDir $o
$tokenPath = Join-Path $dataDir 'device-token.txt'
$checkVersion = '1'

# Verdict and reason (Run-Check, Invoke-Check and Get-ReasonCode are in lib.ps1)
$passed = $false
$reason = ''
if ($o['rules']) {
    $rulesPath = [string]$o['rules']
    $dirArg = [string]$o['dir']
    if (-not $dirArg) { Usage }
    $c = Invoke-Check $rulesPath $dirArg
    if ($c.newer) { Fail 'report.rulesnewer' $null 15 }
    if ($c.code -ne 0 -or -not $c.verdict) { Fail 'report.checkfail' $null 13 }
    $passed = ($c.verdict -eq 'accepted')
    $reasonsPath = $rulesPath -replace '(\.rules)?\.json$', '.reasons.txt'
    if ($reasonsPath -eq $rulesPath) { $reasonsPath = '' }
    # The code comes from the reasons file; a rule of a new type without a code there gets the default code of its type (see Get-ReasonCode in lib.ps1)
    $reason = Get-ReasonCode $rulesPath $reasonsPath $c.out $c.verdict
    try {
        $rv = [string]((([System.IO.File]::ReadAllText($rulesPath, $script:Utf8).TrimStart([char]0xFEFF)) | ConvertFrom-Json).version)
        if ($rv -match '^[0-9A-Za-z.+-]{1,20}$') { $checkVersion = $rv }
    } catch { }
} else {
    $pv = [string]$o['passed']
    if ($pv -ne 'true' -and $pv -ne 'false') { Usage }
    $passed = ($pv -eq 'true')
    $reason = [string]$o['reason']
    if ($reason -and -not ($reason -match '^[a-z0-9_]{1,40}$')) { Usage }
    if ($o['check-version'] -match '^[0-9A-Za-z.+-]{1,20}$') { $checkVersion = [string]$o['check-version'] }
}
if ($passed) { $reason = '' }
if ($reason -and -not ($reason -match '^[a-z0-9_]{1,40}$')) { $reason = '' }

# Token and the address it belongs to
$kv = Read-KV $tokenPath
if (-not $kv -or -not ([string]$kv['token'] -match '^[A-Za-z0-9_-]{20,200}$')) { Fail 'report.notpaired' $null 11 }
$site = [string]$kv['site']
if (-not (Test-SiteUrl $site)) { Fail 'report.nosite' $null 20 }
# The token belongs to the address stored with it. If the settings now point elsewhere, send nothing and explain.
$setting = Get-SiteSetting $dataDir
if ($setting.state -eq 'ok' -and -not (Test-Same $setting.url $site)) { Fail 'report.sitemismatch' @{ old = $site; new = $setting.url } 14 }
$token = [string]$kv['token']

$passedText = 'false'
if ($passed) { $passedText = 'true' }
$body = '{"module":"' + $module + '","step":"' + $step + '","passed":' + $passedText + ',"check_version":"' + $checkVersion + '","plugin_version":"' + (Get-PluginVersion) + '","os":"windows"'
if ($reason) { $body += ',"reason":"' + $reason + '"' }
$body += '}'

for ($attempt = 1; $attempt -le 3; $attempt++) {
    $r = Invoke-Site $site '/api/plugin/step' $body $token
    $j = ConvertFrom-Flat $r.body
    if ($r.status -eq 200 -and $j -and (Test-Same ([string]$j.status) 'recorded')) {
        if ($j.repeated -eq $true) { Fail 'report.repeated' $null 0 }
        if ($passed) { Fail 'report.ok' $null 0 }
        Fail 'report.okfail' $null 0
    }
    if ($r.status -eq 401) {
        try { Remove-Item -LiteralPath $tokenPath -Force -ErrorAction Stop } catch { }
        Fail 'report.rejected' $null 11
    }
    if ($r.status -eq 404) { Fail 'report.disabled' @{ site = $site } 22 }
    if ($r.status -eq 503 -and $j -and (Test-Same ([string]$j.error) 'preview')) { Fail 'report.preview' @{ site = $site } 23 }
    if ($r.status -eq 422) {
        if ($j -and (Test-Same ([string]$j.error) 'engine')) { Fail 'report.rulesnewer' $null 15 }
        Fail 'report.unknownstep' $null 12
    }
    if ($r.status -eq 0 -or $r.status -eq 429 -or $r.status -eq 503) {
        if ($attempt -lt 3) {
            $w = $r.retry; if ($w -lt 1) { $w = 2 * $attempt }; if ($w -gt 15) { $w = 15 }
            Start-Sleep -Seconds $w
            continue
        }
    }
    Fail 'report.offline' $null 10
}
Fail 'report.offline' $null 10
