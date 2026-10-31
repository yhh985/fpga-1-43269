param([string]$Port='COM3',[ValidateRange(2,60)][int]$Seconds=20,[ValidateSet(115200,460800)][int]$Baud=115200)
$ErrorActionPreference='Stop'
$captureRoot=Split-Path -Parent $PSScriptRoot
$capturePath=Join-Path $captureRoot ('verification/voice_capture_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.bin')
$capturePort=[System.IO.Ports.SerialPort]::new($Port,$Baud,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
$capturePort.ReadBufferSize=65536
$capturePort.ReadTimeout=200
$captureBytes=[System.Collections.Generic.List[byte]]::new()
$captureBuffer=[byte[]]::new(4096)
try {
 $capturePort.Open()
 Write-Output "Capturing $Port at $Baud baud for $Seconds seconds."
 $captureDeadline=[DateTime]::UtcNow.AddSeconds($Seconds)
 while([DateTime]::UtcNow -lt $captureDeadline) {
  if($capturePort.BytesToRead -gt 0) {
   $captureCount=$capturePort.Read($captureBuffer,0,[Math]::Min($captureBuffer.Length,$capturePort.BytesToRead))
   for($captureIndex=0;$captureIndex -lt $captureCount;$captureIndex++) {$captureBytes.Add($captureBuffer[$captureIndex])}
  }
  Start-Sleep -Milliseconds 5
 }
} finally {if($capturePort.IsOpen) {$capturePort.Close()};$capturePort.Dispose()}
[System.IO.File]::WriteAllBytes($capturePath,$captureBytes.ToArray())
Write-Output "Captured $($captureBytes.Count) bytes to $capturePath"
Write-Output 'Decode with: python tools/decode_voice_capture.py <capture path>'
