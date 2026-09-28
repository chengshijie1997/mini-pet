param(
  [string]$PreviewPath,
  [int]$RefreshSeconds = 60,
  [switch]$NoNetwork
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$script:LogPath = Join-Path $PSScriptRoot 'hud.log'
try { Remove-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue } catch { }
trap {
  try {
    Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $_.Exception.ToString())
  } catch { }
  break
}

$CodexHome   = Join-Path $env:USERPROFILE '.codex'
$ConfigPath  = Join-Path $CodexHome 'config.toml'
$StatePath   = Join-Path $CodexHome '.codex-global-state.json'
$PricingPath = Join-Path $PSScriptRoot 'pricing.json'

# ---------- 配置 ----------
$script:Pricing = @{
  UtcStart = 990
  UtcEnd   = 30
  Label    = '优惠时段'
  LabelStd = '标准时段'
  Models   = @()
}
try {
  $raw = Get-Content -LiteralPath $PricingPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($raw.offPeak.utcStart) { $script:Pricing.UtcStart = (([int]($raw.offPeak.utcStart -split ':')[0]) * 60) + [int](($raw.offPeak.utcStart -split ':')[1]) }
  if ($raw.offPeak.utcEnd)   { $script:Pricing.UtcEnd   = (([int]($raw.offPeak.utcEnd   -split ':')[0]) * 60) + [int](($raw.offPeak.utcEnd   -split ':')[1]) }
  if ($raw.offPeak.label)         { $script:Pricing.Label = [string]$raw.offPeak.label }
  if ($raw.offPeak.labelStandard) { $script:Pricing.LabelStd = [string]$raw.offPeak.labelStandard }
  if ($raw.models) { $script:Pricing.Models = @($raw.models) }
} catch { }

function Get-DeepSeekConfig {
  $out = @{ BaseUrl = 'https://api.deepseek.com/'; Token = '' }
  try {
    $inSection = $false
    foreach ($line in (Get-Content -LiteralPath $ConfigPath -Encoding UTF8)) {
      $t = $line.Trim()
      if ($t -match '^\[model_providers\.([^\]]+)\]$') { $inSection = ($Matches[1] -eq 'deepseek'); continue }
      if ($t.StartsWith('[')) { $inSection = $false; continue }
      if (-not $inSection) { continue }
      if ($t -match '^base_url\s*=\s*"([^"]*)"') { $out.BaseUrl = $Matches[1] }
      if ($t -match '^experimental_bearer_token\s*=\s*"([^"]*)"') { $out.Token = $Matches[1] }
    }
  } catch { }
  if ($env:DEEPSEEK_API_KEY) { $out.Token = $env:DEEPSEEK_API_KEY }
  $out.BaseUrl = $out.BaseUrl.TrimEnd('/') + '/'
  return $out
}

if (-not $NoNetwork) {
  Add-Type -ReferencedAssemblies 'System.Net.Http' -TypeDefinition @'
using System;
using System.Net.Http;
using System.Threading.Tasks;

public static class DeepSeekApi
{
    public static Task<string> Get(string url, string key)
    {
        var client = new HttpClient();
        client.Timeout = TimeSpan.FromSeconds(15);
        client.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", "Bearer " + key);
        client.DefaultRequestHeaders.TryAddWithoutValidation("Accept", "application/json");
        return client.GetStringAsync(url);
    }
}
'@
}

# ---------- 时段推算（UTC 16:30 - 00:30）----------
function Get-PeriodInfo([datetime]$UtcNow) {
  $dayStart = [datetime]::new($UtcNow.Year, $UtcNow.Month, $UtcNow.Day, 0, 0, 0, [DateTimeKind]::Utc)
  $dayMin   = ($UtcNow - $dayStart).TotalMinutes
  $startToday = $dayStart.AddMinutes($script:Pricing.UtcStart)
  $endToday   = $dayStart.AddMinutes(1440 + $script:Pricing.UtcEnd)
  if ($dayMin -ge $script:Pricing.UtcStart) { return @{ Discount = $true;  Start = $startToday; End = $endToday } }
  if ($dayMin -lt $script:Pricing.UtcEnd)   { return @{ Discount = $true;  Start = $startToday.AddDays(-1); End = $endToday.AddDays(-1) } }
  return @{ Discount = $false; Start = $endToday.AddDays(-1); End = $startToday }
}

# ---------- 界面 ----------
$xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="272" CornerRadius="16" Background="#FF151B24" BorderBrush="#882A3442" BorderThickness="1" Padding="14">
  <StackPanel>
    <DockPanel LastChildFill="False">
      <Ellipse x:Name="Dot" Width="9" Height="9" Fill="#F4696B" VerticalAlignment="Center" DockPanel.Dock="Left"/>
      <TextBlock x:Name="Title" Text="Mini · DeepSeek" Margin="8,0,0,0" FontSize="13" FontWeight="Bold" Foreground="#E6EDF3" VerticalAlignment="Center" DockPanel.Dock="Left"/>
      <TextBlock x:Name="Sync" Text="连接中" FontSize="11" Foreground="#8B98A8" VerticalAlignment="Center" DockPanel.Dock="Right"/>
    </DockPanel>

    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
      <Canvas Width="56" Height="56">
        <Ellipse x:Name="PetBody" Canvas.Left="2" Canvas.Top="2" Width="52" Height="52" Fill="#2A9D84"/>
        <Ellipse x:Name="PetEyeL" Canvas.Left="18" Canvas.Top="22" Width="6" Height="9" Fill="#0E1D27"/>
        <Ellipse x:Name="PetEyeR" Canvas.Left="32" Canvas.Top="22" Width="6" Height="9" Fill="#0E1D27"/>
        <Path x:Name="PetMouth" Data="M22,37 Q28,43 34,37" Stroke="#0E1D27" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
      </Canvas>
      <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
        <Border x:Name="Badge" CornerRadius="999" Background="#1F3FD0A0" BorderBrush="#553FD0A0" BorderThickness="1" Padding="8,2" HorizontalAlignment="Left">
          <TextBlock x:Name="BadgeText" Text="计算中" FontSize="12" FontWeight="Bold" Foreground="#3FD0A0"/>
        </Border>
        <TextBlock x:Name="Countdown" Text="--:--:--" Margin="0,6,0,0" FontSize="12" Foreground="#9FB0C0"/>
      </StackPanel>
    </StackPanel>

    <Border Height="6" CornerRadius="3" Background="#1FFFFFFF" Margin="0,12,0,0">
      <Border x:Name="BarFill" Height="6" CornerRadius="3" Background="#3FD0A0" HorizontalAlignment="Left" Width="0"/>
    </Border>
    <TextBlock x:Name="PeriodLine" Text="当前段 --" Margin="0,8,0,0" FontSize="11" Foreground="#8B98A8"/>

    <TextBlock Text="账户余额" Margin="0,14,0,0" FontSize="11" Foreground="#8B98A8"/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,0">
      <TextBlock x:Name="BalanceNum" Text="--" FontSize="28" FontWeight="Bold" Foreground="#E6EDF3"/>
      <TextBlock x:Name="BalanceCur" Text="CNY" Margin="6,0,0,6" FontSize="12" Foreground="#8B98A8" VerticalAlignment="Bottom"/>
    </StackPanel>
    <TextBlock x:Name="BalanceDetail" Text="赠送 --  充值 --" Margin="0,2,0,0" FontSize="11" Foreground="#8B98A8"/>
    <TextBlock x:Name="BalanceState" Text="尚未读取" Margin="0,2,0,0" FontSize="11" Foreground="#8B98A8"/>

    <TextBlock x:Name="DiscountLine" Text="折扣 --" Margin="0,10,0,0" FontSize="11" Foreground="#8B98A8" TextWrapping="Wrap"/>
    <TextBlock x:Name="Foot" Text="右键：刷新 / 重新贴合宠物 / 退出" Margin="0,10,0,4" FontSize="10" Foreground="#6B7787" TextWrapping="Wrap"/>
  </StackPanel>
</Border>
'@

$root = [System.Windows.Markup.XamlReader]::Parse($xaml)
function Get-El([string]$n) { return $root.FindName($n) }

$brushes = @{
  good = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x3F,0xD0,0xA0))
  std  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x8A,0xB4,0xFF))
  bad  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF4,0x69,0x6B))
  warn = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF0,0xB4,0x29))
  muted= New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x8B,0x98,0xA8))
}

$cfg = Get-DeepSeekConfig
$script:BaseUrl = $cfg.BaseUrl
$script:Token   = $cfg.Token
$script:Balance = $null
$script:FetchTask = $null
$script:LastFetchAt = [datetime]::MinValue
$script:LastError = $null

function Start-BalanceFetch {
  if ($NoNetwork) { return }
  if (-not $script:Token) { $script:LastError = '没有读到 API Key'; return }
  if ($script:FetchTask -and -not $script:FetchTask.IsCompleted) { return }
  try {
    $script:FetchTask = [DeepSeekApi]::Get($script:BaseUrl + 'user/balance', $script:Token)
    $script:LastError = $null
  } catch {
    $script:LastError = $_.Exception.Message
  }
}

function Update-BalanceFromTask {
  if (-not $script:FetchTask) { return }
  if (-not $script:FetchTask.IsCompleted) { return }
  try {
    $json = $script:FetchTask.Result
    $obj = $json | ConvertFrom-Json
    $info = @($obj.balance_infos | Where-Object { $_.currency -eq 'CNY' })
    if (-not $info) { $info = @($obj.balance_infos) }
    $script:Balance = @{
      Total    = [double]$info[0].total_balance
      Granted  = [double]$info[0].granted_balance
      Topped   = [double]$info[0].topped_up_balance
      Currency = [string]$info[0].currency
      Available= [bool]$obj.is_available
      At       = (Get-Date)
    }
    $script:LastError = $null
  } catch {
    $script:LastError = $_.Exception.Message
    $script:Balance = $null
  } finally {
    $script:FetchTask = $null
    $script:LastFetchAt = Get-Date
  }
}

function Format-Hms([double]$ms) {
  if ($ms -lt 0) { $ms = 0 }
  $span = [TimeSpan]::FromMilliseconds($ms)
  return ('{0:00}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds)
}

function Update-Ui {
  $utcNow = [datetime]::UtcNow
  $p = Get-PeriodInfo $utcNow
  $remaining = ($p.End - $utcNow).TotalMilliseconds
  $total = ($p.End - $p.Start).TotalMilliseconds
  $pct = if ($total -gt 0) { [Math]::Min(1, [Math]::Max(0, 1 - ($remaining / $total))) } else { 0 }

  $accent = if ($p.Discount) { $brushes.good } else { $brushes.std }
  $badge  = Get-El 'Badge'; $badgeText = Get-El 'BadgeText'
  $badgeText.Text = if ($p.Discount) { $script:Pricing.Label } else { $script:Pricing.LabelStd }
  $badgeText.Foreground = $accent
  $badge.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x22, $accent.Color.R, $accent.Color.G, $accent.Color.B))
  $badge.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x55, $accent.Color.R, $accent.Color.G, $accent.Color.B))
  $bar = Get-El 'BarFill'
  $bar.Background = $accent
  $bar.Width = [Math]::Round(242 * $pct, 1)
  (Get-El 'Countdown').Text = (Format-Hms $remaining) + ' 后切换'
  (Get-El 'PeriodLine').Text = ('当前段 {0:HH:mm} - {1:HH:mm} · 下一切换 {1:HH:mm}' -f $p.Start.ToLocalTime(), $p.End.ToLocalTime())

  $lowBalance = $script:Balance -and $script:Balance.Total -lt 10
  if ($script:Balance) {
    $num = Get-El 'BalanceNum'
    $num.FontSize = 28
    $num.Text = ('{0:N2}' -f $script:Balance.Total)
    $num.Foreground = if ($lowBalance) { $brushes.warn } else { $brushes.good }
    (Get-El 'BalanceCur').Text = $script:Balance.Currency
    (Get-El 'BalanceDetail').Text = ('赠送 {0:N2}   充值 {1:N2}' -f $script:Balance.Granted, $script:Balance.Topped)
    $st = Get-El 'BalanceState'
    $st.Text = ('{0} · 更新于 {1:HH:mm:ss}' -f $(if ($script:Balance.Available) { '可以调用' } else { '已停用' }), $script:Balance.At)
    $st.Foreground = if ($script:Balance.Available) { $brushes.muted } else { $brushes.bad }
    $sync = Get-El 'Sync'; $sync.Text = '已连接'; $sync.Foreground = $brushes.good
    (Get-El 'Dot').Fill = $brushes.good
  } elseif ($script:LastError) {
    $num = Get-El 'BalanceNum'
    $num.Text = '读取失败'; $num.Foreground = $brushes.bad; $num.FontSize = 18
    $st = Get-El 'BalanceState'; $st.Text = $script:LastError; $st.Foreground = $brushes.bad
    $sync = Get-El 'Sync'; $sync.Text = '离线'; $sync.Foreground = $brushes.bad
    (Get-El 'Dot').Fill = $brushes.bad
  } else {
    $sync = Get-El 'Sync'; $sync.Text = '读取中'; $sync.Foreground = $brushes.warn
    (Get-El 'Dot').Fill = $brushes.warn
  }

  $disc = Get-El 'DiscountLine'
  if ($p.Discount) {
    $parts = @()
    foreach ($m in @($script:Pricing.Models)) { $parts += ('{0} 省 {1}%' -f $m.name, $m.offPeakPct) }
    $disc.Text = '本时段：' + ($parts -join ' · ')
    $disc.Foreground = $brushes.good
  } else {
    $disc.Text = '本时段按标准价计费，优惠时段见上方倒计时'
    $disc.Foreground = $brushes.muted
  }

  # 宠物表情随状态变化
  $mood = if ($script:LastError -or $lowBalance) { 'worried' } elseif ($p.Discount) { 'happy' } else { 'idle' }
  $bodyColor = switch ($mood) {
    'worried' { [System.Windows.Media.Color]::FromRgb(0xE8,0x9B,0x5A) }
    'happy'   { [System.Windows.Media.Color]::FromRgb(0x2A,0x9D,0x84) }
    default   { [System.Windows.Media.Color]::FromRgb(0x3E,0x6F,0xB5) }
  }
  (Get-El 'PetBody').Fill = New-Object System.Windows.Media.SolidColorBrush $bodyColor
  (Get-El 'PetMouth').Data = [System.Windows.Media.Geometry]::Parse($(if ($mood -eq 'worried') { 'M23,40 Q28,34 33,40' } else { 'M22,37 Q28,43 34,37' }))
}

function Save-Preview([string]$path) {
  $root.Measure((New-Object System.Windows.Size -ArgumentList @(272, 1000)))
  $h = [int][Math]::Ceiling($root.DesiredSize.Height) + 8
  $root.Arrange((New-Object System.Windows.Rect -ArgumentList @(0, 0, 272, $h)))
  $root.UpdateLayout()
  $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap -ArgumentList @(272, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $bmp.Render($root)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
  $fs = [System.IO.File]::Create($path)
  try { $enc.Save($fs) } finally { $fs.Dispose() }
}

# 面板要贴着 Codex 桌面宠物放
function Get-PetAnchor {
  $fallback = @{ X = $null; Y = $null; ScreenW = 1920; ScreenH = 1080 }
  try {
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $b = $state.'electron-avatar-overlay-bounds'
    if (-not $b) { return $fallback }
    $x = $b.x; $y = $b.y
    $sw = $b.displayBounds.width; $sh = $b.displayBounds.height
    if ($null -eq $x -and $b.byDisplayId) {
      $first = $b.byDisplayId.PSObject.Properties | Select-Object -First 1
      if ($first) {
        $v = $first.Value
        $x = $v.x; $y = $v.y; $sw = $v.displayBounds.width; $sh = $v.displayBounds.height
      }
    }
    if ($null -ne $x) { return @{ X = [double]$x; Y = [double]$y; ScreenW = [double]$sw; ScreenH = [double]$sh } }
  } catch { }
  return $fallback
}

function Set-PanelPosition($win) {
  $anchor = Get-PetAnchor
  $win.UpdateLayout()
  $w = if ($win.ActualWidth -gt 0) { $win.ActualWidth } else { 272 }
  $h = if ($win.ActualHeight -gt 0) { $win.ActualHeight } else { 300 }

  # WPF 的 Left/Top 用的是 DIP，屏幕 150% 缩放时要把物理像素换算过来
  $scale = 1.0
  try {
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($root).PixelsPerInchX
    if ($dpi -gt 0) { $scale = $dpi / 96.0 }
  } catch { }
  if ($scale -le 0) {
    $dipScreenW = [System.Windows.SystemParameters]::PrimaryScreenWidth
    if ($anchor.ScreenW -gt 0 -and $dipScreenW -gt 0) { $scale = $anchor.ScreenW / $dipScreenW }
  }
  if ($scale -le 0) { $scale = 1.0 }

  $screenWDip = $anchor.ScreenW / $scale
  $screenHDip = $anchor.ScreenH / $scale

  if ($null -ne $anchor.X) {
    # 面板右边缘贴着宠物的左边缘，底部与屏幕下沿留 12 DIP
    $right = ($anchor.X / $scale) - 12
    $left  = $right - $w
    $top   = $screenHDip - $h - 12
    if ($top -lt 8) { $top = 8 }
    if ($left -lt 8) { $left = 8 }
  } else {
    $left = $screenWDip - $w - 160
    $top  = $screenHDip - $h - 24
  }
  $win.Left = $left
  $win.Top  = $top
}

if ($PreviewPath) {
  if (-not $NoNetwork) {
    Start-BalanceFetch
    $deadline = (Get-Date).AddSeconds(20)
    while ($script:FetchTask -and -not $script:FetchTask.IsCompleted -and (Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 200
    }
    Update-BalanceFromTask
  }
  Update-Ui
  Save-Preview $PreviewPath
  Write-Output "preview written: $PreviewPath"
  return
}

$win = New-Object System.Windows.Window
$win.Title = 'Mini DeepSeek 宠物面板'
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.ResizeMode = 'NoResize'
$win.SizeToContent = 'WidthAndHeight'
$win.WindowStartupLocation = 'Manual'
$win.ShowActivated = $false
$win.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI, Segoe UI'
$win.Content = $root

$menu = New-Object System.Windows.Controls.ContextMenu
$miRefresh = New-Object System.Windows.Controls.MenuItem
$miRefresh.Header = '立即刷新余额'
$miRefresh.Add_Click({ $script:LastFetchAt = [datetime]::MinValue; Start-BalanceFetch; Update-Ui })
$miSnap = New-Object System.Windows.Controls.MenuItem
$miSnap.Header = '重新贴合宠物'
$miSnap.Add_Click({ Set-PanelPosition $win })
$miQuit = New-Object System.Windows.Controls.MenuItem
$miQuit.Header = '退出'
$miQuit.Add_Click({ $win.Close() })
$menu.Items.Add($miRefresh) | Out-Null
$menu.Items.Add($miSnap) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miQuit) | Out-Null
$root.ContextMenu = $menu

$win.Add_SourceInitialized({ Set-PanelPosition $win })
$win.Add_Loaded({ Set-PanelPosition $win })
$win.Show()

Start-BalanceFetch

$script:LastAnchor = $null
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
  Update-BalanceFromTask
  if (((Get-Date) - $script:LastFetchAt).TotalSeconds -ge $RefreshSeconds) { Start-BalanceFetch }

  # Codex 宠物被拖动时，面板跟着走
  if ($win.IsLoaded) { Set-PanelPosition $win }
  Update-Ui
})
$timer.Start()

$win.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
$win.Show()
[System.Windows.Threading.Dispatcher]::Run()
