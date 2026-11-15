# Check program for Windows (PowerShell 5.1, present in Windows 11). Same behaviour and output as check.sh.
# ASCII only on purpose: Russian text comes from the rules (JSON), not from this script, so it does not depend on the file encoding.
# Rules are data only and are validated before use: rule id ^[A-Za-z0-9_-]{1,40}$, type and on_fail from short lists,
# the file field is a plain relative path inside the learner folder (no .., absolute path, drive, ~, links; file at most 1 MiB).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1 -Rules <rules.json> -Dir <learner folder>
# Exit codes: 0 the check ran (verdict in the output); 2 bad call or unacceptable rules.
param([string]$Rules, [string]$Dir)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false

function Die([string]$msg) {
    [Console]::Error.WriteLine("error: $msg")
    exit 2
}

if (-not $Rules -or -not $Dir) { Die 'usage: -Rules <rules.json> -Dir <folder>' }
if (-not (Test-Path -LiteralPath $Rules -PathType Leaf)) { Die 'rules file not found' }

try {
    $rawRules = [System.IO.File]::ReadAllText($Rules, $utf8).TrimStart([char]0xFEFF)
    $spec = $rawRules | ConvertFrom-Json
} catch { Die 'rules file is not valid JSON' }

# Rule fields that end up in output or in lookups are checked before anything is used
$ruleTypes = @('file_exists', 'has_heading', 'lists_named', 'max_items', 'min_lines', 'forbidden_text')
foreach ($r in @($spec.rules)) {
    if (-not ([string]$r.id -cmatch '^[A-Za-z0-9_-]{1,40}$')) { Die 'bad rule id' }
    if ($ruleTypes -cnotcontains [string]$r.type) { Die 'unknown rule type' }
    if (@('almost', 'disputed', 'failed') -cnotcontains [string]$r.on_fail) { Die 'bad on_fail value' }
}

# File name from the rules: a plain relative path inside the learner folder
$fileName = [string]$spec.file
if (-not $fileName -or $fileName -match '[\\:*?"<>|~$`\x00-\x1f\x7f]') { Die 'bad file name in rules' }
foreach ($comp in $fileName.Split('/')) {
    if ($comp -eq '' -or $comp -eq '.' -or $comp -eq '..') { Die 'bad file name in rules' }
}

$target = Join-Path $Dir $fileName
$hasFile = Test-Path -LiteralPath $target -PathType Leaf
$text = ''
if ($hasFile) {
    # Neither the file nor any folder on the way to it may be a link (a reparse point): reading would leave the learner folder
    $p = $Dir
    foreach ($comp in $fileName.Split('/')) {
        $p = Join-Path $p $comp
        if (((Get-Item -LiteralPath $p -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Die 'link in file path' }
    }
    if ((Get-Item -LiteralPath $target -Force).Length -gt 1048576) { Die 'file is larger than 1 MiB' }
    $text = [System.IO.File]::ReadAllText($target, $utf8).TrimStart([char]0xFEFF)
}
$lines = [regex]::Split($text, "\r?\n")

$headingRe = '^(#{1,6})[ \t]+(.+?)[ \t]*$'
$boldRe = '^\*\*(.+)\*\*[ \t]*$'
$colonRe = '^([^-*#\s].*):[ \t]*$'
$bulletRe = '^[ \t]*[-*][ \t]+\S'

function Find-Heading([string]$name) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], $headingRe)
        if ($m.Success -and $m.Groups[2].Value -ceq $name) { return $i }
    }
    return -1
}

function Count-Lists($headingName) {
    $start = 0
    $end = $lines.Count
    $h = -1
    if ($null -ne $headingName) { $h = Find-Heading $headingName }
    if ($h -ge 0) {
        $level = [regex]::Match($lines[$h], $headingRe).Groups[1].Value.Length
        $start = $h + 1
        for ($i = $start; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], $headingRe)
            if ($m.Success -and $m.Groups[1].Value.Length -le $level) { $end = $i; break }
        }
    }
    $counts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $cur = $null
    for ($i = $start; $i -lt $end; $i++) {
        $l = $lines[$i]
        $mh = [regex]::Match($l, $headingRe)
        $mb = [regex]::Match($l, $boldRe)
        $mc = [regex]::Match($l, $colonRe)
        if ($mh.Success) { $cur = $mh.Groups[2].Value }
        elseif ($mb.Success) { $cur = $mb.Groups[1].Value }
        elseif ($mc.Success) { $cur = $mc.Groups[1].Value }
        elseif ([regex]::IsMatch($l, $bulletRe) -and $null -ne $cur) {
            if ($counts.ContainsKey($cur)) { $counts[$cur] = $counts[$cur] + 1 } else { $counts[$cur] = 1 }
        }
    }
    return , $counts
}

function Get-Count($counts, [string]$name) {
    if ($counts.ContainsKey($name)) { return $counts[$name] }
    return 0
}

function Fill([string]$t, $vars) {
    return [regex]::Replace($t, '\{(\w+)\}', { param($m) [string]$vars[$m.Groups[1].Value] })
}

$order = @{ accepted = 0; almost = 1; disputed = 2; failed = 3 }
$names = @('accepted', 'almost', 'disputed', 'failed')

$headingRule = $spec.rules | Where-Object { $_.type -eq 'has_heading' } | Select-Object -First 1
$counts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
if ($hasFile) {
    $scope = $null
    if ($headingRule -and (Find-Heading $headingRule.heading) -ge 0) { $scope = $headingRule.heading }
    $counts = Count-Lists $scope
}

$out = New-Object System.Collections.Generic.List[string]
$worst = 0
foreach ($r in $spec.rules) {
    if (-not $hasFile -and $r.type -ne 'file_exists') {
        $out.Add("$($r.id): skipped - $($spec.skipped)")
        continue
    }
    $vars = @{}
    switch ($r.type) {
        'file_exists' { $ok = $hasFile }
        'has_heading' { $ok = ((Find-Heading $r.heading) -ge 0) }
        'lists_named' {
            $missing = @($r.names | Where-Object { (Get-Count $counts $_) -eq 0 })
            $vars = @{ missing = ($missing -join ', ') }
            $ok = ($missing.Count -eq 0)
        }
        'max_items' {
            $n = Get-Count $counts $r.list
            $vars = @{ n = $n; max = $r.max }
            $ok = ($n -le $r.max)
        }
        'min_lines' {
            $n = @($lines | Where-Object { [regex]::IsMatch($_, '[^ \t]') }).Count
            $vars = @{ n = $n; min = $r.min }
            $ok = ($n -ge $r.min)
        }
        'forbidden_text' { $ok = (-not $text.Contains($r.text)) }
        default { Die "unknown rule type: $($r.type)" }
    }
    if ($ok) { $status = 'ok'; $msg = Fill $r.ok $vars }
    else {
        $status = $r.on_fail
        $msg = Fill $r.fail $vars
        if ($order[$r.on_fail] -gt $worst) { $worst = $order[$r.on_fail] }
    }
    $out.Add("$($r.id): $status - $msg")
}

$result = "verdict: $($names[$worst])`n" + ($out -join "`n") + "`n"
$bytes = $utf8.GetBytes($result)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
exit 0
