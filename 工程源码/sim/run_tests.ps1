param([string]$IverilogPath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
if(!$IverilogPath){$IverilogPath=Join-Path $root 'tools/iverilog/app/bin/iverilog.exe'}
$iverilog=$IverilogPath
$vvp=Join-Path (Split-Path -Parent $iverilog) 'vvp.exe'
$output=Join-Path $root 'verification'
$common=@(Get-ChildItem (Join-Path $root 'common') -Filter '*.v' | ForEach-Object {$_.FullName})
$cases=@{
 'tb_mic_overlay'=@('hx4s20/hdl/mic_overlay.v')
 'tb_analysis'=@('aca420/rtl/aca_analysis.v','aca420/rtl/audio_goertzel.v')
 'tb_demo'=@('aca420/rtl/aca_demo.v','aca420/rtl/aca_rhythm.v')
 'tb_audio_goertzel8'=@('aca420/rtl/audio_goertzel.v')
 'tb_rhythm'=@('aca420/rtl/aca_rhythm.v')
 'tb_link'=@()
 'tb_packet'=@()
 'tb_snapshot'=@()
 'tb_audio_goertzel'=@('hx4s20/hdl/audio_goertzel.v')
 'tb_audio_band_overlay'=@('hx4s20/hdl/audio_band_overlay.v')
 'tb_audio_visual_link'=@('hx4s20/hdl/audio_visual_link.v')
}
New-Item -ItemType Directory -Force $output | Out-Null
Remove-Item -LiteralPath (Join-Path $output 'regressions.json') -ErrorAction SilentlyContinue
$results=@()
foreach($name in ($cases.Keys | Sort-Object)) {
 $sources=$common+@($cases[$name] | ForEach-Object {Join-Path $root $_})
 $binary=Join-Path $output "$name.vvp"
 $bench=$name;$extra=@();$testFile=Join-Path $PSScriptRoot "$name.v"
 if($name -eq 'tb_audio_goertzel8'){$bench='tb_audio_goertzel';$extra=@('-Ptb_audio_goertzel.BANDS=8');$testFile=Join-Path $PSScriptRoot 'tb_audio_goertzel.v'}
 & $iverilog -g2012 -Wall @extra -s $bench -o $binary @sources $testFile *> (Join-Path $output "$name.compile.log")
 if($LASTEXITCODE -ne 0) {Get-Content (Join-Path $output "$name.compile.log");throw "$name compile failed"}
 & $vvp $binary *> (Join-Path $output "$name.run.log")
 if($LASTEXITCODE -ne 0) {Get-Content (Join-Path $output "$name.run.log");throw "$name failed"}
 $text=Get-Content (Join-Path $output "$name.run.log") -Raw
 if($text -notmatch 'PASS') {throw "$name did not report PASS"}
 Write-Output $text.Trim()
 $results+=@{name=$name;passed=$true;summary=$text.Trim()}
}
$results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $output 'regressions.json') -Encoding utf8
