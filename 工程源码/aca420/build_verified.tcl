set root [file normalize [pwd]]
set buildStart [clock seconds]
file delete -force $root/verified_build_complete.txt
proc read_text {path} {set f [open $path r];set t [read $f];close $f;return $t}
proc check_run {root run marker start} {
    set path $root/aca420_audio_Runs/$run/$marker
    if {![file exists $path] || [file mtime $path]<$start} {error "No fresh completion: $path"}
    set log [read_text $root/aca420_audio_Runs/$run/run.log]
    if {[regexp {\m(ERROR|FATAL)\M} $log]} {error "Build error in $run"}
    if {[regexp {HDL-(5105|7225).*CRITICAL-WARNING} $log]} {error "Missing initialization or implicit net conflict in $run"}
    if {[regexp {USR-(8105|8159|8130|8208).*CRITICAL-WARNING} $log]} {error "Failed timing command in $run"}
}
import_device eagle_s20.db -package EG4S20BG256
open_project $root/aca420_audio.al
set failed [catch {
    top_module aca420_audio_top
    set_param -run syn_1 gate eram_init on
    set_param -run phy_1 flow thread 2
    set_param -run phy_1 place seed 3
    set_param -run phy_1 place effort high
    set_param -run phy_1 place opt_timing high
    set_param -run phy_1 place post_place_opt high
    set_param -run phy_1 route fix_hold on
    reset_runs {syn_1 phy_1}
    launch_runs syn_1 -jobs 1
    catch {wait_run syn_1 -quiet}
    check_run $root syn_1 .opt_gate.end.f $buildStart
    launch_runs -step opt_place phy_1 -jobs 1
    catch {wait_run phy_1 -quiet}
    check_run $root phy_1 .opt_place.end.f $buildStart
    close_project
    import_db $root/aca420_audio_Runs/phy_1/aca420_audio_place.db
    set_param route fix_hold off
    set_param route post_route_opt high
    set_param route postrt_opt_extra_round 4
    route
    fix_hold
    update_timing -mode final
    report_timing_status -file $root/final_timing_status.txt
    report_timing_summary -file $root/final_timing.rpt
    report_area -io_info -file $root/final_area.rpt
    report_route_status -drc
    export_db $root/final_routed.db
    set status [read_text $root/final_timing_status.txt]
    foreach prefix {S H} name {Setup Hold} {
        set pattern [format {%sWNS:\s*(-?[0-9.]+)ns,\s*%sTNS:\s*(-?[0-9.]+)ns} $prefix $prefix]
        if {![regexp $pattern $status unused wns tns]} {error "No final $name timing"}
        if {$wns<0 || $tns!=0} {error "$name timing failed: $wns $tns"}
        puts "VERIFIED_TIMING $name WNS=${wns}ns TNS=${tns}ns"
    }
    file mkdir $root/deliverable
    set bit $root/deliverable/aca420_liantiao.bit
    bitgen -bit $bit
    if {![file exists $bit] || [file mtime $bit]<$buildStart} {error "No fresh bitstream"}
    set f [open $root/verified_build_complete.txt w]
    puts $f "VERIFIED_BUILD_COMPLETE $bit";close $f
} reason]
catch {close_project}
if {$failed} {puts stderr "VERIFIED_BUILD_FAILED $reason";exit 1}
puts "VERIFIED_BUILD_COMPLETE $bit"
exit 0
