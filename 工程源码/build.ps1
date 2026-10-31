[CmdletBinding()]
param(
 [ValidateSet('aca420','hx4s20','both')][string]$Board='both',
 [string]$TdCommandsPath='E:/Anlogic_fpga/bin/td_commands_prompt.exe',
 [string]$Python='python'
)
$ErrorActionPreference='Stop'
& $Python (Join-Path $PSScriptRoot 'tools/prepare_showcase.py')
if($LASTEXITCODE -ne 0){throw 'Project dependency check failed'}
if(!(Test-Path -LiteralPath $TdCommandsPath)){throw 'Pass -TdCommandsPath with the installed Anlogic TD executable'}
foreach($target in @('aca420','hx4s20')){
 if($Board -eq 'both' -or $Board -eq $target){
  & $Python (Join-Path $PSScriptRoot 'tools/build_verified.py') $target --td $TdCommandsPath
  if($LASTEXITCODE -ne 0){throw "$target build or timing verification failed"}
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "$target/deliverable/${target}_liantiao.bit") -Destination (Join-Path $PSScriptRoot "deliverable/${target}_final_showcase.bit") -Force
 }
}
