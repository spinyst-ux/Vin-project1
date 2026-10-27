# Pixel Lineage auto-play. External macro: reads pixels from the Roblox window and clicks.
# Nothing is injected into Roblox. Control panel: http://localhost:8765/   Hotkey: F6 start/stop.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
  public struct RECT { public int L, T, R, B; }
  public struct POINT { public int X, Y; }
}
"@
[W]::SetProcessDPIAware() | Out-Null

$cfgPath = "$here\config.json"
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
function Save-Cfg { $cfg | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8 }

$script:running = $false
$script:status = 'Idle'
$script:log = [Collections.Generic.List[string]]::new()
$script:last = ''; $script:lastAt = [datetime]::MinValue
$script:calName = $null; $script:calAt = $null
$script:nextAt = Get-Date
$script:rect = $null

function Log($m) { $script:log.Insert(0, (Get-Date -Format 'HH:mm:ss') + '  ' + $m); if ($script:log.Count -gt 40) { $script:log.RemoveAt(40) } }

function Get-Rect {
  $p = Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
  if (-not $p) { return $null }
  $r = New-Object W+RECT; [W]::GetClientRect($p.MainWindowHandle, [ref]$r) | Out-Null
  $o = New-Object W+POINT; [W]::ClientToScreen($p.MainWindowHandle, [ref]$o) | Out-Null
  @{ X = $o.X; Y = $o.Y; W = $r.R; H = $r.B }
}

$bmp = New-Object Drawing.Bitmap 1, 1
$gfx = [Drawing.Graphics]::FromImage($bmp)
function Get-Px($x, $y) { $gfx.CopyFromScreen($x, $y, 0, 0, [Drawing.Size]::new(1, 1)); $bmp.GetPixel(0, 0) }

function Pt-Screen($p) { @([int]($script:rect.X + $p.x * $script:rect.W), [int]($script:rect.Y + $p.y * $script:rect.H)) }

# Detect point: calibrated and pixel color within tolerance of the saved color.
function Test-Pt($name) {
  $p = $cfg.points.$name
  if (-not $p -or $null -eq $p.x -or -not $p.color) { return $false }
  $x, $y = Pt-Screen $p
  $c = Get-Px $x $y
  $h = $p.color.TrimStart('#')
  $d = [Math]::Max([Math]::Abs($c.R - [Convert]::ToInt32($h.Substring(0, 2), 16)),
       [Math]::Max([Math]::Abs($c.G - [Convert]::ToInt32($h.Substring(2, 2), 16)), [Math]::Abs($c.B - [Convert]::ToInt32($h.Substring(4, 2), 16))))
  $d -le $cfg.tolerance
}

# Roblox GUI buttons ignore a click without a prior mouse move, hence the 1px nudge.
function Click-Pt($name) {
  $p = $cfg.points.$name
  if (-not $p -or $null -eq $p.x) { return $false }
  $x, $y = Pt-Screen $p
  [W]::SetCursorPos($x, $y) | Out-Null
  [W]::mouse_event(1, 1, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 30
  [W]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
  [W]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds $cfg.clickDelay
  $true
}

function Act($what) { $script:last = $what; $script:lastAt = Get-Date; $script:status = $what; Log $what }
function Since-Last($what) { if ($script:last -ne $what) { 1e9 } else { ((Get-Date) - $script:lastAt).TotalSeconds } }

# One decision per tick. Returns seconds to wait before the next tick.
function Step {
  $script:rect = Get-Rect
  if (-not $script:rect) { $script:status = 'Roblox window not found'; return 2 }
  $s = $cfg.settings

  if (($s.autoAttack -or $s.autoSkill) -and (Test-Pt 'turn_cursor')) {
    # ponytail: skill retried turn -> fall back to attack (no energy / skill on cooldown). Add an EN pixel check if it misfires.
    if ($s.autoSkill -and (Since-Last 'skill') -gt 4) {
      Click-Pt 'skills' | Out-Null; Click-Pt ('skill_' + $s.skillSlot) | Out-Null; Click-Pt 'target' | Out-Null
      Act "Skill $($s.skillSlot)"; $script:last = 'skill'; return 2
    }
    Click-Pt 'attack' | Out-Null; Click-Pt 'target' | Out-Null
    Act 'Attack'; return 2
  }

  if ($s.autoJoin) {
    if (Test-Pt 'start_run') {
      Click-Pt ('lobby_' + $s.difficulty) | Out-Null; Click-Pt 'start_run' | Out-Null
      Act "Start run ($($s.difficulty))"; return 4
    }
    if (Test-Pt 'mp_host') {
      if ($s.mpMode -eq 'queue' -and (Since-Last 'Queue') -lt 60) { $script:status = 'In queue...'; return 2 }
      Click-Pt ('diff_' + $s.difficulty) | Out-Null
      if ($s.mpMode -eq 'queue') { Click-Pt 'mp_queue' | Out-Null; Act 'Queue' } else { Click-Pt 'mp_host' | Out-Null; Act 'Host lobby' }
      return 3
    }
    if (Test-Pt 'setout_modal') {
      if ($s.mode -eq 'solo') { Click-Pt 'solo' | Out-Null; Act 'Play solo' } else { Click-Pt 'party' | Out-Null; Act 'Find a party' }
      return 2
    }
    if (Test-Pt 'setout_btn') { Click-Pt 'setout_btn' | Out-Null; Act 'Set out'; return 2 }
  }

  foreach ($n in 'continue1', 'continue2', 'continue3') {
    if (Test-Pt $n) { Click-Pt $n | Out-Null; Act "Click $n"; return 1.5 }
  }
  $script:status = 'Waiting...'
  0.5
}

function Do-Calibrate {
  $script:rect = Get-Rect
  $name = $script:calName; $script:calName = $null; $script:calAt = $null
  if (-not $script:rect) { Log "Calibrate $name failed: Roblox window not found"; return }
  $c = New-Object W+POINT; [W]::GetCursorPos([ref]$c) | Out-Null
  $fx = ($c.X - $script:rect.X) / $script:rect.W; $fy = ($c.Y - $script:rect.Y) / $script:rect.H
  if ($fx -lt 0 -or $fx -gt 1 -or $fy -lt 0 -or $fy -gt 1) { Log "Calibrate $name failed: mouse not over Roblox"; return }
  $px = Get-Px $c.X $c.Y
  $hex = '#{0:X2}{1:X2}{2:X2}' -f $px.R, $px.G, $px.B
  $cfg.points | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{ x = [Math]::Round($fx, 4); y = [Math]::Round($fy, 4); color = $hex }) -Force
  Save-Cfg
  Log "Saved $name at $([Math]::Round($fx,3)),$([Math]::Round($fy,3)) $hex"
}

function Handle($ctx) {
  $req = $ctx.Request; $path = $req.Url.AbsolutePath; $type = 'application/json'
  switch ($path) {
    '/' { $out = [IO.File]::ReadAllText("$here\ui.html"); $type = 'text/html' }
    '/settings' { $cfg.settings = (New-Object IO.StreamReader $req.InputStream).ReadToEnd() | ConvertFrom-Json; Save-Cfg }
    '/toggle' { $script:running = -not $script:running; Log ($(if ($script:running) { 'Started' } else { 'Stopped' })); if (-not $script:running) { $script:status = 'Idle' } }
    '/cal' { $script:calName = $req.QueryString['name']; $script:calAt = (Get-Date).AddSeconds(3) }
    '/clear' { $cfg.points.PSObject.Properties.Remove($req.QueryString['name']); Save-Cfg }
    '/quit' { $script:quit = $true }
  }
  if ($path -ne '/') {
    $cal = if ($script:calAt) { [Math]::Ceiling(($script:calAt - (Get-Date)).TotalSeconds) } else { 0 }
    $out = @{ running = $script:running; status = $script:status; log = $script:log; settings = $cfg.settings; points = $cfg.points; calName = $script:calName; calIn = $cal } | ConvertTo-Json -Depth 5 -Compress
  }
  $b = [Text.Encoding]::UTF8.GetBytes($out)
  $ctx.Response.ContentType = "$type; charset=utf-8"
  $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
}

$http = [Net.HttpListener]::new()
$http.Prefixes.Add('http://localhost:8765/')
$http.Start()
Write-Host 'Pixel Lineage macro: http://localhost:8765/  (F6 = start/stop, close this window to exit)'
Start-Process 'http://localhost:8765/'
$task = $http.GetContextAsync()
$f6Down = $false; $script:quit = $false
while (-not $script:quit) {
  if ($task.IsCompleted) { try { Handle $task.Result } catch { Log "HTTP error: $_" }; $task = $http.GetContextAsync() }
  $k = ([W]::GetAsyncKeyState(0x75) -band 0x8000) -ne 0
  if ($k -and -not $f6Down) { $script:running = -not $script:running; Log ($(if ($script:running) { 'Started (F6)' } else { 'Stopped (F6)' })); if (-not $script:running) { $script:status = 'Idle' } }
  $f6Down = $k
  if ($script:calAt -and (Get-Date) -ge $script:calAt) { Do-Calibrate }
  if ($script:running -and (Get-Date) -ge $script:nextAt) {
    try { $w = Step } catch { Log "Error: $_"; $w = 2 }
    $script:nextAt = (Get-Date).AddSeconds($w)
  }
  Start-Sleep -Milliseconds 50
}
$http.Stop()
