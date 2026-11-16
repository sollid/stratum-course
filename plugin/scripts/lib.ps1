# Common helpers for connect.ps1 and step-report.ps1 (PowerShell 5.1, no extra tools).
# ASCII only: Russian text lives in messages.txt (UTF-8), so the file does not depend on the script encoding.
# Secrets (device_code, token) are never printed, never put on a command line and never put in a URL.
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:Here = $PSScriptRoot

function Write-Out([string]$text) {
    $b = $script:Utf8.GetBytes($text)
    $o = [Console]::OpenStandardOutput()
    $o.Write($b, 0, $b.Length)
    $o.Flush()
}

# Engine level of the check programs (the same as in check.sh and check.ps1) and the size limit of a task package in bytes
$script:EngineLevel = 2
$script:TaskMax = 262144

# $vars is a hashtable or an [ordered] one: the values are put in the order of the keys, the same as the sh version does.
# The \n of the template becomes a line break BEFORE the values are put in: a backslash inside a value (a step title from the site) means nothing.
function Get-Msg([string]$key, $vars) {
    $lines = [System.IO.File]::ReadAllLines((Join-Path $script:Here 'messages.txt'), $script:Utf8)
    $prefix = $key + '='
    $line = $lines | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
    $text = ([string]$line).Substring($prefix.Length).TrimEnd("`r")
    $text = $text.Replace('\n', "`n")
    if ($vars) { foreach ($k in $vars.Keys) { $text = $text.Replace('{' + $k + '}', [string]$vars[$k]) } }
    return $text
}

function Say([string]$key, $vars) { Write-Out ((Get-Msg $key $vars) + "`n") }

# Options in the form: <command> --name value ... --soft (the same syntax as in the sh version). Only the names the sh version knows take a value; any other --name is skipped alone.
$script:KnownOpts = @('data', 'window', 'label', 'module', 'step', 'passed', 'reason', 'rules', 'dir', 'check-version')
function Get-Opts($argv) {
    $o = @{ cmd = $null; arg2 = $null; soft = $false; showonly = $false }
    $i = 0
    while ($i -lt $argv.Count) {
        $a = [string]$argv[$i]
        if (Test-Same $a '--soft') { $o.soft = $true; $i++ }
        elseif (Test-Same $a '--show-only') { $o.showonly = $true; $i++ }
        elseif ($a.StartsWith('--') -and ($script:KnownOpts -ccontains $a.Substring(2)) -and ($i + 1) -lt $argv.Count -and -not ([string]$argv[$i + 1]).StartsWith('--')) { $o[$a.Substring(2)] = [string]$argv[$i + 1]; $i += 2 }
        elseif ($a.StartsWith('--')) { $i++ }
        else { if ($null -eq $o.cmd) { $o.cmd = $a } elseif ($null -eq $o.arg2) { $o.arg2 = $a }; $i++ }
    }
    return $o
}

function Get-NowEpoch { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# Plugin data folder: --data, else CLAUDE_PLUGIN_DATA, else a folder in the profile (manual runs only)
function Get-DataDir($o) {
    $d = $o['data']
    if (-not $d -or $d.Contains('${')) { $d = $env:CLAUDE_PLUGIN_DATA }
    if (-not $d -or $d.Contains('${')) { $d = Join-Path $env:USERPROFILE '.stratum-course' }
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    return $d
}

$script:SiteRe = '^(https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?)$'
function Test-SiteUrl([string]$u) { return [regex]::IsMatch($u, $script:SiteRe) }

# Site address setting: COURSE_SITE_URL, else the first line of the site-url file in the data folder.
# Returns @{ state = 'ok'|'none'|'bad'; url }.
function Get-SiteSetting([string]$dataDir) {
    $v = $env:COURSE_SITE_URL
    if (-not $v) {
        $f = Join-Path $dataDir 'site-url'
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

function Get-PluginVersion {
    try {
        $p = Join-Path $script:Here '..\.claude-plugin\plugin.json'
        $v = [string]((([System.IO.File]::ReadAllText($p, $script:Utf8)) | ConvertFrom-Json).version)
        if ($v -match '^[0-9A-Za-z.+-]{1,20}$') { return $v }
    } catch { }
    return '0'
}

# One POST. status 0 = no answer from the site. Redirects are not followed (a token must never go to another address).
function Invoke-Site([string]$site, [string]$path, [string]$json, [string]$token) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($site + $path)
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Accept = 'application/json'
        $req.UserAgent = 'stratum-course-plugin'
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
    if ($null -eq $resp) { return @{ status = 0; body = ''; retry = 0 } }
    $status = [int]$resp.StatusCode
    $retry = 0
    $ra = $resp.Headers['Retry-After']
    if ($ra -and $ra -match '^\s*([0-9]{1,5})') { $retry = [int]$Matches[1]; if ($retry -lt 1) { $retry = 1 }; if ($retry -gt 120) { $retry = 120 } }
    $text = ''
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), $script:Utf8)
        $text = $sr.ReadToEnd()
        $sr.Close()
    } catch { }
    $resp.Close()
    if ($text.Length -gt 65536) { $text = $text.Substring(0, 65536) }
    return @{ status = $status; body = $text; retry = $retry }
}

function ConvertFrom-Flat([string]$text) {
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# Default reason code of the new rule types (used when the reasons file has no code for the rule). The older types have no default.
function Get-DefaultReason($ruleObjs, [string]$id) {
    foreach ($r in @($ruleObjs)) {
        if ([string]$r.id -ceq $id) {
            switch -CaseSensitive ([string]$r.type) {
                'contains_text' { return 'text_missing' }
                'file_absent' { return 'file_present' }
                'min_items' { return 'too_few_items' }
                'answer' { return 'answer_mismatch' }
                'no_placeholder' { return 'placeholder_left' }
            }
            return ''
        }
    }
    return ''
}

# key=value file (one pair per line)
function Read-KV([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    # Keys are compared exactly (ordinal) and the first one wins: the same as kv in the sh version
    $h = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    try {
        foreach ($l in [System.IO.File]::ReadAllLines($path, $script:Utf8)) {
            $i = $l.IndexOf('=')
            if ($i -gt 0) { $k = $l.Substring(0, $i); if (-not $h.ContainsKey($k)) { $h[$k] = $l.Substring($i + 1).TrimEnd("`r") } }
        }
    } catch { return $null }
    return $h
}

# Writes a file only the current user can open: an empty file gets a protected ACL (no inheritance, one rule for this user),
# then the text is written, then the file replaces the target (the ACL moves with it).
function Remove-NameOnly([string]$p) {
    # Removes only the name (a link or a hard link is removed, the file it pointed to stays)
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($item) { if ($item.PSIsContainer) { [System.IO.Directory]::Delete($p) } else { [System.IO.File]::Delete($p) } }
}
function Write-SecureFile([string]$path, [string]$text) {
    $tmp = $path + '.tmp'
    # The temporary name is cleared and the file is created anew (CreateNew fails on an existing file), so a planted link cannot redirect the write
    Remove-NameOnly $tmp
    $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $fs.Close()
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
    Set-Acl -LiteralPath $tmp -AclObject $acl
    [System.IO.File]::WriteAllBytes($tmp, $script:Utf8.GetBytes($text))
    # A link standing in place of the target is removed first; the new file replaces it atomically otherwise
    $dest = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($dest -and (($dest.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { Remove-NameOnly $path }
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# Text for a JSON string field: no quotes, backslashes or control characters, trimmed, at most $max characters.
function Get-JsonText([string]$s, [int]$max) {
    $s = $s -replace '["\\]', ' '
    $s = $s -replace '[\x00-\x1f\x7f]', ''
    $s = $s.Trim()
    if ($s.Length -gt $max) {
        $s = $s.Substring(0, $max)
        if ([char]::IsHighSurrogate($s[$s.Length - 1])) { $s = $s.Substring(0, $s.Length - 1) }
        $s = $s.TrimEnd()
    }
    return $s
}

# Device label the person will see on the site card: the computer name without the user name and without paths, up to 40 characters.
# Source: --label, else COURSE_DEVICE_LABEL, else the computer name. The user name is cut out wherever it appears; nothing left -> "Windows".
function Get-DeviceLabel([string]$override) {
    $s = $override
    if (-not $s) { $s = $env:COURSE_DEVICE_LABEL }
    if (-not $s) { $s = $env:COMPUTERNAME }
    $s = [string]$s
    $s = $s -replace '[\x00-\x1f\x7f]', ''
    $s = $s -replace '[&|\/"`$<>;{}*~\[\]]', ' '
    $u = [string]$env:USERNAME
    if ($u.Length -ge 3) { $s = [regex]::Replace($s, [regex]::Escape($u) + "(['" + [char]0x2019 + "]s)?", ' ', 'IgnoreCase') }
    $s = [regex]::Replace($s, '\.local$', '', 'IgnoreCase')
    $s = ($s -replace ' +', ' ').Trim(' ', '.', '_', '-', [char]39)
    $s = (Get-JsonText $s 40).Trim(' ', '.', '_', '-', [char]39)
    if (-not $s) { $s = 'Windows' }
    return $s
}

# ---------- check and reason code (shared by step-report.ps1 and next.ps1) ----------

function Run-Check([string]$rules, [string]$dir) {
    # A quote inside a value would add parameters of its own: refuse. Trailing backslashes are doubled so they do not escape the closing quote.
    foreach ($v in @($rules, $dir)) { if ($v.Contains('"')) { return @{ code = 2; out = ''; err = '' } } }
    $rules = $rules -replace '(\\+)$', '$1$1'
    $dir = $dir -replace '(\\+)$', '$1$1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $script:Here 'check.ps1') + '" -Rules "' + $rules + '" -Dir "' + $dir + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $errText = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ code = $p.ExitCode; out = $out; err = $errText }
}

# Runs the check: code (-1 = did not run), out, verdict (accepted|almost|disputed|failed or ''), newer ($true = rules newer than this plugin)
function Invoke-Check([string]$rules, [string]$dir) {
    $r = @{ code = -1; out = ''; verdict = ''; newer = $false }
    $c = $null
    try { $c = Run-Check $rules $dir } catch { $c = $null }
    if ($null -eq $c) { return $r }
    $r.code = [int]$c.code
    $r.out = [string]$c.out
    if ($c.code -eq 2 -and ([string]$c.err) -match 'newer than this plugin') { $r.newer = $true }
    $m = [regex]::Match($r.out, '(?m)^verdict: (accepted|almost|disputed|failed)\s*$')
    if ($m.Success) { $r.verdict = $m.Groups[1].Value }
    return $r
}

# The code of the first failed rule whose severity equals the verdict: from the reasons file, else the default code of the rule type. '' if none.
# The order of the rules in the file matters: this is how the plugin and the site understand "disputed" in the same way (RULES.md).
function Get-ReasonCode([string]$rulesPath, [string]$reasonsPath, [string]$outText, [string]$verdict) {
    if (@('almost', 'disputed', 'failed') -cnotcontains $verdict) { return '' }
    $map = $null
    if ($reasonsPath) { $map = Read-KV $reasonsPath }
    $ruleObjs = $null
    try { $ruleObjs = @((([System.IO.File]::ReadAllText($rulesPath, $script:Utf8).TrimStart([char]0xFEFF)) | ConvertFrom-Json).rules) } catch { }
    foreach ($l in [regex]::Split($outText, "\r?\n")) {
        $m = [regex]::Match($l, '^([A-Za-z0-9_-]{1,40}): ' + $verdict + ' - ')
        if (-not $m.Success) { continue }
        $rid = $m.Groups[1].Value
        $code = ''
        if ($map -and $map.ContainsKey($rid)) { $code = [string]$map[$rid] }
        if (-not $code) { $code = Get-DefaultReason $ruleObjs $rid }
        if ($code) { return $code }
    }
    return ''
}

# The main file named in the text of a rules file (read the way check.sh reads it: a line without "type": with "file": "..."). '' if none.
function Get-RulesFileField([string]$text) {
    foreach ($l in $text.Split("`n")) {
        if ($l.Contains('"type":')) { continue }
        $m = [regex]::Match($l, '"file": *"([^"]*)"')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# ---------- course state in the plugin data folder (course-state.txt: key=value lines; rights as the token file) ----------
# workdir is the learning folder; shown is "module/step" whose task was shown; disputed is "module/step" waiting for the curator (their rules are in steps/)

function Read-StateLines([string]$dataDir) {
    $f = Join-Path $dataDir 'course-state.txt'
    $out = @()
    if (Test-Path -LiteralPath $f -PathType Leaf) {
        try { foreach ($l in [System.IO.File]::ReadAllLines($f, $script:Utf8)) { $out += ([string]$l).TrimEnd("`r") } } catch { }
    }
    return $out
}
function Write-StateLines([string]$dataDir, $lines) {
    $text = ''
    foreach ($l in @($lines)) { $text += ([string]$l) + "`n" }
    try { Write-SecureFile (Join-Path $dataDir 'course-state.txt') $text } catch { }
}
function Get-StateValues([string]$dataDir, [string]$key) {
    $out = @()
    foreach ($l in @(Read-StateLines $dataDir)) { if ($l.StartsWith($key + '=', [System.StringComparison]::Ordinal)) { $out += $l.Substring($key.Length + 1) } }
    return $out
}
function Test-State([string]$dataDir, [string]$key, [string]$value) { return (@(Get-StateValues $dataDir $key) -ccontains $value) }
function Add-State([string]$dataDir, [string]$key, [string]$value) {
    if (Test-State $dataDir $key $value) { return }
    Write-StateLines $dataDir (@(Read-StateLines $dataDir) + ($key + '=' + $value))
}
function Set-State([string]$dataDir, [string]$key, [string]$value) {
    $keep = @(Read-StateLines $dataDir | Where-Object { -not $_.StartsWith($key + '=', [System.StringComparison]::Ordinal) })
    Write-StateLines $dataDir ($keep + ($key + '=' + $value))
}
function Remove-State([string]$dataDir, [string]$key, [string]$value) {
    $line = $key + '=' + $value
    Write-StateLines $dataDir @(Read-StateLines $dataDir | Where-Object { $_ -cne $line })
}

# Remembers the learning folder; if it changed, the shown and disputed steps of the old one are forgotten (their rules and files belonged to it)
function Switch-WorkDir([string]$dataDir, [string]$path) {
    $old = [string](@(Get-StateValues $dataDir 'workdir') | Select-Object -First 1)
    if (Test-Same $old $path) { return }
    if ($old) {
        Write-StateLines $dataDir @(Read-StateLines $dataDir | Where-Object { -not $_.StartsWith('shown=', [System.StringComparison]::Ordinal) -and -not $_.StartsWith('disputed=', [System.StringComparison]::Ordinal) })
    }
    Set-State $dataDir 'workdir' $path
}

# A lock (the entry .lock in the plugin data; created atomically with CreateNew) for the time of a run: two Claude Code windows do not lose each other's state records.
# A lock older than 10 minutes is taken as forgotten and removed. Returns $false if another run holds it.
function Enter-CourseLock([string]$dataDir) {
    $lock = Join-Path $dataDir '.lock'
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $fs.Close()
            $script:LockPath = $lock
            return $true
        } catch { }
        $it = Get-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        if ($it -and (((Get-Date).ToUniversalTime() - $it.LastWriteTimeUtc).TotalMinutes -gt 10)) { try { Remove-Item -LiteralPath $lock -Force -Recurse -ErrorAction Stop } catch { } }
        else { return $false }
    }
    return $false
}
function Exit-CourseLock {
    if ($script:LockPath) { try { Remove-Item -LiteralPath $script:LockPath -Force -Recurse -ErrorAction Stop } catch { }; $script:LockPath = $null }
}

# ---------- learning folder ----------

function Test-IsLink([string]$p) {
    # A link is only what Windows follows: a symbolic link or a junction. Other reparse points (OneDrive and other cloud placeholders, app execution aliases) are not links.
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -eq $i) { return $false }
    $t = [string]$i.LinkType
    return ((Test-Same $t 'SymbolicLink') -or (Test-Same $t 'Junction'))
}

# The mark of a learning folder: a regular file .stratum-course (not a link) whose first line is "stratum-course-folder 1". /course:start puts it.
function Test-CourseDir([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    $m = Join-Path $dir '.stratum-course'
    if (-not (Test-Path -LiteralPath $m -PathType Leaf)) { return $false }
    if (Test-IsLink $m) { return $false }
    $first = $null
    try { $first = [System.IO.File]::ReadAllLines($m, $script:Utf8) | Select-Object -First 1 } catch { return $false }
    return (Test-Same ([string]$first) 'stratum-course-folder 1')
}

# Ordinal comparison of untrusted text: -ceq and -cne compare with the culture rules, which ignore some invisible characters (U+FEFF, U+200B)
function Test-Same([string]$a, [string]$b) { return [string]::Equals($a, $b, [System.StringComparison]::Ordinal) }

function Get-ModuleNumber([string]$m) {
    $n = [regex]::Replace($m, '^[^0-9]*', '')
    if (-not $n) { $n = $m }
    return $n
}

# ---------- task package: request, parse, start files ----------

# One POST for the task. status 0 = no answer from the site. Redirects are not followed. At most TaskMax bytes are read: more = big.
function Invoke-SiteTask([string]$site, [string]$json, [string]$token) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($site + '/api/plugin/task')
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Accept = 'text/plain'
        $req.UserAgent = 'stratum-course-plugin'
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
            if (($ms.Length + $n) -gt $script:TaskMax) { $big = $true; break }
            $ms.Write($buf, 0, $n)
        }
    } catch { }
    try { $resp.Close() } catch { }
    return @{ status = $status; bytes = $ms.ToArray(); big = $big }
}

function Test-StartPath([string]$p, [string]$mainFile) {
    if ($p.Length -lt 1 -or $p.Length -gt 120) { return $false }
    if (-not [regex]::IsMatch($p, '^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*){0,3}$')) { return $false }
    $segs = $p.Split('/')
    foreach ($s in $segs) {
        if ($s.EndsWith('.')) { return $false }
        $b = $s.ToUpperInvariant()
        $dot = $b.IndexOf('.')
        if ($dot -ge 0) { $b = $b.Substring(0, $dot) }
        if ([regex]::IsMatch($b, '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$')) { return $false }
    }
    $base = $segs[$segs.Count - 1]
    if (-not ($base.EndsWith('.md', [System.StringComparison]::Ordinal) -or $base.EndsWith('.txt', [System.StringComparison]::Ordinal))) { return $false }
    $low = $base.ToLowerInvariant()
    if ($low -ceq 'claude.md' -or $low -ceq 'claude.local.md' -or $low -ceq 'agents.md') { return $false }
    return $true
}

function Test-MainPath([string]$p) {
    if ($p.Length -lt 1 -or $p.Length -gt 120) { return $false }
    $segs = $p.Split('/')
    if ($segs.Count -gt 4) { return $false }
    foreach ($s in $segs) { if (-not [regex]::IsMatch($s, '^[A-Za-z0-9._-]+$') -or $s -ceq '.' -or $s -ceq '..') { return $false } }
    return $true
}

# Hidden and control characters (not LF and TAB), DEL, C1, zero-width and direction marks, line and paragraph separators, BOM, tag characters U+E0000-E007F
$script:HiddenRe = '[\x00-\x08\x0b-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2060-\u2069\u061c\ufeff]|\uDB40[\uDC00-\uDC7F]'

function Join-PartLines($list) {
    if ($list.Count -eq 0) { return '' }
    return (($list.ToArray() -join "`n") + "`n")
}

# Parses a task package (bytes). Returns @{ err = '' | 'version' | 'format' | 'start'; head; task; rules; reasons; start = @(@{path; text}) }.
# Nothing is written anywhere. The same checks as the sh version (see parse_package in lib.sh): size, no NUL and CR, ends with LF, first line stratum-task 1,
# header (keys, values, required fields, no repeats), part boundaries, kinds and number of parts, valid UTF-8, start file path rules and size.
function Read-TaskPackage([byte[]]$bytes) {
    $bad = @{ err = 'format' }
    $badStart = @{ err = 'start' }
    if ($bytes.Length -lt 1 -or $bytes.Length -gt $script:TaskMax) { return $bad }
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0 -or [Array]::IndexOf($bytes, [byte]13) -ge 0) { return $bad }
    if ($bytes[$bytes.Length - 1] -ne 10) { return $bad }
    $text = $null
    try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { return $bad }
    $lines = $text.Split("`n")
    $n = $lines.Length - 1
    if (-not (Test-Same $lines[0] 'stratum-task 1')) {
        if ([regex]::IsMatch($lines[0], '^stratum-task [0-9]+$')) { return @{ err = 'version' } }
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
        if (-not [regex]::IsMatch($k, '^[a-z_]+$') -or [regex]::IsMatch($v, '[\x00-\x1f\x7f]') -or [regex]::IsMatch($v, $script:HiddenRe) -or $script:Utf8.GetByteCount($v) -gt 300 -or $H.ContainsKey($k)) { return $bad }
        $H[$k] = $v
    }
    $state = [string]$H['state']
    if (-not [regex]::IsMatch([string]$H['boundary'], '^[0-9a-f]{32}$')) { return $bad }
    if (-not [regex]::IsMatch([string]$H['waiting'], '^[0-9]{1,4}$')) { return $bad }
    if (Test-Same $state 'step') {
        if (-not [regex]::IsMatch([string]$H['module'], '^[a-z0-9]{1,10}$') -or -not [regex]::IsMatch([string]$H['step'], '^[a-z0-9]{1,10}$')) { return $bad }
        foreach ($t in @('module_title', 'step_title')) { $bc = $script:Utf8.GetByteCount([string]$H[$t]); if ($bc -lt 1 -or $bc -gt 300) { return $bad } }
        if (-not [regex]::IsMatch([string]$H['number'], '^[0-9]{1,3}$') -or -not [regex]::IsMatch([string]$H['of'], '^[0-9]{1,3}$')) { return $bad }
        if (-not (Test-MainPath ([string]$H['file']))) { return $bad }
        $cv = [string]$H['check_version']; $me = [string]$H['min_engine']
        if (-not [regex]::IsMatch($cv, '^[0-9]{1,2}$') -or -not [regex]::IsMatch($me, '^[0-9]{1,2}$') -or $cv -cne $me -or [int]$cv -lt 1) { return $bad }
        if ($H.ContainsKey('story_path') -and -not [regex]::IsMatch([string]$H['story_path'], '^/[A-Za-z0-9/_-]+$')) { return $bad }
    } elseif (-not (Test-Same $state 'done')) { return $bad }

    $pre = '--' + [string]$H['boundary']
    $cnt = @{ task = 0; rules = 0; reasons = 0 }
    $parts = @{ task = $null; rules = $null; reasons = $null }
    $sizes = @{ task = 0; rules = 0; reasons = 0 }
    $starts = New-Object System.Collections.ArrayList
    $seen = @{}
    $cur = $null; $curKind = ''; $curStart = $false; $startSize = 0
    $ended = $false
    for (; $i -lt $n; $i++) {
        $l = $lines[$i]
        if ($ended) { return $bad }
        if ($l.StartsWith($pre, [System.StringComparison]::Ordinal)) {
            $rest = $l.Substring($pre.Length)
            if (Test-Same $rest ' end') { $ended = $true; continue }
            if (Test-Same $state 'done') { return $bad }
            if ([regex]::IsMatch($rest, '^ (task|rules|reasons)$')) {
                $kind = $rest.Substring(1)
                if ($cnt[$kind] -gt 0) { return $bad }
                $cnt[$kind] = 1
                $cur = New-Object 'System.Collections.Generic.List[string]'
                $parts[$kind] = $cur; $curKind = $kind; $curStart = $false
                continue
            }
            if ([regex]::IsMatch($rest, '^ start [^ ]+$')) {
                $p = $rest.Substring(7)
                if ($starts.Count -ge 8) { return $badStart }
                $low = $p.ToLowerInvariant()
                if (-not (Test-StartPath $p ([string]$H['file'])) -or $seen.ContainsKey($low) -or $low -ceq ([string]$H['file']).ToLowerInvariant()) { return $badStart }
                $seen[$low] = $true
                $cur = New-Object 'System.Collections.Generic.List[string]'
                [void]$starts.Add(@{ path = $p; lines = $cur })
                $curKind = ''; $curStart = $true; $startSize = 0
                continue
            }
            return $bad
        }
        if ($null -eq $cur) { return $bad }
        $len = $script:Utf8.GetByteCount($l) + 1
        if (($curStart -or (Test-Same $curKind 'task')) -and [regex]::IsMatch($l, $script:HiddenRe)) { return $bad }
        if ($curStart) { $startSize += $len; if ($startSize -gt 16384) { return $badStart } }
        else { $sizes[$curKind] += $len }
        $cur.Add($l)
    }
    if (-not $ended) { return $bad }
    # A start path is never the folder of another start path (compared without case)
    $lows = @($starts | ForEach-Object { $_.path.ToLowerInvariant() })
    foreach ($a in $lows) { foreach ($b in $lows) { if (-not (Test-Same $a $b) -and $b.StartsWith($a + '/', [System.StringComparison]::Ordinal)) { return $badStart } } }
    if (Test-Same $state 'done') {
        if (($cnt.task + $cnt.rules + $cnt.reasons + $starts.Count) -gt 0) { return $bad }
    } else {
        if ($cnt.task -ne 1 -or $cnt.rules -ne 1 -or $cnt.reasons -ne 1) { return $bad }
        if ($sizes.task -lt 2 -or $sizes.rules -lt 2) { return $bad }
    }
    $startList = @()
    foreach ($s in $starts) { $startList += , @{ path = $s.path; text = (Join-PartLines $s.lines) } }
    $task = ''; $rules = ''; $reasons = ''
    if (Test-Same $state 'step') { $task = Join-PartLines $parts.task; $rules = Join-PartLines $parts.rules; $reasons = Join-PartLines $parts.reasons }
    return @{ err = ''; head = $H; task = $task; rules = $rules; reasons = $reasons; start = $startList }
}

# Puts one start file. $true = the file is in place (put now, or it was already a regular file of the person), $false = not possible.
# Every folder on the way must be a real folder inside the learning folder (not a link); a missing one is created and checked again.
# An existing file is not overwritten. A link (also a dangling one) or a non-file in place of the file is a refusal. The file is created with CreateNew.
function Write-StartFile([string]$base, [string]$rel, [string]$text) {
    if (-not (Test-StartPath $rel '')) { return $false }
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return $false }
    $parts = $rel.Split('/')
    $cur = $base
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $cur = Join-Path $cur $parts[$i]
        if (Test-IsLink $cur) { return $false }
        if (Test-Path -LiteralPath $cur) {
            if (-not (Test-Path -LiteralPath $cur -PathType Container)) { return $false }
        } else {
            try { [void][System.IO.Directory]::CreateDirectory($cur) } catch { return $false }
            if (Test-IsLink $cur) { return $false }
            if (-not (Test-Path -LiteralPath $cur -PathType Container)) { return $false }
        }
    }
    $file = Join-Path $cur $parts[$parts.Count - 1]
    if (Test-IsLink $file) { return $false }
    if (Test-Path -LiteralPath $file) { return (Test-Path -LiteralPath $file -PathType Leaf) }
    try {
        $fs = [System.IO.File]::Open($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $b = $script:Utf8.GetBytes($text); $fs.Write($b, 0, $b.Length) } finally { $fs.Close() }
    } catch { return $false }
    return $true
}
