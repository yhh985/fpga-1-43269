"""Package the completed two-board music/voice release and verify local sources."""
from pathlib import Path
import hashlib,json,re,shutil,subprocess,sys,xml.etree.ElementTree as ET
from datetime import datetime
from build_verified import validate_record
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def normalized(text):return text.replace('\r\n','\n').strip()
def main():
    build_records={board:validate_record(board) for board in ['aca420','hx4s20']}
    verified_voice=json.loads((ROOT/'voice/verification/rtl_sources.json').read_text())
    assert all(sha(ROOT/path)==digest for path,digest in verified_voice.items()),'Voice RTL regression source snapshot is stale'
    music_rows=json.loads((ROOT/'verification/music_regressions.json').read_text(encoding='utf-8-sig'))
    expected_music={'tb_music_fx','tb_playlist','tb_wav_pcm_parser','tb_sd_music_stream','tb_fat32_bmp_source','tb_fat32_rejection'}
    expected_music.update(f'fx_phase_{phase}_delay_{0 if phase==0 else 5}' for phase in [0,3,7,11,15,19])
    assert len(music_rows)==len(expected_music) and {row['name'] for row in music_rows}==expected_music
    for row in music_rows:
        log=(ROOT/f"verification/{row['name']}.run.log").read_text()
        assert row['passed'] and 'PASS' in log and 'FATAL' not in log and 'ERROR:' not in log
        assert normalized(row['summary'])==normalized(log), f"Stale music report: {row['name']}"
    # Existing release checks timing, model provenance, inferred ROMs and regressions.
    subprocess.run([sys.executable,str(ROOT/'voice/tools/release.py')],check=True)
    out=ROOT/'deliverable';out.mkdir(exist_ok=True)
    report=json.loads((ROOT/'voice/deliverable/release_manifest.json').read_text())
    provenance_tests=ROOT/'verification/build_provenance_tests.log'
    assert 'Ran 7 tests' in provenance_tests.read_text() and '\nOK' in provenance_tests.read_text()
    report['tests']['build_provenance']=dict(passed=7,sha256=sha(provenance_tests))
    zoom_path=ROOT/'verification/zoom_regressions.json'
    zoom_rows=json.loads(zoom_path.read_text(encoding='utf-8-sig'))
    expected_zoom={'tb_zoom_scaler','tb_zoom_production','tb_zoom_no_fit','tb_zoom_sequence','tb_zoom_scheduler','tb_zoom_osd','tb_zoom_overlay_equivalence'}
    assert len(zoom_rows)==len(expected_zoom) and {row['name'] for row in zoom_rows}==expected_zoom and all(row['passed'] for row in zoom_rows)
    zoom_tests=[]
    for row in zoom_rows:
        path=ROOT/f"verification/{row['name']}.run.log"
        log=path.read_text()
        assert 'PASS' in log and 'FATAL' not in log and 'ERROR:' not in log
        assert normalized(row['summary'])==normalized(log), f"Stale zoom report: {row['name']}"
        zoom_tests.append(dict(name=row['name'],sha256=sha(path)))
    report['tests']['zoom']=dict(passed=len(zoom_rows),sha256=sha(zoom_path))
    live_path=ROOT/'verification/live_fix_regressions.json'
    live_rows=json.loads(live_path.read_text(encoding='utf-8-sig'))
    assert {row['name'] for row in live_rows}=={'tb_prefetch','tb_return_guard','tb_voice_noise'}
    for row in live_rows:
        log=(ROOT/f"verification/{row['name']}.run.log").read_text()
        assert row['passed'] and 'PASS' in log and 'FATAL' not in log and 'ERROR:' not in log
        assert normalized(row['summary'])==normalized(log)
    report['tests']['live_fix']=dict(passed=len(live_rows),sha256=sha(live_path))
    audio_path=ROOT/'verification/noise_fix_audio.json'
    audio_checks=json.loads(audio_path.read_text())
    assert audio_checks['passed']==30 and all(c['passed'] for c in audio_checks['cases'])
    for path,digest in audio_checks['sources'].items():assert sha(ROOT/path)==digest,path
    for case in audio_checks['cases']:
        assert sha(ROOT/f"verification/{case['name']}.run.log")==case['sha256']
    noise_path=ROOT/'voice/verification/continuous_noise.json'
    noise_checks=json.loads(noise_path.read_text())
    assert noise_checks['passed'] and noise_checks['false_commands']==0
    for path,digest in noise_checks['sources'].items():assert sha(ROOT/path)==digest,path
    isolation=ROOT/'verification/tb_kws_isolation.run.log'
    assert 'PASS utterance isolation:' in isolation.read_text()
    report['tests']['noise_fix_audio']=dict(passed=30,sha256=sha(audio_path))
    report['tests']['continuous_noise']=dict(seconds=noise_checks['seconds'],false_commands=0,synthetic_only=True,sha256=sha(noise_path))
    report['tests']['utterance_isolation']=dict(passed=True,sha256=sha(isolation))
    track_test=ROOT/'verification/tb_track_overlay.run.log'
    assert 'PASS track OSD:' in track_test.read_text()
    report['tests']['track_overlay']=dict(passed=True,sha256=sha(track_test))
    report['tests']['voice_source_snapshot']=dict(sha256=sha(ROOT/'voice/verification/rtl_sources.json'))
    production_evaluations={}
    for name in ['streaming_adaptive_tts','streaming_adaptive_noise_tts']:
        path=ROOT/f'voice/verification/{name}.json'
        data=json.loads(path.read_text())
        assert data['adaptive_vad'] and data['weight_sha256']==report['model']['weights.mem']
        assert data['reference_sha256']==sha(ROOT/'voice/tools/kws_common.py')
        assert data['frontend_sha256']==sha(ROOT/'aca420/rtl/aca_kws_frontend.v')
        production_evaluations[name]={k:data[k] for k in ['synthetic_only','noise_amplitude','clips','command_correct','command_count','wrong_direction','false_accepts']}
        production_evaluations[name]['sha256']=sha(path)
    report['production_voice_evaluation']=production_evaluations
    resources={};projects={};builds={}
    for board,manifest in [('aca420','aca420_audio.al'),('hx4s20','contest_proj.al')]:
        folder=ROOT/board
        completion=folder/'verified_build_complete.txt'
        assert str(folder).replace('\\','/') in completion.read_text(), 'Copied historical build marker'
        xml=folder/manifest
        content=xml.read_text(encoding='utf-8-sig').replace('Name="UsedInP&R"','Name="UsedInP&amp;R"')
        xml.write_text(content,encoding='utf-8')
        tree=ET.fromstring(content)
        assert Path(tree.attrib['Path']).resolve()==folder.resolve()
        sources=[]
        for element in tree.findall('.//Source_Files//File'):
            path=(folder/element.attrib['Path']).resolve()
            assert path.is_relative_to(ROOT) and path.is_file(),path
            sources.append(dict(file=str(path.relative_to(ROOT)),sha256=sha(path)))
        projects[board]=dict(manifest=str(xml.relative_to(ROOT)),sha256=sha(xml),files=sources)
        bit=ROOT/'voice/deliverable'/(board+'_voice_test.bit')
        target=out/(board+'_music_voice.bit');shutil.copy2(bit,target)
        report['boards'][board]['file']=target.name
        area=(folder/'final_area.rpt').read_text()
        resources[board]={key:int(re.search(r'^#'+key+r'\s+(\d+)',area,re.M)[1]) for key in ['lut','reg','bram','dsp','pll']}
        for name in ['final_area.rpt','final_timing_status.txt']:
            shutil.copy2(folder/name,out/(board+'_'+name))
        record_path=folder/'verified_build_inputs.json'
        builds[board]=dict(completion=completion.read_text().strip(),sha256=sha(folder/'build_console.log'),
            input_record=str(record_path.relative_to(ROOT)),input_record_sha256=sha(record_path),
            started_utc=build_records[board]['started_utc'],finished_utc=build_records[board]['finished_utc'])
        assert sha(target)==sha(folder/('deliverable/'+board+'_liantiao.bit'))
    phases=[]
    for phase in [0,3,7,11,15,19]:
        delay=0 if phase==0 else 5
        path=ROOT/f'verification/fx_phase_{phase}_delay_{delay}.run.log'
        assert 'PASS external music return' in path.read_text()
        phases.append(dict(phase_ns=phase,one_way_delay_ns=delay,sha256=sha(path)))
    link=ROOT/'verification/tb_link_music.run.log'
    assert 'PASS link: music NEXT/PREV' in link.read_text()
    report.update(project_root=str(ROOT),projects=projects,resources=resources,builds=builds,
        music=dict(max_tracks=8,format='FAT32 root directory; PCM16 WAV mono/stereo 48kHz; <=64MiB',
        effects=['bypass','half gain','one-pole lowpass','4x saturating distortion'],
        direction='HX SD -> ACA digital processing -> HX HDMI',phase_tests=phases,
        uart_music_commands_test_sha256=sha(link)),
        zoom=dict(levels=[0.5,1,1.5,2],default=1,reference='aspect-fit 640x480',
            geometry='centered; black borders when smaller; crop when larger',
            controls='HX K4 operations page 3; K1 larger; K2 smaller; K3 reset',
            implementation='same-file SD reload into opposite frame buffer; complete frame and reader ownership handshakes',
            tests=zoom_tests),
        status='EXPERIMENTAL: simulations and internal FPGA timing passed; no physical-board or independent real-person validation')
    report['image_prefetch']=dict(next_frame=True,buffers_added=0,previous_or_zoom='SD reload',transition_seconds_at_60Hz=0.33,physical_latency_measured=False)
    report['music']['return_guard']='No DATA activity for 100ms: local original-audio fallback; FX WAIT/FX RETURN shows activity, not correctness'
    report['music']['serial_link']=dict(slot_bits=32,bclk_hz=3072000,nominal_sample_rate=48000,production_phase_delay_cases=30)
    report['voice_policy']=dict(isolated_utterances=True,alignment_votes=3,agreement='all three confident and same direction',
        minimum_quiet_before_utterance_ms=256,adaptive_noise_bands=16,minimum_active_bands=3,
        supported_phrases=['下一张','上一张'],music_voice_commands_supported=False)
    report['card_test_files']={p.name:sha(p) for p in (ROOT/'card_test').glob('*.WAV')}
    report['package_files']={str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'README.md',ROOT/'MUSIC_上板测试.md',ROOT/'ZOOM_上板测试.md',ROOT/'REVIEW_复审报告.md',ROOT/'run_all.ps1',ROOT/'sim/run_music_tests.ps1',ROOT/'sim/run_zoom_tests.ps1',ROOT/'sim/test_build_provenance.py',ROOT/'tools/build_verified.py',ROOT/'tools/package_music_release.py']}
    documentation=[ROOT/'voice/README_语音上板测试.md',ROOT/'tools/generate_code_inventory.py']
    documentation.extend(sorted((ROOT/'docs').glob('*.md')))
    documentation.extend(sorted((ROOT/'docs').glob('*.json')))
    documentation.extend([ROOT/'sim/run_live_fix_tests.ps1',ROOT/'tools/prepare_fast_images.py'])
    documentation.extend([ROOT/'sim/run_noise_fix_tests.py',ROOT/'sim/tb_kws_isolation.v',ROOT/'sim/tb_music_fx.v',ROOT/'sim/tb_track_overlay.v',
        ROOT/'voice/tools/test_continuous_noise.py',ROOT/'voice/tools/test_isolation.py'])
    documentation.extend(sorted((ROOT/'card_fast_test').glob('*')))
    report['package_files'].update({str(p.relative_to(ROOT)):sha(p) for p in documentation})
    (out/'release_manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    acceptance=dict(passed=True,source_model_tool_hashes_match=True,packaged_bits_match_standard_bits=True,
        resources=resources,tests=report['tests'],music_phase_tests=len(phases),physical_board_test=False,real_person_test=False)
    (ROOT/'voice/verification/final_acceptance.json').write_text(json.dumps(acceptance,indent=2),encoding='utf-8')
    (ROOT/'verification/final_acceptance.json').write_text(json.dumps(acceptance,indent=2),encoding='utf-8')
    print(json.dumps(acceptance,indent=2))
if __name__=='__main__':main()
