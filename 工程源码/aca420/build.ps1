$ErrorActionPreference='Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
 & (Join-Path $PSScriptRoot 'sim/run_tests.ps1')
 & 'E:/Anlogic_fpga/bin/td_commands_prompt.exe' 'build_verified.tcl' *> 'build_console.log'
 if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath 'verified_build_complete.txt')) {
  Get-Content -LiteralPath 'build_console.log' -Tail 50
  throw 'ACA420 build failed; inspect build_console.log'
 }
 # TD rewrites its project file with a bare ampersand in UsedInP&R.
 # Restore valid XML for portable editors/parsers after a successful build.
 $manifest=Join-Path $PSScriptRoot 'aca420_audio.al'
 $content=[System.IO.File]::ReadAllText($manifest).Replace('Name="UsedInP&R"','Name="UsedInP&amp;R"')
 [System.IO.File]::WriteAllText($manifest,$content,(New-Object System.Text.UTF8Encoding($false)))
 Get-Content -LiteralPath 'verified_build_complete.txt'
 Get-Content -LiteralPath 'final_timing_status.txt'
} finally {Pop-Location}
