#Requires -Version 5.1
param(
  [int]$Port = 7389
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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
$script:failCount = 0
$script:tick = 0
$script:lastStatus = $null
$script:dismissed = $false
$script:dismissedMode = ''
$script:dismissedSessionText = ''

function Set-DotColor([string]$hex) {
  $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

function Show-Card {
  $work = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $work.Right - $window.Width - 16
  $window.Top = $work.Bottom - $window.Height - 16
  $window.Visibility = 'Visible'
}

function Hide-Card {
  $window.Visibility = 'Collapsed'
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

  # Idle resets the dismissal so the next turn/request always shows again.
  if ($mode -eq 'idle') {
    $script:dismissed = $false
  } elseif ($script:dismissed -and ($mode -ne $script:dismissedMode -or $session -ne $script:dismissedSessionText)) {
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

  if ($mode -ne $script:lastMode) {
    if ($mode -eq 'pending') {
      try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    } elseif ($mode -eq 'done') {
      try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
    }
    $script:lastMode = $mode
  }

  if ($mode -eq 'running' -or $mode -eq 'pending') {
    $script:tick += 1
    $dot.Opacity = if ($script:tick % 2 -eq 0) { 0.35 } else { 1 }
  } else {
    $dot.Opacity = 1
  }

  if ($mode -eq 'idle' -or $script:dismissed) {
    Hide-Card
  } else {
    Show-Card
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
})
$timer.Start()

$closeButton.Add_Click({
  Write-DebugLog "dismiss clicked"
  Dismiss-Card
})

$window.Add_Closed({
  $timer.Stop()
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

Show-Card
Read-Status
Write-DebugLog "popup before Show/Dispatcher"
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
Write-DebugLog "popup after Dispatcher (window closed)" 
