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

function Get-Msg([string]$key, [hashtable]$vars) {
    $lines = [System.IO.File]::ReadAllLines((Join-Path $script:Here 'messages.txt'), $script:Utf8)
    $prefix = $key + '='
    $line = $lines | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
    $text = ([string]$line).Substring($prefix.Length).TrimEnd("`r")
    if ($vars) { foreach ($k in $vars.Keys) { $text = $text.Replace('{' + $k + '}', [string]$vars[$k]) } }
    return $text.Replace('\n', "`n")
}

function Say([string]$key, [hashtable]$vars) { Write-Out ((Get-Msg $key $vars) + "`n") }

# Options in the form: <command> --name value ... --soft (the same syntax as in the sh version)
function Get-Opts($argv) {
    $o = @{ cmd = $null; soft = $false }
    $i = 0
    while ($i -lt $argv.Count) {
        $a = [string]$argv[$i]
        if ($a -eq '--soft') { $o.soft = $true; $i++ }
        elseif ($a.StartsWith('--') -and ($i + 1) -lt $argv.Count -and -not ([string]$argv[$i + 1]).StartsWith('--')) { $o[$a.Substring(2)] = [string]$argv[$i + 1]; $i += 2 }
        elseif ($a.StartsWith('--')) { $i++ }
        else { if ($null -eq $o.cmd) { $o.cmd = $a }; $i++ }
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

# key=value file (one pair per line)
function Read-KV([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $h = @{}
    try {
        foreach ($l in [System.IO.File]::ReadAllLines($path, $script:Utf8)) {
            $i = $l.IndexOf('=')
            if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1).TrimEnd("`r") }
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
