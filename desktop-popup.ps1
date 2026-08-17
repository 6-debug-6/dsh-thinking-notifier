#Requires -Version 5.1
param(
  [int]$Port = 7389
)

# Single-instance guard: only one popup per port should run at a time.
$mutexCreated = $false
$mutex = $null
try {
  $mutex = New-Object System.Threading.Mutex($true, "Local\dsh-thinking-notifier-$Port", [ref]$mutexCreated)
} catch {
  $mutex = $null
}
if ($mutex -eq $null -or -not $mutexCreated) {
  if ($mutex) { try { $mutex.Dispose() } catch { } }
  exit
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Hide the PowerShell console window; only the WPF popup should be visible.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ConsoleWindow {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
$consoleHwnd = [ConsoleWindow]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) {
  [ConsoleWindow]::ShowWindow($consoleHwnd, 0) | Out-Null
}

$debugLog = Join-Path $env:USERPROFILE '.dsh\tn-popup-debug.log'
function Write-DebugLog([string]$msg) {
  try {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $msg
    Add-Content -Path $debugLog -Value $line -Encoding UTF8
  } catch { }
}
Write-DebugLog "popup start: pid=$PID port=$Port"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$baseUrl = "http://127.0.0.1:$Port"

$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="dsh-thinking-notifier"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="False"
    ResizeMode="NoResize"
    Width="392"
    Height="84">
  <Border x:Name="Card" CornerRadius="12" Background="#F21E2235" BorderBrush="#FF3A4056" BorderThickness="1" Padding="14,10">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Ellipse x:Name="Dot" Grid.Column="0" Width="10" Height="10" Fill="#FF64748B" Margin="0,0,10,0" VerticalAlignment="Center" />
      <StackPanel Grid.Column="1" VerticalAlignment="Center">
        <TextBlock x:Name="StatusText" Text="DSH idle" Foreground="#FFECEEF2" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" MaxWidth="290" />
        <TextBlock x:Name="SessionText" Foreground="#FF9AA3B5" FontSize="11" TextTrimming="CharacterEllipsis" MaxWidth="290" />
        <TextBlock x:Name="TimeText" Foreground="#FF6B7488" FontSize="11" />
      </StackPanel>
      <Button x:Name="CloseButton" Grid.Column="2" Content="X" Width="22" Height="22" Margin="10,0,0,0" VerticalAlignment="Top" Background="Transparent" BorderThickness="0" Foreground="#FF9AA3B5" Cursor="Hand" FontSize="12" FontWeight="Bold" />
    </Grid>
  </Border>
</Window>
"@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)
$card = $window.FindName('Card')
$dot = $window.FindName('Dot')
$statusText = $window.FindName('StatusText')
$sessionText = $window.FindName('SessionText')
$timeText = $window.FindName('TimeText')
$closeButton = $window.FindName('CloseButton')

$script:lastMode = ''
$script:lastSession = ''
$script:failCount = 0
$script:tick = 0
$script:lastStatus = $null
$script:dismissed = $false
$script:dismissedMode = ''
$script:dismissedSessionText = ''
$script:expanded = $false
$script:expandedAt = [DateTime]::Now
$script:autoCollapseMs = 5000

function Set-DotColor([string]$hex) {
  $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

function Show-Card {
  $work = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $work.Right - $window.Width - 16
  $window.Top = $work.Bottom - $window.Height - 16
  $window.Visibility = 'Visible'
  $script:expanded = $true
  $script:expandedAt = [DateTime]::Now
}

function Collapse-Card {
  $work = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $work.Right - 25
  $window.Top = $work.Bottom - $window.Height - 16
  $window.Visibility = 'Visible'
  $script:expanded = $false
}

function Hide-Card {
  $window.Visibility = 'Collapsed'
  $script:expanded = $false
}

function Dismiss-Card {
  $script:dismissed = $true
  if ($script:lastStatus) {
    $script:dismissedMode = $script:lastStatus.mode
    $script:dismissedSessionText = $script:lastStatus.sessionText
  }
  Hide-Card
}

function Update-FromStatus {
  param($status)
  if ($null -eq $status) { return }
  $script:lastStatus = $status

  if ($status.statusText) { $statusText.Text = $status.statusText } else { $statusText.Text = 'DSH idle' }
  if ($status.sessionText) { $sessionText.Text = $status.sessionText } else { $sessionText.Text = '' }
  if ($status.timeText) { $timeText.Text = $status.timeText } else { $timeText.Text = '' }

  $mode = $status.mode
  $session = $status.sessionText
  $shouldExpand = $false

  # A new state (new turn, permission request, completion) re-expands the card.
  if ($mode -ne $script:lastMode -or $session -ne $script:lastSession) {
    if ($mode -ne 'idle') {
      $script:dismissed = $false
      $shouldExpand = $true
    }
    if ($mode -eq 'pending') {
      try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    } elseif ($mode -eq 'done') {
      try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
    }
    $script:lastMode = $mode
    $script:lastSession = $session
  }

  # Idle always resets dismissal and hides.
  if ($mode -eq 'idle') {
    $script:dismissed = $false
  }

  switch ($mode) {
    'pending' {
      Set-DotColor '#FFF59E0B'
      $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#73F59E0B')
    }
    'running' {
      Set-DotColor '#FF4D6BFE'
      $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF3A4056')
    }
    'done' {
      Set-DotColor '#FF22C55E'
      $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF3A4056')
    }
    default {
      Set-DotColor '#FF64748B'
      $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF3A4056')
    }
  }

  if ($mode -eq 'running' -or $mode -eq 'pending') {
    $script:tick += 1
    $dot.Opacity = if ($script:tick % 2 -eq 0) { 0.35 } else { 1 }
  } else {
    $dot.Opacity = 1
  }

  if ($mode -eq 'idle' -or $script:dismissed) {
    Hide-Card
  } elseif ($mode -eq 'pending' -or $mode -eq 'done') {
    Show-Card
  } elseif ($mode -eq 'running') {
    if ($shouldExpand -or $window.Visibility -ne 'Visible') {
      Show-Card
    }
  }
}

function Read-Status {
  try {
    $resp = Invoke-WebRequest -Uri "$baseUrl/status" -TimeoutSec 2 -UseBasicParsing
    $text = $null
    try {
      $bytes = $resp.RawContentStream.ToArray()
      $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
      $text = $resp.Content
    }
    $status = $text | ConvertFrom-Json
    $script:failCount = 0
    Update-FromStatus $status
  } catch {
    $script:failCount += 1
    Write-DebugLog "status poll failed: count=$($script:failCount) error=$($_.Exception.Message)"
    if ($script:failCount -ge 15) {
      $window.Close()
    }
  }
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(1000)
$timer.Add_Tick({
  Read-Status

  # Auto-collapse only while the AI is thinking; permission requests and
  # completion stay expanded until the state changes.
  if ($script:expanded -and $script:lastStatus -and $script:lastStatus.mode -eq 'running' -and -not $script:dismissed) {
    $span = [DateTime]::Now - $script:expandedAt
    if ($span.TotalMilliseconds -ge $script:autoCollapseMs) {
      Collapse-Card
      Write-DebugLog "auto collapsed"
    }
  }
})
$timer.Start()

$closeButton.Add_Click({
  Write-DebugLog "dismiss clicked"
  Dismiss-Card
})

# Hovering or clicking the exposed edge expands the collapsed card.
$window.Add_MouseEnter({
  if (-not $script:expanded -and -not $script:dismissed -and $script:lastStatus -and $script:lastStatus.mode -ne 'idle') {
    Show-Card
  }
})

$window.Add_Closed({
  $timer.Stop()
  try { $mutex.ReleaseMutex() } catch { }
  try { $mutex.Dispose() } catch { }
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

Show-Card
Read-Status
Write-DebugLog "popup before Show/Dispatcher"
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
Write-DebugLog "popup after Dispatcher (window closed)" 
