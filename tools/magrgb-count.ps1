<#
  Secretlab MAGRGB (NL72S2) - find the real zone count, the strip orientation,
  and whether white is broken. Reuses the saved token.

  powershell -ExecutionPolicy Bypass -File magrgb-count.ps1
#>
param(
  [string]         = "192.168.1.50",
  [int]   $Port       = 16021,
  [int]   $StreamPort = 60222,
  [string]$Token
)

$ErrorActionPreference = 'Stop'
$tokenFile = Join-Path $PSScriptRoot "magrgb-token.json"
if (-not $Token) {
  if (-not (Test-Path $tokenFile)) { Write-Host "Run magrgb-probe.ps1 first." -ForegroundColor Red; exit 1 }
  $Token = (Get-Content $tokenFile -Raw | ConvertFrom-Json).auth_token
}
$base = "http://$($Ip):$Port/api/v1/$Token"
function Head($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

function New-Frame([int[]]$ids, [byte[][]]$cols, [int]$tt = 0) {
  $n = $ids.Count
  $b = New-Object 'System.Collections.Generic.List[byte]'
  $b.Add([byte](($n -shr 8) -band 0xFF)); $b.Add([byte]($n -band 0xFF))
  for ($i = 0; $i -lt $n; $i++) {
    $id = $ids[$i]; $c = $cols[$i]
    $b.Add([byte](($id -shr 8) -band 0xFF)); $b.Add([byte]($id -band 0xFF))
    $b.Add($c[0]); $b.Add($c[1]); $b.Add($c[2])
    if ($c.Count -ge 4) { $b.Add($c[3]) } else { $b.Add([byte]0) }
    $b.Add([byte](($tt -shr 8) -band 0xFF)); $b.Add([byte]($tt -band 0xFF))
  }
  return $b.ToArray()
}

$udp = New-Object System.Net.Sockets.UdpClient
function Blast([byte[]]$pkt, [int]$times = 10, [int]$gap = 30) {
  for ($k = 0; $k -lt $times; $k++) { [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort); Start-Sleep -Milliseconds $gap }
}
function Fill([int]$n, [byte[]]$col) {
  $ids = 0..($n - 1); $c = @()
  for ($i = 0; $i -lt $n; $i++) { $c += ,$col }
  return (New-Frame $ids $c)
}
function Arm() {
  $body = @{ write = @{ command = "display"; animType = "extControl"; extControlVersion = "v2" } } | ConvertTo-Json -Depth 5
  try { $r = Invoke-WebRequest -Uri "$base/effects" -Method Put -Body $body -ContentType "application/json" -TimeoutSec 8 -UseBasicParsing
        Write-Host ("armed (HTTP {0})" -f $r.StatusCode) -ForegroundColor Green }
  catch { Write-Host "arm failed: $($_.Exception.Message)" -ForegroundColor Red }
}

Arm
Blast (Fill 32 ([byte[]]@(0,0,0))) 5   # clear

# ---------------------------------------------------------------- A. coverage sweep
Head "A - COVERAGE SWEEP (all declared zones RED)"
Write-Host "The lit section should grow. Tell me the number where it STOPS growing." -ForegroundColor Yellow
Write-Host "That number is the strip's real zone count.`n" -ForegroundColor Yellow
foreach ($n in @(1,2,4,6,8,10,12,16,20,24,28,32,40,48,64,96,128)) {
  Blast (Fill 32 ([byte[]]@(0,0,0))) 3 15
  Blast (Fill $n ([byte[]]@(255,0,0))) 8 30
  Write-Host ("  N = {0,3}   (packet {1} bytes)" -f $n, (Fill $n ([byte[]]@(255,0,0))).Length)
  Start-Sleep -Milliseconds 1200
}
$realN = Read-Host "`nAt what N did coverage stop growing? (just the number)"
if (-not ($realN -as [int])) { $realN = 32 }
$realN = [int]$realN
Write-Host "Using N = $realN" -ForegroundColor Green

# ---------------------------------------------------------------- B. orientation
Head "B - ORIENTATION (which end is zone 0?)"
Write-Host "Zone 0 = RED, last zone = BLUE, everything between = off." -ForegroundColor Yellow
$ids = 0..($realN - 1); $c = @()
for ($i = 0; $i -lt $realN; $i++) { $c += ,([byte[]]@(0,0,0)) }
$c[0] = [byte[]]@(255,0,0); $c[$realN - 1] = [byte[]]@(0,0,255)
Blast (New-Frame $ids $c) 25 40
Read-Host "`nIs RED on the LEFT or the RIGHT? (type left/right)" | Out-Null

# ---------------------------------------------------------------- C. white
Head "C - IS WHITE BROKEN?"
$tests = @(
  @{ n = "full white  RGB(255,255,255) W=0";   col = [byte[]]@(255,255,255,0) },
  @{ n = "full white  RGB(255,255,255) W=255"; col = [byte[]]@(255,255,255,255) },
  @{ n = "dim  white  RGB(180,180,180) W=0";   col = [byte[]]@(180,180,180,0) },
  @{ n = "near white  RGB(255,250,240) W=0";   col = [byte[]]@(255,250,240,0) },
  @{ n = "pure  red   RGB(255,0,0)     W=0";   col = [byte[]]@(255,0,0,0) },
  @{ n = "pure green  RGB(0,255,0)     W=0";   col = [byte[]]@(0,255,0,0) },
  @{ n = "pure  blue  RGB(0,0,255)     W=0";   col = [byte[]]@(0,0,255,0) }
)
foreach ($t in $tests) {
  Blast (Fill $realN $t.col) 10 30
  Write-Host ("  {0}" -f $t.n)
  Start-Sleep -Milliseconds 1400
}
Read-Host "`nWhich of those did NOT light up? (list them)" | Out-Null

# ---------------------------------------------------------------- D. dead-end check
Head "D - IS THE 'DEAD' END REALLY DEAD?"
Write-Host "Lighting ONLY the first quarter, then ONLY the last quarter, in GREEN." -ForegroundColor Yellow
$q = [Math]::Max(1, [Math]::Floor($realN / 4))
foreach ($seg in @(@{lbl="first quarter (zones 0..$($q-1))"; from=0; to=$q-1},
                   @{lbl="last quarter (zones $($realN-$q)..$($realN-1))"; from=$realN-$q; to=$realN-1})) {
  $c = @()
  for ($i = 0; $i -lt $realN; $i++) {
    if ($i -ge $seg.from -and $i -le $seg.to) { $c += ,([byte[]]@(0,255,0)) } else { $c += ,([byte[]]@(0,0,0)) }
  }
  Blast (New-Frame $ids $c) 20 40
  Write-Host ("  {0}" -f $seg.lbl)
  Start-Sleep -Milliseconds 1600
}
Read-Host "`nDid BOTH quarters light? (yes/no - which one failed)" | Out-Null

Blast (Fill $realN ([byte[]]@(0,40,120))) 6
$udp.Close()

Head "Summary to send back"
Write-Host "A) zone count where coverage stopped growing"
Write-Host "B) is zone 0 on the left or the right"
Write-Host "C) which colours failed to light"
Write-Host "D) did both quarters light, or is one end genuinely dead"
