# Check program for Windows (PowerShell 5.1, present in Windows 11). Same behaviour and output as check.sh (rules format: RULES.md; rules of version 3: the contract "Rules of version 3 (and 4)").
# ASCII only on purpose: Russian text comes from the rules (JSON), not from this script, so it does not depend on the file encoding.
# Rules are data only and are validated before use: rule id ^[A-Za-z0-9_-]{1,40}$, type, on_fail and the fields of each type,
# the file and path fields are plain relative paths inside the learner folder (no .., absolute path, drive, ~, links; file at most 1 MiB, from version 3 at most 256 KiB).
# No value from the rules is ever used as code or as a regular expression: text is compared as a literal string.
# Files are read as bytes and decoded as UTF-8 explicitly; nothing depends on the culture (text is compared by ordinal rules and by own tables). No external programs.
# Engine level 3: rules of versions 1..3. Rules of version 4 and higher: exit 2 with "newer than this plugin" (update the plugin).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1 -Rules <rules.json> -Dir <learner folder>
# Exit codes: 0 the check ran (verdict in the output); 2 bad call or unacceptable rules.
param([string]$Rules, [string]$Dir)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$inv = [System.Globalization.CultureInfo]::InvariantCulture

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

# Version of the rules: the header line "version": N (the same reading as in check.sh); the rules themselves are the lines with "type":
$engineLevel = 3
$ver = 0
$ruleRaw = New-Object 'System.Collections.Generic.List[string]'
$badLine = $false
foreach ($piece in $rawRules.Split([char]10)) {
    $line = $piece
    if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
    if ($line.Contains('"type":')) { $ruleRaw.Add($line); continue }
    if ($line.Contains('"skipped":')) { continue }
    if ($line.Contains('"engine":')) { continue }
    $m = [regex]::Match($line, '^[ \t]*"version"[ \t]*:[ \t]*(.*?)[ \t]*,?[ \t]*$')
    if ($m.Success -and $line -cmatch '^[ \t]*"version"[ \t]*:') {
        $vs = $m.Groups[1].Value
        if (-not [regex]::IsMatch($vs, '^[0-9]+$') -or $vs.Length -gt 3) { Die 'bad version' }
        $ver = [int]$vs
        continue
    }
    if ([regex]::IsMatch($line, '^[ \t]*\{[ \t]*"')) { $badLine = $true }
}

# Engine level: 1 is plugin 0.1.0, 2 is the types and fields of RULES.md, 3 adds the rules of version 3. The rules file may name the level it needs with "engine": N
if (Has-Prop $spec 'engine') {
    if (-not (Is-Num $spec.engine) -or $spec.engine -lt 1) { Die 'bad engine level' }
    if ($spec.engine -gt $engineLevel) { Die "rules newer than this plugin: update the plugin (rules need engine level $($spec.engine), this one is $engineLevel)" }
}
if ($ver -gt $engineLevel) { Die "rules newer than this plugin: update the plugin (rules need version $ver, this plugin knows up to $engineLevel)" }

# ---------- rules of version 3: one object on one line, read by characters ----------
$type3 = @{
    'file_exists' = @('', 'path', 1); 'file_absent' = @('path', '', 2); 'has_heading' = @('heading', '', 1); 'lists_named' = @('names', '', 1)
    'max_items' = @('list,max', '', 1); 'min_items' = @('list,min', '', 2); 'min_lines' = @('min', '', 1); 'forbidden_text' = @('text', '', 1)
    'contains_text' = @('text', 'loose', 2); 'no_placeholder' = @('', '', 2); 'answer' = @('label,expect', '', 2)
    'contains_number' = @('value', 'tolerance,list', 3); 'contains_some' = @('texts,min', 'loose', 3); 'each_item_has' = @('list,any', 'loose', 3)
    'fields_filled' = @('labels', '', 3); 'file_unchanged' = @('path,sha256', '', 3)
}
$textReaders = @('has_heading', 'lists_named', 'max_items', 'min_items', 'min_lines', 'forbidden_text', 'contains_text', 'no_placeholder', 'answer', 'contains_number', 'contains_some', 'each_item_has', 'fields_filled')
function Ch([string]$s, [int]$p) { if ($p -ge 0 -and $p -lt $s.Length) { return [string]$s[$p] } return '' }
function Skip-Ws([string]$s, [int]$p) { while ($p -lt $s.Length -and ($s[$p] -eq ' ' -or $s[$p] -eq "`t")) { $p++ } return $p }
# Returns $null if the line is not a rule object in the accepted shape; else @{ keys = ordered names; kind = key -> s|n|b|l; val = key -> string; list = key -> string[] }
function Parse-Rule3([string]$s) {
    $n = $s.Length
    $p = Skip-Ws $s 0
    if ((Ch $s $p) -ne '{') { return $null }
    $p++
    $keys = New-Object 'System.Collections.Generic.List[string]'
    $kind = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    $val = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    $lst = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    while ($true) {
        $p = Skip-Ws $s $p
        if ((Ch $s $p) -ne '"') { return $null }
        $q = $s.IndexOf('"', $p + 1)
        if ($q -lt 0) { return $null }
        $key = $s.Substring($p + 1, $q - $p - 1)
        $p = $q + 1
        if ($key.Length -eq 0 -or [regex]::IsMatch($key, '[^a-z0-9_]')) { return $null }
        if ($kind.ContainsKey($key)) { return $null }
        $p = Skip-Ws $s $p
        if ((Ch $s $p) -ne ':') { return $null }
        $p = Skip-Ws $s ($p + 1)
        $c = Ch $s $p
        if ($c -eq '"') {
            $q = $s.IndexOf('"', $p + 1)
            if ($q -lt 0) { return $null }
            $val[$key] = $s.Substring($p + 1, $q - $p - 1); $kind[$key] = 's'; $p = $q + 1
        } elseif ($c -eq '[') {
            $p = Skip-Ws $s ($p + 1)
            if ((Ch $s $p) -eq ']') { return $null }
            $items = New-Object 'System.Collections.Generic.List[string]'
            while ($true) {
                if ((Ch $s $p) -ne '"') { return $null }
                $q = $s.IndexOf('"', $p + 1)
                if ($q -lt 0) { return $null }
                $items.Add($s.Substring($p + 1, $q - $p - 1))
                $p = Skip-Ws $s ($q + 1)
                $c = Ch $s $p
                if ($c -eq ',') { $p = Skip-Ws $s ($p + 1); continue }
                if ($c -eq ']') { $p++; break }
                return $null
            }
            $lst[$key] = $items.ToArray(); $kind[$key] = 'l'; $val[$key] = ''
        } elseif ($s.Length -ge $p + 4 -and $s.Substring($p, 4) -ceq 'true') { $val[$key] = 'true'; $kind[$key] = 'b'; $p += 4 }
        elseif ($s.Length -ge $p + 5 -and $s.Substring($p, 5) -ceq 'false') { $val[$key] = 'false'; $kind[$key] = 'b'; $p += 5 }
        else {
            $w = ''
            while ($p -lt $n -and '0123456789.'.IndexOf($s[$p]) -ge 0) { $w += [string]$s[$p]; $p++ }
            if ($w.Length -eq 0) { return $null }
            $val[$key] = $w; $kind[$key] = 'n'
        }
        $keys.Add($key)
        $p = Skip-Ws $s $p
        $c = Ch $s $p
        if ($c -eq ',') { $p++; continue }
        if ($c -eq '}') { $p++; break }
        return $null
    }
    $p = Skip-Ws $s $p
    if ((Ch $s $p) -eq ',') { $p = Skip-Ws $s ($p + 1) }
    if ($p -lt $n) { return $null }
    return @{ keys = $keys; kind = $kind; val = $val; list = $lst }
}
function Code-Count([string]$s) { return $s.Length - [regex]::Matches($s, '[\uDC00-\uDFFF]').Count }
$loosenRe = New-Object System.Text.RegularExpressions.Regex ('[ \t\n' + [char]0xA0 + [char]0x2009 + [char]0x202F + ']')
# Text value: not blank (only spaces, tabs and U+00A0), up to 200 characters, no control characters (codes below 32, DEL, U+2028, U+2029) and no backslash
function Test-StrBad([string]$v) {
    if ([regex]::IsMatch($v, '^[ \t' + [char]0xA0 + ']*$')) { return $true }
    if ((Code-Count $v) -gt 200) { return $true }
    if ([regex]::IsMatch($v, '[\u0000-\u001F\u007F' + [char]0x2028 + [char]0x2029 + '\\]')) { return $true }
    return $false
}
function Test-PathBad([string]$p) {
    if ($p.Length -eq 0 -or $p.Length -gt 120 -or [regex]::IsMatch($p, '[^A-Za-z0-9._/-]') -or $p.Contains('..')) { return $true }
    $parts = $p.Split('/')
    if ($parts.Length -gt 4) { return $true }
    foreach ($seg in $parts) {
        if ($seg.Length -eq 0 -or $seg -ceq '.' -or $seg.EndsWith('.')) { return $true }
        $dot = $seg.IndexOf('.')
        $dev = $seg
        if ($dot -ge 0) { $dev = $seg.Substring(0, $dot) }
        $dev = $dev.ToLowerInvariant()
        if (@('con', 'prn', 'aux', 'nul') -ccontains $dev -or [regex]::IsMatch($dev, '^(com|lpt)[1-9]$')) { return $true }
    }
    return $false
}
function Test-IntVal($t, [string]$key) { return ($t.kind.ContainsKey($key) -and $t.kind[$key] -ceq 'n' -and [regex]::IsMatch($t.val[$key], '^(0|[1-9][0-9]*)$') -and $t.val[$key].Length -le 5) }
function Test-NumVal($t, [string]$key) {
    if (-not ($t.kind.ContainsKey($key) -and $t.kind[$key] -ceq 'n')) { return $false }
    $w = $t.val[$key]
    if (-not [regex]::IsMatch($w, '^(0|[1-9][0-9]*)(\.[0-9]+)?$')) { return $false }
    $p = $w.IndexOf('.')
    if ($p -lt 0) { return ($w.Length -le 9) }
    return (($p -le 9) -and (($w.Length - $p - 1) -le 4))
}
function Loosen([string]$s) { return (Fold ($loosenRe.Replace($s, ''))) }
# Returns '' (the rule is fine), 'unknown', 'id' or 'bad'
function Test-Rule3($t) {
    $ty = $t.val['type']
    if (-not $t.kind.ContainsKey('type') -or $t.kind['type'] -cne 's' -or -not $type3.ContainsKey($ty)) { return 'unknown' }
    $row = $type3[$ty]
    if ([int]$row[2] -gt $ver) { return 'bad' }
    $req = @(); if ($row[0] -ne '') { $req = $row[0].Split(',') }
    $opt = @(); if ($row[1] -ne '') { $opt = $row[1].Split(',') }
    foreach ($key in $t.keys) {
        $allowed = (@('id', 'type', 'on_fail', 'ok', 'fail') -ccontains $key) -or ($req -ccontains $key) -or ($opt -ccontains $key) -or ($key -ceq 'path' -and ($textReaders -ccontains $ty))
        if (-not $allowed) { return 'bad' }
    }
    foreach ($key in @('id', 'on_fail', 'ok', 'fail')) { if (-not $t.kind.ContainsKey($key)) { return 'bad' } }
    foreach ($key in $req) { if (-not $t.kind.ContainsKey($key)) { return 'bad' } }
    if ($t.kind['id'] -cne 's' -or -not [regex]::IsMatch($t.val['id'], '^[A-Za-z0-9_-]+$') -or $t.val['id'].Length -gt 40) { return 'id' }
    if ($t.kind['on_fail'] -cne 's' -or @('almost', 'disputed', 'failed') -cnotcontains $t.val['on_fail']) { return 'bad' }
    foreach ($key in @('ok', 'fail')) {
        $x = $t.val[$key]
        if ($t.kind[$key] -cne 's' -or $x.Contains('\')) { return 'bad' }
        if ([regex]::IsMatch($x, '^[ \t' + [char]0xA0 + ']*$')) { return 'bad' }
    }
    $loose = $false
    if ($t.kind.ContainsKey('loose')) { if ($t.kind['loose'] -cne 'b') { return 'bad' }; $loose = ($t.val['loose'] -ceq 'true') }
    foreach ($key in $t.keys) {
        if (@('id', 'type', 'on_fail', 'ok', 'fail', 'loose') -ccontains $key) { continue }
        if ($key -ceq 'path') { if ($t.kind[$key] -cne 's' -or (Test-PathBad $t.val[$key])) { return 'bad' } }
        elseif (@('heading', 'list', 'text', 'label', 'expect', 'item') -ccontains $key) { if ($t.kind[$key] -cne 's' -or (Test-StrBad $t.val[$key])) { return 'bad' } }
        elseif (@('names', 'texts', 'any', 'labels') -ccontains $key) {
            if ($t.kind[$key] -cne 'l' -or $t.list[$key].Length -lt 1 -or $t.list[$key].Length -gt 16) { return 'bad' }
            $seen = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($x in $t.list[$key]) {
                if (Test-StrBad $x) { return 'bad' }
                if (@('texts', 'any') -ccontains $key -and $loose) { $x = Loosen $x }
                if (-not $seen.Add($x)) { return 'bad' }
            }
        }
        elseif ($key -ceq 'max') { if (-not (Test-IntVal $t $key)) { return 'bad' } }
        elseif ($key -ceq 'min') {
            if (-not (Test-IntVal $t $key)) { return 'bad' }
            if ($ty -ceq 'contains_some' -and ([int]$t.val[$key] -lt 1 -or [int]$t.val[$key] -gt $t.list['texts'].Length)) { return 'bad' }
        }
        elseif (@('value', 'tolerance') -ccontains $key) { if (-not (Test-NumVal $t $key)) { return 'bad' } }
        elseif ($key -ceq 'sha256') { if ($t.kind[$key] -cne 's' -or -not [regex]::IsMatch($t.val[$key], '^[0-9a-f]{64}$')) { return 'bad' } }
        else { return 'bad' }
    }
    return ''
}

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

# ---------- the rule list ----------
$ruleList = @()
if ($ver -ge 3) {
    if ($ruleRaw.Count -eq 0) { Die 'rules file is not valid JSON' }
    if ($ruleRaw.Count -gt 40 -or $badLine) { Die 'bad rule fields' }
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    $list3 = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rl in $ruleRaw) {
        $t = Parse-Rule3 $rl
        if ($null -eq $t) { Die 'bad rule fields' }
        $e = Test-Rule3 $t
        if ($e -ceq 'unknown') { Die 'unknown rule type (rules newer than this plugin: update the plugin)' }
        if ($e -ceq 'id') { Die 'bad rule id' }
        if ($e -cne '') { Die 'bad rule fields' }
        if (-not $ids.Add($t.val['id'])) { Die 'bad rule id' }
        $o = New-Object PSObject
        foreach ($key in $t.keys) {
            switch ($t.kind[$key]) {
                's' { $o | Add-Member -NotePropertyName $key -NotePropertyValue ([string]$t.val[$key]) }
                'b' { $o | Add-Member -NotePropertyName $key -NotePropertyValue ($t.val[$key] -ceq 'true') }
                'l' { $o | Add-Member -NotePropertyName $key -NotePropertyValue ([string[]]$t.list[$key]) }
                'n' { if (@('max', 'min') -ccontains $key) { $o | Add-Member -NotePropertyName $key -NotePropertyValue ([int]$t.val[$key]) } else { $o | Add-Member -NotePropertyName $key -NotePropertyValue ([string]$t.val[$key]) } }
            }
        }
        $list3.Add($o)
    }
    $ruleList = $list3.ToArray()
} else {
    $ruleList = @($spec.rules)
    foreach ($r in $ruleList) {
        if (-not ([string]$r.id -cmatch '^[A-Za-z0-9_-]{1,40}$')) { Die 'bad rule id' }
        if ($ruleTypes -cnotcontains [string]$r.type) {
            if ($type3.ContainsKey([string]$r.type)) { Die 'bad rule fields' }
            Die 'unknown rule type (rules newer than this plugin: update the plugin)'
        }
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

# ---------- files of the learner folder ----------
# Version 3: a file is read through Get-Slot: N no regular file, L a link on the file or on a folder of the path, B more than 262144 bytes, Z contains NUL, R readable (bytes in .bytes).
# For a file_unchanged rule the sha256 of the bytes is computed as well (the NUL does not matter there).
$slots = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
function Get-Slot([string]$rel, [bool]$needHash) {
    if ($slots.ContainsKey($rel)) {
        $sl = $slots[$rel]
        if ($needHash -and -not $sl.sha -and ($sl.st -ceq 'R' -or $sl.st -ceq 'Z')) { $sl.sha = Get-Sha $sl.bytes }
        return $sl
    }
    $sl = @{ st = 'R'; bytes = $null; sha = '' }
    $full = Join-Path $Dir $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $sl.st = 'N' }
    else {
        $p = $Dir; $lk = $false
        foreach ($comp in $rel.Split('/')) {
            $p = Join-Path $p $comp
            if (Test-Link $p) { $lk = $true }
        }
        if ($lk) { $sl.st = 'L' }
        elseif ((Get-Item -LiteralPath $full -Force).Length -gt 262144) { $sl.st = 'B' }
        else {
            $sl.bytes = [System.IO.File]::ReadAllBytes($full)
            if ([System.Array]::IndexOf($sl.bytes, [byte]0) -ge 0) { $sl.st = 'Z' }
        }
    }
    if ($needHash -and ($sl.st -ceq 'R' -or $sl.st -ceq 'Z')) { $sl.sha = Get-Sha $sl.bytes }
    $slots[$rel] = $sl
    return $sl
}
function Get-Sha([byte[]]$bytes) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { $d = $h.ComputeHash($bytes) } finally { $h.Dispose() }
    $sb2 = New-Object System.Text.StringBuilder
    foreach ($b in $d) { [void]$sb2.Append($b.ToString('x2', $inv)) }
    return $sb2.ToString()
}

$target = Join-Path $Dir $fileName
$hasFile = $false
$raw = ''
$mainSlot = $null
if ($ver -ge 3) {
    $mainSlot = Get-Slot $fileName $false
    $hasFile = ($mainSlot.st -cne 'N')
} else {
    $hasFile = Test-Path -LiteralPath $target -PathType Leaf
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
}

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
    if ((Is-Str $r.list) -and ($r.type -ceq 'max_items' -or $r.type -ceq 'min_items')) { [void]$known.Add((Norm $r.list)) }
    if ($r.type -ceq 'lists_named') { foreach ($n in @($r.names)) { [void]$known.Add((Norm $n)) } }
}
[void]$known.Remove('')

# ---------- documents: lines, line kinds, the section and the count of items ----------
# A document is the main file (key '') or a file named by the field path of a rule of version 3 (key = the path).
function New-Doc($lines, [string]$st) {
    $n = $lines.Count
    $d = @{ st = $st; lines = $lines; n = $n; kind = (New-Object 'string[]' $n); lvl = (New-Object 'int[]' $n); nm = (New-Object 'string[]' $n); ind = (New-Object 'int[]' $n); text = ''; start = 0; end = $n; counts = $null; caches = @{} }
    $kind = $d.kind; $lvl = $d.lvl; $nm = $d.nm; $ind = $d.ind
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in $lines) { [void]$sb.Append($l).Append("`n") }
    $d.text = $sb.ToString()
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
            if (($ver -ge 3 -and [regex]::IsMatch($l, ':[ \t]*$')) -or ($ver -lt 3 -and $ut.EndsWith(':'))) { $name = (Norm $ut) }
            elseif ([regex]::IsMatch($l, '^(\*\*|__|\*|_)[^*_]+(\*\*|__|\*|_)[ \t]*$')) { $name = (Norm $l) }
            else {
                $pc = $u.IndexOf(':')
                if ($pc -gt 0 -and $ver -lt 3) { $head = (Norm ($u.Substring(0, $pc))); if ($known.Contains($head)) { $name = $head } }
            }
            if ($name.Length -gt 0) { $kind[$i] = 'l'; $nm[$i] = $name }
        }
    }
    # the section: the block of the first has_heading of this document (found by its heading), else the whole file; then the items under the labels
    $hr = $null
    foreach ($r in $ruleList) {
        if ($r.type -ceq 'has_heading' -and -not ((Has-Prop $r 'scope') -and [string]$r.scope -ceq 'none') -and (Get-RuleKey $r) -ceq $script:docKey) { $hr = $r; break }
    }
    $start = 0; $end = $n
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
    $d.start = $start; $d.end = $end
    $counts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $cur = $null; $inList = $false; $base = 0
    for ($i = $start; $i -lt $end; $i++) {
        if ($kind[$i] -ceq 'h' -or $kind[$i] -ceq 'l') { $cur = $nm[$i]; $inList = $false; continue }
        if ($kind[$i] -ceq 'b') {
            $counted = $false
            if ($ver -ge 3) { $counted = $true }
            elseif (-not $inList) { if ($ind[$i] -le 3) { $counted = $true; $base = $ind[$i]; $inList = $true } }
            elseif ($ind[$i] -le $base) { $counted = $true; $base = $ind[$i] }
            if ($counted -and $null -ne $cur) {
                if ($counts.ContainsKey($cur)) { $counts[$cur] = $counts[$cur] + 1 } else { $counts[$cur] = 1 }
            }
            continue
        }
        if ($lines[$i].Length -gt 0 -and $ind[$i] -eq 0) { $inList = $false }
    }
    $d.counts = $counts
    return $d
}
# The document key of a rule: the path of a text rule of version 3, else the main file ''
function Get-RuleKey($r) {
    if ($ver -ge 3 -and (Has-Prop $r 'path') -and ($textReaders -ccontains [string]$r.type)) { return [string]$r.path }
    return ''
}
$docs = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
$script:docKey = ''
function Get-Doc([string]$key) {
    if ($docs.ContainsKey($key)) { return $docs[$key] }
    $script:docKey = $key
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $st = 'R'
    if ($ver -lt 3) {
        # Lines: split on LF, one trailing CR removed from each, the empty piece after the final line break dropped
        if ($raw.Length -gt 0) {
            foreach ($piece in $raw.Split([char]10)) {
                if ($piece.EndsWith("`r")) { $piece = $piece.Substring(0, $piece.Length - 1) }
                $lines.Add($piece)
            }
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Length -eq 0 -and $raw.EndsWith("`n")) { $lines.RemoveAt($lines.Count - 1) }
        }
    } else {
        $rel = $key
        if ($key -ceq '') { $rel = $fileName }
        $sl = Get-Slot $rel $false
        $st = $sl.st
        if ($st -ceq 'R') {
            $t = $utf8.GetString($sl.bytes)
            if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
            $t = $t.Replace("`r`n", "`n").Replace("`r", "`n")
            if ($t.Length -gt 0) {
                foreach ($piece in $t.Split([char]10)) { $lines.Add($piece) }
                if ($t.EndsWith("`n")) { $lines.RemoveAt($lines.Count - 1) }
            }
        }
    }
    $d = New-Doc $lines $st
    $docs[$key] = $d
    return $d
}

# ---------- text search ----------
function Prepare([string]$s, [string]$mode) {
    if ($mode -ceq 'nocase' -or $mode -ceq 'nocase_nospace') { $s = Fold $s }
    if ($mode -ceq 'nospace' -or $mode -ceq 'nocase_nospace') { $s = [regex]::Replace($s, '[ \t\r\n]', '') }
    return $s
}
function Test-Contains($r, $d) {
    $mode = 'exact'
    if (Has-Prop $r 'match') { $mode = [string]$r.match }
    if ((Has-Prop $r 'loose') -and $r.loose -eq $true) { $mode = 'nocase_nospace' }
    $needle = Prepare ([string]$r.text) $mode
    if ($needle.Length -eq 0) { Die 'bad rule fields' }
    $ck = 'hay:' + $mode
    if (-not $d.caches.ContainsKey($ck)) { $d.caches[$ck] = (Prepare $d.text $mode) }
    return ($d.caches[$ck].Contains($needle))
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
function Count-Placeholders($d) {
    if ($ver -ge 3) { $c3 = 0; foreach ($l3 in $d.lines) { $c3 += Get-FieldPlaceholders $l3 }; return $c3 }
    $stripped = [regex]::Replace($d.text, '<!--[\s\S]*?(?:-->|\z)', $keepNl)
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
function Test-Answer($r, $d) {
    $want = Norm ([string]$r.label)
    $wanted = @()
    if (Has-Prop $r 'answers') { foreach ($a in @($r.answers)) { $wanted += (Norm-Value ([string]$a)) } } else { $wanted = @((Norm-Value ([string]$r.expect))) }
    $found = 0
    foreach ($line in $d.lines) {
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

# ---------- new types of version 3: numbers, items, fields ----------
$digitChars = [char[]]'0123456789'
# Letters for the edges of a number (Latin and Cyrillic: Russian and Ukrainian), by code
$isLetter = New-Object 'bool[]' 1280
foreach ($c in (65..90) + (97..122) + (0x410..0x44F) + @(0x401, 0x451, 0x404, 0x454, 0x406, 0x456, 0x407, 0x457, 0x490, 0x491)) { $isLetter[$c] = $true }
function Convert-Dec([string]$w) {
    $p = $w.IndexOf('.')
    if ($p -lt 0) { return [long]::Parse($w, $inv) * 10000 }
    $frac = ($w.Substring($p + 1) + '0000').Substring(0, 4)
    return [long]::Parse($w.Substring(0, $p), $inv) * 10000 + [long]::Parse($frac, $inv)
}
# The numbers of one line (a walk over the characters; no function calls inside the walk, it is the hot path), as integers in ten-thousandths.
# A number: digits; if they are 1-3, groups of one separator (space, U+00A0, U+2009, U+202F) and exactly three digits not followed by a digit; then . or , and the digits of the fraction.
# The number is not a part of a word or of a number name: no letter, digit, - _ / before it, no letter or digit after it. More than 9 digits in the whole part or more than 4 in the fraction: skipped.
function Get-LineNumbers([string]$s) {
    $res = New-Object 'System.Collections.Generic.List[long]'
    $n = $s.Length; $i = 0
    while ($i -lt $n) {
        $i = $s.IndexOfAny($digitChars, $i)
        if ($i -lt 0) { break }
        $j = $i + 1
        while ($j -lt $n) { $c = [int]$s[$j]; if ($c -ge 48 -and $c -le 57) { $j++ } else { break } }
        $nd = $j - $i; $k = $j; $v = 0L
        if ($nd -le 9) { for ($m = $i; $m -lt $j; $m++) { $v = $v * 10 + ([int]$s[$m] - 48) } }
        if ($nd -le 3) {
            while ($k + 3 -lt $n) {
                $c = [int]$s[$k]
                if (-not ($c -eq 32 -or $c -eq 0xA0 -or $c -eq 0x2009 -or $c -eq 0x202F)) { break }
                $d1 = [int]$s[$k + 1] - 48; $d2 = [int]$s[$k + 2] - 48; $d3 = [int]$s[$k + 3] - 48
                if ($d1 -lt 0 -or $d1 -gt 9 -or $d2 -lt 0 -or $d2 -gt 9 -or $d3 -lt 0 -or $d3 -gt 9) { break }
                if ($k + 4 -lt $n) { $c = [int]$s[$k + 4]; if ($c -ge 48 -and $c -le 57) { break } }
                $v = $v * 1000 + $d1 * 100 + $d2 * 10 + $d3; $nd += 3; $k += 4
            }
        }
        $fv = 0L; $fd = 0
        if ($k + 1 -lt $n) {
            $c = [int]$s[$k]
            if ($c -eq 46 -or $c -eq 44) {
                $c = [int]$s[$k + 1]
                if ($c -ge 48 -and $c -le 57) {
                    $m = $k + 1
                    while ($m -lt $n) {
                        $c = [int]$s[$m]
                        if ($c -ge 48 -and $c -le 57) { if ($fd -lt 4) { $fv = $fv * 10 + ($c - 48) }; $fd++; $m++ } else { break }
                    }
                    $k = $m
                }
            }
        }
        $ok = $true
        if ($i -gt 0) {
            $c = [int]$s[$i - 1]
            if (($c -lt 1280 -and $isLetter[$c]) -or ($c -ge 48 -and $c -le 57) -or $c -eq 45 -or $c -eq 95 -or $c -eq 47) { $ok = $false }
        }
        if ($ok -and $k -lt $n) {
            $c = [int]$s[$k]
            if (($c -lt 1280 -and $isLetter[$c]) -or ($c -ge 48 -and $c -le 57)) { $ok = $false }
        }
        if ($ok -and $nd -le 9 -and $fd -le 4) {
            for ($m = $fd; $m -lt 4; $m++) { $fv = $fv * 10 }
            $res.Add($v * 10000 + $fv)
        }
        $i = $k
    }
    return , $res
}
function Test-LineNumber($d, [int]$q, [long]$want, [long]$tol) {
    $ck = "num:$q"
    if (-not $d.caches.ContainsKey($ck)) {
        $nums = $null
        if ($d.lines[$q].IndexOfAny($digitChars) -ge 0) { $nums = Get-LineNumbers $d.lines[$q] }
        $d.caches[$ck] = $nums
    }
    $nums = $d.caches[$ck]
    if ($null -eq $nums) { return $false }
    foreach ($v in $nums) { $df = $v - $want; if ($df -lt 0) { $df = -$df }; if ($df -le $tol) { return $true } }
    return $false
}
function Test-Number($r, $d) {
    $want = Convert-Dec ([string]$r.value)
    $tol = 0
    if (Has-Prop $r 'tolerance') { $tol = Convert-Dec ([string]$r.tolerance) }
    if (-not (Has-Prop $r 'list')) {
        for ($q = 0; $q -lt $d.n; $q++) { if (Test-LineNumber $d $q $want $tol) { return $true } }
        return $false
    }
    $w = Norm ([string]$r.list)
    $cur = $null
    for ($q = $d.start; $q -lt $d.end; $q++) {
        if ($d.kind[$q] -ceq 'h' -or $d.kind[$q] -ceq 'l') { $cur = $d.nm[$q]; continue }
        if ($null -ne $cur -and $cur -ceq $w -and (Test-LineNumber $d $q $want $tol)) { return $true }
    }
    return $false
}
function Remove-Marker([string]$l) { return [regex]::Replace($l, '^[ \t]*([-*+]|[0-9]{1,3}[.)])[ \t]+', '') }
function Get-Lead([string]$l) { $n = 0; while ($n -lt $l.Length -and ($l[$n] -eq ' ' -or $l[$n] -eq "`t")) { $n++ } return $n }
# The items under the label: the least indent among the item lines of a section; an item runs to the next one with that indent. Text of an item: its lines without indent (the first one also without the marker), joined with LF
function Get-Items($d, [string]$name) {
    $w = Norm $name
    $items = New-Object 'System.Collections.Generic.List[string]'
    $cur = $null; $bs = -1
    for ($q = $d.start; $q -le $d.end; $q++) {
        if ($q -lt $d.end -and $d.kind[$q] -cne 'h' -and $d.kind[$q] -cne 'l') { if ($null -ne $cur -and $cur -ceq $w -and $bs -lt 0) { $bs = $q }; continue }
        if ($bs -ge 0) {
            $be = $q - 1
            $starts = New-Object 'System.Collections.Generic.List[int]'
            $least = -1
            for ($k = $bs; $k -le $be; $k++) {
                if ($d.kind[$k] -ceq 'b') { $li = Get-Lead $d.lines[$k]; if ($least -lt 0 -or $li -lt $least) { $least = $li } }
            }
            for ($k = $bs; $k -le $be; $k++) { if ($d.kind[$k] -ceq 'b' -and (Get-Lead $d.lines[$k]) -eq $least) { $starts.Add($k) } }
            for ($k = 0; $k -lt $starts.Count; $k++) {
                $e = $be
                if ($k + 1 -lt $starts.Count) { $e = $starts[$k + 1] - 1 }
                $t = [regex]::Replace((Remove-Marker $d.lines[$starts[$k]]), '[ \t]+$', '')
                for ($x = $starts[$k] + 1; $x -le $e; $x++) { $t += "`n" + $d.lines[$x].Trim(" `t") }
                $items.Add($t)
            }
        }
        $bs = -1
        if ($q -lt $d.end) { $cur = $d.nm[$q] }
    }
    return , $items
}
function Test-ItemsHave($r, $d) {
    $items = Get-Items $d ([string]$r.list)
    if ($items.Count -eq 0) { return $false }
    $loose = ((Has-Prop $r 'loose') -and $r.loose -eq $true)
    foreach ($it in $items) {
        if ($loose) { $h = Loosen $it } else { $h = Fold $it }
        $found = $false
        foreach ($a in @($r.any)) {
            if ($loose) { $x = Loosen $a } else { $x = Fold $a }
            if ($x.Length -eq 0 -or $h.Contains($x)) { $found = $true; break }
        }
        if (-not $found) { return $false }
    }
    return $true
}
function Test-SomeHave($r, $d) {
    $loose = ((Has-Prop $r 'loose') -and $r.loose -eq $true)
    $cnt = 0
    if ($loose -and -not $d.caches.ContainsKey('loose')) { $d.caches['loose'] = (Loosen $d.text) }
    foreach ($x in @($r.texts)) {
        if ($loose) { $nd = Loosen $x; if ($nd.Length -eq 0 -or $d.caches['loose'].Contains($nd)) { $cnt++ } }
        elseif ($d.text.Contains($x)) { $cnt++ }
    }
    return ($cnt -ge $r.min)
}
function Trim-Value([string]$v) { return $v.Trim([char[]]@([char]32, [char]9, [char]0xA0)) }
# A placeholder <...> in a field: one line, 1-200 characters; with @ or :// inside, or with !, =, - or a space or a tab right after < it is not a placeholder
function Test-FieldPlaceholder([string]$v) { return ((Get-FieldPlaceholders $v) -gt 0) }
function Get-FieldPlaceholders([string]$v) {
    $pos = 0; $cnt = 0
    while ($true) {
        $a = $v.IndexOf('<', $pos)
        if ($a -lt 0) { return $cnt }
        $rest = $v.Substring($a + 1)
        $j1 = $rest.IndexOf('>'); $j2 = $rest.IndexOf('<')
        if ($j1 -lt 0) { return $cnt }
        if ($j2 -ge 0 -and $j2 -lt $j1) { $pos = $a + 1 + $j2; continue }
        $inner = $rest.Substring(0, $j1)
        if ($inner.Length -gt 0 -and (Code-Count $inner) -le 200) {
            if ($inner.IndexOf('@') -lt 0 -and $inner.IndexOf('://', [System.StringComparison]::Ordinal) -lt 0 -and ('!=- ' + "`t").IndexOf($inner[0]) -lt 0) { $cnt++ }
            $pos = $a + 1 + $j1 + 1
        } else { $pos = $a + 1 }
    }
}
function Test-Filled([string]$v) {
    $v = Trim-Value ($v.Replace('*', ''))
    if ($v.Length -eq 0) { return $false }
    if (-not [regex]::IsMatch($v, '[^ \t._\-' + [char]0x2013 + [char]0x2014 + [char]0x2026 + ']')) { return $false }
    if (Test-FieldPlaceholder $v) { return $false }
    return $true
}
function Test-Fields($r, $d) {
    foreach ($label in @($r.labels)) {
        $want = Norm $label
        $found = 0
        foreach ($l in $d.lines) {
            $s = Remove-Marker $l
            $p = $s.IndexOf(':')
            if ($p -gt 0) {
                $head = [regex]::Replace($s.Substring(0, $p), '^#{1,6}[ \t]+', '')
                if ((Norm $head) -ceq $want) { if (-not (Test-Filled $s.Substring($p + 1))) { return $false }; $found++ }
            }
        }
        if ($found -eq 0) { return $false }
    }
    return $true
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
$newTypes = @('contains_number', 'contains_some', 'each_item_has', 'fields_filled', 'file_unchanged')
$out = New-Object System.Collections.Generic.List[string]
$worst = 0
foreach ($r in $ruleList) {
    $own = ($ver -ge 3 -and (Has-Prop $r 'path'))
    if (-not $hasFile -and $r.type -cne 'file_exists' -and $r.type -cne 'file_absent' -and -not $own) {
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
        'file_unchanged' {
            $sl = Get-Slot ([string]$r.path) $true
            $ok = (($sl.st -ceq 'R' -or $sl.st -ceq 'Z') -and $sl.sha -ceq [string]$r.sha256)
        }
        default {
            $d = Get-Doc (Get-RuleKey $r)
            if ($ver -ge 3 -and $d.st -cne 'R') { $ok = ($r.type -ceq 'forbidden_text' -and $own -and $d.st -ceq 'N') }
            else {
                switch -CaseSensitive ([string]$r.type) {
                    'has_heading' {
                        $want = Norm ([string]$r.heading)
                        for ($i = 0; $i -lt $d.n; $i++) { if (($d.kind[$i] -ceq 'h' -or ($d.kind[$i] -ceq 'l' -and $ver -lt 3)) -and $d.nm[$i] -ceq $want) { $ok = $true; break } }
                    }
                    'lists_named' {
                        $missing = @(@($r.names) | Where-Object { $key = Norm $_; (-not $d.counts.ContainsKey($key)) -or $d.counts[$key] -eq 0 })
                        $vars = @{ missing = ($missing -join ', ') }
                        $ok = ($missing.Count -eq 0)
                    }
                    'max_items' {
                        $key = Norm ([string]$r.list); $c = 0; if ($d.counts.ContainsKey($key)) { $c = $d.counts[$key] }
                        $vars = @{ n = $c; max = $r.max }
                        $ok = ($c -le $r.max)
                    }
                    'min_items' {
                        $key = Norm ([string]$r.list); $c = 0; if ($d.counts.ContainsKey($key)) { $c = $d.counts[$key] }
                        $vars = @{ n = $c; min = $r.min }
                        $ok = ($c -ge $r.min)
                    }
                    'min_lines' {
                        $c = 0
                        foreach ($l in $d.lines) { if ([regex]::IsMatch($l, '[^ \t]')) { $c++ } }
                        $vars = @{ n = $c; min = $r.min }
                        $ok = ($c -ge $r.min)
                    }
                    'forbidden_text' { $ok = (-not (Test-Contains $r $d)) }
                    'contains_text' { $ok = (Test-Contains $r $d) }
                    'no_placeholder' {
                        $c = Count-Placeholders $d
                        $vars = @{ n = $c }
                        $ok = ($c -eq 0)
                    }
                    'answer' { $ok = (Test-Answer $r $d) }
                    'contains_number' { $ok = (Test-Number $r $d) }
                    'contains_some' { $ok = (Test-SomeHave $r $d) }
                    'each_item_has' { $ok = (Test-ItemsHave $r $d) }
                    'fields_filled' { $ok = (Test-Fields $r $d) }
                    default { Die "unknown rule type: $($r.type)" }
                }
            }
        }
    }
    $plain = ($ver -ge 3 -and ($newTypes -ccontains [string]$r.type))
    if ($ok) { $status = 'ok'; $msg = [string]$r.ok }
    else {
        $status = $r.on_fail
        $msg = [string]$r.fail
        if ($order[$r.on_fail] -gt $worst) { $worst = $order[$r.on_fail] }
    }
    if (-not $plain) { $msg = Fill $msg $vars }
    $out.Add("$($r.id): $status - $msg")
}

$result = "verdict: $($names[$worst])`n" + ($out -join "`n") + "`n"
$bytes = $utf8.GetBytes($result)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
exit 0
