# Check program for Windows (PowerShell 5.1, present in Windows 11). Same behaviour and output as check.sh (rules format: RULES.md).
# ASCII only on purpose: Russian text comes from the rules (JSON), not from this script, so it does not depend on the file encoding.
# Rules are data only and are validated before use: rule id ^[A-Za-z0-9_-]{1,40}$, type, on_fail and the fields of each type,
# the file and path fields are plain relative paths inside the learner folder (no .., absolute path, drive, ~, links; file at most 1 MiB).
# No value from the rules is ever used as code or as a regular expression: text is compared as a literal string.
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
    $rawRules = [System.IO.File]::ReadAllText($Rules, $utf8)
    if ($rawRules.Length -gt 0 -and $rawRules[0] -eq [char]0xFEFF) { $rawRules = $rawRules.Substring(1) }
    $spec = $rawRules | ConvertFrom-Json
} catch { Die 'rules file is not valid JSON' }

# ---------- rules are checked before anything is used ----------
$ruleTypes = @('file_exists', 'file_absent', 'has_heading', 'lists_named', 'max_items', 'min_items', 'min_lines', 'forbidden_text', 'contains_text', 'no_placeholder', 'answer')
$matchModes = @('exact', 'nocase', 'nospace', 'nocase_nospace')
function Is-Str($v) { return (($v -is [string]) -and $v.Length -gt 0) }
function Is-Num($v) { return ((($v -is [int]) -or ($v -is [long])) -and $v -ge 0) }
function Is-StrList($v) {
    if ($null -eq $v -or $v -is [string]) { return $false }
    $a = @($v)
    if ($a.Count -eq 0) { return $false }
    foreach ($x in $a) { if (-not (Is-Str $x)) { return $false } }
    return $true
}
function Has-Prop($o, [string]$name) { return ($null -ne $o.PSObject.Properties[$name]) }
function Test-TextFields($r) {
    if (-not (Is-Str $r.text)) { return $false }
    if ((Has-Prop $r 'match') -and ($matchModes -cnotcontains [string]$r.match)) { return $false }
    if (Has-Prop $r 'loose') { if (($r.loose -isnot [bool]) -or (Has-Prop $r 'match')) { return $false } }
    return $true
}
function Test-AnswerFields($r) {
    if (-not (Is-Str $r.label)) { return $false }
    $hasList = Has-Prop $r 'answers'
    $hasOne = Has-Prop $r 'expect'
    if ($hasList -eq $hasOne) { return $false }
    if ($hasList) { return (Is-StrList $r.answers) }
    return (Is-Str $r.expect)
}

# Engine level: 1 is plugin 0.1.0, 2 is the types and fields of RULES.md. The rules file may name the level it needs with "engine": N
if (Has-Prop $spec 'engine') {
    if (-not (Is-Num $spec.engine) -or $spec.engine -lt 1) { Die 'bad engine level' }
    if ($spec.engine -gt 2) { Die "rules newer than this plugin: update the plugin (rules need engine level $($spec.engine), this one is 2)" }
}
$ruleList = @($spec.rules)
foreach ($r in $ruleList) {
    if (-not ([string]$r.id -cmatch '^[A-Za-z0-9_-]{1,40}$')) { Die 'bad rule id' }
    if ($ruleTypes -cnotcontains [string]$r.type) { Die 'unknown rule type (rules newer than this plugin: update the plugin)' }
    if (@('almost', 'disputed', 'failed') -cnotcontains [string]$r.on_fail) { Die 'bad on_fail value' }
    $okFields = $true
    switch -CaseSensitive ([string]$r.type) {
        'has_heading' { $okFields = ((Is-Str $r.heading) -and (-not (Has-Prop $r 'scope') -or @('none', 'block') -ccontains [string]$r.scope)) }
        'lists_named' { $okFields = (Is-StrList $r.names) }
        'max_items' { $okFields = ((Is-Str $r.list) -and (Is-Num $r.max)) }
        'min_items' { $okFields = ((Is-Str $r.list) -and (Is-Num $r.min)) }
        'min_lines' { $okFields = (Is-Num $r.min) }
        'forbidden_text' { $okFields = (Test-TextFields $r) }
        'contains_text' { $okFields = (Test-TextFields $r) }
        'answer' { $okFields = (Test-AnswerFields $r) }
        'file_exists' { $okFields = (-not (Has-Prop $r 'path') -or (Is-Str $r.path)) }
        'file_absent' { $okFields = (-not (Has-Prop $r 'path') -or (Is-Str $r.path)) }
    }
    if (-not $okFields) { Die 'bad rule fields' }
}

# A plain relative path inside the learner folder
function Test-BadName($n) {
    if (-not (Is-Str $n)) { return $true }
    if ($n -match '[\\:*?"<>|~$`\x00-\x1f\x7f]') { return $true }
    foreach ($comp in $n.Split('/')) { if ($comp -eq '' -or $comp -eq '.' -or $comp -eq '..') { return $true } }
    return $false
}
$fileName = [string]$spec.file
if (Test-BadName $fileName) { Die 'bad file name in rules' }
foreach ($r in $ruleList) { if (($r.type -ceq 'file_absent' -or $r.type -ceq 'file_exists') -and (Has-Prop $r 'path') -and (Test-BadName $r.path)) { Die 'bad file name in rules' } }

function Test-Link([string]$p) {
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    # A link is only what Windows follows: a symbolic link or a junction. Other reparse points (OneDrive and other cloud placeholders) are not links.
    if (-not $item) { return $false }
    $t = [string]$item.LinkType
    return ([string]::Equals($t, 'SymbolicLink', [System.StringComparison]::Ordinal) -or [string]::Equals($t, 'Junction', [System.StringComparison]::Ordinal))
}

# ---------- the learner file ----------
$target = Join-Path $Dir $fileName
$hasFile = Test-Path -LiteralPath $target -PathType Leaf
$raw = ''
if ($hasFile) {
    # Neither the file nor any folder on the way to it may be a link (a reparse point): reading would leave the learner folder
    $p = $Dir
    foreach ($comp in $fileName.Split('/')) {
        $p = Join-Path $p $comp
        if (Test-Link $p) { Die 'link in file path' }
    }
    if ((Get-Item -LiteralPath $target -Force).Length -gt 1048576) { Die 'file is larger than 1 MiB' }
    $raw = [System.IO.File]::ReadAllText($target, $utf8)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
}
# Lines: split on LF, one trailing CR removed from each, the empty piece after the final line break dropped
$lines = New-Object 'System.Collections.Generic.List[string]'
if ($raw.Length -gt 0) {
    foreach ($piece in $raw.Split([char]10)) {
        if ($piece.EndsWith("`r")) { $piece = $piece.Substring(0, $piece.Length - 1) }
        $lines.Add($piece)
    }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Length -eq 0 -and $raw.EndsWith("`n")) { $lines.RemoveAt($lines.Count - 1) }
}
$sb = New-Object System.Text.StringBuilder
foreach ($l in $lines) { [void]$sb.Append($l).Append("`n") }
$text = $sb.ToString()

# ---------- comparison of names ----------
$foldRe = New-Object System.Text.RegularExpressions.Regex ('[A-Z' + [char]0x410 + '-' + [char]0x42F + [char]0x401 + [char]0x404 + [char]0x406 + [char]0x407 + [char]0x490 + ']')
$foldEval = [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $k = [int][char]$m.Value[0]
    if ($k -le 0x5A -or ($k -ge 0x410 -and $k -le 0x42F)) { return [string][char]($k + 32) }
    if ($k -eq 0x401) { return [string][char]0x451 }
    if ($k -eq 0x404) { return [string][char]0x454 }
    if ($k -eq 0x406) { return [string][char]0x456 }
    if ($k -eq 0x407) { return [string][char]0x457 }
    return [string][char]0x491
}
function Fold([string]$s) { return $foldRe.Replace($s, $foldEval) }
function Norm([string]$s) {
    $s = [regex]::Replace($s, '[*_]', '')
    $s = [regex]::Replace($s, '^[ \t]+|[ \t]+$', '')
    $s = [regex]::Replace($s, '^[0-9]{1,3}[.)][ \t]+', '')
    $s = [regex]::Replace($s, '[:. \t]+$', '')
    $s = [regex]::Replace($s, '[ \t]+', ' ')
    return (Fold $s)
}
function Norm-Value([string]$s) {
    $s = [regex]::Replace($s, '[*_]', '')
    $s = [regex]::Replace($s, '^[ \t]+|[ \t]+$', '')
    $s = [regex]::Replace($s, '[ \t]+', ' ')
    return (Fold $s)
}
# The value is allowed if it equals the allowed word or starts with it and then (after spaces) comes end of line or one of , - . : ; ! ( [ en dash em dash and any comment
$answerDelims = ',-.:;!([' + [char]0x2013 + [char]0x2014
function Test-ValueMatches([string]$v, [string]$a) {
    if ($a.Length -eq 0 -or -not $v.StartsWith($a, [System.StringComparison]::Ordinal)) { return $false }
    $rest = [regex]::Replace($v.Substring($a.Length), '^[ \t]+', '')
    return ($rest.Length -eq 0 -or $answerDelims.IndexOf($rest[0]) -ge 0)
}
$known = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($r in $ruleList) {
    if (Is-Str $r.heading) { [void]$known.Add((Norm $r.heading)) }
    if (Is-Str $r.list) { [void]$known.Add((Norm $r.list)) }
    if ($r.type -ceq 'lists_named') { foreach ($n in @($r.names)) { [void]$known.Add((Norm $n)) } }
}
[void]$known.Remove('')

# ---------- line classification ----------
$n = $lines.Count
$kind = New-Object 'string[]' $n
$lvl = New-Object 'int[]' $n
$nm = New-Object 'string[]' $n
$ind = New-Object 'int[]' $n
for ($i = 0; $i -lt $n; $i++) {
    $l = $lines[$i]
    $indent = 0; $k = 0
    while ($k -lt $l.Length) {
        $c = $l[$k]
        if ($c -eq ' ') { $indent++ } elseif ($c -eq "`t") { $indent += 4 } else { break }
        $k++
    }
    $rest = $l.Substring($k)
    $ind[$i] = $indent
    $kind[$i] = 't'
    $m = [regex]::Match($l, '^(#{1,6})[ \t]+([^ \t].*)$')
    if ($m.Success) { $kind[$i] = 'h'; $lvl[$i] = $m.Groups[1].Value.Length; $nm[$i] = (Norm ([regex]::Replace($m.Groups[2].Value, '[ \t]+#+[ \t]*$', ''))); continue }
    $m = [regex]::Match($rest, '^([-*+]|[0-9]{1,3}[.)])[ \t]+(.*)$')
    if ($m.Success -and [regex]::IsMatch($m.Groups[2].Value, '[^-*_ \t]')) { $kind[$i] = 'b'; continue }
    if ($indent -eq 0 -and $l.Length -gt 0) {
        $u = [regex]::Replace($l, '[*_]', '')
        $ut = [regex]::Replace($u, '^[ \t]+|[ \t]+$', '')
        $name = ''
        if ($ut.EndsWith(':')) { $name = (Norm $ut) }
        elseif ([regex]::IsMatch($l, '^(\*\*|__|\*|_)[^*_]+(\*\*|__|\*|_)[ \t]*$')) { $name = (Norm $l) }
        else {
            $pc = $u.IndexOf(':')
            if ($pc -gt 0) { $head = (Norm ($u.Substring(0, $pc))); if ($known.Contains($head)) { $name = $head } }
        }
        if ($name.Length -gt 0) { $kind[$i] = 'l'; $nm[$i] = $name }
    }
}

function Test-Section([string]$name) {
    $want = Norm $name
    for ($i = 0; $i -lt $n; $i++) { if (($kind[$i] -ceq 'h' -or $kind[$i] -ceq 'l') -and $nm[$i] -ceq $want) { return $true } }
    return $false
}
function Get-SectionCounts([int]$start, [int]$end) {
    $counts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $cur = $null; $inList = $false; $base = 0
    for ($i = $start; $i -lt $end; $i++) {
        if ($kind[$i] -ceq 'h' -or $kind[$i] -ceq 'l') { $cur = $nm[$i]; $inList = $false; continue }
        if ($kind[$i] -ceq 'b') {
            $counted = $false
            if (-not $inList) { if ($ind[$i] -le 3) { $counted = $true; $base = $ind[$i]; $inList = $true } }
            elseif ($ind[$i] -le $base) { $counted = $true; $base = $ind[$i] }
            if ($counted -and $null -ne $cur) {
                if ($counts.ContainsKey($cur)) { $counts[$cur] = $counts[$cur] + 1 } else { $counts[$cur] = 1 }
            }
            continue
        }
        if ($lines[$i].Length -gt 0 -and $ind[$i] -eq 0) { $inList = $false }
    }
    return , $counts
}
function Get-Count($counts, [string]$name) {
    $key = Norm $name
    if ($counts.ContainsKey($key)) { return $counts[$key] }
    return 0
}

$counts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
if ($hasFile) {
    $start = 0; $end = $n
    $hr = $ruleList | Where-Object { $_.type -ceq 'has_heading' -and -not ((Has-Prop $_ 'scope') -and [string]$_.scope -ceq 'none') } | Select-Object -First 1
    if ($hr) {
        $want = Norm $hr.heading
        $idx = -1
        for ($i = 0; $i -lt $n; $i++) { if ($kind[$i] -ceq 'h' -and $nm[$i] -ceq $want) { $idx = $i; break } }
        if ($idx -ge 0) {
            $level = $lvl[$idx]
            $start = $idx + 1
            for ($i = $start; $i -lt $n; $i++) { if ($kind[$i] -ceq 'h' -and $lvl[$i] -le $level) { $end = $i; break } }
        }
    }
    $counts = Get-SectionCounts $start $end
}

# ---------- text search ----------
function Prepare([string]$s, [string]$mode) {
    if ($mode -ceq 'nocase' -or $mode -ceq 'nocase_nospace') { $s = Fold $s }
    if ($mode -ceq 'nospace' -or $mode -ceq 'nocase_nospace') { $s = [regex]::Replace($s, '[ \t\r\n]', '') }
    return $s
}
function Test-Contains($r) {
    $mode = 'exact'
    if (Has-Prop $r 'match') { $mode = [string]$r.match }
    if ((Has-Prop $r 'loose') -and $r.loose -eq $true) { $mode = 'nocase_nospace' }
    $needle = Prepare ([string]$r.text) $mode
    if ($needle.Length -eq 0) { Die 'bad rule fields' }
    return ((Prepare $text $mode).Contains($needle))
}
$keepNl = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return [regex]::Replace($m.Value, '[^\n]', '') }
# Placeholder: text between < and > on one line, 1-80 characters, with a letter (Latin or Cyrillic), not starting or ending with a space, - or =
# (this drops <=, >=, <-, ->, => and comparisons with spaces), not an HTML tag from the list, not an address with a scheme, mailto: or an e-mail
$letterRe = '[A-Za-z' + [char]0x400 + '-' + [char]0x4FF + ']'
$tagNames = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($t in 'a abbr b blockquote br caption center code col dd del details dfn div dl dt em figcaption figure font h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p pre q s samp small span strike strong sub summary sup table tbody td tfoot th thead tr tt u ul var'.Split(' ')) { [void]$tagNames.Add($t) }
function Test-Placeholder([string]$inner) {
    if ($inner.Length -eq 0) { return $false }
    $chars = $inner.Length - [regex]::Matches($inner, '[\uDC00-\uDFFF]').Count
    if ($chars -gt 80) { return $false }
    if ([regex]::IsMatch($inner, '^[ \t=-]|[ \t=-]$')) { return $false }
    if (-not [regex]::IsMatch($inner, $letterRe)) { return $false }
    $tag = [regex]::Match($inner, '^/?([A-Za-z][A-Za-z0-9]*)([ \t/].*)?$')
    if ($tag.Success -and $tagNames.Contains($tag.Groups[1].Value.ToLowerInvariant())) { return $false }
    if ([regex]::IsMatch($inner, '^[A-Za-z][A-Za-z0-9+.-]*://') -or [regex]::IsMatch($inner, '^(?i:mailto:)') -or [regex]::IsMatch($inner, '^[^ \t@]+@[^ \t@]+$')) { return $false }
    return $true
}
function Count-Placeholders {
    $stripped = [regex]::Replace($text, '<!--[\s\S]*?(?:-->|\z)', $keepNl)
    $count = 0
    foreach ($line in $stripped.Split([char]10)) {
        $i = 0
        while ($i -lt $line.Length) {
            if ($line[$i] -ne '<') { $i++; continue }
            $j = $i + 1
            while ($j -lt $line.Length -and $line[$j] -ne '>' -and $line[$j] -ne '<') { $j++ }
            if ($j -ge $line.Length) { break }
            if ($line[$j] -eq '<') { $i = $j; continue }
            $inner = $line.Substring($i + 1, $j - $i - 1)
            if (Test-Placeholder $inner) { $count++; $i = $j + 1 } else { $i++ }
        }
    }
    return $count
}
function Test-Answer($r) {
    $want = Norm ([string]$r.label)
    $wanted = @()
    if (Has-Prop $r 'answers') { foreach ($a in @($r.answers)) { $wanted += (Norm-Value ([string]$a)) } } else { $wanted = @((Norm-Value ([string]$r.expect))) }
    $found = 0
    foreach ($line in $lines) {
        $noMarker = [regex]::Replace($line, '^[ \t]*([-*+]|[0-9]{1,3}[.)])[ \t]+', '')
        $u = [regex]::Replace($noMarker, '[*_]', '')
        $pc = $u.IndexOf(':')
        if ($pc -gt 0 -and (Norm ($u.Substring(0, $pc))) -ceq $want) {
            $v = Norm-Value ($u.Substring($pc + 1))
            if ($v.Length -eq 0) { return $false }
            $okValue = $false
            foreach ($w in $wanted) { if (Test-ValueMatches $v $w) { $okValue = $true; break } }
            if (-not $okValue) { return $false }
            $found++
        }
    }
    return ($found -gt 0)
}
function Test-FileAt([string]$rel) {
    $p = $Dir
    foreach ($comp in $rel.Split('/')) {
        $p = Join-Path $p $comp
        if (Test-Link $p) { Die 'link in file path' }
    }
    return (Test-Path -LiteralPath $p -PathType Leaf)
}
function Test-EntryExists([string]$rel) {
    $p = $Dir
    $parts = $rel.Split('/')
    for ($k = 0; $k -lt $parts.Length; $k++) {
        $p = Join-Path $p $parts[$k]
        if ($k -lt $parts.Length - 1 -and (Test-Link $p)) { Die 'link in file path' }
    }
    return ($null -ne (Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue))
}

function Fill([string]$t, $vars) {
    return [regex]::Replace($t, '\{(\w+)\}', { param($m) [string]$vars[$m.Groups[1].Value] })
}

# ---------- run ----------
$order = @{ accepted = 0; almost = 1; disputed = 2; failed = 3 }
$names = @('accepted', 'almost', 'disputed', 'failed')
$out = New-Object System.Collections.Generic.List[string]
$worst = 0
foreach ($r in $ruleList) {
    if (-not $hasFile -and $r.type -cne 'file_exists' -and $r.type -cne 'file_absent') {
        $out.Add("$($r.id): skipped - $($spec.skipped)")
        continue
    }
    $vars = @{}
    $ok = $false
    switch -CaseSensitive ([string]$r.type) {
        'file_exists' {
            if (Has-Prop $r 'path') { $ok = (Test-FileAt ([string]$r.path)) } else { $ok = $hasFile }
        }
        'file_absent' {
            $rel = $fileName
            if (Has-Prop $r 'path') { $rel = [string]$r.path }
            $ok = (-not (Test-EntryExists $rel))
        }
        'has_heading' { $ok = (Test-Section ([string]$r.heading)) }
        'lists_named' {
            $missing = @(@($r.names) | Where-Object { (Get-Count $counts $_) -eq 0 })
            $vars = @{ missing = ($missing -join ', ') }
            $ok = ($missing.Count -eq 0)
        }
        'max_items' {
            $c = Get-Count $counts ([string]$r.list)
            $vars = @{ n = $c; max = $r.max }
            $ok = ($c -le $r.max)
        }
        'min_items' {
            $c = Get-Count $counts ([string]$r.list)
            $vars = @{ n = $c; min = $r.min }
            $ok = ($c -ge $r.min)
        }
        'min_lines' {
            $c = 0
            foreach ($l in $lines) { if ([regex]::IsMatch($l, '[^ \t]')) { $c++ } }
            $vars = @{ n = $c; min = $r.min }
            $ok = ($c -ge $r.min)
        }
        'forbidden_text' { $ok = (-not (Test-Contains $r)) }
        'contains_text' { $ok = (Test-Contains $r) }
        'no_placeholder' {
            $c = Count-Placeholders
            $vars = @{ n = $c }
            $ok = ($c -eq 0)
        }
        'answer' { $ok = (Test-Answer $r) }
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
