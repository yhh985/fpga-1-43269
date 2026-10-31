$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
 $common=@(Get-ChildItem common -Filter '*.v' | ForEach-Object {$_.FullName})
 $binary='verification/tb_link_board_clocks.vvp'
 & tools/iverilog/app/bin/iverilog.exe -g2012 -s tb_link_board_clocks -o $binary @common sim/tb_link_board_clocks.v
 if($LASTEXITCODE -ne 0){throw 'Board-clock link test compilation failed'}
 & tools/iverilog/app/bin/vvp.exe $binary | Tee-Object -FilePath verification/tb_link_board_clocks.run.log
 if($LASTEXITCODE -ne 0){throw 'Board-clock link test failed'}
} finally {Pop-Location}
