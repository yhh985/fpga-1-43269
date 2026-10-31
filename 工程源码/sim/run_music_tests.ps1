param([string]$IverilogPath,[switch]$Focused)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(!$IverilogPath){$IverilogPath=Join-Path $root 'tools/iverilog/app/bin/iverilog.exe'}
$vvp=Join-Path (Split-Path -Parent $IverilogPath) 'vvp.exe'
$sources=@('hx4s20/hdl/SD/fat32_bmp_source.v','hx4s20/hdl/SD/sd_media_arbiter.v','hx4s20/hdl/SD/wav_sector_reader.v','hx4s20/hdl/wav_pcm_parser.v','hx4s20/hdl/audio_pcm_fifo.v','hx4s20/hdl/audio_wav_i2s.v','hx4s20/hdl/I2S_receiver.v','hx4s20/hdl/SD/sd_card_bmp.v','hx4s20/hdl/SD/bmp_read.v','hx4s20/hdl/image_resizer.v','hx4s20/hdl/image_resizer_sd_quality.v','hx4s20/hdl/SD/sd_card_top.v','hx4s20/hdl/SD/sd_card_cmd.v','hx4s20/hdl/SD/sd_card_sec_read_write.v','hx4s20/hdl/SD/spi_master.v','common/music_fx_return.v') | ForEach-Object {Join-Path $root $_}
$results=@()
if($Focused -and (Test-Path (Join-Path $root 'verification/music_regressions.json'))){
 $results=@(Get-Content (Join-Path $root 'verification/music_regressions.json') -Raw | ConvertFrom-Json | Where-Object {$_.name -notin @('tb_music_fx','tb_playlist') -and $_.name -notlike 'fx_phase_*'})
}
$names=if($Focused){@('tb_music_fx','tb_playlist')}else{@('tb_music_fx','tb_playlist','tb_wav_pcm_parser','tb_sd_music_stream','tb_fat32_bmp_source','tb_fat32_rejection')}
Remove-Item -LiteralPath (Join-Path $root 'verification/music_regressions.json') -ErrorAction SilentlyContinue
Push-Location $root
try{
 foreach($name in $names){
  $binary=Join-Path $root "verification/$name.vvp"
  & $IverilogPath -g2012 -I (Join-Path $root 'hx4s20/hdl') -s $name -o $binary @sources (Join-Path $PSScriptRoot "$name.v") *> "verification/$name.compile.log"
  if($LASTEXITCODE -ne 0){Get-Content "verification/$name.compile.log";throw "$name compile failed"}
  & $vvp $binary *> "verification/$name.run.log"
  $log=Get-Content "verification/$name.run.log" -Raw
  if($LASTEXITCODE -ne 0 -or $log -notmatch 'PASS'){Write-Output $log;throw "$name failed"}
  Write-Output $log.Trim();$results+=@{name=$name;passed=$true;summary=$log.Trim()}
 }
 foreach($phase in @(0,3,7,11,15,19)){
  $delay=if($phase -eq 0){0}else{5};$name="fx_phase_${phase}_delay_${delay}"
  $binary="verification/$name.vvp"
  & $IverilogPath -g2012 -s tb_music_fx "-Ptb_music_fx.PHASE=$phase" "-Ptb_music_fx.LINK_DELAY=$delay" -o $binary @sources sim/tb_music_fx.v *> "verification/$name.compile.log"
  if($LASTEXITCODE -ne 0){throw "$name compile failed"}
  & $vvp $binary *> "verification/$name.run.log"
  $log=Get-Content "verification/$name.run.log" -Raw
  if($LASTEXITCODE -ne 0 -or $log -notmatch 'PASS'){Write-Output $log;throw "$name failed"}
  $results+=@{name=$name;passed=$true;summary=$log.Trim()}
 }
 $results | ConvertTo-Json -Depth 4 | Set-Content verification/music_regressions.json -Encoding utf8
}finally{Pop-Location}
