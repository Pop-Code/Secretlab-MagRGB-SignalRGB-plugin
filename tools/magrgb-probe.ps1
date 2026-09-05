<#
  Secretlab MAGRGB (Nanoleaf NL72S2) - OpenAPI pairing + extControl v2 streaming probe.

  Run this WHILE the device's API authorization window is open:
    Nanoleaf Desktop -> select the strip -> settings -> "Enable API" ON -> "Connect to API"
  You then have ~30 seconds. This script polls for the whole window.

  Usage:
    powershell -ExecutionPolicy Bypass -File magrgb-probe.ps1
    powershell -ExecutionPolicy Bypass -File magrgb-probe.ps1 -Ip 192.168.1.50 -Seconds 45
    powershell -ExecutionPolicy Bypass -File magrgb-probe.ps1 -SkipPair      # reuse saved token
#>
param(
  [string]       = "192.168.1.50",
  [int]   $Port     = 16021,
  [int]   $Seconds  = 45,
  [switch]$SkipPair,
  [int]   $StreamPort = 60222
)

$ErrorActionPreference = 'Stop'
$tokenFile = Join-Path $PSScriptRoot "magrgb-token.json"
$base      = "http://$($Ip):$Port/api/v1"

function Write-Head($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. token
$token = $null
if (Test-Path $tokenFile) {
  try { $token = (Get-Content $tokenFile -Raw | ConvertFrom-Json).auth_token } catch { }
  if ($token) { Write-Host "Loaded saved token: $token" -ForegroundColor DarkGray }
}

if (-not $token -and -not $SkipPair) {
  Write-Head "Requesting auth token (POST $base/new)"
  Write-Host "Open the authorization window in Nanoleaf Desktop NOW. Polling for $Seconds s..." -ForegroundColor Yellow
  $deadline = (Get-Date).AddSeconds($Seconds)
  $lastCode = ""
  while ((Get-Date) -lt $deadline -and -not $token) {
    try {
      $r = Invoke-WebRequest -Uri "$base/new" -Method Post -TimeoutSec 5 -UseBasicParsing
      $token = ($r.Content | ConvertFrom-Json).auth_token
      if ($token) {
        Write-Host "GOT TOKEN: $token" -ForegroundColor Green
        @{ ip = $Ip; auth_token = $token } | ConvertTo-Json | Set-Content -Path $tokenFile -Encoding utf8
        Write-Host "Saved to $tokenFile"
      }
    } catch {
      $code = ""
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ("$code" -ne $lastCode) { Write-Host "  ... HTTP $code" -ForegroundColor DarkGray; $lastCode = "$code" }
      Start-Sleep -Milliseconds 900
    }
  }
}

if (-not $token) {
  Write-Host ""
  Write-Host "No token obtained. The device never entered its authorization window." -ForegroundColor Red
  Write-Host "403 = API not enabled / not in pairing mode. Enable the API toggle first, then Connect to API." -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------- 2. inspect
function Get-Api($path) {
  try { return Invoke-RestMethod -Uri "$base/$token$path" -Method Get -TimeoutSec 8 }
  catch { Write-Host ("  GET {0} failed: {1}" -f $path, $_.Exception.Message) -ForegroundColor Red; return $null }
}

Write-Head "Device info  (GET /)"
$info = Get-Api "/"
if ($info) { $info | ConvertTo-Json -Depth 8 }

Write-Head "Panel layout (GET /panelLayout/layout)  <-- THIS DECIDES ZONE GRANULARITY"
$layout = Get-Api "/panelLayout/layout"
if ($layout) { $layout | ConvertTo-Json -Depth 8 }

$panelIds = @()
$numPanels = 0
if ($layout -and $layout.numPanels) { $numPanels = [int]$layout.numPanels }
if ($layout -and $layout.positionData) { $panelIds = @($layout.positionData | ForEach-Object { [int]$_.panelId }) }
if ($panelIds.Count -eq 0) {
  Write-Host "No positionData returned -> falling back to a single panel (id 0)." -ForegroundColor Yellow
  $panelIds = @(0)
}
Write-Host ("Panels: {0}  ids: {1}" -f $panelIds.Count, ($panelIds -join ",")) -ForegroundColor Green

Write-Head "Effects list (GET /effects/effectsList)"
$fx = Get-Api "/effects/effectsList"
if ($fx) { $fx -join ", " }

# ---------------------------------------------------------------- 3. extControl
Write-Head "Enabling extControl v2 (PUT /effects)"
$body = @{ write = @{ command = "display"; animType = "extControl"; extControlVersion = "v2" } } | ConvertTo-Json -Depth 5
try {
  $resp = Invoke-WebRequest -Uri "$base/$token/effects" -Method Put -Body $body `
                            -ContentType "application/json" -TimeoutSec 8 -UseBasicParsing
  Write-Host ("HTTP {0}  {1}" -f $resp.StatusCode, $resp.Content) -ForegroundColor Green
  if ($resp.Content) {
    try {
      $sc = $resp.Content | ConvertFrom-Json
      if ($sc.streamControlPort) { $StreamPort = [int]$sc.streamControlPort; Write-Host "Device asked for port $StreamPort" }
    } catch { }
  }
} catch {
  $code = ""; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
  Write-Host "extControl PUT failed (HTTP $code): $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Trying v1 as a fallback..." -ForegroundColor Yellow
  $body1 = @{ write = @{ command = "display"; animType = "extControl"; extControlVersion = "v1" } } | ConvertTo-Json -Depth 5
  try {
    $resp1 = Invoke-WebRequest -Uri "$base/$token/effects" -Method Put -Body $body1 `
                               -ContentType "application/json" -TimeoutSec 8 -UseBasicParsing
    Write-Host ("v1 HTTP {0}  {1}" -f $resp1.StatusCode, $resp1.Content) -ForegroundColor Green
  } catch { Write-Host "v1 also failed: $($_.Exception.Message)" -ForegroundColor Red }
}

# ---------------------------------------------------------------- 4. stream test
# extControl v2 packet, all big-endian:
#   uint16 nPanels
#   per panel: uint16 panelId, uint8 R, uint8 G, uint8 B, uint8 W, uint16 transitionTime(100ms units)
function New-ExtControlV2Packet([int[]]$ids, [byte[][]]$rgbPerPanel, [int]$transition = 1) {
  $n = $ids.Count
  $buf = New-Object 'System.Collections.Generic.List[byte]'
  $buf.Add([byte](($n -shr 8) -band 0xFF)); $buf.Add([byte]($n -band 0xFF))
  for ($i = 0; $i -lt $n; $i++) {
    $id = $ids[$i]; $c = $rgbPerPanel[$i]
    $buf.Add([byte](($id -shr 8) -band 0xFF)); $buf.Add([byte]($id -band 0xFF))
    $buf.Add($c[0]); $buf.Add($c[1]); $buf.Add($c[2]); $buf.Add([byte]0)
    $buf.Add([byte](($transition -shr 8) -band 0xFF)); $buf.Add([byte]($transition -band 0xFF))
  }
  return $buf.ToArray()
}

Write-Head "Streaming test -> udp://$($Ip):$StreamPort  (watch the strip)"
$udp = New-Object System.Net.Sockets.UdpClient
$n = $panelIds.Count

# a) solid colour sweep - proves the transport works at all
foreach ($c in @(@(255,0,0), @(0,255,0), @(0,0,255), @(255,255,255))) {
  $colors = @(); for ($i=0; $i -lt $n; $i++) { $colors += ,([byte[]]$c) }
  $pkt = New-ExtControlV2Packet $panelIds $colors 1
  for ($k=0; $k -lt 10; $k++) { [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort); Start-Sleep -Milliseconds 30 }
  Write-Host ("  sent rgb({0}) x10  [{1} bytes/pkt]" -f ($c -join ","), $pkt.Length)
  Start-Sleep -Milliseconds 400
}

# b) travelling dot - proves PER-ZONE addressing (only visible if zones > 1)
if ($n -gt 1) {
  Write-Host "  travelling dot across $n panels (per-zone test)..." -ForegroundColor Yellow
  for ($pass = 0; $pass -lt 3; $pass++) {
    for ($p = 0; $p -lt $n; $p++) {
      $colors = @()
      for ($i=0; $i -lt $n; $i++) { $colors += ,([byte[]]@(0,0,0)) }
      $colors[$p] = [byte[]]@(255,255,255)
      $pkt = New-ExtControlV2Packet $panelIds $colors 1
      [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort)
      Start-Sleep -Milliseconds 40
    }
  }
} else {
  Write-Host "  only one panel -> per-zone test skipped." -ForegroundColor Yellow
}

# c) throughput check
Write-Head "Throughput check (200 frames as fast as possible)"
$colors = @(); for ($i=0; $i -lt $n; $i++) { $colors += ,([byte[]]@(0,40,120)) }
$pkt = New-ExtControlV2Packet $panelIds $colors 1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($k=0; $k -lt 200; $k++) { [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort) }
$sw.Stop()
Write-Host ("200 frames in {0} ms  =>  {1:N0} fps ceiling (network side)" -f $sw.ElapsedMilliseconds, (200000 / [Math]::Max(1,$sw.ElapsedMilliseconds)))

$udp.Close()

Write-Head "Summary"
Write-Host "token       : $token"
Write-Host "panels      : $($panelIds.Count)  ($($panelIds -join ','))"
Write-Host "stream port : $StreamPort"
Write-Host ""
Write-Host "Paste the panel layout output above back into the chat - it determines whether the" -ForegroundColor Yellow
Write-Host "plugin gets real per-zone streaming or a single averaged colour." -ForegroundColor Yellow
