<#
  Secretlab MAGRGB (NL72S2) - zone discovery.
  Reuses the token saved by magrgb-probe.ps1. No pairing window needed.

  Usage:
    powershell -ExecutionPolicy Bypass -File magrgb-zones.ps1
    powershell -ExecutionPolicy Bypass -File magrgb-zones.ps1 -MaxZones 64
#>
param(
  [string]         = "192.168.1.50",
  [int]   $Port       = 16021,
  [int]   $StreamPort = 60222,
  [int]   $MaxZones   = 32,
  [string]$Token
)

$ErrorActionPreference = 'Stop'
$tokenFile = Join-Path $PSScriptRoot "magrgb-token.json"

if (-not $Token) {
  if (-not (Test-Path $tokenFile)) { Write-Host "No token file. Run magrgb-probe.ps1 first." -ForegroundColor Red; exit 1 }
  $Token = (Get-Content $tokenFile -Raw | ConvertFrom-Json).auth_token
}
$base = "http://$($Ip):$Port/api/v1/$Token"
function Head($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

# ------------------------------------------------------------------ 1. dump everything
Head "FULL DEVICE INFO (GET /)  <-- paste this whole block back"
try {
  (Invoke-RestMethod -Uri "$base/" -Method Get -TimeoutSec 10) | ConvertTo-Json -Depth 12
} catch { Write-Host "failed: $($_.Exception.Message)" -ForegroundColor Red }

Head "Other layout / state endpoints"
foreach ($p in @("/panelLayout", "/panelLayout/globalOrientation", "/panelLayout/layout",
                 "/state", "/state/colorMode", "/state/brightness", "/effects/select")) {
  Write-Host ("--- GET {0}" -f $p) -ForegroundColor DarkGray
  try {
    $r = Invoke-RestMethod -Uri "$base$p" -Method Get -TimeoutSec 8
    ($r | ConvertTo-Json -Depth 10)
  } catch {
    $c = ""; if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode }
    Write-Host "    HTTP $c" -ForegroundColor DarkYellow
  }
}

# ------------------------------------------------------------------ 2. extControl helpers
function New-Frame([int[]]$ids, [byte[][]]$cols, [int]$tt = 0) {
  $n = $ids.Count
  $b = New-Object 'System.Collections.Generic.List[byte]'
  $b.Add([byte](($n -shr 8) -band 0xFF)); $b.Add([byte]($n -band 0xFF))
  for ($i = 0; $i -lt $n; $i++) {
    $id = $ids[$i]; $c = $cols[$i]
    $b.Add([byte](($id -shr 8) -band 0xFF)); $b.Add([byte]($id -band 0xFF))
    $b.Add($c[0]); $b.Add($c[1]); $b.Add($c[2]); $b.Add([byte]0)
    $b.Add([byte](($tt -shr 8) -band 0xFF)); $b.Add([byte]($tt -band 0xFF))
  }
  return $b.ToArray()
}

function Arm() {
  $body = @{ write = @{ command = "display"; animType = "extControl"; extControlVersion = "v2" } } | ConvertTo-Json -Depth 5
  try {
    $r = Invoke-WebRequest -Uri "$base/effects" -Method Put -Body $body -ContentType "application/json" -TimeoutSec 8 -UseBasicParsing
    Write-Host ("armed extControl v2 (HTTP {0})" -f $r.StatusCode) -ForegroundColor Green
  } catch { Write-Host "arm failed: $($_.Exception.Message)" -ForegroundColor Red }
}

$udp = New-Object System.Net.Sockets.UdpClient
function Blast([byte[]]$pkt, [int]$times = 6, [int]$gap = 25) {
  for ($k = 0; $k -lt $times; $k++) { [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort); Start-Sleep -Milliseconds $gap }
}

Arm

# ------------------------------------------------------------------ 3. baseline
Head "TEST 1 - baseline, 1 panel (id 0)"
Write-Host "Expect: whole strip WHITE, then whole strip RED." -ForegroundColor Yellow
Blast (New-Frame @(0) @(,[byte[]]@(255,255,255))) 8; Start-Sleep -Milliseconds 900
Blast (New-Frame @(0) @(,[byte[]]@(255,0,0)))     8; Start-Sleep -Milliseconds 900
Read-Host "Did the strip respond? (press Enter to continue)" | Out-Null

# ------------------------------------------------------------------ 4. does it accept N panels?
Head "TEST 2 - gradient across $MaxZones declared panels (ids 0..$($MaxZones-1))"
Write-Host "Watch closely: a RED->BLUE GRADIENT means per-zone works." -ForegroundColor Yellow
Write-Host "A single flat colour (or nothing) means the strip is one zone." -ForegroundColor Yellow
$ids = 0..($MaxZones - 1)
$cols = @()
for ($i = 0; $i -lt $MaxZones; $i++) {
  $f = $i / [double]($MaxZones - 1)
  $cols += ,([byte[]]@([byte](255 * (1 - $f)), 0, [byte](255 * $f)))
}
Blast (New-Frame $ids $cols) 20 40
Start-Sleep -Milliseconds 1500
Read-Host "Gradient, or one flat colour? (press Enter to continue)" | Out-Null

# ------------------------------------------------------------------ 5. walk a dot
Head "TEST 3 - white dot walking through ids 0..$($MaxZones-1)"
Write-Host "If a dot MOVES along the strip, note roughly how many distinct steps you see." -ForegroundColor Yellow
for ($pass = 0; $pass -lt 3; $pass++) {
  for ($p = 0; $p -lt $MaxZones; $p++) {
    $c = @()
    for ($i = 0; $i -lt $MaxZones; $i++) { $c += ,([byte[]]@(0,0,0)) }
    $c[$p] = [byte[]]@(255,255,255)
    $pkt = New-Frame $ids $c
    [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort)
    Start-Sleep -Milliseconds 60
  }
}
Start-Sleep -Milliseconds 800

# ------------------------------------------------------------------ 6. half/half
Head "TEST 4 - hard split: first half RED, second half GREEN ($MaxZones panels)"
$c = @()
for ($i = 0; $i -lt $MaxZones; $i++) {
  if ($i -lt $MaxZones / 2) { $c += ,([byte[]]@(255,0,0)) } else { $c += ,([byte[]]@(0,255,0)) }
}
Blast (New-Frame $ids $c) 25 40
Start-Sleep -Milliseconds 1500

# ------------------------------------------------------------------ 7. sustained rate test
Head "TEST 5 - sustained 30 Hz for 6 s (smoothness / dropout check)"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frames = 0
while ($sw.ElapsedMilliseconds -lt 6000) {
  $phase = ($sw.ElapsedMilliseconds / 1000.0)
  $c = @()
  for ($i = 0; $i -lt $MaxZones; $i++) {
    $v = [Math]::Sin($phase * 3 + $i * 0.4) * 0.5 + 0.5
    $c += ,([byte[]]@([byte](255 * $v), 0, [byte](255 * (1 - $v))))
  }
  $pkt = New-Frame $ids $c
  [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort)
  $frames++
  Start-Sleep -Milliseconds 33
}
$sw.Stop()
Write-Host ("sent {0} frames in {1} ms" -f $frames, $sw.ElapsedMilliseconds)

# turn it back to a calm colour
Blast (New-Frame @(0) @(,[byte[]]@(0,40,120))) 5
$udp.Close()

Head "Report back"
Write-Host "1) TEST 1 - did the strip change colour at all?"
Write-Host "2) TEST 2 - gradient or one flat colour?"
Write-Host "3) TEST 3 - did a dot move? roughly how many steps?"
Write-Host "4) TEST 4 - two halves in different colours, or one colour?"
Write-Host "5) TEST 5 - smooth, or stuttery/laggy?"
Write-Host "Plus the FULL DEVICE INFO block from the top."
