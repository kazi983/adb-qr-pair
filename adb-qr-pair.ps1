<#
.SYNOPSIS
  adb-qr-pair for Windows: pair an Android 11+ phone for wireless debugging
  by QR code, then connect to it. One-shot.

.DESCRIPTION
  Shows a QR code in the terminal, waits for the phone to scan it, runs
  "adb pair", then finds the phone's debug port and runs "adb connect".
  Discovery uses adb's built-in mDNS (platform-tools 35.0.2 or newer),
  so no Bonjour install is needed. Works on Windows PowerShell 5.1 and
  PowerShell 7.x.

  Install adb:   winget install Google.PlatformTools
  Run:           adb-qr-pair            (via adb-qr-pair.cmd)
                 adb-qr-pair -Timeout 60
  Phone:         Settings > Developer options > Wireless debugging >
                 Pair device with QR code  (same Wi-Fi as this PC)

.PARAMETER Timeout
  Seconds to wait for each step (scan, then connect). Default 30, or the
  ADB_QR_TIMEOUT environment variable if set.
#>
[CmdletBinding()]
param(
  [int]$Timeout = 0
)

# Note: this file is kept pure ASCII so Windows PowerShell 5.1 reads it
# correctly regardless of the system code page.

if ($Timeout -le 0) {
  if ($env:ADB_QR_TIMEOUT -match '^\d+$') { $Timeout = [int]$env:ADB_QR_TIMEOUT } else { $Timeout = 30 }
}

# =====================================================================
# QR code encoder: byte mode, error correction level M, versions 1-10
# (up to 213 bytes, far more than the ~42 bytes a pairing code needs).
# =====================================================================

# version = @(ecCodewordsPerBlock, group1Blocks, group1DataCw, group2Blocks, group2DataCw)
$script:QrSpecM = @{
  1 = @(10, 1, 16, 0, 0);  2 = @(16, 1, 28, 0, 0);  3 = @(26, 1, 44, 0, 0)
  4 = @(18, 2, 32, 0, 0);  5 = @(24, 2, 43, 0, 0);  6 = @(16, 4, 27, 0, 0)
  7 = @(18, 4, 31, 0, 0);  8 = @(22, 2, 38, 2, 39); 9 = @(22, 3, 36, 2, 37)
  10 = @(26, 4, 43, 1, 44)
}
$script:QrAlign = @{
  1 = @(); 2 = @(6, 18); 3 = @(6, 22); 4 = @(6, 26); 5 = @(6, 30); 6 = @(6, 34)
  7 = @(6, 22, 38); 8 = @(6, 24, 42); 9 = @(6, 26, 46); 10 = @(6, 28, 50)
}

# GF(256) tables for Reed-Solomon, primitive polynomial 0x11D
$script:GfExp = New-Object 'int[]' 512
$script:GfLog = New-Object 'int[]' 256
$x = 1
for ($i = 0; $i -lt 255; $i++) {
  $script:GfExp[$i] = $x; $script:GfLog[$x] = $i
  $x = $x -shl 1
  if ($x -band 0x100) { $x = $x -bxor 0x11D }
}
for ($i = 255; $i -lt 512; $i++) { $script:GfExp[$i] = $script:GfExp[$i - 255] }

function Get-GfMul([int]$a, [int]$b) {
  if ($a -eq 0 -or $b -eq 0) { return 0 }
  return $script:GfExp[$script:GfLog[$a] + $script:GfLog[$b]]
}

function Get-RsRemainder([int[]]$Data, [int]$EcLen) {
  # Generator polynomial (x - a^0)(x - a^1)...(x - a^(EcLen-1)), highest degree first
  $gen = [int[]]@(1)
  for ($i = 0; $i -lt $EcLen; $i++) {
    $next = New-Object 'int[]' ($gen.Length + 1)
    for ($j = 0; $j -lt $gen.Length; $j++) {
      $next[$j] = $next[$j] -bxor $gen[$j]
      $next[$j + 1] = $next[$j + 1] -bxor (Get-GfMul $gen[$j] $script:GfExp[$i])
    }
    $gen = $next
  }
  $rem = New-Object 'int[]' $EcLen
  foreach ($d in $Data) {
    $factor = $d -bxor $rem[0]
    for ($k = 0; $k -lt $EcLen - 1; $k++) { $rem[$k] = $rem[$k + 1] }
    $rem[$EcLen - 1] = 0
    for ($k = 0; $k -lt $EcLen; $k++) {
      $rem[$k] = $rem[$k] -bxor (Get-GfMul $gen[$k + 1] $factor)
    }
  }
  return , $rem
}

function Get-QrPenalty($M, [int]$N) {
  $rows = New-Object 'string[]' $N
  $cols = New-Object 'string[]' $N
  for ($i = 0; $i -lt $N; $i++) {
    $r = New-Object System.Text.StringBuilder $N
    $c = New-Object System.Text.StringBuilder $N
    for ($j = 0; $j -lt $N; $j++) {
      [void]$r.Append($M[$i, $j]); [void]$c.Append($M[$j, $i])
    }
    $rows[$i] = $r.ToString(); $cols[$i] = $c.ToString()
  }
  $score = 0
  foreach ($line in ($rows + $cols)) {
    # Rule 1: runs of 5+ same-colour modules
    foreach ($run in [regex]::Matches($line, '0{5,}|1{5,}')) { $score += 3 + $run.Length - 5 }
    # Rule 3: finder-like patterns
    $score += 40 * [regex]::Matches($line, '(?=10111010000|00001011101)').Count
  }
  # Rule 2: 2x2 blocks of one colour
  for ($y = 0; $y -lt $N - 1; $y++) {
    for ($x = 0; $x -lt $N - 1; $x++) {
      $v = $M[$y, $x]
      if ($v -eq $M[$y, ($x + 1)] -and $v -eq $M[($y + 1), $x] -and $v -eq $M[($y + 1), ($x + 1)]) { $score += 3 }
    }
  }
  # Rule 4: dark/light balance
  $all = -join $rows
  $dark = $all.Length - $all.Replace('1', '').Length
  $score += 10 * [Math]::Floor([Math]::Abs($dark * 100.0 / $all.Length - 50) / 5)
  return $score
}

function New-QrMatrix([string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)

  # Pick the smallest version that fits
  $ver = 0
  for ($v = 1; $v -le 10; $v++) {
    $s = $script:QrSpecM[$v]
    $cap = 8 * ($s[1] * $s[2] + $s[3] * $s[4])
    $countBits = 8; if ($v -ge 10) { $countBits = 16 }
    if (4 + $countBits + 8 * $bytes.Length -le $cap) { $ver = $v; break }
  }
  if ($ver -eq 0) { throw "Text is too long for this QR encoder (max 213 bytes)." }
  $spec = $script:QrSpecM[$ver]
  $dataCw = $spec[1] * $spec[2] + $spec[3] * $spec[4]
  $countBits = 8; if ($ver -ge 10) { $countBits = 16 }

  # Bit stream: mode 0100 (byte), length, data, terminator, padding
  $bits = New-Object 'System.Collections.Generic.List[int]'
  $addBits = { param([int]$val, [int]$len) for ($b = $len - 1; $b -ge 0; $b--) { $bits.Add(($val -shr $b) -band 1) } }
  & $addBits 4 4
  & $addBits $bytes.Length $countBits
  foreach ($byte in $bytes) { & $addBits $byte 8 }
  $capBits = 8 * $dataCw
  & $addBits 0 ([Math]::Min(4, $capBits - $bits.Count))
  while ($bits.Count % 8) { $bits.Add(0) }
  $data = New-Object 'System.Collections.Generic.List[int]'
  for ($i = 0; $i -lt $bits.Count; $i += 8) {
    $cw = 0; for ($b = 0; $b -lt 8; $b++) { $cw = ($cw -shl 1) -bor $bits[$i + $b] }
    $data.Add($cw)
  }
  $pad = 0xEC
  while ($data.Count -lt $dataCw) { $data.Add($pad); if ($pad -eq 0xEC) { $pad = 0x11 } else { $pad = 0xEC } }

  # Split into blocks, add error correction, interleave
  $blocks = @(); $ecBlocks = @(); $pos = 0
  foreach ($g in @(@($spec[1], $spec[2]), @($spec[3], $spec[4]))) {
    for ($k = 0; $k -lt $g[0]; $k++) {
      $blk = [int[]]$data.GetRange($pos, $g[1]).ToArray(); $pos += $g[1]
      $blocks += , $blk
      $ecBlocks += , (Get-RsRemainder $blk $spec[0])
    }
  }
  $final = New-Object 'System.Collections.Generic.List[int]'
  $maxLen = ($blocks | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
  for ($i = 0; $i -lt $maxLen; $i++) { foreach ($blk in $blocks) { if ($i -lt $blk.Length) { $final.Add($blk[$i]) } } }
  for ($i = 0; $i -lt $spec[0]; $i++) { foreach ($blk in $ecBlocks) { $final.Add($blk[$i]) } }

  # Matrix and function-pattern map
  $n = 17 + 4 * $ver
  $m = New-Object 'int[,]' $n, $n
  $fn = New-Object 'bool[,]' $n, $n
  $setFn = { param([int]$x, [int]$y, [bool]$dark) $m[$y, $x] = [int]$dark; $fn[$y, $x] = $true }

  for ($i = 0; $i -lt $n; $i++) { & $setFn 6 $i ($i % 2 -eq 0); & $setFn $i 6 ($i % 2 -eq 0) }   # timing
  foreach ($c in @(@(3, 3), @(($n - 4), 3), @(3, ($n - 4)))) {                                 # finders + separators
    for ($dy = -4; $dy -le 4; $dy++) {
      for ($dx = -4; $dx -le 4; $dx++) {
        $xx = $c[0] + $dx; $yy = $c[1] + $dy
        if ($xx -ge 0 -and $xx -lt $n -and $yy -ge 0 -and $yy -lt $n) {
          $dist = [Math]::Max([Math]::Abs($dx), [Math]::Abs($dy))
          & $setFn $xx $yy ($dist -ne 2 -and $dist -ne 4)
        }
      }
    }
  }
  $al = $script:QrAlign[$ver]; $na = $al.Count                                                   # alignment
  for ($i = 0; $i -lt $na; $i++) {
    for ($j = 0; $j -lt $na; $j++) {
      if (($i -eq 0 -and $j -eq 0) -or ($i -eq 0 -and $j -eq $na - 1) -or ($i -eq $na - 1 -and $j -eq 0)) { continue }
      for ($dy = -2; $dy -le 2; $dy++) {
        for ($dx = -2; $dx -le 2; $dx++) {
          & $setFn ($al[$i] + $dx) ($al[$j] + $dy) ([Math]::Max([Math]::Abs($dx), [Math]::Abs($dy)) -ne 1)
        }
      }
    }
  }
  $drawFormat = {
    param([int]$mask)
    $d = $mask                                   # EC level M = 00
    $rem = $d
    for ($i = 0; $i -lt 10; $i++) { $rem = ($rem -shl 1) -bxor (($rem -shr 9) * 0x537) }
    $fb = (($d -shl 10) -bor $rem) -bxor 0x5412
    for ($i = 0; $i -le 5; $i++) { & $setFn 8 $i ((($fb -shr $i) -band 1) -eq 1) }
    & $setFn 8 7 ((($fb -shr 6) -band 1) -eq 1)
    & $setFn 8 8 ((($fb -shr 7) -band 1) -eq 1)
    & $setFn 7 8 ((($fb -shr 8) -band 1) -eq 1)
    for ($i = 9; $i -lt 15; $i++) { & $setFn (14 - $i) 8 ((($fb -shr $i) -band 1) -eq 1) }
    for ($i = 0; $i -lt 8; $i++) { & $setFn ($n - 1 - $i) 8 ((($fb -shr $i) -band 1) -eq 1) }
    for ($i = 8; $i -lt 15; $i++) { & $setFn 8 ($n - 15 + $i) ((($fb -shr $i) -band 1) -eq 1) }
    & $setFn 8 ($n - 8) $true                    # dark module
  }
  & $drawFormat 0                                # reserve format areas
  if ($ver -ge 7) {                              # version information
    $rem = $ver
    for ($i = 0; $i -lt 12; $i++) { $rem = ($rem -shl 1) -bxor (($rem -shr 11) * 0x1F25) }
    $vb = ($ver -shl 12) -bor $rem
    for ($i = 0; $i -lt 18; $i++) {
      $bit = (($vb -shr $i) -band 1) -eq 1
      $a = $n - 11 + ($i % 3); $b = [Math]::Floor($i / 3)
      & $setFn $a $b $bit; & $setFn $b $a $bit
    }
  }

  # Place data in the zigzag pattern
  $bitIdx = 0; $totalBits = $final.Count * 8
  for ($right = $n - 1; $right -ge 1; $right -= 2) {
    if ($right -eq 6) { $right = 5 }
    for ($vert = 0; $vert -lt $n; $vert++) {
      for ($j = 0; $j -lt 2; $j++) {
        $xx = $right - $j
        if ((($right + 1) -band 2) -eq 0) { $yy = $n - 1 - $vert } else { $yy = $vert }
        if (-not $fn[$yy, $xx] -and $bitIdx -lt $totalBits) {
          $m[$yy, $xx] = ($final[$bitIdx -shr 3] -shr (7 - ($bitIdx -band 7))) -band 1
          $bitIdx++
        }
      }
    }
  }

  # Try all 8 masks, keep the one with the lowest penalty
  $applyMask = {
    param([int]$mask)
    for ($y = 0; $y -lt $n; $y++) {
      for ($x = 0; $x -lt $n; $x++) {
        if ($fn[$y, $x]) { continue }
        switch ($mask) {
          0 { $inv = (($x + $y) % 2) -eq 0 }
          1 { $inv = ($y % 2) -eq 0 }
          2 { $inv = ($x % 3) -eq 0 }
          3 { $inv = (($x + $y) % 3) -eq 0 }
          4 { $inv = (([Math]::Floor($x / 3) + [Math]::Floor($y / 2)) % 2) -eq 0 }
          5 { $inv = ((($x * $y) % 2) + (($x * $y) % 3)) -eq 0 }
          6 { $inv = (((($x * $y) % 2) + (($x * $y) % 3)) % 2) -eq 0 }
          7 { $inv = (((($x + $y) % 2) + (($x * $y) % 3)) % 2) -eq 0 }
        }
        if ($inv) { $m[$y, $x] = 1 - $m[$y, $x] }
      }
    }
  }
  $best = 0; $bestScore = [int]::MaxValue
  for ($mask = 0; $mask -lt 8; $mask++) {
    & $applyMask $mask; & $drawFormat $mask
    $p = Get-QrPenalty $m $n
    if ($p -lt $bestScore) { $bestScore = $p; $best = $mask }
    & $applyMask $mask                           # undo (XOR)
  }
  & $applyMask $best; & $drawFormat $best
  return , $m
}

function Write-QrCode($M) {
  $n = $M.GetLength(0); $quiet = 2; $size = $n + 2 * $quiet
  $upper = [string][char]0x2580; $lower = [string][char]0x2584; $full = [string][char]0x2588
  for ($y = 0; $y -lt $size; $y += 2) {
    $sb = New-Object System.Text.StringBuilder
    for ($x = 0; $x -lt $size; $x++) {
      $mx = $x - $quiet; $t = $y - $quiet; $bt = $y + 1 - $quiet
      $top = ($mx -ge 0 -and $mx -lt $n -and $t -ge 0 -and $t -lt $n -and $M[$t, $mx] -eq 1)
      $bot = ($mx -ge 0 -and $mx -lt $n -and $bt -ge 0 -and $bt -lt $n -and $M[$bt, $mx] -eq 1)
      if ($top -and $bot) { [void]$sb.Append($full) }
      elseif ($top) { [void]$sb.Append($upper) }
      elseif ($bot) { [void]$sb.Append($lower) }
      else { [void]$sb.Append(' ') }
    }
    # Fixed colours so the code scans on both dark and light terminal themes
    Write-Host $sb.ToString() -ForegroundColor Black -BackgroundColor White
  }
}

# =====================================================================
# adb helpers
# =====================================================================

function Find-Adb {
  $cmd = Get-Command adb -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Definition }
  foreach ($p in @("$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
                   "$env:ANDROID_HOME\platform-tools\adb.exe",
                   "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe")) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  return $null
}

# Runs adb and returns its output lines (stdout + stderr) as strings.
# Exit code is left in $script:AdbExit.
function Invoke-Adb {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = @(& $script:Adb @args 2>&1 | ForEach-Object { "$_" }) }
  finally { $ErrorActionPreference = $prev }
  $script:AdbExit = $LASTEXITCODE
  return $out
}

# Returns objects { Name, Type, Ip, Port } from "adb mdns services" (IPv4 only).
function Get-MdnsServices {
  foreach ($line in (Invoke-Adb mdns services)) {
    $tokens = @($line -split '\s+' | Where-Object { $_ })
    if ($tokens.Count -lt 3) { continue }
    $type = $tokens | Where-Object { $_ -match '^_adb-tls-(pairing|connect)\._tcp\.?$' } | Select-Object -First 1
    $addr = $tokens | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}:\d+$' } | Select-Object -First 1
    if (-not $type -or -not $addr) { continue }
    $ip, $port = $addr -split ':'
    New-Object PSObject -Property @{ Name = $tokens[0]; Type = $type.TrimEnd('.'); Ip = $ip; Port = $port }
  }
}

# Polls mDNS with a countdown until services of $Type pass $Filter.
# Returns the matching services, or nothing on timeout.
function Wait-AdbService([string]$Type, [scriptblock]$Filter, [int]$Seconds, [string]$Label) {
  $end = (Get-Date).AddSeconds($Seconds)
  $interactive = -not [Console]::IsOutputRedirected
  if (-not $interactive) { Write-Host "$Label (up to ${Seconds}s)" }
  while ($true) {
    $hits = @(Get-MdnsServices | Where-Object { $_.Type -eq $Type } | Where-Object $Filter)
    if ($hits.Count -gt 0) {
      if ($interactive) { Write-Host -NoNewline ("`r" + (' ' * 60) + "`r") }
      return $hits
    }
    $left = [int][Math]::Ceiling(($end - (Get-Date)).TotalSeconds)
    if ($left -le 0) { break }
    if ($interactive) {
      Write-Host -NoNewline ("`r{0} {1,2}s  (Ctrl-C to cancel)  " -f $Label, $left) -ForegroundColor DarkGray
    }
    Start-Sleep -Milliseconds 500
  }
  if ($interactive) { Write-Host '' }
}

function Get-WifiSsid {
  if (-not (Get-Command netsh -ErrorAction SilentlyContinue)) { return '' }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = @(netsh wlan show interfaces 2>$null) } finally { $ErrorActionPreference = $prev }
  foreach ($line in $out) {
    if ("$line" -match '^\s*SSID\s*:\s*(.*\S)\s*$') { return $Matches[1] }
  }
  return ''
}

function New-RandomAlnum([int]$Length) {
  $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  $buf = New-Object 'byte[]' $Length
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($buf); $rng.Dispose()
  return -join ($buf | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Write-Red([string]$Msg) { Write-Host $Msg -ForegroundColor Red }

function Stop-WithHint([string]$Msg) {
  Write-Red $Msg
  Write-Host @'

Things to check:
  * PC and phone are on the same Wi-Fi / subnet (not a guest network)
  * The router doesn't use "AP / client isolation"
  * Windows Firewall allows adb on this network (if Windows asked, allow
    "Private networks"); make sure the Wi-Fi is set as a Private network

Manual fallback (no QR / no mDNS needed):
  1. On the phone: Wireless debugging > Pair device with pairing code
  2. On the PC:    adb pair <IP>:<PORT> <6-digit code>
  3. Then:         adb connect <IP>:<PORT shown on the main Wireless debugging screen>
'@
  exit 1
}

# =====================================================================
# main
# =====================================================================

function Invoke-AdbQrPair {
  # ---------- dependency checks ----------
  $script:Adb = Find-Adb
  if (-not $script:Adb) {
    Write-Red "adb was not found."
    Write-Host "Install it with:  winget install Google.PlatformTools   (then open a new terminal)"
    exit 1
  }
  $verText = (Invoke-Adb version) -join "`n"
  # Case-sensitive and line-anchored: the first line says "...Bridge version 1.0.41",
  # which is the protocol version, not the platform-tools release we need.
  if ($verText -cmatch '(?m)^Version (\d+)\.(\d+)\.(\d+)') {
    $v = [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
    if ($v -lt [version]'35.0.2') {
      Write-Red "Your adb ($v) is too old: built-in mDNS discovery needs platform-tools 35.0.2 or newer."
      Write-Host "Update with:  winget upgrade Google.PlatformTools"
      exit 1
    }
  }

  # ---------- 1. show QR ----------
  $name = 'adbqr-' + (New-RandomAlnum 8)
  $pass = New-RandomAlnum 10
  $ssid = Get-WifiSsid

  Write-Host ''
  Write-QrCode (New-QrMatrix "WIFI:T:ADB;S:$name;P:$pass;;")
  if ($ssid) {
    Write-Host "PC Wi-Fi: $ssid  (phone must be on the same network)"
  } else {
    Write-Host "PC Wi-Fi: not detected (wired, or Location access is off) - phone must be on the same network"
  }
  Write-Host "Scan with: Developer options > Wireless debugging > Pair device with QR code"

  # ---------- 2. wait for the phone's pairing service ----------
  $hits = @(Wait-AdbService '_adb-tls-pairing._tcp' { $_.Name -eq $name }.GetNewClosure() $Timeout 'Waiting for the phone...')
  if ($hits.Count -eq 0) { Stop-WithHint "Timed out: the phone's pairing service never appeared." }
  $pairIp = $hits[0].Ip; $pairPort = $hits[0].Port
  Write-Host "Found phone at ${pairIp}:${pairPort}, pairing..."

  # ---------- 3. pair ----------
  $out = (Invoke-Adb pair "${pairIp}:${pairPort}" $pass) -join "`n"
  if ($script:AdbExit -ne 0 -or $out -notmatch '(?i)success') {
    Write-Host $out
    Stop-WithHint "Pairing failed."
  }
  Write-Host "Paired." -ForegroundColor Green

  # ---------- 4. find the connect port and connect ----------
  $conns = @(Wait-AdbService '_adb-tls-connect._tcp' { $_.Ip -eq $pairIp }.GetNewClosure() $Timeout 'Finding the connect port...')
  if ($conns.Count -eq 0) { Stop-WithHint "Paired, but timed out finding the phone's connect port." }

  foreach ($port in @($conns | ForEach-Object { $_.Port } | Select-Object -Unique)) {
    $target = "${pairIp}:${port}"
    $out = (Invoke-Adb connect $target) -join "`n"
    Write-Host $out
    if ($out -match '(?i)connected to|already connected') {
      Write-Host "Done. Device ready:" -ForegroundColor Green
      $devs = @(Invoke-Adb devices -l)
      $mine = @($devs | Where-Object { $_.StartsWith($target) })
      if ($mine.Count -gt 0) { $mine | ForEach-Object { Write-Host $_ } } else { $devs | ForEach-Object { Write-Host $_ } }
      exit 0
    }
  }
  Stop-WithHint "adb connect to ${pairIp} failed."
}

# Run unless dot-sourced (dot-sourcing loads the functions only, for testing).
if ($MyInvocation.InvocationName -ne '.') { Invoke-AdbQrPair }
