param([string]$IverilogPath,[switch]$UserImageTest,[switch]$PlaybackControls,[switch]$UserBmpTest,[switch]$TransitionHandoff,[int]$TransitionFrameStep=1,[string]$OutputDirectory='sim/audit_work')
$ErrorActionPreference='Stop'
$projectDir=Split-Path -Parent $PSScriptRoot
if(-not $IverilogPath){$IverilogPath=Join-Path (Split-Path -Parent $projectDir) 'tools/iverilog/app/bin/iverilog.exe'}
$vvpPath=Join-Path (Split-Path -Parent $IverilogPath) 'vvp.exe'
$outputDir=Join-Path $projectDir $OutputDirectory
New-Item -ItemType Directory -Force $outputDir | Out-Null

# Generate test-only peripheral declarations from the actual current headers.
# None of the pixel processors, Goertzel, visual-link or AXIS stages are stubbed.
$stubFile=Join-Path $outputDir 'top_peripheral_stubs.v'
$stubText="// TEST ONLY: external storage/PLL/encrypted HDMI peripherals, not a hardware model.`n"
$stubText+='`include "global_def.v"'+"`n"
$ansiPeripherals=@(
    @{Name='sd_card_bmp';File='hdl\SD\sd_card_bmp.v'},
    @{Name='frame_read_write';File='hdl\SD\frame_read_write.v'},
    @{Name='sdram';File='hdl\SD\sdram.v'},
    @{Name='video_timing_data';File='hdl\SD\video_timing_data.v'},
    @{Name='video_delay';File='hdl\SD\video_delay.v'},
    @{Name='hdmi_1_4b_transmitter_core_wrapper';File='hdl\hdmi1.4b_transmitter_core\hdmi_1_4b_transmitter_core_wrapper.enc.v'},
    @{Name='hdmi_phy_wrapper';File='hdl\hdmi_phy_warpper.v'}
)
foreach($peripheral in $ansiPeripherals){
    # RTL headers are UTF-8.  An explicit encoding keeps non-ASCII comments
    # from corrupting the ANSI header parser and dropping following ports.
    $source=Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $projectDir $peripheral.File)
    # Strip comments before extracting ANSI headers. Unicode comments can be
    # converted by Windows PowerShell's ASCII Set-Content and otherwise make
    # the following port declaration disappear from the generated stub.
    $source=[regex]::Replace($source,'(?s)/\*.*?\*/','')
    # Process line comments line-by-line. This avoids PowerShell/.NET escape
    # handling turning a UTF-8 comment into a newline-spanning match.
    $source=(($source -split "`n") | ForEach-Object { $_ -replace '//.*$','' }) -join "`n"
    $match=[regex]::Match($source,'(?ms)^[ \t]*module\s+'+$peripheral.Name+'\b.*?^\s*\);')
    if(-not $match.Success){throw ('Cannot extract actual header for '+$peripheral.Name)}
    $header=$match.Value
    $header=[regex]::Replace($header,'(?s)`ifdef\s+SIMULATION.*?`endif','')
    $header=[regex]::Replace($header,'\boutput\s+reg\b','output wire')
    # Emit the cleaned header.  Keeping source comments here is unsafe because
    # non-ASCII comments are converted to '?' by the ASCII stub encoding; in
    # some PowerShell/.NET combinations that conversion can also collapse the
    # following newline and comment out the next port declaration.
    $clean=$header
    if($peripheral.Name -eq 'sd_card_bmp'){
        foreach($requiredPort in @('test_mode','audio_next_toggle','state_code')){
            if($clean -notmatch ('\b'+$requiredPort+'\b')){ throw ('Generated sd_card_bmp stub is missing '+$requiredPort) }
        }
    }
    $stubText+=$clean+"`n"
    foreach($output in [regex]::Matches($clean,'\boutput\b(?:\s+(?:wire|reg))?(?:\s*\[[^\]]+\])?\s+([A-Za-z_]\w*)')){
        $outputName=$output.Groups[1].Value
        $value=if($outputName -eq 'O_axis_s_ready'){"1'b1"}else{"'0"}
        $stubText+='assign '+$outputName+' = '+$value+";`n"
    }
    $stubText+="endmodule`n"
}
foreach($pll in @('sys_pll','video_pll','PLL_HDMI_AUDIO')){
    $source=Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $projectDir ('hdl\IP\'+$pll+'.v'))
    $match=[regex]::Match($source,'(?ms)^module\s+'+$pll+'\s*\(.*?^\s*\);')
    if(-not $match.Success){throw ('Cannot extract actual PLL header '+$pll)}
    $stubText+=$match.Value+"`n"
    foreach($declaration in [regex]::Matches($source,'(?m)^\s*(input|output)\s+([A-Za-z_]\w*)\s*;')){
        $stubText+=$declaration.Value+"`n"
        if($declaration.Groups[1].Value -eq 'output'){
            $name=$declaration.Groups[2].Value
            $value=if($name -eq 'extlock'){"1'b1"}else{"1'b0"}
            $stubText+='assign '+$name+' = '+$value+";`n"
        }
    }
    $stubText+="endmodule`n"
}
Set-Content -LiteralPath $stubFile -Value $stubText -Encoding ascii
$sources=@('..\common\music_fx_return.v','hdl\mic_overlay.v','..\common\link_sensor.v','..\common\link_host.v','..\common\link_packet.v','..\common\link_snapshot_cdc.v','..\common\uart_rx.v','..\common\uart_tx.v','hdl\top_tf_hdmi_audio.v','hdl\transition_fx.v','hdl\image_enhance.v',
    'hdl\user_image_rom.v',
    'hdl\color_filter.v','hdl\osd_overlay.v','hdl\audio_spectrum.v','hdl\audio_goertzel.v',
    'hdl\audio_band_overlay.v','hdl\audio_visual_link.v','hdl\osd_status_overlay.v',
    'hdl\video_rgb_to_axis_640x480.v','hdl\test_pattern_gen.v','hdl\startup_pulse.v',
    'hdl\audio_wav_i2s.v','hdl\hdmi_audio_tone_i2s_64fs.v','hdl\I2S_receiver.v','hdl\audio_arc_calculate.v',
    'hdl\image_number_2digit.v','hdl\SD\seg_decoder.v','hdl\SD\seg_scan.v','sim\tb_top_video_pipeline.v')
if(Test-Path -LiteralPath (Join-Path $projectDir 'hdl\reset_release.v')){
    $sources+='hdl\reset_release.v'
}
$bench='tb_top_video_pipeline'
if($UserImageTest){
    $bench='tb_user_image_top'
    $sources=$sources | Where-Object {$_ -ne 'sim\tb_top_video_pipeline.v'}
    $sources+='sim\tb_user_image_top.v'
}
if($PlaybackControls){
    $bench='tb_playback_top_keys'
    $sources=$sources | Where-Object {$_ -ne 'sim\tb_top_video_pipeline.v'}
    $sources+='sim\tb_playback_top_keys.v'
}
$compiled=Join-Path $outputDir ($bench+'.vvp')
if($TransitionHandoff){
    $sources=$sources | Where-Object {$_ -ne ('sim\'+$bench+'.v')}
    $bench='tb_top_transition_handoff'
    $sources+='sim\tb_top_transition_handoff.v'
    $compiled=Join-Path $outputDir ($bench+'.vvp')
}
$benchParameters=@()
if($TransitionHandoff){
    $benchParameters=@('-P',('tb_top_transition_handoff.FRAME_STEP='+$TransitionFrameStep))
}
if($UserBmpTest){
    if(!$PlaybackControls){throw '-UserBmpTest requires -PlaybackControls'}
    $benchParameters=@('-P','tb_playback_top_keys.BMP_TEST=1')
}
$compileLog=Join-Path $outputDir ($bench+'-compile.log')
$runLog=Join-Path $outputDir ($bench+'.log')
Push-Location $projectDir
try {
    [IO.File]::WriteAllText($compileLog,'')
    [IO.File]::WriteAllText($runLog,'')
    # Windows PowerShell converts native stderr warnings to ErrorRecords. Keep
    # warnings in the log and use the compiler exit code as the failure verdict.
    $ErrorActionPreference='Continue'
    & $IverilogPath -g2012 -I hdl\include -I hdl -s $bench @benchParameters -o $compiled $stubFile @sources 2>&1 | Tee-Object -FilePath $compileLog
    $compileExit=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    if($compileExit -ne 0){throw 'Actual top compilation failed'}
    & $vvpPath $compiled 2>&1 | Tee-Object -FilePath $runLog
    if($LASTEXITCODE -ne 0){throw 'Actual top integration simulation failed'}
    if(!(Select-String -LiteralPath $runLog -SimpleMatch 'ALL TESTS PASSED' -Quiet)){throw 'Missing actual top integration PASS'}
} finally {Pop-Location}
Write-Output ('PASS actual top integration: '+$bench)
