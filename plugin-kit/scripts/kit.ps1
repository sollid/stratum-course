# Team kit, Windows (PowerShell 5.1). The same behaviour and output as kit.sh.
#   kit.ps1 install|update|check|list [--data <dir>] [--probe true] [--flat true] [--soft] [--background]
#   kit.ps1 off <id> | on <id> [--data <dir>] [--soft]
#   kit.ps1 hook loaded|deny|start      (hooks: off until the build has hooks and the setting probe_hooks is true)
# Puts the rule packages of the site (by the device token that the course plugin made) into ~/.claude/rules/stratum/<id>/, shows what stands, switches a package off and on.
# Requests to the site: install - up to three POSTs (report and list, packages in one request, the final report), update and on - the same, check and off - one.
# A package that fails a check (name, size, hash, number of parts, characters) is not written. A foreign file in the way is never overwritten.
# Exit codes: 0 done; 10 no answer from the site; 11 pair again; 12 bad package name; 13 no such package; 14 the site address in the settings is not the token's; 15 a newer plugin is needed;
#   16 answer not in the format; 17 some packages not put; 18 the package cannot be returned; 19 another run is going; 20 bad site address in the token file; 21 the site does not know the package;
#   22 off at this site; 23 site in preview mode; 24 odd answer of the site; 25 could not write; 26 several course pairings; 40 device not paired.
# --soft: always exit 0 (for a skill's inline command). --background: quiet, at most once in 24 hours, always exit 0. ASCII only (see messages.txt).
. (Join-Path $PSScriptRoot 'lib.ps1')

$o = Get-Opts $args
function Finish([int]$code) { Exit-KitLock; if ($o.soft -or $o.background) { exit 0 } else { exit $code } }
trap { Exit-KitLock; break }
function Fail([string]$key, $vars, [int]$code) { Say $key $vars; Finish $code }

Initialize-Data $o
Initialize-Settings $o
Initialize-Rules
if ($o.background) { $script:Quiet = $true }
$cmd = [string]$o.cmd
$arg2 = [string]$o.arg2
if (@('install', 'update', 'check', 'list', 'off', 'on', 'hook') -cnotcontains $cmd) {
    [Console]::Error.WriteLine('usage: kit.ps1 install|update|check|list|off <id>|on <id>|hook <name> [--data <dir>] [--soft]')
    exit 2
}

# ---------- hooks ----------
function Read-Stdin([int]$max) {
    $ms = New-Object System.IO.MemoryStream
    try {
        $in = [Console]::OpenStandardInput()
        $buf = New-Object byte[] 8192
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            if (($ms.Length + $n) -gt $max) { $ms.Write($buf, 0, [int]($max - $ms.Length)); break }
            $ms.Write($buf, 0, $n)
        }
    } catch { }
    return $script:Utf8.GetString($ms.ToArray())
}
function Get-JsonDoc([string]$text) { try { return ($text | ConvertFrom-Json) } catch { return $null } }
function Get-JsonString($doc, [string]$name) {
    if ($null -eq $doc) { return '' }
    $v = $doc.PSObject.Properties[$name]
    if ($v -and $v.Value -is [string]) { return [string]$v.Value }
    return ''
}

function Invoke-HookLoaded {
    if (-not $script:Probe) { exit 0 }
    $doc = Get-JsonDoc (Read-Stdin 65536)
    $fp = (Get-JsonString $doc 'file_path').Replace('\', '/')
    $mt = Get-JsonString $doc 'memory_type'
    $lr = Get-JsonString $doc 'load_reason'
    if (-not (Test-Same $mt 'User')) { exit 0 }
    if (-not [regex]::IsMatch($lr, '^[a-z_]{1,30}\z')) { exit 0 }
    if (-not ($fp.Contains('/rules/stratum/') -or $fp.Contains('/rules/stratum-'))) { exit 0 }
    if ($fp.Length -gt 500 -or [regex]::IsMatch($fp, '[\x00-\x1f\x7f]')) { exit 0 }
    $lines = @(Read-LoadedLines) + ([string](Get-NowEpoch) + ' ' + $lr + ' ' + $fp)
    if ($lines.Count -gt 600) { $lines = @($lines | Select-Object -Last 300) }
    $text = ''
    foreach ($l in $lines) { $text += [string]$l + "`n" }
    Write-SecureFile (Join-Path $script:KD 'loaded.log') $text
    exit 0
}

function Get-JsonStringRaw([string]$text, [string]$name) {
    # When ConvertFrom-Json cannot read the input (it was cut at the limit), the first "name": "value" pair is taken by a pattern, the way the sh version scans the text
    $m = [regex]::Match($text, '"' + [regex]::Escape($name) + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { return '' }
    $v = $m.Groups[1].Value
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $v.Length) {
        $c = $v[$i]
        if ($c -eq [char]92 -and ($i + 1) -lt $v.Length) {
            $d = $v[$i + 1]; $i += 2
            switch -CaseSensitive ($d) {
                'n' { [void]$sb.Append("`n") }
                't' { [void]$sb.Append("`t") }
                'r' { [void]$sb.Append("`r") }
                'b' { [void]$sb.Append([char]8) }
                'f' { [void]$sb.Append([char]12) }
                'u' {
                    if (($i + 4) -le $v.Length -and [regex]::IsMatch($v.Substring($i, 4), '^[0-9A-Fa-f]{4}$')) { [void]$sb.Append([char][Convert]::ToInt32($v.Substring($i, 4), 16)); $i += 4 } else { [void]$sb.Append('?') }
                }
                default { [void]$sb.Append($d) }
            }
        } else { [void]$sb.Append($c); $i++ }
    }
    return $sb.ToString()
}

function Invoke-HookDeny {
    if (-not $script:Probe) { exit 0 }
    $text = Read-Stdin 262144
    $doc = Get-JsonDoc $text
    $tn = ''
    if ($doc) { $tn = Get-JsonString $doc 'tool_name' } else { $tn = Get-JsonStringRaw $text 'tool_name' }
    $tool = ''; $target = ''
    $ti = $null
    if ($doc) { $ti = $doc.PSObject.Properties['tool_input'] }
    if (@('Read', 'Edit', 'Write') -ccontains $tn) {
        $tool = $tn
        if ($ti) { $target = Get-JsonString $ti.Value 'file_path' } elseif (-not $doc) { $target = Get-JsonStringRaw $text 'file_path' }
    } elseif (@('Bash', 'PowerShell') -ccontains $tn) {
        $tool = 'Bash'
        if ($ti) { $target = Get-JsonString $ti.Value 'command' } elseif (-not $doc) { $target = Get-JsonStringRaw $text 'command' }
    } else { exit 0 }
    if (-not $target) { exit 0 }
    foreach ($e in @(Get-StateEntries)) {
        if (Test-Same $e.st 'off') { continue }
        $dp = Join-Path (Join-Path $script:KD $e.id) 'deny.txt'
        if (-not (Test-Path -LiteralPath $dp -PathType Leaf)) { continue }
        $n = 0
        foreach ($l0 in [System.IO.File]::ReadAllLines($dp, $script:Utf8)) {
            $l = ([string]$l0).TrimEnd("`r")
            $n++
            if ($n -gt 60) { break }
            if (-not (Test-DenyLine $l)) { continue }
            $sp = $l.IndexOf(' ')
            $lt = $l.Substring(0, $sp); $lp = $l.Substring($sp + 1)
            if (-not (Test-Same $lt $tool)) { continue }
            if (Test-DenyMatch $lt $target $lp) {
                $reason = Get-Msg 'hook.deny' ([ordered]@{ name = (Get-PkgName $e.id); rule = $l; id = $e.id })
                Write-Out ('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"' + (ConvertTo-JsonText $reason) + '"}}' + "`n")
                exit 0
            }
        }
    }
    exit 0
}

if ($cmd -ceq 'hook') {
    switch -CaseSensitive ($arg2) {
        'loaded' { Invoke-HookLoaded }
        'deny' { Invoke-HookDeny }
        'start' { if (-not $script:Probe) { exit 0 }; $cmd = 'check'; $o.background = $true; $script:Quiet = $true }
        default { [Console]::Error.WriteLine('usage: kit.ps1 hook loaded|deny|start'); exit 2 }
    }
}

# ---------- token and site address ----------
$script:CourseData = ''
$script:Token = ''
$script:Site = ''
$script:TokenFile = ''
$script:SiteSet = $null
function Import-Token {
    $script:TokenErr = ''
    $script:CourseData = Find-CourseData
    if ($script:CourseMany) { $script:TokenErr = 'many'; return $false }
    if (-not $script:CourseData) { $script:TokenErr = 'notpaired'; return $false }
    $script:TokenFile = Join-Path $script:CourseData 'device-token.txt'
    $kv = Read-KV $script:TokenFile
    $tok = ''
    if ($kv) { $tok = [string]$kv['token'] }
    if (-not [regex]::IsMatch($tok, '^[A-Za-z0-9_-]{20,200}$')) { $script:TokenErr = 'notpaired'; return $false }
    $script:Token = $tok
    $site = [string]$kv['site']
    if (-not (Test-SiteUrl $site)) { $script:TokenErr = 'nosite'; return $false }
    $script:Site = $site
    $script:SiteSet = Get-SiteSetting $script:CourseData
    if ($script:SiteSet.state -eq 'ok' -and $script:SiteSet.url -cne $site) { $script:TokenErr = 'mismatch'; return $false }
    return $true
}
function Request-Token {
    if (Import-Token) { return }
    switch -CaseSensitive ($script:TokenErr) {
        'nosite' { Fail 'kit.nosite' $null 20 }
        'many' { Fail 'kit.manycourse' $null 26 }
        'mismatch' { Fail 'kit.sitemismatch' ([ordered]@{ old = $script:Site; new = $script:SiteSet.url }) 14 }
        default { Fail 'kit.notpaired' ([ordered]@{ cmd = ('/kit:' + $cmd) }) 40 }
    }
}
function Remove-Token { try { Remove-Item -LiteralPath $script:TokenFile -Force -ErrorAction Stop } catch { } }

# A refusal of a request: prints the phrase and ends the run
function Stop-OnReply($r) {
    $c = ('/kit:' + $cmd)
    $e = Get-JsonError $r.bytes
    switch ($r.status) {
        401 { if (-not $o.background) { Remove-Token }; Fail 'kit.rejected' ([ordered]@{ cmd = $c }) 11 }
        404 { Fail 'kit.disabled' ([ordered]@{ site = $script:Site }) 22 }
        422 { if (Test-Same $e 'unknown_package') { Fail 'kit.unknownpkg' $null 21 }; if (Test-Same $e 'engine') { Fail 'kit.updateplugin' $null 15 }; Fail 'kit.invalid' $null 24 }
        503 { if (Test-Same $e 'preview') { Fail 'kit.preview' ([ordered]@{ site = $script:Site }) 23 }; Fail 'kit.offline' ([ordered]@{ cmd = $c }) 10 }
        0 { if ($o.background) { Remove-Item -LiteralPath (Join-Path $script:KD 'last-bg') -Force -ErrorAction SilentlyContinue }; Fail 'kit.offline' ([ordered]@{ cmd = $c }) 10 }
        429 { Fail 'kit.offline' ([ordered]@{ cmd = $c }) 10 }
        default { Fail 'kit.unexpected' ([ordered]@{ status = $r.status }) 24 }
    }
}

# Request 1: report by state.txt and the list of new things. Returns the parsed list; errors end the run
function Request-List {
    $r = Invoke-Kit $script:Site '/api/plugin/kit' (Get-ReportBody) $script:Token
    if ($r.status -ne 200) { Stop-OnReply $r }
    if ($r.big) { Fail 'kit.badreply' $null 16 }
    $l = Read-List $r.bytes
    if ($l.err -ceq 'version') { Fail 'kit.updateplugin' $null 15 }
    if ($l.err) { Fail 'kit.badreply' $null 16 }
    return $l
}

# Statuses of all packages in state.txt by the disk (the time is now)
function Update-StateFromDisk {
    foreach ($e in @(Get-StateEntries)) {
        $ls = Get-LocalStatus $e.id
        try { Set-StateEntry $e.id $e.ver $ls $e.hash } catch { Fail 'kit.cantwrite' $null 25 }
    }
}

# ---------- show ----------
function Show-Status([string]$id, [string]$ver, [string]$st, [string]$latest) {
    $nm = Get-PkgName $id
    switch -CaseSensitive ($st) {
        'ok' {
            if ($latest -and (Test-VerLt $ver $latest)) { Say 'pkg.ok.newer' ([ordered]@{ name = $nm; version = $ver; latest = $latest }) }
            else { Say 'pkg.ok' ([ordered]@{ name = $nm; version = $ver }) }
        }
        'files' { Say 'pkg.files' ([ordered]@{ name = $nm; version = $ver }) }
        'absent' { Say 'pkg.absent' ([ordered]@{ name = $nm; version = $ver }) }
        'not_loaded' { Say 'pkg.notloaded' ([ordered]@{ name = $nm; version = $ver }) }
        'off' { Say 'pkg.off' ([ordered]@{ name = $nm; version = $ver; id = $id }) }
    }
}

# The result for each package of the list and for the packages that the list lacks. $res: @(@{ id; kind; arg })
function Show-All($list, $res, [string]$only) {
    foreach ($it in @($list.items)) {
        if ($only -and -not (Test-Same $only $it.id)) { continue }
        $hit = $null
        foreach ($r in @($res)) { if (Test-Same $r.id $it.id) { $hit = $r; break } }
        $kind = ''; $arg = ''
        if ($hit) { $kind = $hit.kind; $arg = [string]$hit.arg }
        $nm = Get-PkgName $it.id
        $loc = Get-StateEntry $it.id
        switch -CaseSensitive ($kind) {
            'placed' {
                $cur = Get-StateEntry $it.id
                if ($arg -and -not (Test-Same $arg $cur.ver)) { Say 'pkg.updated' ([ordered]@{ name = $nm; version = $cur.ver; old = $arg }) }
                else { Say 'pkg.ok' ([ordered]@{ name = $nm; version = $cur.ver }) }
            }
            'removed' { Say 'pkg.teamoff' ([ordered]@{ name = $nm }) }
            'occupied' { Say 'pkg.occupied' ([ordered]@{ name = $nm; version = $it.ver; path = $arg }) }
            'cantwrite' { Say 'pkg.cantwrite' ([ordered]@{ name = $nm; version = $it.ver }) }
            'bad' { Say ('pkg.bad.' + $arg) ([ordered]@{ name = $nm; version = $it.ver }) }
            'later' { Say 'pkg.later' ([ordered]@{ name = $nm; version = $it.ver }) }
            default {
                if ($loc) {
                    if ((Test-Same $it.want 'off') -and -not (Test-Same $loc.st 'off')) { Say 'pkg.wantoff' ([ordered]@{ name = $nm; version = $loc.ver }) }
                    else { Show-Status $it.id $loc.ver $loc.st $it.ver }
                } elseif (Test-Same $it.want 'on') { Say 'pkg.notinstalled' ([ordered]@{ name = $nm; version = $it.ver }) }
            }
        }
    }
    if ($only) { return }
    foreach ($e in @(Get-StateEntries)) {
        $inList = $false
        foreach ($it in @($list.items)) { if (Test-Same $it.id $e.id) { $inList = $true } }
        if ($inList) { continue }
        Show-Status $e.id $e.ver $e.st ''
    }
}

# Check of the denials: a decoy file with a harmless text in the plugin data (the name fits the pattern Read .env*). While the hooks are off the step says "not checked", never "stands".
function Show-DenyProbe {
    $any = $false
    foreach ($e in @(Get-StateEntries)) {
        if (Test-Same $e.st 'off') { continue }
        if (Test-Path -LiteralPath (Join-Path (Join-Path $script:KD $e.id) 'deny.txt') -PathType Leaf) { $any = $true }
    }
    if (-not $any) { return }
    if (-not $script:Probe) { Say 'kit.deny.notchecked' $null; return }
    $pd = Join-Path $script:KD 'probe'
    if (-not (Test-Path -LiteralPath $pd -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($pd) }
    $decoy = Join-Path $pd '.env.probe'
    Write-SecureFile $decoy "KIT_PROBE=this-is-a-harmless-decoy`n"
    Say 'kit.deny.probe' ([ordered]@{ path = $decoy })
}

# ---------- commands ----------
function Invoke-List {
    $any = $false
    foreach ($e in @(Get-StateEntries)) {
        $any = $true
        $ls = Get-LocalStatus $e.id
        Show-Status $e.id $e.ver $ls ''
    }
    if (-not $any) { Say 'kit.list.none' $null }
    Finish 0
}

function Invoke-Check {
    if ($o.background) {
        $lf = Join-Path $script:KD 'last-bg'
        $last = ''
        if (Test-Path -LiteralPath $lf -PathType Leaf) { try { $last = [string]([System.IO.File]::ReadAllLines($lf, $script:Utf8) | Select-Object -First 1) } catch { } }
        if ([regex]::IsMatch($last, '^[0-9]{1,12}$') -and ((Get-NowEpoch) - [int64]$last) -lt 86400) { exit 0 }
    }
    if (-not (Enter-KitLock)) { Fail 'kit.busy' $null 19 }
    Request-Token
    Update-StateFromDisk
    # Background: "at most once a day" holds on the site's refusals too: the mark is written before the request (no network - it is removed in Stop-OnReply)
    if ($o.background) { Write-SecureFile (Join-Path $script:KD 'last-bg') ([string](Get-NowEpoch) + "`n") }
    $list = Request-List
    if ($o.background) { exit 0 }
    if ((Test-Same $list.state 'none') -and @(Get-StateEntries).Count -eq 0) { Say 'kit.none' $null; Finish 0 }
    Show-All $list @() ''
    Show-DenyProbe
    Finish 0
}

# install | update | on: the common course. $mode = install|update|on, $onId - the package for on
function Invoke-Sync([string]$mode, [string]$onId) {
    if (-not (Enter-KitLock)) { Fail 'kit.busy' $null 19 }
    Request-Token
    Update-StateFromDisk
    $list = Request-List
    $res = New-Object System.Collections.ArrayList
    $fetch = @(); $changed = $false
    foreach ($it in @($list.items)) {
        $locE = Get-StateEntry $it.id
        $loc = ''; $lver = ''
        if ($locE) { $loc = $locE.st; $lver = $locE.ver }
        if ($mode -ceq 'on') {
            if (-not (Test-Same $it.id $onId)) { continue }
            if (-not $loc) { Fail 'kit.off.unknown' ([ordered]@{ id = $it.id }) 13 }
            if (-not (Test-Same $loc 'off')) { Fail 'kit.on.notoff' ([ordered]@{ id = $it.id }) 13 }
            if (Test-Same $it.want 'off') { Fail 'kit.on.teamoff' ([ordered]@{ name = (Get-PkgName $it.id) }) 18 }
            if (-not (Test-Same $it.want 'on')) { Fail 'kit.on.notinset' ([ordered]@{ name = (Get-PkgName $it.id) }) 18 }
            $fetch += $it.id
            continue
        }
        if (Test-Same $it.want 'on') {
            if (Test-Same $loc 'off') { continue }
            $need = $false
            if (-not $loc) { if ($mode -ceq 'install') { $need = $true } }
            elseif (Test-VerLt $lver $it.ver) { $need = $true }
            elseif (($mode -ceq 'install') -and ((Test-Same $loc 'files') -or (Test-Same $loc 'absent'))) { $need = $true }
            if ($need) {
                if ($fetch.Count -ge 8) { [void]$res.Add(@{ id = $it.id; kind = 'later'; arg = '' }) } else { $fetch += $it.id }
            }
        } elseif (Test-Same $it.want 'off') {
            if ($loc -and -not (Test-Same $loc 'off')) {
                try { Remove-Package $it.id } catch { Fail 'kit.cantwrite' $null 25 }
                [void]$res.Add(@{ id = $it.id; kind = 'removed'; arg = '' }); $changed = $true
            }
        }
    }
    if (($mode -ceq 'on') -and $fetch.Count -eq 0) { Fail 'kit.on.notinset' ([ordered]@{ name = (Get-PkgName $onId) }) 18 }
    # Request 2: packages. A 422 "split" (what the person is entitled to is over 200 KB, contract clarification 11) splits the group in two and asks the halves in turn;
    # at most three package requests per run, the rest is "later". One package that does not fit is "bigger than allowed"
    if ($fetch.Count -gt 0) {
        $queue = New-Object System.Collections.ArrayList
        [void]$queue.Add(@($fetch))
        $pkgPosts = 0
        while ($queue.Count -gt 0) {
            $grp = @($queue[0]); $queue.RemoveAt(0)
            if ($pkgPosts -ge 3) { foreach ($x in $grp) { [void]$res.Add(@{ id = $x; kind = 'later'; arg = '' }) }; continue }
            $pkgPosts++
            $ids = ($grp | ForEach-Object { '"' + $_ + '"' }) -join ','
            $body = '{"plugin_version":"' + (Get-PluginVersion) + '","os":"windows","engine":' + $script:EngineLevel + ',"ids":[' + $ids + ']}'
            $r = Invoke-Kit $script:Site '/api/plugin/kit/package' $body $script:Token
            if ($r.status -eq 422 -and (Test-Same (Get-JsonError $r.bytes) 'split')) {
                if ($grp.Count -le 1) { [void]$res.Add(@{ id = $grp[0]; kind = 'bad'; arg = 'size' }); continue }
                $half = [int][math]::Ceiling($grp.Count / 2)
                $ha = @($grp[0..($half - 1)]); $hb = @($grp[$half..($grp.Count - 1)])
                $queue.Insert(0, $hb); $queue.Insert(0, $ha)
                continue
            }
            if ($r.status -ne 200 -and $r.status -ne 401 -and $changed) {
                # some packages already stand: the others are "later", the final report still goes
                foreach ($x in $grp) { [void]$res.Add(@{ id = $x; kind = 'later'; arg = '' }) }
                foreach ($q in $queue) { foreach ($x in @($q)) { [void]$res.Add(@{ id = $x; kind = 'later'; arg = '' }) } }
                $queue.Clear()
                break
            }
            if ($r.status -ne 200) { Stop-OnReply $r }
            if ($r.big) { Fail 'kit.badreply' $null 16 }
            $pk = Read-Packages $r.bytes $grp
            if ($pk.err -ceq 'version') { Fail 'kit.updateplugin' $null 15 }
            if ($pk.err) { Fail 'kit.badreply' $null 16 }
            Test-PackageHashes $pk.pkgs
            foreach ($p in @($pk.pkgs)) {
                if ($p.err) { [void]$res.Add(@{ id = $p.id; kind = 'bad'; arg = $p.err }); continue }
                $beforeE = Get-StateEntry $p.id
                $before = ''
                if ($beforeE) { $before = $beforeE.ver }
                $pl = Save-Package $p
                switch -CaseSensitive ($pl.result) {
                    'placed' { [void]$res.Add(@{ id = $p.id; kind = 'placed'; arg = $before }); $changed = $true }
                    'occupied' { [void]$res.Add(@{ id = $p.id; kind = 'occupied'; arg = $pl.occ }) }
                    default { [void]$res.Add(@{ id = $p.id; kind = 'cantwrite'; arg = '' }) }
                }
            }
        }
    }
    if ($mode -ceq 'on') { Show-All $list $res $onId } else { Show-All $list $res '' }
    if ((Test-Same $list.state 'none') -and -not $changed -and @(Get-StateEntries).Count -eq 0) { Say 'kit.none' $null }
    # Request 3: the final report, only if something changed
    if ($changed) {
        $r3 = Invoke-Kit $script:Site '/api/plugin/kit' (Get-ReportBody) $script:Token
        if ($r3.status -eq 401) { Remove-Token; Fail 'kit.rejected' ([ordered]@{ cmd = '/kit:check' }) 11 }
        if ($r3.status -ne 200) { Say 'kit.reportlater' $null; Finish 10 }
    }
    foreach ($r in $res) { if (@('occupied', 'bad', 'cantwrite', 'later') -ccontains $r.kind) { Finish 17 } }
    Finish 0
}

function Invoke-Off {
    if (-not (Test-IdArg $arg2)) { Fail 'kit.badid' $null 12 }
    if (-not (Enter-KitLock)) { Fail 'kit.busy' $null 19 }
    $cur = Get-StateEntry $arg2
    if (-not $cur) { Fail 'kit.off.unknown' ([ordered]@{ id = $arg2 }) 13 }
    $nm = Get-PkgName $arg2
    if (Test-Same $cur.st 'off') { Say 'kit.off.already' ([ordered]@{ name = $nm; id = $arg2 }); Finish 0 }
    try { Remove-Package $arg2 } catch { Fail 'kit.cantwrite' $null 25 }
    Say 'kit.off.done' ([ordered]@{ name = $nm; id = $arg2 })
    # The site learns of it with the next report; no token or no network - it is off on this computer only
    if (-not (Import-Token)) { Say 'kit.off.local' $null; Finish 0 }
    $r = Invoke-Kit $script:Site '/api/plugin/kit' (Get-ReportBody) $script:Token
    if ($r.status -eq 200) { Finish 0 }
    if ($r.status -eq 401) { Remove-Token }
    Say 'kit.off.local' $null
    Finish 0
}

switch -CaseSensitive ($cmd) {
    'list' { Invoke-List }
    'check' { Invoke-Check }
    'install' { Invoke-Sync 'install' '' }
    'update' { Invoke-Sync 'update' '' }
    'on' { if (-not (Test-IdArg $arg2)) { Fail 'kit.badid' $null 12 }; Invoke-Sync 'on' $arg2 }
    'off' { Invoke-Off }
}
