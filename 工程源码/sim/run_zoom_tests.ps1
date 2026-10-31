param([string]$IverilogPath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Remove-Item -LiteralPath (Join-Path $root 'verification/zoom_regressions.json') -ErrorAction SilentlyContinue
if(!$IverilogPath){$IverilogPath=Join-Path $root 'tools/iverilog/app/bin/iverilog.exe'}
$vvp=Join-Path (Split-Path -Parent $IverilogPath) 'vvp.exe'
$storage=@('SD/fat32_bmp_source.v','SD/sd_media_arbiter.v','SD/wav_sector_reader.v','wav_pcm_parser.v','audio_pcm_fifo.v','SD/sd_card_bmp.v','SD/bmp_read.v','image_resizer.v','image_resizer_sd_quality.v','SD/sd_card_top.v','SD/sd_card_cmd.v','SD/sd_card_sec_read_write.v','SD/spi_master.v') | ForEach-Object {Join-Path $root "hx4s20/hdl/$_"}
$cases=@(
 @{name='tb_zoom_scaler';bench='tb_zoom_scaler';params=@();sources=@('hx4s20/hdl/image_resizer_sd_quality.v','sim/tb_zoom_scaler.v')},
 @{name='tb_zoom_production';bench='tb_zoom_scaler';params=@('-Ptb_zoom_scaler.DW=640','-Ptb_zoom_scaler.DH=480','-Ptb_zoom_scaler.QUICK=1');sources=@('hx4s20/hdl/image_resizer_sd_quality.v','sim/tb_zoom_scaler.v')},
 @{name='tb_zoom_no_fit';bench='tb_zoom_scaler';params=@('-Ptb_zoom_scaler.FIT=0','-Ptb_zoom_scaler.QUICK=1');sources=@('hx4s20/hdl/image_resizer_sd_quality.v','sim/tb_zoom_scaler.v')},
 @{name='tb_zoom_sequence';bench='tb_zoom_scaler';params=@('-Ptb_zoom_scaler.REVIEW=1');sources=@('hx4s20/hdl/image_resizer_sd_quality.v','sim/tb_zoom_scaler.v')},
 @{name='tb_zoom_scheduler';bench='tb_zoom_scheduler';params=@();sources=($storage+@('sim/tb_zoom_scheduler.v'))},
 @{name='tb_zoom_osd';bench='tb_zoom_osd';params=@();sources=@('hx4s20/hdl/osd_status_overlay.v','sim/tb_zoom_osd.v')},
 @{name='tb_zoom_overlay_equivalence';bench='tb_zoom_overlay_equivalence';params=@();sources=@('hx4s20/hdl/mic_overlay.v','sim/mic_overlay_reference.v','sim/tb_zoom_overlay_equivalence.v')}
)
$results=@()
Push-Location $root
try{
 foreach($case in $cases){
  $name=$case.name;$arguments=$case.params
  & $IverilogPath -g2012 -I hx4s20/hdl -I hx4s20/hdl/include -s $case.bench @arguments -o "verification/$name.vvp" @($case.sources) *> "verification/$name.compile.log"
  if($LASTEXITCODE -ne 0){Get-Content "verification/$name.compile.log";throw "$name compile failed"}
  if($name -eq 'tb_zoom_osd'){
   Push-Location (Join-Path $root 'hx4s20')
   try{ & $vvp "../verification/$name.vvp" *> "../verification/$name.run.log" }finally{Pop-Location}
  }else{ & $vvp "verification/$name.vvp" *> "verification/$name.run.log" }
  $log=Get-Content "verification/$name.run.log" -Raw
  if($LASTEXITCODE -ne 0 -or $log -notmatch 'PASS' -or $log -match 'ERROR:'){throw "${name} failed: $log"}
  Write-Output $log.Trim();$results+=@{name=$name;passed=$true;summary=$log.Trim()}
 }
 $results | ConvertTo-Json -Depth 4 | Set-Content verification/zoom_regressions.json -Encoding utf8
}finally{Pop-Location}
