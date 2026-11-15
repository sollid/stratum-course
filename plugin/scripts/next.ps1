# Next course step, Windows (PowerShell 5.1). Same behaviour and output as next.sh.
#   next.ps1 [--data <dir>] [--soft]
# The task comes from the site after pairing. This plugin version does not load tasks from the site: the script says what to do, honestly, and does not fail.
# Exit codes: 0 paired, no task yet; 40 device not paired. The token file is only checked for a token, never printed.
# --soft: always exit 0 (for a skill's inline command). ASCII only (see messages.txt).
. (Join-Path $PSScriptRoot 'lib.ps1')

$o = Get-Opts $args
function Finish([int]$code) { if ($o.soft) { exit 0 } else { exit $code } }

$dataDir = Get-DataDir $o
$kv = Read-KV (Join-Path $dataDir 'device-token.txt')
if ($null -eq $kv -or -not $kv['token']) { Say 'next.notpaired' $null; Finish 40 }
Say 'next.nolesson' @{ version = (Get-PluginVersion) }
Finish 0
