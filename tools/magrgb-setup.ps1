<#
  Secretlab MAGRGB (Nanoleaf) - one-stop setup.

    1. finds the strip on your LAN over mDNS
    2. obtains an OpenAPI auth token (needs the pairing window open, see below)
    3. verifies control by streaming a few test colours

  The token is what the SignalRGB plugin needs. It is written to
  magrgb-token.json next to this script, and that file is gitignored.

  Opening the pairing window (once, ever):
    Nanoleaf Desktop -> select the strip -> Enable API ON -> Connect to API
  You then have 30 seconds. Start this script FIRST, it polls for the whole window.

  Usage:
    powershell -ExecutionPolicy Bypass -File magrgb-setup.ps1
    powershell -ExecutionPolicy Bypass -File magrgb-setup.ps1 -Ip 192.168.1.50
    powershell -ExecutionPolicy Bypass -File magrgb-setup.ps1 -AuthToken <token>
#>
param(
  [string]$Ip         = "",     # skip discovery if you already know it
  [string]$LocalIp    = "",     # force a specific network interface
  [int]   $Port       = 16021,
  [int]   $StreamPort = 60222,
  [int]   $Zones      = 41,     # NL72S2 (2 m MAGRGB). Use magrgb-zones.ps1 for other sizes.
  [int]   $Seconds    = 45,     # how long to poll for the pairing window
  [string]$AuthToken  = ""      # inject a token you already hold; skips pairing
)

$ErrorActionPreference = 'Continue'
$tokenFile = Join-Path $PSScriptRoot "magrgb-token.json"
function Head($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

# ==================================================================== 1. discovery
function Find-Strips([string]$forceIface) {
  function New-Query([string]$qname) {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([byte[]]@(0,0, 0,0, 0,1, 0,0, 0,0, 0,0))
    foreach ($l in $qname.Split('.')) {
      if ($l.Length -eq 0) { continue }
      $b = [System.Text.Encoding]::ASCII.GetBytes($l)
      $bw.Write([byte]$b.Length); $bw.Write($b)
    }
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]12)
    $bw.Write([byte]0x80); $bw.Write([byte]1)      # class IN + unicast-response bit
    $bw.Flush(); return $ms.ToArray()
  }

  # A VPN adapter is often "first", so query from every usable interface.
  if ($forceIface) { $ifaces = @($forceIface) }
  else {
    $ifaces = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
                Select-Object -ExpandProperty IPAddress -Unique)
  }
  Write-Host ("Searching from: {0}" -f ($ifaces -join ", ")) -ForegroundColor DarkGray

  $mc = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('224.0.0.251'), 5353)
  $found = @{}

  foreach ($iface in $ifaces) {
    $udp = $null
    try {
      $udp = New-Object System.Net.Sockets.UdpClient
      $udp.Client.SetSocketOption('Socket','ReuseAddress',$true)
      $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($iface), 0)))
      $udp.Client.ReceiveTimeout = 700
    } catch { if ($udp) { $udp.Close() }; continue }

    foreach ($svc in @('_nanoleafapi._tcp.local', '_ltpdu._tcp.local')) {
      $q = New-Query $svc
      try { [void]$udp.Send($q, $q.Length, $mc) } catch { }
    }

    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
      # NOTE: empty catch on purpose. 'continue' inside a catch block breaks the
      # enclosing loop in PowerShell instead of continuing it.
      $d = $null
      $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
      try { $d = $udp.Receive([ref]$ep) } catch { }

      if ($d) {
        $sip = $ep.Address.ToString()
        if (-not $found.ContainsKey($sip)) {
          $found[$sip] = [ordered]@{ IP = $sip; Name = ""; Model = ""; Firmware = "" }
        }
        $txt = -join ($d | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { "`n" } })
        if ($txt -match 'md=([A-Za-z0-9_-]+)')  { $found[$sip].Model    = $Matches[1] }
        if ($txt -match 'srcvers=([0-9.]+)')    { $found[$sip].Firmware = $Matches[1] }
        if ($txt -match '([A-Za-z0-9 ]*MAGRGB[A-Za-z0-9 ]*)') { $found[$sip].Name = $Matches[1].Trim() }
      }
    }
    $udp.Close()
  }
  return $found
}

if (-not $Ip) {
  Head "1/3  Finding your strip"
  $devices = Find-Strips $LocalIp

  if ($devices.Count -eq 0) {
    Write-Host ""
    Write-Host "No Nanoleaf / MAGRGB device answered." -ForegroundColor Red
    Write-Host "  - is the strip powered and already set up in the Nanoleaf mobile app?"
    Write-Host "  - same subnet as this PC? (guest VLAN / AP isolation will block it)"
    Write-Host "  - Windows Firewall blocking inbound UDP 5353?"
    Write-Host "  - several adapters? try:  -LocalIp <your LAN IP>"
    Write-Host "  - or skip discovery entirely:  -Ip <strip IP from your router>"
    exit 1
  }

  foreach ($k in ($devices.Keys | Sort-Object)) {
    $d = $devices[$k]
    $isMag = $d.Model -like "NL72*" -or $d.Name -like "*MAGRGB*"
    Write-Host ("  {0,-15}  {1,-10} fw {2,-8} {3}" -f $d.IP, $d.Model, $d.Firmware, $d.Name) `
               -ForegroundColor $(if ($isMag) { "Cyan" } else { "DarkGray" })
    if ($isMag -and -not $Ip) { $Ip = $d.IP }
  }

  if (-not $Ip) { $Ip = ($devices.Keys | Sort-Object)[0] }
  Write-Host ""
  Write-Host "Using $Ip" -ForegroundColor Green
}

$base = "http://$($Ip):$Port/api/v1"

# ==================================================================== 2. token
Head "2/3  Auth token"
# NOTE: PowerShell variable names are case-INSENSITIVE, so $token and the $AuthToken
# parameter must not differ only by case, or one silently clobbers the other.
$token = $AuthToken
if ($token) {
  Write-Host "Using the token passed on the command line" -ForegroundColor DarkGray
} elseif (Test-Path $tokenFile) {
  try { $token = (Get-Content $tokenFile -Raw | ConvertFrom-Json).auth_token } catch { }
  if ($token) { Write-Host "Reusing saved token from magrgb-token.json" -ForegroundColor DarkGray }
}

if (-not $token) {
  Write-Host "In Nanoleaf Desktop: select the strip -> Enable API ON -> Connect to API" -ForegroundColor Yellow
  Write-Host "Polling for $Seconds seconds..." -ForegroundColor Yellow
  $deadline = (Get-Date).AddSeconds($Seconds)
  $lastCode = ""
  while ((Get-Date) -lt $deadline -and -not $token) {
    $resp = $null
    try { $resp = Invoke-WebRequest -Uri "$base/new" -Method Post -TimeoutSec 5 -UseBasicParsing } catch {
      $c = ""; if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode }
      if ("$c" -ne $lastCode) { Write-Host "  ... HTTP $c" -ForegroundColor DarkGray; $lastCode = "$c" }
    }
    if ($resp) {
      try { $token = ($resp.Content | ConvertFrom-Json).auth_token } catch { }
    }
    if (-not $token) { Start-Sleep -Milliseconds 900 }
  }
}

if (-not $token) {
  Write-Host ""
  Write-Host "No token obtained - the pairing window never opened." -ForegroundColor Red
  Write-Host "HTTP 403 means the API is not enabled. Turn ON 'Enable API' BEFORE pressing 'Connect to API'." -ForegroundColor Red
  exit 1
}

@{ ip = $Ip; auth_token = $token } | ConvertTo-Json | Set-Content -Path $tokenFile -Encoding utf8
Write-Host "Token: $token" -ForegroundColor Green
Write-Host "Saved to $tokenFile"

$info = $null
try { $info = Invoke-RestMethod -Uri "$base/$token/" -Method Get -TimeoutSec 8 } catch { }
if ($info) {
  Write-Host ("Device: {0}  model {1}  firmware {2}" -f $info.name, $info.model, $info.firmwareVersion)
}

# ==================================================================== 3. verify
Head "3/3  Streaming test  ($Zones zones)"

$body = @{ write = @{ command = "display"; animType = "extControl"; extControlVersion = "v2" } } | ConvertTo-Json -Depth 5
try {
  $r = Invoke-WebRequest -Uri "$base/$token/effects" -Method Put -Body $body -ContentType "application/json" -TimeoutSec 8 -UseBasicParsing
  Write-Host ("extControl armed (HTTP {0})" -f $r.StatusCode) -ForegroundColor Green
} catch { Write-Host "Could not arm extControl: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

function New-Frame([byte[][]]$cols, [int]$tt = 0) {
  $n = $cols.Count
  $b = New-Object 'System.Collections.Generic.List[byte]'
  $b.Add([byte](($n -shr 8) -band 0xFF)); $b.Add([byte]($n -band 0xFF))
  for ($i = 0; $i -lt $n; $i++) {
    $b.Add([byte](($i -shr 8) -band 0xFF)); $b.Add([byte]($i -band 0xFF))
    $b.Add($cols[$i][0]); $b.Add($cols[$i][1]); $b.Add($cols[$i][2]); $b.Add([byte]0)
    $b.Add([byte](($tt -shr 8) -band 0xFF)); $b.Add([byte]($tt -band 0xFF))
  }
  return $b.ToArray()
}
function Solid([byte[]]$c) { $a = @(); for ($i = 0; $i -lt $Zones; $i++) { $a += ,$c }; return (New-Frame $a) }

$udp = New-Object System.Net.Sockets.UdpClient
function Blast([byte[]]$pkt, [int]$times = 8) {
  for ($k = 0; $k -lt $times; $k++) { [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort); Start-Sleep -Milliseconds 30 }
}

Write-Host "Watch the strip: red, green, blue, then a moving gradient." -ForegroundColor Yellow
foreach ($c in @(@(255,0,0), @(0,255,0), @(0,0,255))) {
  Blast (Solid ([byte[]]$c)); Start-Sleep -Milliseconds 500
}
for ($f = 0; $f -lt 90; $f++) {
  $a = @()
  for ($i = 0; $i -lt $Zones; $i++) {
    $v = [Math]::Sin(($f * 0.15) + ($i * 0.35)) * 0.5 + 0.5
    $a += ,([byte[]]@([byte](255 * $v), 0, [byte](255 * (1 - $v))))
  }
  $pkt = New-Frame $a
  [void]$udp.Send($pkt, $pkt.Length, $Ip, $StreamPort)
  Start-Sleep -Milliseconds 33
}
Blast (Solid ([byte[]]@(0,40,120))) 4
$udp.Close()

Head "Done"
Write-Host "IP    : $Ip"
Write-Host "Token : $token"
Write-Host ""
Write-Host "Put both into the SignalRGB plugin panel:" -ForegroundColor Yellow
Write-Host "  Devices -> Secretlab MAGRGB (Nanoleaf) -> enter IP -> Add" -ForegroundColor Yellow
Write-Host "  then paste the token -> Save token" -ForegroundColor Yellow
Write-Host ""
Write-Host "If the strip did not light up, your zone count may differ." -ForegroundColor DarkGray
Write-Host "Run magrgb-zones.ps1 to find it, then tell the plugin author." -ForegroundColor DarkGray
