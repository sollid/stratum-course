# Entry for bin\course-run.cmd: course-run <connect|step-report|selfcheck|next> <arguments...>. ASCII only.
$name = [string]$args[0]
if (@('connect', 'step-report', 'selfcheck', 'next') -cnotcontains $name) {
    [Console]::Error.WriteLine('usage: course-run connect|step-report|selfcheck|next ...')
    exit 2
}
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
& (Join-Path $PSScriptRoot ($name + '.ps1')) @rest
exit $LASTEXITCODE
