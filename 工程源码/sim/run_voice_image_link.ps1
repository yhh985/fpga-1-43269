$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
 $storage=@('SD/fat32_bmp_source.v','SD/sd_media_arbiter.v','SD/wav_sector_reader.v','wav_pcm_parser.v','audio_pcm_fifo.v','SD/sd_card_bmp.v','SD/bmp_read.v','image_resizer.v','image_resizer_sd_quality.v','SD/sd_card_top.v','SD/sd_card_cmd.v','SD/sd_card_sec_read_write.v','SD/spi_master.v') | ForEach-Object {"hx4s20/hdl/$_"}
 $common=@(Get-ChildItem common -Filter '*.v' | ForEach-Object {$_.FullName})
 & tools/iverilog/app/bin/iverilog.exe -g2012 -I hx4s20/hdl -I hx4s20/hdl/include -s tb_voice_image_link -o verification/tb_voice_image_link.vvp @storage @common sim/tb_voice_image_link.v *> verification/tb_voice_image_link.compile.log
 if($LASTEXITCODE -ne 0){throw 'UART to image compile failed'}
 & tools/iverilog/app/bin/vvp.exe verification/tb_voice_image_link.vvp | Tee-Object verification/tb_voice_image_link.run.log
 if($LASTEXITCODE -ne 0){throw 'UART to image simulation failed'}
} finally {Pop-Location}
