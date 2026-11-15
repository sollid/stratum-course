# Install self-check, Windows (PowerShell 5.1). Same behaviour and output as selfcheck.sh (except the shell line).
#   selfcheck.ps1 [--soft]
# Checks: PowerShell version, Claude Code version, the check program on the built-in service rule
# (selfcheck/selfcheck.json: the folder has README.md with at least one non-empty line). Folders are made in the temp folder and removed.
# Exit codes: 0 works; 41 missing tools; 42 Claude Code version unknown; 43 version too old; 44 built-in check misbehaved.
# --soft: always exit 0 (for a skill's inline command). ASCII only (see messages.txt).
. (Join-Path $PSScriptRoot 'lib.ps1')

$o = Get-Opts $args
function Finish([int]$code) { if ($o.soft) { exit 0 } else { exit $code } }
function Fail([string]$key, [hashtable]$vars, [int]$code) { Say $key $vars; Finish $code }
$min = [version]'2.1.287'

if ($PSVersionTable.PSVersion.Major -lt 5) { Fail 'selfcheck.noshell' @{ tools = 'PowerShell 5.1' } 41 }

$cmd = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cmd) { Fail 'selfcheck.noclaude' $null 42 }
$ver = $null
try {
    $raw = (& $cmd.Source --version 2>$null) | Select-Object -First 1
    if ([string]$raw -match '^(\d+\.\d+\.\d+)') { $ver = [version]$Matches[1] }
} catch { }
if ($null -eq $ver) { Fail 'selfcheck.noclaude' $null 42 }
if ($ver -lt $min) { Fail 'selfcheck.oldclaude' @{ version = $ver.ToString(); min = $min.ToString() } 43 }

function Run-Check([string]$rules, [string]$dir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'check.ps1') + '" -Rules "' + $rules + '" -Dir "' + $dir + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ code = $p.ExitCode; out = $out }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('course-selfcheck-' + [guid]::NewGuid().ToString('N'))
$good = $null
$bad = $null
try {
    $okDir = Join-Path $work 'ok'
    $emptyDir = Join-Path $work 'empty'
    [void](New-Item -ItemType Directory -Path $okDir -Force)
    [void](New-Item -ItemType Directory -Path $emptyDir -Force)
    [System.IO.File]::WriteAllText((Join-Path $okDir 'README.md'), "Stratum course install self-check`n", $script:Utf8)
    $rules = Join-Path $PSScriptRoot '..\selfcheck\selfcheck.json'
    $good = Run-Check $rules $okDir
    $bad = Run-Check $rules $emptyDir
} catch { $good = $null } finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($null -eq $good -or $null -eq $bad -or $good.code -ne 0 -or $bad.code -ne 0 -or -not ($good.out -match '(?m)^verdict: accepted\s*$') -or -not ($bad.out -match '(?m)^verdict: failed\s*$')) {
    Fail 'selfcheck.enginefail' $null 44
}

Say 'selfcheck.ok' @{ version = $ver.ToString(); min = $min.ToString(); shell = ('PowerShell ' + $PSVersionTable.PSVersion.ToString(2)) }
Finish 0
