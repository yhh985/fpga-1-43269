param([string]$OutputDirectory='verification',[string]$IverilogPath,[string]$Python='python')
$ErrorActionPreference='Stop'
$options=@('--output',$OutputDirectory)
if($IverilogPath){$options+=@('--iverilog',$IverilogPath)}
& $Python (Join-Path $PSScriptRoot 'run_tests.py') @options
if($LASTEXITCODE -ne 0){throw 'ACA production RTL / model regression failed'}
