# Common helpers for kit.ps1 (PowerShell 5.1, no extra tools). The same behaviour and output as lib.sh.
# ASCII only: Russian text lives in messages.txt (UTF-8), so the file does not depend on the script encoding.
# The token is never printed, never put on a command line and never put in a URL. Helpers marked "course" are copies from the course plugin (it is not changed).
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Here = $PSScriptRoot
$script:Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$script:Quiet = $false
$script:EngineLevel = 1
$script:BodyMax = 262144

function Write-Out([string]$text) {
    $b = $script:Utf8.GetBytes($text)
    $o = [Console]::OpenStandardOutput()
    $o.Write($b, 0, $b.Length)
    $o.Flush()
}

# Message from messages.txt; $null if there is no such key. The \n of the template becomes a line break BEFORE the values are put in.
function Get-MsgOrNull([string]$key) {
    $lines = [System.IO.File]::ReadAllLines((Join-Path $script:Here 'messages.txt'), $script:Utf8)
    $prefix = $key + '='
    $line = $lines | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    return ([string]$line).Substring($prefix.Length).TrimEnd("`r")
}
function Get-Msg([string]$key, $vars) {
    $text = [string](Get-MsgOrNull $key)
    $text = $text.Replace('\n', "`n")
    if ($vars) { foreach ($k in $vars.Keys) { $text = $text.Replace('{' + $k + '}', [string]$vars[$k]) } }
    return $text
}
function Say([string]$key, $vars) { if ($script:Quiet) { return }; Write-Out ((Get-Msg $key $vars) + "`n") }

# Options: <command> [<argument>] --name value ... --soft --background (the same syntax as in the sh version)
$script:KnownOpts = @('data', 'probe', 'flat')
function Get-Opts($argv) {
    $o = @{ cmd = $null; arg2 = $null; soft = $false; background = $false }
    $i = 0
    while ($i -lt $argv.Count) {
        $a = [string]$argv[$i]
        if (Test-Same $a '--soft') { $o.soft = $true; $i++ }
        elseif (Test-Same $a '--background') { $o.background = $true; $i++ }
        elseif ($a.StartsWith('--') -and ($script:KnownOpts -ccontains $a.Substring(2))) {
            if (($i + 1) -lt $argv.Count -and -not ([string]$argv[$i + 1]).StartsWith('--')) { $o[$a.Substring(2)] = [string]$argv[$i + 1]; $i += 2 } else { $i++ }
        }
        elseif ($a.StartsWith('--')) { $i++ }
        else { if ($null -eq $o.cmd) { $o.cmd = $a } elseif ($null -eq $o.arg2) { $o.arg2 = $a }; $i++ }
    }
    return $o
}

function Test-Same([string]$a, [string]$b) { return [string]::Equals($a, $b, [System.StringComparison]::Ordinal) }
function Get-NowEpoch { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Get-IsoNow { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }

# Plugin data folder: --data, else CLAUDE_PLUGIN_DATA, else a folder in the profile (manual runs only). The kit folder is inside it.
function Initialize-Data($o) {
    $d = [string]$o['data']
    if (-not $d -or $d.Contains('${')) { $d = [string]$env:CLAUDE_PLUGIN_DATA }
    $script:DataFallback = $false
    if (-not $d -or $d.Contains('${')) { $d = Join-Path $env:USERPROFILE '.stratum-kit'; $script:DataFallback = $true }
    $kd = Join-Path $d 'kit'
    if (-not (Test-Path -LiteralPath $kd -PathType Container)) { [void](New-Item -ItemType Directory -Path $kd -Force) }
    $script:Data = $d
    $script:KD = $kd
}

# Switches: true from the plugin settings (${user_config...} in the skill) or from the hook environment. An unexpanded substitution means off.
function Test-FlagOn([string]$value, [string]$envName) {
    $v = $value
    if ($v -and $v.Contains('${')) { $v = '' }
    if (-not $v) { $v = [string][Environment]::GetEnvironmentVariable($envName) }
    return (Test-Same $v 'true')
}
function Initialize-Settings($o) {
    $script:Probe = (Test-FlagOn ([string]$o['probe']) 'CLAUDE_PLUGIN_OPTION_PROBE_HOOKS')
    $script:Layout = 'folders'
    if (Test-FlagOn ([string]$o['flat']) 'CLAUDE_PLUGIN_OPTION_FLAT_NAMES') { $script:Layout = 'flat' }
}
function Initialize-Rules {
    $c = [string]$env:CLAUDE_CONFIG_DIR
    if (-not $c) { $c = Join-Path $env:USERPROFILE '.claude' }
    $script:Rules = Join-Path $c 'rules'
}

$script:SiteRe = '^(https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?)$'
function Test-SiteUrl([string]$u) { return [regex]::IsMatch($u, $script:SiteRe) }

function Get-PluginVersion {
    try {
        $p = Join-Path $script:Here '..\.claude-plugin\plugin.json'
        $v = [string]((([System.IO.File]::ReadAllText($p, $script:Utf8)) | ConvertFrom-Json).version)
        if ($v -match '^[0-9A-Za-z.+-]{1,20}$') { return $v }
    } catch { }
    return '0'
}

# key=value file (one pair per line): exact keys, the first one wins (the same as kv in the sh version)
function Read-KV([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $h = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    try {
        foreach ($l in [System.IO.File]::ReadAllLines($path, $script:Utf8)) {
            $i = $l.IndexOf('=')
            if ($i -gt 0) { $k = $l.Substring(0, $i); if (-not $h.ContainsKey($k)) { $h[$k] = $l.Substring($i + 1).TrimEnd("`r") } }
        }
    } catch { return $null }
    return $h
}

function Test-IsLink([string]$p) {
    # A link is only what Windows follows: a symbolic link or a junction (cloud placeholders and app aliases are not links)
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -eq $i) { return $false }
    $t = [string]$i.LinkType
    return ((Test-Same $t 'SymbolicLink') -or (Test-Same $t 'Junction'))
}
function Remove-NameOnly([string]$p) {
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($item) { if ($item.PSIsContainer) { [System.IO.Directory]::Delete($p) } else { [System.IO.File]::Delete($p) } }
}

# A file only the current user can open: the empty temporary file gets a protected ACL, then the bytes are written, then the file replaces the target.
function Write-SecureBytes([string]$path, [byte[]]$bytes) {
    $tmp = $path + '.tmp'
    Remove-NameOnly $tmp
    $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $fs.Close()
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
    Set-Acl -LiteralPath $tmp -AclObject $acl
    [System.IO.File]::WriteAllBytes($tmp, $bytes)
    $dest = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($dest -and (($dest.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { Remove-NameOnly $path }
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Write-SecureFile([string]$path, [string]$text) { Write-SecureBytes $path ($script:Utf8.GetBytes($text)) }

function Get-Sha256([byte[]]$bytes) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { $d = $h.ComputeHash($bytes) } finally { $h.Dispose() }
    return (($d | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Get-FileSha([string]$path) { return (Get-Sha256 ([System.IO.File]::ReadAllBytes($path))) }

# ---------- lock: the entry .lock with the process number (created atomically with CreateNew) ----------
# Held by a live process: a straight phrase and code 19. The lock of a dead process, or older than 10 minutes, is removed at once.
function Enter-KitLock {
    $lock = Join-Path $script:Data '.lock'
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $b = $script:Utf8.GetBytes([string]$PID + "`n"); $fs.Write($b, 0, $b.Length) } finally { $fs.Close() }
            $script:LockPath = $lock
            return $true
        } catch { }
        $it = Get-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        if (-not $it) { continue }
        $dead = $false
        $lp = ''
        try { $lp = [string]([System.IO.File]::ReadAllLines($lock, $script:Utf8) | Select-Object -First 1) } catch { }
        if ([regex]::IsMatch($lp, '^[0-9]{1,9}$')) { if (-not (Get-Process -Id ([int]$lp) -ErrorAction SilentlyContinue)) { $dead = $true } }
        if (((Get-Date).ToUniversalTime() - $it.LastWriteTimeUtc).TotalMinutes -gt 10) { $dead = $true }
        if ($dead) { try { Remove-Item -LiteralPath $lock -Force -Recurse -ErrorAction Stop } catch { } } else { return $false }
    }
    return $false
}
function Exit-KitLock {
    if ($script:LockPath) { try { Remove-Item -LiteralPath $script:LockPath -Force -Recurse -ErrorAction Stop } catch { }; $script:LockPath = $null }
}

# ---------- token and site address: from the course plugin, the pairing is not duplicated ----------
# The token file is in the data folder of the course plugin (course-<marketplace>), a neighbour of the kit data folder. In order: KIT_COURSE_DATA,
# the neighbour folder course-stratum-course, else the only neighbour course-* with a token (several: refusal, code 26), the profile folder .stratum-course (manual course runs; with the fallback data folder only this one).
function Find-CourseData {
    $script:CourseMany = $false
    if ($env:KIT_COURSE_DATA) {
        if (Test-Path -LiteralPath (Join-Path $env:KIT_COURSE_DATA 'device-token.txt') -PathType Leaf) { return [string]$env:KIT_COURSE_DATA }
        return ''
    }
    $best = ''
    # With the fallback data folder (manual run) there are no neighbours: only the profile folder .stratum-course is looked at
    if (-not $script:DataFallback) {
        $par = Split-Path -Parent $script:Data
        $exact = Join-Path $par 'course-stratum-course'
        $ef = Join-Path $exact 'device-token.txt'
        if ((Test-Path -LiteralPath $ef -PathType Leaf) -and -not (Test-IsLink $ef)) { $best = $exact }
        else {
            # No exact name: the only neighbour course-* with a token is taken; several - refusal (the person says which one: KIT_COURSE_DATA)
            $cnt = 0
            foreach ($c in @(Get-ChildItem -LiteralPath $par -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith('course-', [System.StringComparison]::Ordinal) } | Sort-Object Name)) {
                $f = Join-Path $c.FullName 'device-token.txt'
                if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Test-IsLink $f)) { continue }
                $cnt++; $best = $c.FullName
            }
            if ($cnt -gt 1) { $script:CourseMany = $true; return '' }
        }
    }
    if (-not $best) {
        $h = Join-Path $env:USERPROFILE '.stratum-course'
        if (Test-Path -LiteralPath (Join-Path $h 'device-token.txt') -PathType Leaf) { $best = $h }
    }
    return $best
}

# Site address setting of the course: COURSE_SITE_URL, else the first line of the site-url file in the course data folder. Returns @{ state = 'ok'|'none'|'bad'; url }.
function Get-SiteSetting([string]$courseData) {
    $v = [string]$env:COURSE_SITE_URL
    if (-not $v -and $courseData) {
        $f = Join-Path $courseData 'site-url'
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            $first = [System.IO.File]::ReadAllLines($f, $script:Utf8) | Select-Object -First 1
            if ($first) { $v = [string]$first }
        }
    }
    if (-not $v) { return @{ state = 'none'; url = '' } }
    $v = $v.Trim().TrimEnd('/')
    if (Test-SiteUrl $v) { return @{ state = 'ok'; url = $v } }
    return @{ state = 'bad'; url = '' }
}

# ---------- request to the site ----------
# One POST. status 0 = no answer from the site. Redirects are not followed (a token must never go to another address). At most BodyMax bytes are read: more = big.
function Invoke-Kit([string]$site, [string]$path, [string]$json, [string]$token) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($site + $path)
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Accept = 'text/plain'
        $req.UserAgent = 'stratum-kit-plugin'
        $req.Timeout = 15000
        $req.ReadWriteTimeout = 15000
        $req.AllowAutoRedirect = $false
        if ($token) { $req.Headers.Add('Authorization', 'Bearer ' + $token) }
        $bytes = $script:Utf8.GetBytes($json)
        $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream()
        $rs.Write($bytes, 0, $bytes.Length)
        $rs.Close()
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
    } catch {
        $resp = $null
    }
    if ($null -eq $resp) { return @{ status = 0; bytes = (New-Object byte[] 0); big = $false } }
    $status = [int]$resp.StatusCode
    $ms = New-Object System.IO.MemoryStream
    $big = $false
    try {
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 8192
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
            if (($ms.Length + $n) -gt $script:BodyMax) { $big = $true; break }
            $ms.Write($buf, 0, $n)
        }
    } catch { }
    try { $resp.Close() } catch { }
    return @{ status = $status; bytes = $ms.ToArray(); big = $big }
}
function Get-JsonError([byte[]]$bytes) {
    try { $j = $script:Utf8.GetString($bytes) | ConvertFrom-Json; return [string]$j.error } catch { return '' }
}

# ---------- parsing of answers (the same checks as in lib.sh) ----------
# Hidden and control characters (not LF and TAB), DEL, C1, zero-width and direction marks, line and paragraph separators, BOM, tag characters
$script:HiddenRe = '[\x00-\x08\x0b-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2060-\u2069\u061c\ufeff]|\uDB40[\uDC00-\uDC7F]'

# Windows device names (con, prn, aux, nul, com0-9, lpt0-9) are refused as an id and as a rule name (the part before the first dot), without case
function Test-ReservedName([string]$s) {
    $b = $s
    $i = $b.IndexOf('.')
    if ($i -ge 0) { $b = $b.Substring(0, $i) }
    return [regex]::IsMatch($b.ToLowerInvariant(), '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$')
}
function Test-IdOk([string]$s) { return ($s.Length -ge 2 -and $s.Length -le 30 -and [regex]::IsMatch($s, '^[a-z][a-z0-9-]*$') -and -not (Test-ReservedName $s)) }
function Test-VerOk([string]$s) { return [regex]::IsMatch($s, '^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$') }
function Test-ShaOk([string]$s) { return [regex]::IsMatch($s, '^[0-9a-f]{64}$') }
function Test-RuleName([string]$s) {
    if ($s.Length -lt 4 -or $s.Length -gt 43 -or -not [regex]::IsMatch($s, '^[a-z0-9][a-z0-9-]*\.md$')) { return $false }
    $low = $s.ToLowerInvariant()
    return -not ((Test-Same $low 'claude.md') -or (Test-Same $low 'agents.md') -or (Test-ReservedName $s))
}

# Basic checks of an answer: size, no NUL and CR, ends with LF, valid UTF-8. Returns the text or $null.
function Get-BodyText([byte[]]$bytes, [int]$max) {
    if ($bytes.Length -lt 1 -or $bytes.Length -gt $max) { return $null }
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0 -or [Array]::IndexOf($bytes, [byte]13) -ge 0) { return $null }
    if ($bytes[$bytes.Length - 1] -ne 10) { return $null }
    try { return $script:Utf8Strict.GetString($bytes) } catch { return $null }
}
function Test-HeadValue([string]$v) {
    return ([regex]::IsMatch($v, '[\x00-\x1f\x7f]') -or [regex]::IsMatch($v, $script:HiddenRe) -or $script:Utf8.GetByteCount($v) -gt 300)
}

# Request 1 answer. Returns @{ err = '' | 'version' | 'format'; state; team; items = @(@{ id; ver; want }) }
function Read-List([byte[]]$bytes) {
    $bad = @{ err = 'format'; state = ''; team = 0; items = @() }
    $text = Get-BodyText $bytes 65536
    if ($null -eq $text) { return $bad }
    $lines = $text.Split("`n")
    $n = $lines.Length - 1
    if (-not (Test-Same $lines[0] 'stratum-kit 1')) {
        if ([regex]::IsMatch($lines[0], '^stratum-kit [0-9]+$')) { return @{ err = 'version'; state = ''; team = 0; items = @() } }
        return $bad
    }
    $H = @{}
    for ($i = 1; $i -lt $n; $i++) {
        $l = $lines[$i]
        if ($l.Length -eq 0) { return $bad }
        $eq = $l.IndexOf('=')
        if ($eq -lt 1) { return $bad }
        $k = $l.Substring(0, $eq); $v = $l.Substring($eq + 1)
        if (-not [regex]::IsMatch($k, '^[a-z_0-9]+$') -or (Test-HeadValue $v) -or $H.ContainsKey($k)) { return $bad }
        $H[$k] = $v
    }
    $st = [string]$H['state']
    if (-not ((Test-Same $st 'ok') -or (Test-Same $st 'none'))) { return $bad }
    if (-not [regex]::IsMatch([string]$H['packages'], '^[0-9]{1,2}$') -or [int]$H['packages'] -gt 16) { return $bad }
    if ($H.ContainsKey('team') -and -not ((Test-Same ([string]$H['team']) '0') -or (Test-Same ([string]$H['team']) '1'))) { return $bad }
    $np = [int]$H['packages']
    if ((Test-Same $st 'none') -and $np -ne 0) { return $bad }
    foreach ($k in @($H.Keys)) {
        if ($k.StartsWith('pkg_', [System.StringComparison]::Ordinal)) {
            $s = $k.Substring(4)
            if (-not [regex]::IsMatch($s, '^[0-9]{1,2}$') -or [int]$s -lt 1 -or [int]$s -gt $np) { return $bad }
        }
    }
    $items = @(); $seen = @{}
    for ($j = 1; $j -le $np; $j++) {
        if (-not $H.ContainsKey('pkg_' + $j)) { return $bad }
        $f = ([string]$H['pkg_' + $j]).Split(' ')
        if ($f.Count -ne 3 -or -not (Test-IdOk $f[0]) -or -not (Test-VerOk $f[1]) -or -not (@('on', 'off', 'none') -ccontains $f[2]) -or $seen.ContainsKey($f[0])) { return $bad }
        $seen[$f[0]] = $true
        $items += , @{ id = $f[0]; ver = $f[1]; want = $f[2] }
    }
    $team = 0
    if ($H.ContainsKey('team')) { $team = [int]$H['team'] }
    return @{ err = ''; state = $st; team = $team; items = $items }
}

# Request 2 answer ("stratum-kit-package 1"). $wantIds - ids asked for. Returns @{ err = '' | 'version' | 'format'; pkgs = @(@{ id; ver; err; rules = @(@{ name; sha; text }); deny; denySha }) }.
# A structural fault rejects the whole answer; a fault of one package rejects only that package (err: name | size | paths | deny | text | parts; the hashes are checked later).
function Read-Packages([byte[]]$bytes, [string[]]$wantIds) {
    $bad = @{ err = 'format'; pkgs = @() }
    $text = Get-BodyText $bytes $script:BodyMax
    if ($null -eq $text) { return $bad }
    $lines = $text.Split("`n")
    $n = $lines.Length - 1
    if (-not (Test-Same $lines[0] 'stratum-kit-package 1')) {
        if ([regex]::IsMatch($lines[0], '^stratum-kit-package [0-9]+$')) { return @{ err = 'version'; pkgs = @() } }
        return $bad
    }
    $H = @{}
    $i = 1
    while ($true) {
        if ($i -ge $n) { return $bad }
        $l = $lines[$i]; $i++
        if ($l.Length -eq 0) { break }
        $eq = $l.IndexOf('=')
        if ($eq -lt 1) { return $bad }
        $k = $l.Substring(0, $eq); $v = $l.Substring($eq + 1)
        if (-not [regex]::IsMatch($k, '^[a-z_0-9]+$') -or (Test-HeadValue $v) -or $H.ContainsKey($k)) { return $bad }
        $H[$k] = $v
    }
    if (-not [regex]::IsMatch([string]$H['boundary'], '^[0-9a-f]{32}$')) { return $bad }
    if (-not [regex]::IsMatch([string]$H['packages'], '^[1-8]$')) { return $bad }
    if ($H.ContainsKey('min_engine')) {
        if (-not [regex]::IsMatch([string]$H['min_engine'], '^[0-9]{1,2}$')) { return $bad }
        if ([int]$H['min_engine'] -gt $script:EngineLevel) { return @{ err = 'version'; pkgs = @() } }
    }
    $want = @{}
    foreach ($w in $wantIds) { $want[$w] = $true }
    if ([int]$H['packages'] -ne @($wantIds).Count) { return $bad }
    $pre = '--' + [string]$H['boundary']
    $pkgs = New-Object System.Collections.ArrayList
    $seen = @{}
    $cur = $null          # current package
    $kind = ''            # '' | 'sink' | 'rule' | 'deny'
    $buf = $null; $sz = 0; $curRule = $null
    $ended = $false
    function Add-Err($p, [string]$e) { if (-not $p.err) { $p.err = $e } }
    function Close-Part {
        if ($null -ne $script:pkBuf -and $script:pkKind -ne 'sink') {
            $t = $null
            if ($script:pkBuf.Count -gt 0) { $t = (($script:pkBuf.ToArray() -join "`n") + "`n") } else { $t = '' }
            if ($script:pkKind -eq 'rule') { $script:pkRule.text = $t } elseif ($script:pkKind -eq 'deny') { $script:pkCur.deny = $t }
        }
        $script:pkBuf = $null
    }
    $script:pkBuf = $null; $script:pkKind = ''; $script:pkRule = $null; $script:pkCur = $null
    for (; $i -lt $n; $i++) {
        $l = $lines[$i]
        if ($ended) { return $bad }
        if ($l.StartsWith($pre, [System.StringComparison]::Ordinal)) {
            $rest = $l.Substring($pre.Length)
            $t = $rest.Split(' ')
            if (Test-Same $rest ' end') {
                Close-Part
                if ($null -ne $script:pkCur -and ($script:pkCur.rules.Count -lt 1 -or $script:pkCur.rules.Count -gt 4)) { Add-Err $script:pkCur 'parts' }
                $ended = $true; continue
            }
            if ($t.Count -eq 4 -and $t[0] -eq '' -and (Test-Same $t[1] 'package')) {
                Close-Part
                if ($null -ne $script:pkCur -and ($script:pkCur.rules.Count -lt 1 -or $script:pkCur.rules.Count -gt 4)) { Add-Err $script:pkCur 'parts' }
                if (-not (Test-IdOk $t[2]) -or -not (Test-VerOk $t[3]) -or -not $want.ContainsKey($t[2]) -or $seen.ContainsKey($t[2])) { return $bad }
                $seen[$t[2]] = $true
                $script:pkCur = @{ id = $t[2]; ver = $t[3]; err = ''; rules = (New-Object System.Collections.ArrayList); deny = $null; denySha = ''; bytes = 0; dn = 0; nd = 0; names = @{} }
                [void]$pkgs.Add($script:pkCur)
                $script:pkBuf = New-Object 'System.Collections.Generic.List[string]'
                $script:pkKind = 'sink'
                continue
            }
            if ($null -eq $script:pkCur) { return $bad }
            Close-Part
            if ($t.Count -eq 4 -and $t[0] -eq '' -and (Test-Same $t[1] 'rule') -and (Test-ShaOk $t[3]) -and $script:pkCur.nd -eq 0) {
                $low = $t[2].ToLowerInvariant()
                if (-not (Test-RuleName $t[2]) -or $script:pkCur.names.ContainsKey($low)) { Add-Err $script:pkCur 'name' }
                $script:pkCur.names[$low] = $true
                $r = @{ name = $t[2]; sha = $t[3]; text = '' }
                [void]$script:pkCur.rules.Add($r)
                $script:pkRule = $r
                $script:pkBuf = New-Object 'System.Collections.Generic.List[string]'
                $script:pkKind = 'rule'; $sz = 0
                continue
            }
            if ($t.Count -eq 3 -and $t[0] -eq '' -and (Test-Same $t[1] 'deny') -and (Test-ShaOk $t[2]) -and $script:pkCur.nd -eq 0 -and $script:pkCur.rules.Count -ge 1) {
                $script:pkCur.nd = 1
                $script:pkCur.denySha = $t[2]
                $script:pkCur.deny = ''
                $script:pkBuf = New-Object 'System.Collections.Generic.List[string]'
                $script:pkKind = 'deny'; $sz = 0
                continue
            }
            Add-Err $script:pkCur 'parts'
            $script:pkBuf = New-Object 'System.Collections.Generic.List[string]'
            $script:pkKind = 'sink'
            continue
        }
        if ($null -eq $script:pkBuf) { return $bad }
        if ($script:pkKind -eq 'sink') { Add-Err $script:pkCur 'parts'; continue }
        if ([regex]::IsMatch($l, $script:HiddenRe)) { Add-Err $script:pkCur 'text' }
        $len = $script:Utf8.GetByteCount($l) + 1
        $sz += $len; $script:pkCur.bytes += $len
        if ($script:pkKind -eq 'rule') {
            if ($sz -gt 16384 -or $script:pkCur.bytes -gt 40960) { Add-Err $script:pkCur 'size' }
            if ($l.StartsWith('paths:', [System.StringComparison]::Ordinal)) { Add-Err $script:pkCur 'paths' }
        } else {
            $script:pkCur.dn++
            if ($l.Contains('?')) { Add-Err $script:pkCur 'denyq' }
            elseif ($script:pkCur.dn -gt 60 -or -not (Test-DenyLine $l) -or $script:pkCur.bytes -gt 40960) { Add-Err $script:pkCur 'deny' }
        }
        $script:pkBuf.Add($l)
    }
    if (-not $ended) { return $bad }
    if ($pkgs.Count -ne [int]$H['packages']) { return $bad }
    return @{ err = ''; pkgs = @($pkgs.ToArray()) }
}

# Compares the sha256 of every part with the one in the answer; a mismatch gives err = hash (when the package has no fault yet)
function Test-PackageHashes($pkgs) {
    foreach ($p in $pkgs) {
        if ($p.err) { continue }
        $badHash = $false
        foreach ($r in $p.rules) { if (-not (Test-Same (Get-Sha256 ($script:Utf8.GetBytes([string]$r.text))) $r.sha)) { $badHash = $true } }
        if ($p.nd -eq 1 -and -not (Test-Same (Get-Sha256 ($script:Utf8.GetBytes([string]$p.deny))) $p.denySha)) { $badHash = $true }
        if ($badHash) { $p.err = 'hash' }
    }
}

# ---------- state: state.txt ("id version status sha256 time"), the manifest of a package, the load log ----------
$script:StatusList = @('ok', 'files', 'not_loaded', 'absent', 'off')
function Get-StateEntries {
    $out = @()
    $f = Join-Path $script:KD 'state.txt'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $out }
    $seen = @{}
    try {
        foreach ($l0 in [System.IO.File]::ReadAllLines($f, $script:Utf8)) {
            $l = ([string]$l0).TrimEnd("`r")
            $t = $l.Split(' ')
            if ($t.Count -ne 5) { continue }
            if (-not (Test-IdOk $t[0]) -or -not [regex]::IsMatch($t[1], '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') -or $t[1].Length -gt 7 -or ($script:StatusList -cnotcontains $t[2]) -or -not (Test-ShaOk $t[3]) -or -not [regex]::IsMatch($t[4], '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')) { continue }
            if ($seen.ContainsKey($t[0])) { continue }
            $seen[$t[0]] = $true
            $out += , @{ id = $t[0]; ver = $t[1]; st = $t[2]; hash = $t[3]; time = $t[4] }
        }
    } catch { }
    return $out
}
function Get-StateEntry([string]$id) {
    foreach ($e in @(Get-StateEntries)) { if (Test-Same $e.id $id) { return $e } }
    return $null
}
function Write-StateEntries($entries) {
    $text = ''
    foreach ($e in @($entries)) { $text += ($e.id + ' ' + $e.ver + ' ' + $e.st + ' ' + $e.hash + ' ' + $e.time + "`n") }
    Write-SecureFile (Join-Path $script:KD 'state.txt') $text
}
# Replaces the line of the package (it stays in its place) or adds a new one at the end; the time is now
function Set-StateEntry([string]$id, [string]$ver, [string]$st, [string]$hash) {
    $new = @{ id = $id; ver = $ver; st = $st; hash = $hash; time = (Get-IsoNow) }
    $all = @(Get-StateEntries)
    $out = @(); $found = $false
    foreach ($e in $all) { if (Test-Same $e.id $id) { $out += , $new; $found = $true } else { $out += , $e } }
    if (-not $found) { $out += , $new }
    Write-StateEntries $out
}

function Get-ManifestPath([string]$id) { return (Join-Path (Join-Path $script:KD $id) 'manifest.txt') }
# The manifest: @{ layout; rules = @(@{name; sha}); deny } or $null
function Read-Manifest([string]$id) {
    $f = Get-ManifestPath $id
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    $m = @{ layout = ''; rules = @(); deny = '' }
    try {
        foreach ($l0 in [System.IO.File]::ReadAllLines($f, $script:Utf8)) {
            $t = ([string]$l0).TrimEnd("`r").Split(' ')
            if ($t[0] -ceq 'layout' -and $t.Count -ge 2 -and -not $m.layout) { $m.layout = $t[1] }
            elseif ($t[0] -ceq 'rule' -and $t.Count -eq 3) { $m.rules += , @{ name = $t[1]; sha = $t[2] } }
            elseif ($t[0] -ceq 'deny' -and $t.Count -eq 2 -and -not $m.deny) { $m.deny = $t[1] }
        }
    } catch { return $null }
    return $m
}

# Where a rule goes. folders: rules/stratum/<id>/<name>; flat: rules/stratum-<id>-<name>
function Get-RulePath([string]$layout, [string]$id, [string]$name) {
    if (Test-Same $layout 'flat') { return (Join-Path $script:Rules ('stratum-' + $id + '-' + $name)) }
    return (Join-Path (Join-Path (Join-Path $script:Rules 'stratum') $id) $name)
}
function Get-RuleShow([string]$layout, [string]$id, [string]$name) {
    if (Test-Same $layout 'flat') { return ('rules/stratum-' + $id + '-' + $name) }
    return ('rules/stratum/' + $id + '/' + $name)
}

# The load log (loaded.log): "seconds reason path" (the path with forward slashes), no content
function Read-LoadedLines {
    $f = Join-Path $script:KD 'loaded.log'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @() }
    try { return @([System.IO.File]::ReadAllLines($f, $script:Utf8)) } catch { return @() }
}
function Test-LoadedHas([string]$layout, [string]$id, [string]$name) {
    if (Test-Same $layout 'flat') { $suffix = '/rules/stratum-' + $id + '-' + $name } else { $suffix = '/rules/stratum/' + $id + '/' + $name }
    $suffix = Get-AsciiLower $suffix
    foreach ($l in @(Read-LoadedLines)) {
        $t = ([string]$l).Split(' ')
        if ($t.Count -lt 3) { continue }
        $p = Get-AsciiLower ($t[2])
        if ($p.Length -ge $suffix.Length -and $p.EndsWith($suffix, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}
function Clear-LoadedFor([string]$id) {
    $f = Join-Path $script:KD 'loaded.log'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return }
    $a = '/rules/stratum/' + $id + '/'; $b = '/rules/stratum-' + $id + '-'
    $keep = @()
    foreach ($l in @(Read-LoadedLines)) {
        $t = ([string]$l).Split(' ')
        $p = ''
        if ($t.Count -ge 3) { $p = Get-AsciiLower $t[2] }
        if ($p.Contains($a) -or $p.Contains($b)) { continue }
        $keep += [string]$l
    }
    $text = ''
    foreach ($l in $keep) { $text += $l + "`n" }
    Write-SecureFile $f $text
}

# Lower case for the letters A-Z only (the same as tr in sh)
function Get-AsciiLower([string]$s) {
    $ca = $s.ToCharArray()
    for ($i = 0; $i -lt $ca.Length; $i++) { $c = [int]$ca[$i]; if ($c -ge 65 -and $c -le 90) { $ca[$i] = [char]($c + 32) } }
    return ($ca -join '')
}

# Status of a package by the disk: ok | files | absent | off | not_loaded
function Get-LocalStatus([string]$id) {
    $e = Get-StateEntry $id
    if ($e -and (Test-Same $e.st 'off')) { return 'off' }
    $m = Read-Manifest $id
    $lay = 'folders'
    if ($m -and $m.layout) { $lay = $m.layout }
    $present = 0; $missing = $false; $diff = $false; $total = 0
    if ($m) {
        foreach ($r in $m.rules) {
            $total++
            $p = Get-RulePath $lay $id $r.name
            if ((Test-Path -LiteralPath $p -PathType Leaf) -and -not (Test-IsLink $p)) {
                $present++
                if (-not (Test-Same (Get-FileSha $p) $r.sha)) { $diff = $true }
            } else { $missing = $true }
        }
    }
    if ($total -eq 0 -or $present -eq 0) { return 'absent' }
    if ($missing -or $diff) { return 'files' }
    if ($script:Probe) {
        foreach ($r in $m.rules) { if (-not (Test-LoadedHas $lay $id $r.name)) { return 'not_loaded' } }
    }
    return 'ok'
}

# Version a is lower than version b ("major.minor" as numbers)
function Test-VerLt([string]$a, [string]$b) {
    $x = $a.Split('.'); $y = $b.Split('.')
    if ([int]$x[0] -ne [int]$y[0]) { return ([int]$x[0] -lt [int]$y[0]) }
    return ([int]$x[1] -lt [int]$y[1])
}

# The name of a package for a person from messages.txt (pkgname.<id>); not there - the id itself
function Get-PkgName([string]$id) {
    $n = Get-MsgOrNull ('pkgname.' + $id)
    if (-not $n) { return $id }
    return $n
}
function Test-IdArg([string]$s) { return ([regex]::IsMatch($s, '^[a-z][a-z0-9-]{1,29}\z') -and -not (Test-ReservedName $s)) }

# ---------- writing a package ----------
function Test-RealDir([string]$p) {
    if (Test-IsLink $p) { return $false }
    if (Test-Path -LiteralPath $p) { return (Test-Path -LiteralPath $p -PathType Container) }
    try { [void][System.IO.Directory]::CreateDirectory($p) } catch { return $false }
    if (Test-IsLink $p) { return $false }
    return (Test-Path -LiteralPath $p -PathType Container)
}
function Save-Backup([string]$srcPath, [string]$id, [string]$name) {
    $dir = Join-Path (Join-Path $script:KD 'backup') $id
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $dest = Join-Path $dir $name
    Remove-NameOnly $dest
    Write-SecureBytes $dest ([System.IO.File]::ReadAllBytes($srcPath))
}
function Write-NewFile([string]$path, [byte[]]$bytes) {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
}

# Puts one verified package. Returns @{ result = 'placed' | 'occupied' | 'cantwrite'; occ }.
# Order: checks of the paths (nothing changes) -> temporary files beside the target (the name is not .md, Claude Code does not load them) -> copies into backup -> renames
# -> old files that the new version lacks -> denials, the manifest, the state.
function Save-Package($p) {
    $id = $p.id; $ver = $p.ver
    $lay = $script:Layout
    $old = Read-Manifest $id
    $oldPaths = @()
    $oldLay = ''
    if ($old -and $old.layout) { $oldLay = $old.layout; foreach ($r in $old.rules) { $oldPaths += (Get-RulePath $oldLay $id $r.name) } }
    $cant = @{ result = 'cantwrite'; occ = '' }
    try {
        if (-not (Test-Path -LiteralPath $script:Rules -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($script:Rules) }
        if (-not (Test-Path -LiteralPath $script:Rules -PathType Container)) { return $cant }
        if (-not (Test-Same $lay 'flat')) {
            $sd = Join-Path $script:Rules 'stratum'
            if (-not (Test-RealDir $sd)) { return $cant }
            if (-not (Test-RealDir (Join-Path $sd $id))) { return $cant }
        }
        # 1. occupied paths: an own file (it is in the old manifest) may be replaced, a foreign one may not
        foreach ($r in $p.rules) {
            $tgt = Get-RulePath $lay $id $r.name
            if ((Test-Path -LiteralPath $tgt) -or (Get-Item -LiteralPath $tgt -Force -ErrorAction SilentlyContinue)) {
                $isFile = (Test-Path -LiteralPath $tgt -PathType Leaf)
                if ((Test-IsLink $tgt) -or -not $isFile -or ($oldPaths -cnotcontains $tgt)) { return @{ result = 'occupied'; occ = (Get-RuleShow $lay $id $r.name) } }
            }
        }
        # 2. temporary files
        $tmps = @()
        foreach ($r in $p.rules) {
            $tgt = Get-RulePath $lay $id $r.name
            $tmp = $tgt + '.kit-tmp'
            Remove-NameOnly $tmp
            try { Write-NewFile $tmp ($script:Utf8.GetBytes([string]$r.text)); $tmps += $tmp }
            catch { foreach ($t in $tmps) { Remove-NameOnly $t }; Remove-NameOnly $tmp; return $cant }
        }
        # 3. copies of what is replaced (a failed copy changes nothing) and 4. renames; a failed rename returns the files from the copies and removes the temporary ones
        $had = @{}
        try {
            foreach ($r in $p.rules) {
                $tgt = Get-RulePath $lay $id $r.name
                if (Test-Path -LiteralPath $tgt -PathType Leaf) { Save-Backup $tgt $id $r.name; $had[$r.name] = $true }
            }
        } catch {
            foreach ($r in $p.rules) { Remove-NameOnly ((Get-RulePath $lay $id $r.name) + '.kit-tmp') }
            return $cant
        }
        $done = @()
        try {
            foreach ($r in $p.rules) {
                $tgt = Get-RulePath $lay $id $r.name
                Move-Item -LiteralPath ($tgt + '.kit-tmp') -Destination $tgt -Force
                $done += $r.name
            }
        } catch {
            foreach ($n in $done) {
                $t2 = Get-RulePath $lay $id $n
                if ($had.ContainsKey($n)) { [System.IO.File]::WriteAllBytes($t2, [System.IO.File]::ReadAllBytes((Join-Path (Join-Path (Join-Path $script:KD 'backup') $id) $n))) } else { Remove-NameOnly $t2 }
            }
            foreach ($r in $p.rules) { Remove-NameOnly ((Get-RulePath $lay $id $r.name) + '.kit-tmp') }
            return $cant
        }
        # 5. old files of the package that the new version lacks (own ones only, from the old manifest)
        $newPaths = @($p.rules | ForEach-Object { Get-RulePath $lay $id $_.name })
        if ($old -and $oldLay) {
            foreach ($r in $old.rules) {
                $op = Get-RulePath $oldLay $id $r.name
                if ($newPaths -cnotcontains $op -and (Test-Path -LiteralPath $op -PathType Leaf) -and -not (Test-IsLink $op)) { Save-Backup $op $id $r.name; Remove-NameOnly $op }
            }
        }
        # 6. denials of the package, the manifest, the state
        $pdir = Join-Path $script:KD $id
        if (-not (Test-Path -LiteralPath $pdir -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($pdir) }
        $denyPath = Join-Path $pdir 'deny.txt'
        if ($p.nd -eq 1) {
            if (Test-Path -LiteralPath $denyPath -PathType Leaf) { Save-Backup $denyPath $id 'deny.txt' }
            Write-SecureFile $denyPath ([string]$p.deny)
        } elseif (Test-Path -LiteralPath $denyPath -PathType Leaf) { Save-Backup $denyPath $id 'deny.txt'; Remove-NameOnly $denyPath }
        $man = 'version ' + $ver + "`n" + 'layout ' + $lay + "`n"
        foreach ($r in $p.rules) { $man += 'rule ' + $r.name + ' ' + $r.sha + "`n" }
        if ($p.nd -eq 1) { $man += 'deny ' + $p.denySha + "`n" }
        Write-SecureFile (Get-ManifestPath $id) $man
        Clear-LoadedFor $id
        Set-StateEntry $id $ver 'ok' (Get-Sha256 ($script:Utf8.GetBytes($man)))
    } catch { return $cant }
    return @{ result = 'placed'; occ = '' }
}

# A package goes off: its files go into backup (own ones only, from the manifest), the denials too; the state is off
function Remove-Package([string]$id) {
    $m = Read-Manifest $id
    $lay = 'folders'
    if ($m -and $m.layout) { $lay = $m.layout }
    if ($m) {
        foreach ($r in $m.rules) {
            $p = Get-RulePath $lay $id $r.name
            if ((Test-Path -LiteralPath $p -PathType Leaf) -and -not (Test-IsLink $p)) { Save-Backup $p $id $r.name; Remove-NameOnly $p }
        }
    }
    $dp = Join-Path (Join-Path $script:KD $id) 'deny.txt'
    if (Test-Path -LiteralPath $dp -PathType Leaf) { Save-Backup $dp $id 'deny.txt'; Remove-NameOnly $dp }
    Clear-LoadedFor $id
    $e = Get-StateEntry $id
    $ver = '0.0'; $h = ('0' * 64)
    if ($e) { $ver = $e.ver; $h = $e.hash }
    Set-StateEntry $id $ver 'off' $h
}

# The body of request 1 by the state lines (up to 16 packages): only id, version, status, time
function Get-ReportBody {
    $items = @()
    $cnt = 0
    foreach ($e in @(Get-StateEntries)) {
        if ($cnt -ge 16) { break }
        $cnt++
        $items += ('{"id":"' + $e.id + '","version":"' + $e.ver + '","status":"' + $e.st + '","checked_at":"' + $e.time + '"}')
    }
    return ('{"plugin_version":"' + (Get-PluginVersion) + '","os":"windows","engine":' + $script:EngineLevel + ',"packages":[' + ($items -join ',') + ']}')
}

# ---------- hooks: matching of denials ----------
# Strings are compared as bytes (UTF-8 turned into Latin-1 characters), so the result is the same as in the sh version
function ConvertTo-ByteString([string]$s) { return $script:Latin1.GetString($script:Utf8.GetBytes($s)) }
# Only * is special: any run of characters, including / and \. Every other character, ? too, stands for itself.
function Test-Glob([string]$p, [string]$s) {
    $pl = $p.Length; $sl = $s.Length; $pi = 0; $si = 0; $star = -1; $mark = 0
    while ($si -lt $sl) {
        if ($pi -lt $pl -and [int]$p[$pi] -eq 42) { $star = $pi; $mark = $si; $pi++ }
        elseif ($pi -lt $pl -and [int]$p[$pi] -eq [int]$s[$si]) { $pi++; $si++ }
        elseif ($star -ge 0) { $pi = $star + 1; $mark++; $si = $mark }
        else { return $false }
    }
    while ($pi -lt $pl -and [int]$p[$pi] -eq 42) { $pi++ }
    return ($pi -ge $pl)
}
# tool: Read | Edit | Write | Bash. Files: the path with "/", without case; a pattern without "/" is compared with the file name, one with "/" with the whole path.
# Bash: the pattern is compared with the whole command. Case does not matter anywhere.
function Test-DenyMatch([string]$tool, [string]$target, [string]$pattern) {
    if ($tool -ceq 'Read' -or $tool -ceq 'Edit' -or $tool -ceq 'Write') {
        $t = ConvertTo-ByteString (Get-AsciiLower ($target.Replace('\', '/')))
        $p = ConvertTo-ByteString (Get-AsciiLower $pattern)
        if ($p.Contains('/')) { return (Test-Glob $p $t) }
        $k = $t.LastIndexOf('/')
        return (Test-Glob $p $t.Substring($k + 1))
    }
    if ($tool -ceq 'Bash') {
        return (Test-Glob (ConvertTo-ByteString (Get-AsciiLower $pattern)) (ConvertTo-ByteString (Get-AsciiLower $target)))
    }
    return $false
}
function Test-DenyLine([string]$l) {
    $b = $script:Utf8.GetByteCount($l)
    if ($b -gt 200 -or $b -lt 3) { return $false }
    if (-not [regex]::IsMatch($l, '^(Read|Edit|Write|Bash) [^ ]')) { return $false }
    # Only printable ASCII; no [ ] \ or a backquote; the pattern holds at least three characters other than * and a space (contract, clarification 7)
    if ([regex]::IsMatch($l, '[^\x20-\x7e]')) { return $false }
    if ($l.Contains('[') -or $l.Contains(']') -or $l.Contains('\') -or $l.Contains([string][char]96) -or $l.Contains('?')) { return $false }
    $p = $l.Substring($l.IndexOf(' ') + 1)
    return (($p -replace '[* ]', '').Length -ge 3)
}
function ConvertTo-JsonText([string]$s) { return $s.Replace('\', '\\').Replace('"', '\"') }
