# TD 6.2 combined route/hold crashes at this density. Run them separately.
set buildRoot [file normalize [pwd]]
set buildStart [clock seconds]
file delete -force $buildRoot/verified_build_complete.txt
proc read_text {path} {
    set handle [open $path r]
    set result [read $handle]
    close $handle
    return $result
}
proc check_step {root run marker start} {
    set path $root/contest_proj_Runs/$run/$marker
    if {![file exists $path] || [file mtime $path] < $start} {error "No fresh completion: $path"}
    set logText [read_text $root/contest_proj_Runs/$run/run.log]
    if {[regexp {\m(ERROR|FATAL)\M} $logText]} {error "Error in $run/run.log"}
    if {[regexp {HDL-(5105|7225).*CRITICAL-WARNING|USR-(8105|8159|8130|8208).*CRITICAL-WARNING} $logText]} {
        error "Missing initialization or failed clock constraints in $run"
    }
}
import_device eagle_s20.db -package EG4S20BG256
open_project $buildRoot/contest_proj.al
set result [catch {
    top_module top
    set_param -run syn_1 gate eram_init on
    set_param -run phy_1 place pr_strategy 2
    set_param -run phy_1 place seed 8
    set_param -run phy_1 flow thread 2
    set_param -run phy_1 place effort high
    set_param -run phy_1 place opt_timing high
    set_param -run phy_1 place logic_level_opt on
    set_param -run phy_1 place aggressive_opt 21
    set_param -run phy_1 place aggr_neighbor_dist 5
    set_param -run phy_1 place enhanced_beeline_opt 3
    set_param -run phy_1 place timing_driven_mode on
    set_param -run phy_1 place shifter_opt off
    set_param -run phy_1 place crit_path_opt on
    set_param -run phy_1 place post_place_opt high
    set_param -run phy_1 place hfn_opt_effort low
    set_param -run phy_1 place split_data_from_clock on
    reset_runs {syn_1 phy_1}
    launch_runs syn_1 -jobs 1
    catch {wait_run syn_1 -quiet}
    check_step $buildRoot syn_1 .opt_gate.end.f $buildStart
    launch_runs -step opt_place phy_1 -jobs 1
    catch {wait_run phy_1 -quiet}
    check_step $buildRoot phy_1 .opt_place.end.f $buildStart
    close_project
    import_db $buildRoot/contest_proj_Runs/phy_1/contest_proj_place.db
    set_param flow qor_monitor off
    set_param route fix_hold off
    set_param route post_route_opt high
    set_param route postrt_opt_extra_round 4
    route
    export_db $buildRoot/routed_unfixed.db
    fix_hold
    update_timing -mode final
    set status $buildRoot/final_timing_status.txt
    report_timing_status -file $status
    report_timing_summary -file $buildRoot/final_timing.rpt
    report_route_status -drc
    report_area -io_info -file $buildRoot/final_area.rpt
    export_db $buildRoot/final_routed.db
    set timing [read_text $status]
    foreach prefix {S H} name {Setup Hold} {
        set pattern [format {%sWNS:\s*(-?[0-9.]+)ns,\s*%sTNS:\s*(-?[0-9.]+)ns} $prefix $prefix]
        if {![regexp $pattern $timing unused wns tns]} {error "Missing final $name timing"}
        if {$wns < 0 || $tns != 0} {error "$name timing failed: WNS=$wns TNS=$tns"}
        puts "VERIFIED_TIMING $name WNS=${wns}ns TNS=${tns}ns"
    }
    file mkdir $buildRoot/contest_proj_Runs/best_result
    set bit $buildRoot/contest_proj_Runs/best_result/contest_proj.bit
    bitgen -bit $bit
    if {![file exists $bit] || [file mtime $bit] < $buildStart} {error "No fresh bitstream"}
    set marker [open $buildRoot/verified_build_complete.txt w]
    puts $marker "VERIFIED_BUILD_COMPLETE $bit"
    close $marker
} errorText]
catch {close_project}
if {$result} {puts stderr "VERIFIED_BUILD_FAILED $errorText";exit 1}
puts "VERIFIED_BUILD_COMPLETE $bit"
exit 0
