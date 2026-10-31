param([string]$IverilogPath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(!$IverilogPath){$IverilogPath=Join-Path $root 'tools/iverilog/app/bin/iverilog.exe'}
$vvp=Join-Path (Split-Path -Parent $IverilogPath) 'vvp.exe'
$storage=@('SD/fat32_bmp_source.v','SD/sd_media_arbiter.v','SD/wav_sector_reader.v','wav_pcm_parser.v','audio_pcm_fifo.v','SD/sd_card_bmp.v','SD/bmp_read.v','image_resizer.v','image_resizer_sd_quality.v','SD/sd_card_top.v','SD/sd_card_cmd.v','SD/sd_card_sec_read_write.v','SD/spi_master.v') | ForEach-Object {"hx4s20/hdl/$_"}
$cases=@(
 @{name='tb_prefetch';sources=($storage+@('sim/tb_prefetch.v'))},
 @{name='tb_return_guard';sources=@('common/music_fx_return.v','sim/tb_return_guard.v')},
 @{name='tb_voice_noise';sources=@('aca420/rtl/aca_kws_frontend.v','aca420/rtl/aca_kws_engine.v','aca420/rtl/kws_goertzel.v','sim/tb_voice_noise.v')}
)
Push-Location $root
try {
 Remove-Item verification/live_fix_regressions.json -ErrorAction SilentlyContinue
 $results=@()
 foreach($case in $cases){
  $name=$case.name
  & $IverilogPath -g2012 -I hx4s20/hdl -I hx4s20/hdl/include -s $name -o "verification/$name.vvp" @($case.sources) *> "verification/$name.compile.log"
  if($LASTEXITCODE -ne 0){Get-Content "verification/$name.compile.log";throw "$name compile failed"}
  & $vvp "verification/$name.vvp" *> "verification/$name.run.log"
  $log=Get-Content "verification/$name.run.log" -Raw
  if($LASTEXITCODE -ne 0 -or $log -notmatch 'PASS' -or $log -match 'ERROR:'){throw "${name}: $log"}
  Write-Output $log.Trim()
  $results+=@{name=$name;passed=$true;summary=$log.Trim()}
 }
 $results | ConvertTo-Json -Depth 4 | Set-Content verification/live_fix_regressions.json -Encoding utf8
}finally{Pop-Location}
