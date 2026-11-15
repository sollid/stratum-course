# Device pairing, Windows (PowerShell 5.1). Same behaviour and output as connect.sh.
#   connect.ps1 start [--data <dir>] [--label <text>] [--soft]   ask the site for a code, print it, remember the wait file
#   connect.ps1 wait  [--data <dir>] [--window <sec>] [--soft]   poll for up to <window> seconds (90 by default); may be called again
# Exit codes: 0 done; 30 still waiting (call wait again); 31 code expired; 32 no pairing started; 20 no or bad site address;
#   21 site not answering; 22 pairing off at this site; 23 site in preview mode; 24 site busy; 25 unexpected answer; 26 token not saved.
# --soft: always exit 0 (for a skill's inline command, where a non-zero exit would abort the skill).
# ASCII only (see messages.txt). The device code is only in the wait file; the token only in the token file; neither is printed.
. (Join-Path $PSScriptRoot 'lib.ps1')

$o = Get-Opts $args
function Finish([int]$code) { if ($o.soft) { exit 0 } else { exit $code } }
function Fail([string]$key, [hashtable]$vars, [int]$code) { Say $key $vars; Finish $code }

$dataDir = Get-DataDir $o
$pendingPath = Join-Path $dataDir 'pair-pending.txt'
$tokenPath = Join-Path $dataDir 'device-token.txt'

function Get-Site {
    $s = Get-SiteSetting $dataDir
    if ($s.state -eq 'none') { Fail 'connect.nosite' $null 20 }
    if ($s.state -eq 'bad') { Fail 'connect.badsite' $null 20 }
    return $s.url
}

function Save-Pending($p) {
    Write-SecureFile $pendingPath ("device_code=$($p.device_code)`nexpires=$($p.expires)`ninterval=$($p.interval)`nsite=$($p.site)`nnot_before=$($p.not_before)`n")
}

# Common reactions to answers that end the attempt
function Stop-OnSiteAnswer($site, $r) {
    $j = ConvertFrom-Flat $r.body
    if ($r.status -eq 404) { Fail 'connect.disabled' @{ site = $site } 22 }
    if ($r.status -eq 503 -and $j -and $j.error -eq 'preview') { Fail 'connect.preview' @{ site = $site } 23 }
}

function Do-Start {
    $site = Get-Site
    $ver = Get-PluginVersion
    $label = Get-DeviceLabel $o['label']
    $body = '{"os":"windows","label":"' + $label + '","plugin_version":"' + $ver + '"}'
    $r = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $r = Invoke-Site $site '/api/plugin/pair/start' $body $null
        if ($r.status -eq 200) { break }
        Stop-OnSiteAnswer $site $r
        if ($r.status -eq 0) {
            if ($attempt -eq 2) { Fail 'connect.unreachable' @{ site = $site } 21 }
            Start-Sleep -Seconds 3
        } elseif ($r.status -eq 429 -or $r.status -eq 503) {
            if ($attempt -eq 2) { Fail 'connect.busy' $null 24 }
            $w = $r.retry; if ($w -lt 1) { $w = 5 }; if ($w -gt 60) { $w = 60 }
            Start-Sleep -Seconds $w
        } else { Fail 'connect.unexpected' @{ status = $r.status } 25 }
    }
    $j = ConvertFrom-Flat $r.body
    $okShape = $j -and ([string]$j.device_code -match '^[A-Za-z0-9_-]{20,100}$') -and ([string]$j.user_code -cmatch '^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$')
    if (-not $okShape) { Fail 'connect.unexpected' @{ status = 200 } 25 }
    $expiresIn = 600
    if ([string]$j.expires_in -match '^[0-9]{1,5}$' -and [int]$j.expires_in -ge 30) { $expiresIn = [int]$j.expires_in }
    $interval = 5
    if ([string]$j.interval -match '^[0-9]{1,3}$' -and [int]$j.interval -ge 1 -and [int]$j.interval -le 60) { $interval = [int]$j.interval }
    $path = '/connect'
    # The page path from the answer is accepted only in the strict form /connect or /<two letters>/connect
    if ([string]$j.verification_path -cmatch '^/([a-z]{2}/)?connect$') { $path = [string]$j.verification_path }
    $p = @{ device_code = [string]$j.device_code; expires = ((Get-NowEpoch) + $expiresIn); interval = $interval; site = $site; not_before = 0 }
    try { Save-Pending $p } catch { Fail 'connect.cantsave' $null 26 }
    Say 'connect.start' @{ page = ($site + $path); code = [string]$j.user_code; label = $label; os = 'Windows'; minutes = [int][math]::Ceiling($expiresIn / 60) }
    # If this computer is already paired to another address, say so right after the code (the text still starts with the pairing title)
    $old = Read-KV $tokenPath
    if ($old -and (Test-SiteUrl ([string]$old['site'])) -and [string]$old['site'] -ne $site) { Say 'connect.sitechanged' @{ old = [string]$old['site']; new = $site } }
    Finish 0
}

function Remove-Quiet([string]$path) { try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { } }

function Do-Wait {
    $kv = Read-KV $pendingPath
    $valid = $kv -and ([string]$kv['device_code'] -match '^[A-Za-z0-9_-]{20,100}$') -and ([string]$kv['expires'] -match '^[0-9]{1,12}$') -and ([string]$kv['interval'] -match '^[0-9]{1,3}$') -and (Test-SiteUrl ([string]$kv['site']))
    if (-not $valid) { Remove-Quiet $pendingPath; Fail 'connect.nopending' $null 32 }
    $p = @{ device_code = $kv['device_code']; expires = [int64]$kv['expires']; interval = [int]$kv['interval']; site = $kv['site']; not_before = 0 }
    if ([string]$kv['not_before'] -match '^[0-9]{1,12}$') { $p.not_before = [int64]$kv['not_before'] }
    $site = $p.site
    $window = 90
    if ([string]$o['window'] -match '^[0-9]{1,3}$' -and [int]$o['window'] -ge 1) { $window = [int]$o['window'] }
    $winEnd = (Get-NowEpoch) + $window
    $backoff = [math]::Max($p.interval, 1)
    $netFail = $false
    $odd = 0
    $body = '{"device_code":"' + $p.device_code + '"}'
    while ($true) {
        $now = Get-NowEpoch
        if ($now -ge $p.expires) { Remove-Quiet $pendingPath; Fail 'connect.expired' $null 31 }
        if ($now -ge $winEnd) {
            if ($netFail) { Fail 'connect.unreachable' @{ site = $site } 21 }
            Fail 'connect.waiting' $null 30
        }
        if ($now -lt $p.not_before) {
            $s = [math]::Min([math]::Min($p.not_before - $now, $winEnd - $now), $p.expires - $now)
            Start-Sleep -Seconds ([int][math]::Max($s, 1))
            continue
        }
        $r = Invoke-Site $site '/api/plugin/pair/poll' $body $null
        $pause = 0
        $extra = 0
        if ($r.status -eq 0) {
            $netFail = $true; $pause = $backoff; $backoff = [math]::Min($backoff * 2, 60)
        } elseif ($r.status -eq 410) {
            Remove-Quiet $pendingPath; Fail 'connect.expired' $null 31
        } elseif ($r.status -eq 200) {
            $netFail = $false
            $j = ConvertFrom-Flat $r.body
            if ($j -and $j.status -eq 'pending') {
                $odd = 0; $backoff = [math]::Max($p.interval, 1); $pause = $p.interval
            } elseif ($j -and $j.status -eq 'ready') {
                $tok = [string]$j.token; $dev = [string]$j.device_id; $exp = [string]$j.expires_at
                if (-not ($tok -match '^[A-Za-z0-9_-]{20,200}$') -or -not ($dev -match '^[A-Za-z0-9-]{8,64}$')) { Remove-Quiet $pendingPath; Fail 'connect.unexpected' @{ status = 200 } 25 }
                if (-not ($exp -match '^[0-9TZ:.+-]{10,40}$')) { $exp = '' }
                try { Write-SecureFile $tokenPath ("token=$tok`ndevice_id=$dev`nexpires_at=$exp`nsite=$site`n") } catch { Remove-Quiet $pendingPath; Fail 'connect.cantsave' $null 26 }
                Remove-Quiet $pendingPath
                Fail 'connect.paired' $null 0
            } else {
                $odd++; if ($odd -ge 3) { Fail 'connect.unexpected' @{ status = 200 } 25 }
                $pause = $backoff; $backoff = [math]::Min($backoff * 2, 60)
            }
        } else {
            $netFail = $false
            Stop-OnSiteAnswer $site $r
            if ($r.status -eq 429 -or $r.status -eq 503) {
                if ($r.retry -gt 0) { $pause = $r.retry; $extra = 1 } else { $pause = $backoff; $backoff = [math]::Min($backoff * 2, 60) }
            } else {
                $odd++; if ($odd -ge 3) { Fail 'connect.unexpected' @{ status = $r.status } 25 }
                $pause = $backoff; $backoff = [math]::Min($backoff * 2, 60)
            }
        }
        $p.not_before = (Get-NowEpoch) + [math]::Max($pause, 1) + $extra
        if ($p.not_before -gt $winEnd) { try { Save-Pending $p } catch { } }
    }
}

if ($o.cmd -eq 'start') { Do-Start }
elseif ($o.cmd -eq 'wait') { Do-Wait }
else { [Console]::Error.WriteLine('usage: connect.ps1 start|wait [--data <dir>] [--window <sec>] [--soft]'); exit 2 }
