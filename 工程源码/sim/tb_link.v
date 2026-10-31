`timescale 1ns/1ps
module tb_link;
 reg clk=0,rst=1,drop_ack=0,disconnect=0,event_valid=0,host_reset=0,sensor_reset=0;reg [7:0] cmd=1;reg [255:0] status=256'h123456;
 always #5 clk=~clk;
 wire sensor_tx,host_tx,sensor_online,host_online,failed,overflow,status_valid,command_valid;
 wire music_valid;wire [7:0] music_command;wire music_valid;wire [7:0] music_command;wire [1:0] command;wire [255:0] host_status;wire [15:0] ce0,ce1;
 link_sensor #(.PRESCALE(2),.PERIOD(24000),.RETRY(30000),.LINK_TIMEOUT(300000)) sensor(
 .clk(clk),.rst(rst|sensor_reset),.rx(drop_ack||disconnect?1'b1:host_tx),.tx(sensor_tx),.status(status),
 .event_valid(event_valid),.event_command(cmd),.online(sensor_online),.event_failed(failed),.queue_overflow(overflow),.crc_errors(ce0));
 link_host #(.PRESCALE(2),.LINK_TIMEOUT(300000)) host(.clk(clk),.rst(rst|host_reset),.rx(disconnect?1'b1:sensor_tx),.tx(host_tx),
 .music_valid(music_valid),.music_command(music_command),.music_valid(music_valid),.music_command(music_command),.voice_allow(1'b0),.online(host_online),.command_valid(command_valid),.command(command),.status_valid(status_valid),.status(host_status),.crc_errors(ce1));
 integer music_events=0,music_last=0;
 always @(posedge clk)begin #1;if(music_valid)begin music_events=music_events+1;music_last=music_command;end end
 integer music_events=0,music_last=0;
 always @(posedge clk)begin #1;if(music_valid)begin music_events=music_events+1;music_last=music_command;end end
 integer events=0,last=0,packets=0;
 always @(posedge clk)begin #1;if(command_valid)begin events=events+1;last=command;end if(status_valid)packets=packets+1;end
 task fire;input [7:0] c;begin @(negedge clk);cmd=c;event_valid=1;@(negedge clk);event_valid=0;end endtask
 initial begin
  repeat(10)@(negedge clk);rst=0;wait(sensor.ready_session);wait(status_valid);#1;
  if(host_status!==status || !host_online || !sensor_online)$fatal(1,"status/session");
  // Drop return direction only, forcing event retransmissions.
  drop_ack=1;fire(2);wait(events==1);repeat(105000)@(negedge clk);
  if(events!=1 || last!=2)$fatal(1,"duplicate event execution");
  drop_ack=0;wait(!sensor.waiting);fire(3);wait(events==2);
  if(last!=3)$fatal(1,"command3");
  disconnect=1;repeat(320000)@(negedge clk);
  if(sensor_online || host_online)$fatal(1,"disconnect timeout");
  fire(1);repeat(2000)@(negedge clk);if(events!=2)$fatal(1,"offline must not command");
  disconnect=0;wait(sensor.ready_session);fire(1);wait(events==3);
  if(last!=1 || ce0!=0 || ce1!=0 || overflow)$fatal(1,"reconnect");
  // Host-only reset while sensor is still in the previous session.
  host_reset=1;repeat(10)@(negedge clk);host_reset=0;
  wait(!sensor.ready_session);wait(sensor.ready_session);wait(status_valid);
  fire(2);wait(events==4);wait(!sensor.waiting);
  if(last!=2)$fatal(1,"host-only reboot recovery");
  sensor_reset=1;repeat(10)@(negedge clk);sensor_reset=0;
  wait(sensor.ready_session);wait(status_valid);
  fire(3);wait(events==5);wait(!sensor.waiting);
  if(last!=3 || failed || overflow)$fatal(1,"sensor-only reboot recovery");
  drop_ack=1;fire(4);wait(music_events==1);repeat(105000)@(negedge clk);
  if(events!=5||music_events!=1||music_last!=4)$fatal(1,"music retry leaked into legacy command or repeated");
  drop_ack=0;wait(!sensor.waiting);fire(5);wait(music_events==2);wait(!sensor.waiting);
  if(music_last!=5||events!=5)$fatal(1,"previous track isolation");
  drop_ack=1;fire(4);wait(music_events==1);repeat(105000)@(negedge clk);
  if(events!=5||music_events!=1||music_last!=4)$fatal(1,"music retry leaked into legacy command or repeated");
  drop_ack=0;wait(!sensor.waiting);fire(5);wait(music_events==2);wait(!sensor.waiting);
  if(music_last!=5||events!=5)$fatal(1,"previous track isolation");
  $display("PASS link: music NEXT/PREV retry/dedup and legacy isolation; music NEXT/PREV retry/dedup and legacy isolation; real UART session/status, dropped ACK retries, event dedup, timeout, reconnect, independent host/sensor reboot");$finish;
 end
 initial begin #25000000;$fatal(1,"link watchdog");end
endmodule
