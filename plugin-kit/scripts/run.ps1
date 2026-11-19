# Entry for bin\kit-run.cmd: kit-run <install|check|update|off|on|list|hook> <arguments...>. ASCII only.
$name = [string]$args[0]
if (@('install', 'check', 'update', 'off', 'on', 'list', 'hook') -cnotcontains $name) {
    [Console]::Error.WriteLine('usage: kit-run install|check|update|off|on|list|hook ...')
    exit 2
}
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
& (Join-Path $PSScriptRoot 'kit.ps1') $name @rest
exit $LASTEXITCODE
