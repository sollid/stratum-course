# Learning folder of the course, Windows (PowerShell 5.1). Same behaviour and output as folder.sh.
#   folder.ps1 create [<path>] [--data <dir>] [--soft]
# Creates the learning folder (claude-course in the profile folder by default; a relative path is also taken from the profile folder), puts the mark .stratum-course
# and a short README.md in it, and remembers the path in the plugin data. By the mark /course:next knows the learning folder: the plugin puts nothing into a foreign folder.
# A folder that already exists: with the mark - remembered as it is; empty - becomes the learning folder; with foreign files - refusal. A link in place of the folder - refusal.
# Exit codes: 0 done; 50 bad path; 51 folder taken by foreign files; 52 could not create; 2 bad call.
# --soft: always exit 0 (for a skill's inline command). The path is put nowhere except into the commands of this script. ASCII only (see messages.txt).
. (Join-Path $PSScriptRoot 'lib.ps1')

$o = Get-Opts $args
function Finish([int]$code) { Exit-CourseLock; if ($o.soft) { exit 0 } else { exit $code } }
trap { Exit-CourseLock; break }
function Fail([string]$key, $vars, [int]$code) { Say $key $vars; Finish $code }

if ([string]$o.cmd -cne 'create') { [Console]::Error.WriteLine('usage: folder.ps1 create [<path>] [--data <dir>] [--soft]'); exit 2 }
$dataDir = Get-DataDir $o
if (-not (Enter-CourseLock $dataDir)) { Fail 'course.busy' $null 19 }

$p = [string]$o.arg2
if (-not $p) { $p = 'claude-course' }
$home1 = [string]$env:USERPROFILE
# The path is checked against a list of allowed characters: letters of any language, digits, space and . _ - ~ / \ ; at most 240 bytes.
# A colon is allowed only in the drive prefix (C:/ or C:\); a path starting with a single slash is not clear on Windows and is refused.
if ($script:Utf8.GetByteCount($p) -gt 240 -or -not [regex]::IsMatch($p, '^(?:[A-Za-z]:[/\\]|\\\\)?[\p{L}\p{M}\p{Nd} ._~/\\-]*$') -or [regex]::IsMatch($p, $script:HiddenRe)) { Fail 'folder.bad' $null 50 }
if (Test-Same $p '~') { $p = $home1 }
elseif ($p.StartsWith('~/') -or $p.StartsWith('~\')) { $p = Join-Path $home1 $p.Substring(2) }
if ([regex]::IsMatch($p, '^[/\\](?![/\\])')) { Fail 'folder.bad' $null 50 }
if (-not [regex]::IsMatch($p, '^([A-Za-z]:[/\\]|\\\\)')) { $p = Join-Path $home1 $p }
while (($p.EndsWith('/') -or $p.EndsWith('\')) -and $p.Length -gt 1 -and -not [regex]::IsMatch($p, '^[A-Za-z]:[/\\]$')) { $p = $p.Substring(0, $p.Length - 1) }

if (Test-IsLink $p) { Fail 'folder.cantcreate' @{ path = $p } 52 }
$made = $false
if (Test-Path -LiteralPath $p) {
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { Fail 'folder.cantcreate' @{ path = $p } 52 }
    if (Test-CourseDir $p) { $made = $false }
    elseif (@(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Where-Object { @('.DS_Store', 'desktop.ini', 'Thumbs.db') -cnotcontains $_.Name }).Count -eq 0) { $made = $true }
    else { Fail 'folder.busy' @{ path = $p } 51 }
} else {
    try { [void][System.IO.Directory]::CreateDirectory($p) } catch { Fail 'folder.cantcreate' @{ path = $p } 52 }
    $made = $true
}
if ($made) {
    try {
        $fs = [System.IO.File]::Open((Join-Path $p '.stratum-course'), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $b = $script:Utf8.GetBytes("stratum-course-folder 1`n"); $fs.Write($b, 0, $b.Length) } finally { $fs.Close() }
    } catch { Fail 'folder.cantcreate' @{ path = $p } 52 }
    try {
        $fs = [System.IO.File]::Open((Join-Path $p 'README.md'), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $b = $script:Utf8.GetBytes((Get-Msg 'folder.readme' $null) + "`n"); $fs.Write($b, 0, $b.Length) } finally { $fs.Close() }
    } catch { }
}

# The path is remembered in the plugin data; if the learning folder changed, the shown and disputed steps belonged to the old one and are forgotten
$old = [string](@(Get-StateValues $dataDir 'workdir') | Select-Object -First 1)
if ($old -and -not (Test-Same $old $p)) {
    Write-StateLines $dataDir @(Read-StateLines $dataDir | Where-Object { -not $_.StartsWith('shown=', [System.StringComparison]::Ordinal) -and -not $_.StartsWith('disputed=', [System.StringComparison]::Ordinal) })
}
Set-State $dataDir 'workdir' $p
if ($made) { Fail 'folder.created' @{ path = $p } 0 }
Fail 'folder.exists' @{ path = $p } 0
