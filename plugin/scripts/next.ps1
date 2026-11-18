# Next course step, Windows (PowerShell 5.1). Same behaviour and output as next.sh.
#   next.ps1 [--data <dir>] [--dir <learning folder>] [--show-only] [--soft]
# Order: token -> learning folder (by its mark) -> quiet re-check of disputed steps -> one task request (POST /api/plugin/task) -> parse and check the package
# -> save in the plugin data -> start files into the learning folder -> show the task, or check and send the mark -> on "accepted" one more request and show the next step.
# At most three POSTs per run. A package that fails the format check writes nothing to disk.
# --show-only (skill /course:task): only show the current task, no check and no mark.
# Exit codes: 0 done; 10 no answer from the site or busy; 11 pair again; 12 the site does not know the step; 13 the check did not run; 14 the site address in the settings is not the one the token belongs to;
#   15 a newer plugin is needed; 16 task package not in the format; 17 start file not put; 18 package not saved; 20 bad site address in the token file;
#   22 off at this site; 23 site in preview mode; 24 odd answer of the site; 40 device not paired; 41 not a learning folder.
# --soft: always exit 0 (for a skill's inline command). ASCII only (see messages.txt).
# The token is read from the token file and sent only in the Authorization header to the address stored with it; it is never printed.
# The content of start files is never printed.
. (Join-Path $PSScriptRoot 'lib.ps1')

$o = Get-Opts $args
function Finish([int]$code) { Exit-CourseLock; if ($o.soft) { exit 0 } else { exit $code } }
trap { Exit-CourseLock; break }
function Fail([string]$key, $vars, [int]$code) { Say $key $vars; Finish $code }

$dataDir = Get-DataDir $o
if (-not (Enter-CourseLock $dataDir)) { Fail 'course.busy' $null 19 }
$tokenPath = Join-Path $dataDir 'device-token.txt'
$script:Posts = 0

# 1. token
$kv = Read-KV $tokenPath
$tok = ''
if ($kv) { $tok = [string]$kv['token'] }
if (-not [regex]::IsMatch($tok, '^[A-Za-z0-9_-]{20,200}$')) { Fail 'next.notpaired' $null 40 }

# 2. learning folder: only with the mark that /course:start puts. The plugin puts nothing into a foreign folder
$dir = [string]$o['dir']
if (-not $dir) { $dir = '.' }
if (-not [regex]::IsMatch($dir, '^([/\\]|[A-Za-z]:)')) {
    try { $dir = (Resolve-Path -LiteralPath $dir -ErrorAction Stop).ProviderPath } catch { $dir = '' }
}
if (-not $dir -or -not (Test-CourseDir $dir)) {
    $wd = @(Get-StateValues $dataDir 'workdir') | Select-Object -First 1
    if ($wd) { Fail 'next.notfolder' @{ path = $wd } 41 }
    Fail 'next.notfolder.nopath' $null 41
}
Switch-WorkDir $dataDir $dir

$site = [string]$kv['site']
if (-not (Test-SiteUrl $site)) { Fail 'next.nosite' $null 20 }
# The token belongs to the address stored with it. If the settings now point elsewhere, send nothing and explain.
$setting = Get-SiteSetting $dataDir
if ($setting.state -eq 'ok' -and $setting.url -cne $site) { Fail 'next.sitemismatch' ([ordered]@{ old = $site; new = $setting.url }) 14 }

# One attempt to send a mark: recorded | repeated | rejected | disabled | preview | unknown | offline. Every sending is one POST
function Send-Mark([string]$module, [string]$step, [bool]$passed, [string]$reason, [string]$checkVersion) {
    $pt = 'false'
    if ($passed) { $pt = 'true' }
    $body = '{"module":"' + $module + '","step":"' + $step + '","passed":' + $pt + ',"check_version":"' + $checkVersion + '","plugin_version":"' + (Get-PluginVersion) + '","os":"windows"'
    if ($reason) { $body += ',"reason":"' + $reason + '"' }
    $body += '}'
    $script:Posts++
    $r = Invoke-Site $site '/api/plugin/step' $body $tok
    $j = ConvertFrom-Flat $r.body
    if ($r.status -eq 200 -and $j -and (Test-Same ([string]$j.status) 'recorded')) {
        if ($j.repeated -eq $true) { return 'repeated' }
        return 'recorded'
    }
    if ($r.status -eq 401) { return 'rejected' }
    if ($r.status -eq 404) { return 'disabled' }
    if ($r.status -eq 422) { if ($j -and (Test-Same ([string]$j.error) 'engine')) { return 'newer' }; return 'unknown' }
    if ($r.status -eq 503 -and $j -and (Test-Same ([string]$j.error) 'preview')) { return 'preview' }
    return 'offline'
}
function Remove-Token { try { Remove-Item -LiteralPath $tokenPath -Force -ErrorAction Stop } catch { } }

# 3. quiet re-check of disputed steps (by the rules saved in the plugin data). At most one sending per run
if (-not $o.showonly) {
    foreach ($k in @(Get-StateValues $dataDir 'disputed')) {
        if (-not [regex]::IsMatch($k, '^[a-z0-9]{1,10}/[a-z0-9]{1,10}$')) { continue }
        $m = $k.Split('/')[0]; $s = $k.Split('/')[1]
        $sdd = Join-Path $dataDir ('steps\' + $m + '-' + $s)
        $rp = Join-Path $sdd 'rules.json'
        if (-not ($script:Posts -lt 1 -and (Test-Path -LiteralPath $rp -PathType Leaf))) { continue }
        $c = Invoke-Check $rp $dir
        if (-not ($c.code -eq 0 -and $c.verdict -ceq 'accepted')) { continue }
        $meta = Read-KV (Join-Path $sdd 'meta.txt')
        $cv = '1'
        if ($meta -and $meta['check_version']) { $cv = [string]$meta['check_version'] }
        $res = Send-Mark $m $s $true '' $cv
        if ($res -ceq 'recorded' -or $res -ceq 'repeated') {
            Remove-State $dataDir 'disputed' $k
            Say 'next.recheck' ([ordered]@{ module_n = (Get-ModuleNumber $m); n = [string]$meta['number']; step_title = [string]$meta['step_title'] })
        } elseif ($res -ceq 'rejected') {
            Remove-Token
            Fail 'report.rejected' $null 11
        }
    }
}

# 4-6. task request, parse, save, start files. Prints a refusal and ends the run if the step cannot be shown
function Get-Task {
    $json = '{"plugin_version":"' + (Get-PluginVersion) + '","os":"windows","engine":' + $script:EngineLevel + '}'
    $script:Posts++
    $r = Invoke-SiteTask $site $json $tok
    $status = [int]$r.status
    if ($status -eq 200) { }
    elseif ($status -eq 401) { Remove-Token; Fail 'next.rejected' $null 11 }
    elseif ($status -eq 404) { Fail 'next.disabled' @{ site = $site } 22 }
    elseif ($status -eq 503) {
        $j = ConvertFrom-Flat ($script:Utf8.GetString($r.bytes))
        if ($j -and (Test-Same ([string]$j.error) 'preview')) { Fail 'next.preview' @{ site = $site } 23 }
        Fail 'next.offline' $null 10
    }
    elseif ($status -eq 0 -or $status -eq 429) { Fail 'next.offline' $null 10 }
    else { Fail 'next.unexpected' @{ status = $status } 24 }
    if ($r.big) { Fail 'next.badpackage' $null 16 }
    $pk = Read-TaskPackage $r.bytes
    if ($pk.err -ceq 'version') { Fail 'next.updateplugin' $null 15 }
    if ($pk.err -ceq 'start') { Fail 'next.badstart' $null 16 }
    if ($pk.err) { Fail 'next.badpackage' $null 16 }
    $H = $pk.head
    if (Test-Same ([string]$H['state']) 'done') {
        if (Test-Same ([string]$H['waiting']) '0') { Fail 'next.done' $null 0 }
        Fail 'next.donewaiting' @{ waiting = [string]$H['waiting'] } 0
    }
    # The main file in the rules is the one in the package header
    if (-not (Test-Same (Get-RulesFileField $pk.rules) ([string]$H['file']))) { Fail 'next.badpackage' $null 16 }
    if ([int]$H['min_engine'] -gt $script:EngineLevel) { Fail 'next.updateplugin' $null 15 }
    # Save the package in the plugin data, apart from the token file
    $sdir = Join-Path $dataDir ('steps\' + $H['module'] + '-' + $H['step'])
    try {
        [void][System.IO.Directory]::CreateDirectory($sdir)
        Write-SecureFile (Join-Path $sdir 'task.md') $pk.task
        Write-SecureFile (Join-Path $sdir 'rules.json') $pk.rules
        Write-SecureFile (Join-Path $sdir 'reasons.txt') $pk.reasons
        $metaText = ''
        foreach ($key in @('module_title', 'step_title', 'number', 'of', 'file', 'check_version')) { $metaText += $key + '=' + [string]$H[$key] + "`n" }
        Write-SecureFile (Join-Path $sdir 'meta.txt') $metaText
    } catch { Fail 'next.cantsave' $null 18 }
    $script:P = $H
    $script:SD = $sdir
    $script:Pk = $pk
}

# 7. show the task: title, learning folder, reminder about the manual mode, the step text word for word. It is not an attempt: nothing goes to the site
function Show-Task([bool]$first) {
    # Missing start files are put by the plugin script, only together with showing the task (nothing is restored before a check:
    # the person may have removed a file on purpose); existing files of the person are not overwritten. Not put: a direct phrase, the task is not shown
    foreach ($sf in $script:Pk.start) {
        if (-not (Write-StartFile $dir $sf.path $sf.text)) { Fail 'next.startfail' @{ path = $sf.path } 17 }
    }
    $H = $script:P
    Say 'next.header' ([ordered]@{ n = (Get-ModuleNumber ([string]$H['module'])); module_title = [string]$H['module_title']; k = [string]$H['number']; of = [string]$H['of']; step_title = [string]$H['step_title'] })
    if ($first -and $H.ContainsKey('story_path')) { Say 'next.story' @{ url = ($site + [string]$H['story_path']) } }
    Say 'next.folder' @{ path = $dir }
    Say 'next.permission' $null
    Write-Out "`n"
    Write-Out $script:Pk.task
    Add-State $dataDir 'shown' ([string]$H['module'] + '/' + [string]$H['step'])
}

Get-Task
$H = $script:P
$pModule = [string]$H['module']
$pStep = [string]$H['step']
$pFile = [string]$H['file']
$key = $pModule + '/' + $pStep
$first = -not (Test-State $dataDir 'shown' $key)
if ($o.showonly -or $first -or -not (Test-Path -LiteralPath (Join-Path $dir $pFile) -PathType Leaf)) {
    Show-Task $first
    Finish 0
}

# 8. check by the saved rules, the output of the check, sending the mark (only the verdict and the reason code)
$rulesPath = Join-Path $script:SD 'rules.json'
$c = Invoke-Check $rulesPath $dir
if ($c.newer) { Fail 'report.rulesnewer' $null 15 }
if ($c.code -ne 0 -or -not $c.verdict) { Fail 'report.checkfail' $null 13 }
$outText = ($c.out -replace "`r`n", "`n").TrimEnd("`n")
Write-Out ($outText + "`n")
$passed = ($c.verdict -ceq 'accepted')
$reason = ''
if (-not $passed) {
    $reason = Get-ReasonCode $rulesPath (Join-Path $script:SD 'reasons.txt') $c.out $c.verdict
    if (-not [regex]::IsMatch($reason, '^[a-z0-9_]{1,40}$')) { $reason = '' }
}
$res = Send-Mark $pModule $pStep $passed $reason ([string]$H['check_version'])
if ($res -ceq 'rejected') { Remove-Token; Fail 'report.rejected' $null 11 }
if ($res -ceq 'disabled') { Fail 'report.disabled' @{ site = $site } 22 }
if ($res -ceq 'preview') { Fail 'report.preview' @{ site = $site } 23 }
if ($res -ceq 'newer') { Fail 'report.rulesnewer' $null 15 }
if ($res -ceq 'unknown') { Fail 'report.unknownstep' $null 12 }
if ($res -ceq 'offline') { Fail 'report.offline' $null 10 }
if ($passed) {
    if ($res -ceq 'repeated') { Say 'report.repeated' $null } else { Say 'report.ok' $null }
    Say 'next.verdict.accepted' $null
    # chain "accepted -> next task": if three sendings of this run are used, the next task comes with a separate run
    if ($script:Posts -ge 3) { Fail 'next.nextlater' $null 0 }
    Get-Task
    $H = $script:P
    Show-Task $true
    Finish 0
}
if ($c.verdict -ceq 'disputed') {
    Add-State $dataDir 'disputed' $key
    Fail 'next.verdict.disputed' $null 0
}
if ($res -ceq 'repeated') { Say 'report.repeated' $null } else { Say 'report.okfail' $null }
Fail ('next.verdict.' + $c.verdict) $null 0
