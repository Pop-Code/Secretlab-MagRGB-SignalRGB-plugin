<#
  Secretlab MAGRGB (NL72S2) - manual zone-count finder.
  YOU drive. Nothing changes until you press a key.

  powershell -ExecutionPolicy Bypass -File magrgb-find.ps1
#>
param(
  [string]         = "192.168.1.50",
  [int]   $Port       = 16021,
  [int]   $StreamPort = 60222,
  [int]   $Start      = 40,
  [int]   $Ceiling    = 48,   # how many zones to blank before each paint
  [string]$Token
)

$ErrorActionPreference = 'Stop'
$tokenFile = Join-Path $PSScriptRoot "magrgb-token.json"
if (-not $Token) {
  if (-not (Test-Path $tokenFile)) { Write-Host "Run magrgb-probe.ps1 first." -ForegroundColor Red; exit 1 }
  $Token = (Get-Content $tokenFile -Raw | ConvertFrom-Json).auth_token
}
$base = "http://$($Ip):$Port/api/v1/$Token"

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

$udp = New-Object System.Net.Sockets.UdpClient
function Send-Frame([byte[]]$pkt, [int]$times = 12) {
  for ($k = 0; $k -lt $times; $k++) { [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort); Start-Sleep -Milliseconds 25 }
}
function Arm() {
  $body = @{ write = @{ command = "display"; animType = "extControl"; extControlVersion = "v2" } } | ConvertTo-Json -Depth 5
  try { Invoke-WebRequest -Uri "$base/effects" -Method Put -Body $body -ContentType "application/json" -TimeoutSec 8 -UseBasicParsing | Out-Null }
  catch { Write-Host "  (re-arm failed: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}

# IMPORTANT: extControl only updates the panels present in the frame - every other
# zone keeps its previous colour. So always blank the full ceiling before painting,
# otherwise a smaller N looks identical to a larger one.
function Clear-All() {
  $ids = 0..($Ceiling - 1); $c = @()
  for ($i = 0; $i -lt $Ceiling; $i++) { $c += ,([byte[]]@(0,0,0)) }
  Send-Frame (New-Frame $ids $c) 6
  Start-Sleep -Milliseconds 120
}

# paint zones 0..n-1; optional distinct colour on the last one
function Show-Fill([int]$n, [switch]$MarkLast) {
  Clear-All
  $ids = 0..($n - 1); $c = @()
  for ($i = 0; $i -lt $n; $i++) { $c += ,([byte[]]@(255,0,0)) }
  if ($MarkLast) { $c[$n - 1] = [byte[]]@(0,0,255) }
  Send-Frame (New-Frame $ids $c)
}
function Show-Only([int]$n, [int]$idx, [byte[]]$col) {
  Clear-All
  $ids = 0..($n - 1); $c = @()
  for ($i = 0; $i -lt $n; $i++) { $c += ,([byte[]]@(0,0,0)) }
  $c[$idx] = $col
  Send-Frame (New-Frame $ids $c)
}

Arm
$N = $Start
$mark = $false

Write-Host ""
Write-Host "  Secretlab MAGRGB - manual zone finder" -ForegroundColor Cyan
Write-Host "  ------------------------------------" -ForegroundColor Cyan
Write-Host "  All zones 0..N-1 are lit RED. Adjust N until the WHOLE strip is lit"
Write-Host "  with nothing left over and nothing broken."
Write-Host ""
Write-Host "   n / Enter  N + 1          N - 1        p"
Write-Host "   N / PageUp N + 5          N - 5        P"
Write-Host "   m          toggle BLUE marker on the last zone"
Write-Host "   0          light ONLY zone 0    (red)   -> which end is this?"
Write-Host "   l          light ONLY zone N-1  (blue)  -> which end is this?"
Write-Host "   a          re-arm extControl (if the strip stops responding)"
Write-Host "   r          repaint current N"
Write-Host "   f          FINISH - accept current N"
Write-Host "   q          quit"
Write-Host ""

Show-Fill $N -MarkLast:$mark

while ($true) {
  Write-Host ("  N = {0,3}   packet {1,4} bytes   marker {2}" -f $N, (2 + $N * 8), $(if ($mark) { "ON" } else { "off" })) -ForegroundColor Green
  $k = Read-Host "  >"

  switch -CaseSensitive ($k) {
    ""   { $N += 1;  Show-Fill $N -MarkLast:$mark }
    "n"  { $N += 1;  Show-Fill $N -MarkLast:$mark }
    "p"  { $N = [Math]::Max(1, $N - 1); Show-Fill $N -MarkLast:$mark }
    "N"  { $N += 5;  Show-Fill $N -MarkLast:$mark }
    "P"  { $N = [Math]::Max(1, $N - 5); Show-Fill $N -MarkLast:$mark }
    "m"  { $mark = -not $mark; Show-Fill $N -MarkLast:$mark }
    "r"  { Show-Fill $N -MarkLast:$mark }
    "a"  { Arm; Show-Fill $N -MarkLast:$mark; Write-Host "  re-armed" -ForegroundColor DarkGray }
    "0"  { Show-Only $N 0 ([byte[]]@(255,0,0));       Write-Host "  zone 0 only (RED) - which end of the strip?" -ForegroundColor Yellow }
    "l"  { Show-Only $N ($N-1) ([byte[]]@(0,0,255));  Write-Host ("  zone {0} only (BLUE) - which end?" -f ($N-1)) -ForegroundColor Yellow }
    "f"  {
      Write-Host ""
      Write-Host ("  ZONE COUNT = {0}" -f $N) -ForegroundColor Cyan
      Write-Host "  Send me this number, plus which end zone 0 is on (keys 0 and l)." -ForegroundColor Cyan
      Send-Frame (New-Frame (0..($N-1)) (@(,[byte[]]@(0,40,120)) * $N)) 6
      $udp.Close(); exit 0
    }
    "q"  { $udp.Close(); exit 0 }
    default { Write-Host "  ?" -ForegroundColor DarkGray }
  }
}
