<#
  Claude Progress - a small always-on-top window that shows what Claude Code is doing,
  step by step, how long it has been running and roughly how long is left.
  Every chat that is working gets its own card.

  It reads %USERPROFILE%\.claude-progress\state.json, which hook.js keeps up to date.

  ClaudeProgress.ps1                  normal mode
  ClaudeProgress.ps1 -Demo            plays two fake chats so you can see it work
  ClaudeProgress.ps1 -SelfTest        builds the window in every theme and exits
  ClaudeProgress.ps1 -Theme DADA      start in a theme (Normal, DADA, REN)

  Estimates never stall at 99%: when a step runs past its estimate, the estimate is
  raised (the bar drops back), the extra time is added to that step, and a notice says so.
  Right-click the window for size, theme and other options; Ctrl + scroll resizes it.
#>
param([switch]$Demo, [switch]$SelfTest, [string]$Theme, [string]$Snapshot, [string]$Mode)
# -Snapshot <folder>: renders the window in each theme, with sample activity, to PNG files there.

$ErrorActionPreference = 'Stop'
# Any error that would stop the app is written to %USERPROFILE%\.claude-progress\window-errors.log first.
trap {
  try {
    $d = Join-Path $env:USERPROFILE '.claude-progress'; New-Item -ItemType Directory -Force -Path $d | Out-Null
    Add-Content -Path (Join-Path $d 'window-errors.log') -Value "$(Get-Date -Format s) STOPPED: $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
  } catch {}
  break
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# Lets the window hand unused memory back to Windows (see Performance modes).
Add-Type -Namespace ClaudeProgress -Name Mem -MemberDefinition '[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(System.IntPtr hProcess);'

# Performance modes (right-click > Performance).
#   fps: animation frame rate   refresh: how often state.json is read (ms)
#   anim: smooth motion on/off  glow: outer glow on/off   trim: free unused memory every N seconds (0 = never)
$modes = [ordered]@{
  Saver   = @{ fps = 20; refresh = 1500; anim = $false; glow = $false; trim = 20 }
  Neutral = @{ fps = 40; refresh = 500;  anim = $true;  glow = $true;  trim = 120 }
  Full    = @{ fps = 60; refresh = 250;  anim = $true;  glow = $true;  trim = 0 }
}
$script:perf = $modes.Neutral

$root = Join-Path $env:USERPROFILE '.claude-progress'
$dataDir = if ($Demo) { Join-Path $root 'demo' } else { $root }
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$stateFile = Join-Path $dataDir 'state.json'
$prefsFile = Join-Path $root 'window.json'

# Only one copy in normal mode.
#  - If another copy is still closing (you chose Exit a moment ago), wait for it, then start.
#  - If another copy is running, ask it to show itself (it may be hidden while Claude is idle), then quit.
$script:showSignal = $null
if (-not $Demo -and -not $SelfTest -and -not $Snapshot) {
  $created = $false
  $script:showSignal = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\ClaudeProgressShow')
  $script:mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeProgressWindow')
  $owned = $false
  try {
    $owned = $script:mutex.WaitOne(0)
    if (-not $owned) {
      [void]$script:showSignal.Set()            # a running copy shows itself right away
      $owned = $script:mutex.WaitOne(5000)      # or, if it was closing, we take over once it's gone
    }
  } catch [System.Threading.AbandonedMutexException] { $owned = $true }   # the last copy was closed abruptly
  if (-not $owned) { exit 0 }
}

# ---------- themes ----------
# ui:   colours of the window itself (bg1 -> bg2 is the background gradient, glow is the outer light)
# cats: colours of the step categories, tuned to sit well on that background
$themes = [ordered]@{
  Normal = @{
    badge = $null
    ui = @{
      bg1 = '#F5242220'; bg2 = '#F51A1816'; border = '#33FFFFFF'; glow = '#000000'; glowOpacity = 0.45
      card = '#14FFFFFF'; cardBorder = '#1FFFFFFF'; track = '#2EFFFFFF'; divider = '#22FFFFFF'
      text = '#FFFFFF'; sub = '#C8C3BC'; muted = '#8C867E'
      accent = '#D97757'; done = '#7FB77E'; noticeBg = '#33E5B94E'; noticeText = '#F2D58A'; fail = '#E06C6C'
    }
    cats = @{ read = '#6FB3D2'; edit = '#7FB77E'; run = '#E5B94E'; render = '#D97757'; web = '#B48EDB'; agent = '#E58FB4'; other = '#9AA0A6'; think = '#756F66' }
  }
  DADA = @{
    badge = 'DADA'
    ui = @{
      bg1 = '#F72A1747'; bg2 = '#F7130A26'; border = '#66B98BFF'; glow = '#A66BFF'; glowOpacity = 0.55
      card = '#1AC9A2FF'; cardBorder = '#38C9A2FF'; track = '#2ED9C2FF'; divider = '#33C9A2FF'
      text = '#FFFFFF'; sub = '#E0D2FA'; muted = '#A592C9'
      accent = '#C38BFF'; done = '#9BE8C0'; noticeBg = '#33FF8FD8'; noticeText = '#FFC9EE'; fail = '#FF7A9C'
    }
    cats = @{ read = '#8EC5FF'; edit = '#9BE8C0'; run = '#FFD37A'; render = '#FF8FD8'; web = '#C9A2FF'; agent = '#FF9E7A'; other = '#B8B0D4'; think = '#7A68A8' }
  }
  Ren = @{
    badge = 'REN'
    ui = @{
      bg1 = '#F7102540'; bg2 = '#F7070F22'; border = '#665CBDFF'; glow = '#3AA8FF'; glowOpacity = 0.55
      card = '#1A5CBDFF'; cardBorder = '#385CBDFF'; track = '#2EA8D8FF'; divider = '#335CBDFF'
      text = '#FFFFFF'; sub = '#CCE0F5'; muted = '#7FA0C4'
      accent = '#4FB8FF'; done = '#7FE3C4'; noticeBg = '#3348C6FF'; noticeText = '#BFE8FF'; fail = '#FF8A8A'
    }
    cats = @{ read = '#7FD8FF'; edit = '#7FE3C4'; run = '#FFD580'; render = '#FF9F7A'; web = '#A9B8FF'; agent = '#F0A6D8'; other = '#A8B8CC'; think = '#5578A8' }
  }
}
$catNames = [ordered]@{ read = 'Reading'; edit = 'Editing'; run = 'Running'; render = 'Rendering'; web = 'Web'; agent = 'Agent'; other = 'Other'; think = 'Thinking' }

[xml]$windowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Progress" SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
  <!-- Fixed width: the window keeps its right edge when minimized (the empty part is click-through). -->
  <Grid Margin="14" Width="440">
    <Grid.LayoutTransform>
      <ScaleTransform x:Name="Zoom" ScaleX="1" ScaleY="1"/>
    </Grid.LayoutTransform>
    <Grid.Resources>
      <!-- Tabular numbers: every digit is the same width, so counting timers and percentages never wobble. -->
      <Style TargetType="TextBlock">
        <Setter Property="Typography.NumeralAlignment" Value="Tabular"/>
      </Style>
    </Grid.Resources>
    <!-- The glow lives on its own static layer, cached as a bitmap, so animating content never re-blurs it. -->
    <Border x:Name="GlowLayer" CornerRadius="14" Background="{DynamicResource ShellBg}" Margin="1"
            HorizontalAlignment="Right" Width="{Binding ActualWidth, ElementName=Shell}">
      <Border.CacheMode><BitmapCache/></Border.CacheMode>
      <Border.Effect>
        <DropShadowEffect x:Name="Glow" BlurRadius="22" ShadowDepth="0" Opacity="0.5" Color="Black"/>
      </Border.Effect>
    </Border>
    <!-- Anchored right: minimizing shrinks the window toward its minimize button. -->
    <Border x:Name="Shell" Width="440" HorizontalAlignment="Right" CornerRadius="14" Background="{DynamicResource ShellBg}" BorderBrush="{DynamicResource ShellBorder}" BorderThickness="1" Padding="14,12">
      <Border.ContextMenu>
        <ContextMenu>
          <MenuItem Header="Theme">
            <MenuItem x:Name="ThemeNormal" Header="Normal" IsCheckable="True"/>
            <MenuItem x:Name="ThemeDADA" Header="DADA  (purple)" IsCheckable="True"/>
            <MenuItem x:Name="ThemeRen" Header="REN  (blue)" IsCheckable="True"/>
          </MenuItem>
          <MenuItem Header="Performance">
            <MenuItem x:Name="ModeSaver" Header="Saver  (least CPU and memory, no animation)" IsCheckable="True"/>
            <MenuItem x:Name="ModeNeutral" Header="Neutral  (smooth and light)" IsCheckable="True"/>
            <MenuItem x:Name="ModeFull" Header="Full power  (smoothest, 60 fps)" IsCheckable="True"/>
          </MenuItem>
          <MenuItem Header="Size (or Ctrl + scroll)">
            <MenuItem x:Name="Size75" Header="Small" IsCheckable="True"/>
            <MenuItem x:Name="Size100" Header="Medium" IsCheckable="True"/>
            <MenuItem x:Name="Size125" Header="Large" IsCheckable="True"/>
            <MenuItem x:Name="Size150" Header="Extra large" IsCheckable="True"/>
          </MenuItem>
          <Separator/>
          <MenuItem x:Name="MenuMini" Header="Minimize  (or double-click)" IsCheckable="True"/>
          <MenuItem x:Name="MenuDetails" Header="Show activity details" IsCheckable="True"/>
          <MenuItem x:Name="MenuProgressOnly" Header="Show only progress" IsCheckable="True"/>
          <MenuItem x:Name="MenuChats" Header="Show regular Claude chats" IsCheckable="True"/>
          <MenuItem x:Name="MenuHideIdle" Header="Hide when Claude is idle" IsCheckable="True"/>
          <MenuItem x:Name="MenuSound" Header="Sound when a long job finishes" IsCheckable="True"/>
          <Separator/>
          <MenuItem x:Name="MenuReset" Header="Move to bottom-right corner"/>
          <MenuItem x:Name="MenuExit" Header="Exit"/>
        </ContextMenu>
      </Border.ContextMenu>
      <StackPanel>
        <DockPanel LastChildFill="True">
          <Ellipse x:Name="Dot" Width="9" Height="9" Fill="{DynamicResource Done}" Margin="0,0,8,0" VerticalAlignment="Center" DockPanel.Dock="Left"/>
          <!-- 24px target with a soft hover highlight. -->
          <Border x:Name="MinHit" DockPanel.Dock="Right" Width="24" Height="24" CornerRadius="6" Margin="6,-4,-6,-4" VerticalAlignment="Center" Cursor="Hand" ToolTip="Minimize" Background="Transparent">
            <Grid>
              <Border x:Name="MinHover" CornerRadius="6" Background="{DynamicResource Track}" Opacity="0"/>
              <TextBlock x:Name="MinBtn" Text="&#xE921;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{DynamicResource TextMuted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <Border x:Name="Badge" DockPanel.Dock="Right" CornerRadius="8" Padding="8,1" Margin="8,0,0,0" VerticalAlignment="Center" Background="{DynamicResource BadgeBg}" BorderBrush="{DynamicResource Accent}" BorderThickness="1">
            <TextBlock x:Name="BadgeText" Foreground="{DynamicResource Accent}" FontFamily="Segoe UI" FontSize="10" FontWeight="Bold"/>
          </Border>
          <TextBlock x:Name="Count" DockPanel.Dock="Right" Typography.NumeralAlignment="Tabular" Foreground="{DynamicResource TextMuted}" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center"/>
          <TextBlock x:Name="Title" Foreground="{DynamicResource TextMain}" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <!-- Shown only when minimized: the first working chat's whole-job progress. -->
        <Border x:Name="MiniTrack" Height="5" CornerRadius="2.5" Margin="0,9,0,1" Background="{DynamicResource Track}" Visibility="Collapsed">
          <Border x:Name="MiniFill" CornerRadius="2.5" HorizontalAlignment="Left" Width="0" Background="{DynamicResource Accent}"/>
        </Border>
        <StackPanel x:Name="Sessions"/>
        <WrapPanel x:Name="Legend" Margin="0,8,0,0"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

# One card per chat. Colours come from the window's theme resources.
$cardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="10" Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1" Padding="12,10" Margin="0,10,0,0">
  <StackPanel>
    <DockPanel LastChildFill="True">
      <Ellipse x:Name="Dot" Width="7" Height="7" Fill="{DynamicResource Accent}" Margin="0,0,7,0" VerticalAlignment="Center" DockPanel.Dock="Left"/>
      <TextBlock x:Name="Clock" DockPanel.Dock="Right" Typography.NumeralAlignment="Tabular" MinWidth="46" TextAlignment="Right" Foreground="{DynamicResource TextMain}" FontFamily="Segoe UI" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center" Margin="8,0,0,0"/>
      <TextBlock x:Name="Chat" Foreground="{DynamicResource TextSub}" FontFamily="Segoe UI" FontSize="11.5" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    </DockPanel>

    <StackPanel x:Name="NowPanel" Margin="0,8,0,0">
      <TextBlock x:Name="NowLabel" Foreground="{DynamicResource TextMain}" FontFamily="Segoe UI" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="NowDetail" Foreground="{DynamicResource TextMuted}" FontFamily="Consolas" FontSize="11.5" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
    </StackPanel>

    <StackPanel x:Name="JobPanel" Margin="0,9,0,0">
      <DockPanel x:Name="JobHead">
        <TextBlock x:Name="TurnPct" DockPanel.Dock="Right" Typography.NumeralAlignment="Tabular" MinWidth="34" TextAlignment="Right" Foreground="{DynamicResource TextMain}" FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold"/>
        <TextBlock Text="WHOLE JOB" Foreground="{DynamicResource TextMuted}" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"/>
      </DockPanel>
      <Border x:Name="JobBar" CornerRadius="5" Background="{DynamicResource Track}" Height="12" Margin="0,4,0,0">
        <Border.LayoutTransform><ScaleTransform x:Name="JobBarScale" ScaleX="1" ScaleY="1"/></Border.LayoutTransform>
        <Canvas x:Name="Seg" Height="12"/>
      </Border>
      <TextBlock x:Name="TurnText" Typography.NumeralAlignment="Tabular" LineHeight="17" LineStackingStrategy="BlockLineHeight" Foreground="{DynamicResource TextSub}" FontFamily="Segoe UI" FontSize="11.5" Margin="0,5,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <StackPanel x:Name="TeamPanel" Margin="0,11,0,0" Visibility="Collapsed">
      <TextBlock x:Name="TeamHead" Text="TEAM" Foreground="{DynamicResource TextMuted}" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"/>
      <StackPanel x:Name="Team" Margin="0,6,0,0"/>
    </StackPanel>

    <StackPanel x:Name="StepPanel" Margin="0,9,0,0">
      <DockPanel>
        <TextBlock x:Name="StepPct" DockPanel.Dock="Right" Typography.NumeralAlignment="Tabular" MinWidth="34" TextAlignment="Right" Foreground="{DynamicResource TextMain}" FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold"/>
        <TextBlock x:Name="StepHead" Text="THIS STEP" Foreground="{DynamicResource TextMuted}" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold"/>
      </DockPanel>
      <Border x:Name="StepTrack" CornerRadius="3.5" Background="{DynamicResource Track}" Height="7" Margin="0,4,0,0">
        <Border x:Name="StepFill" CornerRadius="3.5" HorizontalAlignment="Left" Width="0"/>
      </Border>
      <TextBlock x:Name="StepText" Typography.NumeralAlignment="Tabular" LineHeight="17" LineStackingStrategy="BlockLineHeight" Foreground="{DynamicResource TextSub}" FontFamily="Segoe UI" FontSize="11.5" Margin="0,4,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <Border x:Name="Notice" CornerRadius="7" Background="{DynamicResource NoticeBg}" Padding="8,5" Margin="0,8,0,0" Visibility="Collapsed">
      <TextBlock x:Name="NoticeText" LineHeight="17" LineStackingStrategy="BlockLineHeight" Foreground="{DynamicResource NoticeText}" FontFamily="Segoe UI" FontSize="11.5" TextWrapping="Wrap"/>
    </Border>

    <StackPanel x:Name="DetailPanel" Margin="0,10,0,0">
      <Border Height="1" Background="{DynamicResource Divider}" Margin="0,0,0,7"/>
      <TextBlock Text="ACTIVITY" Foreground="{DynamicResource TextMuted}" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold" Margin="0,0,0,3"/>
      <StackPanel x:Name="Activity"/>
    </StackPanel>
  </StackPanel>
</Border>
'@
$cardNames = 'Dot','Clock','Chat','NowPanel','NowLabel','NowDetail','JobPanel','JobHead','JobBar','JobBarScale','TurnPct','Seg','TurnText','TeamPanel','TeamHead','Team','StepPanel','StepPct','StepHead','StepTrack','StepFill','StepText','Notice','NoticeText','DetailPanel','Activity'

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $windowXaml))
$ui = @{}
foreach ($n in 'Shell','GlowLayer','Glow','ModeSaver','ModeNeutral','ModeFull','Zoom','Badge','BadgeText','ThemeNormal','ThemeDADA','ThemeRen','Size75','Size100','Size125','Size150',
               'Dot','Count','Title','Sessions','Legend','MinHit','MinHover','MinBtn','MiniTrack','MiniFill','MenuMini','MenuDetails','MenuProgressOnly','MenuChats','MenuHideIdle','MenuSound','MenuReset','MenuExit') {
  $ui[$n] = $window.FindName($n)
}

$bc = New-Object System.Windows.Media.BrushConverter
function New-Brush([string]$hex) { $b = $bc.ConvertFromString($hex); $b.Freeze(); $b }
function New-Color([string]$hex) { [System.Windows.Media.ColorConverter]::ConvertFromString($hex) }

# Current theme's brushes, used by code that draws (bars, activity rows, legend).
$script:T = @{}
$script:catBrush = @{}
function Get-CatBrush($cat) { if ($script:catBrush.ContainsKey([string]$cat)) { $script:catBrush[[string]$cat] } else { $script:catBrush['other'] } }
function Get-CatName($cat) { if ($catNames.Contains([string]$cat)) { $catNames[[string]$cat] } else { 'Other' } }

function Build-Legend {
  $ui.Legend.Children.Clear()
  foreach ($k in $catNames.Keys) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.Margin = '0,0,7,2'
    $r = New-Object System.Windows.Shapes.Rectangle
    $r.Width = 7; $r.Height = 7; $r.RadiusX = 2; $r.RadiusY = 2; $r.Fill = Get-CatBrush $k; $r.Margin = '0,0,3,0'; $r.VerticalAlignment = 'Center'
    if ($k -eq 'think') { $r.Height = 3; $r.RadiusX = 1; $r.RadiusY = 1 }   # matches the thin thinking band in the bar
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $catNames[$k]; $t.Foreground = $script:T.muted; $t.FontSize = 10; $t.FontFamily = 'Segoe UI'
    [void]$sp.Children.Add($r); [void]$sp.Children.Add($t)
    [void]$ui.Legend.Children.Add($sp)
  }
}

# Applies a theme to the whole window (cards follow through the shared resources).
function Set-Theme([string]$name, [bool]$save = $true) {
  if (-not $themes.Contains($name)) { $name = 'Normal' }
  $th = $themes[$name]; $c = $th.ui
  $res = $window.Resources
  $setRes = { param($k, $v) [void]$res.Remove($k); $res.Add($k, $v.PSObject.BaseObject) }
  $grad = New-Object System.Windows.Media.LinearGradientBrush((New-Color $c.bg1), (New-Color $c.bg2), 60.0)
  $grad.Freeze()
  & $setRes 'ShellBg' $grad
  $map = @{ ShellBorder = 'border'; CardBg = 'card'; CardBorder = 'cardBorder'; Track = 'track'; Divider = 'divider'; TextMain = 'text'; TextSub = 'sub'; TextMuted = 'muted'; Accent = 'accent'; Done = 'done'; NoticeBg = 'noticeBg'; NoticeText = 'noticeText' }
  foreach ($k in $map.Keys) { & $setRes $k (New-Brush $c[$map[$k]]) }
  $badgeBg = New-Object System.Windows.Media.SolidColorBrush((New-Color $c.accent))
  $badgeBg.Opacity = 0.16; $badgeBg.Freeze()
  & $setRes 'BadgeBg' $badgeBg

  $script:T = @{}
  foreach ($k in $c.Keys) { if ($c[$k] -is [string] -and $c[$k].StartsWith('#')) { $script:T[$k] = New-Brush $c[$k] } }
  $script:catBrush = @{}
  foreach ($k in $th.cats.Keys) { $script:catBrush[$k] = New-Brush $th.cats[$k] }

  $ui.Glow.Color = New-Color $c.glow
  $ui.Glow.Opacity = $c.glowOpacity
  if ($th.badge) { $ui.BadgeText.Text = $th.badge; $ui.Badge.Visibility = 'Visible' } else { $ui.Badge.Visibility = 'Collapsed' }
  $ui.ThemeNormal.IsChecked = ($name -eq 'Normal'); $ui.ThemeDADA.IsChecked = ($name -eq 'DADA'); $ui.ThemeRen.IsChecked = ($name -eq 'Ren')
  Build-Legend
  $script:themeName = $name
  if ($save) { $prefs.theme = $name; Save-Prefs }
}

function New-Card {
  $el = [Windows.Markup.XamlReader]::Parse($cardXaml)
  $c = @{ root = $el; noticeInfo = $null; wasBusy = $false; busySince = 0; leaving = $false; removeAt = 0; lastPct = 0; lastScale = 0; segW = 0; noticeHideAt = $null
          compact = $false; settleAt = 0 }
  foreach ($n in $cardNames) { $c[$n] = $el.FindName($n) }
  # Cards fade in and rise a few pixels when they appear (see Show-Element), and shrink a little
  # as they leave (scale from the top edge).
  $c.scale = New-Object System.Windows.Media.ScaleTransform(1, 1)
  $tg = New-Object System.Windows.Media.TransformGroup
  [void]$tg.Children.Add($c.scale); [void]$tg.Children.Add((New-Object System.Windows.Media.TranslateTransform))
  $el.RenderTransform = $tg
  $el.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0)
  $el.Opacity = 0
  $c.Notice.RenderTransform = New-Object System.Windows.Media.TranslateTransform
  return $c
}

if ($SelfTest) {
  $prefs = @{}
  foreach ($name in $themes.Keys) { Set-Theme $name $false; $card = New-Card; [void]$ui.Sessions.Children.Add($card.root) }
  Write-Output "Window built OK (themes: $($themes.Keys -join ', '))"
  exit 0
}

# ---------- preferences ----------
$prefs = @{ left = $null; top = $null; hideIdle = $false; sound = $true; details = $true; scale = 1.0; theme = 'Normal'; mode = 'Neutral'; mini = $false; chats = $true; progressOnly = $false }
if (Test-Path $prefsFile) {
  try {
    $p = Get-Content $prefsFile -Raw | ConvertFrom-Json
    foreach ($k in 'left','top','hideIdle','sound','details','scale','theme','mode','mini','chats','progressOnly') { if ($null -ne $p.$k) { $prefs[$k] = $p.$k } }
  } catch {}
}
if ($Theme) { $prefs.theme = $Theme }
if ($Mode) { $prefs.mode = $Mode }
if ($Snapshot) { $prefs.scale = 1.0; $prefs.details = $true; $prefs.progressOnly = $false; $prefs.hideIdle = $false; $prefs.left = -10000; $prefs.top = -10000 }
function Save-Prefs {
  if ($Demo -or $Snapshot) { return }   # the demo and previews never change your saved settings
  if ($window.IsLoaded) { $prefs.left = $window.Left; $prefs.top = $window.Top }
  $prefs | ConvertTo-Json | Set-Content -Path $prefsFile -Encoding utf8
}
function Move-ToCorner {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $h = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { 300 }
  $w = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { 468 }
  $window.Left = $wa.Right - $w - 4
  $window.Top = $wa.Bottom - $h - 4
}

# Theme menu
$ui.ThemeNormal.Add_Click({ Set-Theme 'Normal' })
$ui.ThemeDADA.Add_Click({ Set-Theme 'DADA' })
$ui.ThemeRen.Add_Click({ Set-Theme 'Ren' })
Set-Theme ([string]$prefs.theme) $false

# Size: scales the whole window, from 60% to 200%.
$sizes = @{ Size75 = 0.75; Size100 = 1.0; Size125 = 1.25; Size150 = 1.5 }
function Set-Scale([double]$v, [bool]$save = $true) {
  $v = [math]::Round([math]::Min(2.0, [math]::Max(0.6, $v)), 2)
  $prefs.scale = $v
  $ui.Zoom.ScaleX = $v; $ui.Zoom.ScaleY = $v
  foreach ($k in $sizes.Keys) { $ui[$k].IsChecked = ([math]::Abs($sizes[$k] - $v) -lt 0.01) }
  if ($save) { Save-Prefs }
}
foreach ($k in $sizes.Keys) {
  $ui[$k].Tag = $sizes[$k]
  $ui[$k].Add_Click({ param($sender, $ev) Set-Scale ([double]$sender.Tag) })
}
$ui.Shell.Add_PreviewMouseWheel({
  param($sender, $ev)
  if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
    $step = if ($ev.Delta -gt 0) { 0.05 } else { -0.05 }
    Set-Scale ($prefs.scale + $step)
    $ev.Handled = $true
  }
})
Set-Scale ([double]$prefs.scale) $false

$ui.MenuDetails.IsChecked = [bool]$prefs.details
$ui.MenuHideIdle.IsChecked = [bool]$prefs.hideIdle
$ui.MenuSound.IsChecked = [bool]$prefs.sound
$ui.MenuDetails.Add_Click({ $prefs.details = $ui.MenuDetails.IsChecked; Save-Prefs })
# Show only progress: every card becomes a slim row (name, % and time left, the coloured timeline).
# The cards fold or open on the next refresh (see Update-ActiveCard / Update-FinishedCard).
$ui.MenuProgressOnly.IsChecked = [bool]$prefs.progressOnly
$ui.MenuProgressOnly.Add_Click({ $prefs.progressOnly = $ui.MenuProgressOnly.IsChecked; Save-Prefs })
$ui.MenuHideIdle.Add_Click({ $prefs.hideIdle = $ui.MenuHideIdle.IsChecked; Save-Prefs })

# Regular Claude chats have no hooks: chat-watch.ps1 reads the Claude app's window and reports them.
$script:chatWatch = $null
function Set-ChatWatch([bool]$on) {
  if ($Demo -or $Snapshot -or $SelfTest) { return }
  if ($script:chatWatch -and -not $script:chatWatch.HasExited) { try { $script:chatWatch.Kill() } catch {} }
  $script:chatWatch = $null
  $watcher = Join-Path $PSScriptRoot 'chat-watch.ps1'
  if ($on -and (Test-Path $watcher)) {
    $every = if ($script:perf.trim -gt 0 -and $script:perf.fps -le 20) { 3000 } else { 1500 }
    $script:chatWatch = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$watcher`"", '-ParentPid', $PID, '-IntervalMs', $every)
  }
}
$ui.MenuChats.IsChecked = [bool]$prefs.chats
$ui.MenuChats.Add_Click({ $prefs.chats = $ui.MenuChats.IsChecked; Save-Prefs; Set-ChatWatch $prefs.chats })
$ui.MenuSound.Add_Click({ $prefs.sound = $ui.MenuSound.IsChecked; Save-Prefs })
$ui.MenuReset.Add_Click({ Move-ToCorner; Save-Prefs })
$ui.MenuExit.Add_Click({ $window.Close() })
# Minimize: shrink to a slim bar (status, time left, a thin progress line). The window has no
# taskbar button, so a real minimize would make it vanish.
# Origin-aware: the window is anchored at its right edge, so it shrinks toward the button you clicked,
# and the full view folds down into the slim bar (width and height morph together). Restore unfolds
# from the same corner.
function Write-UiError($err) {
  try { Add-Content -Path (Join-Path $root 'window-errors.log') -Value "$(Get-Date -Format s) $($err.Exception.Message) @ line $($err.InvocationInfo.ScriptLineNumber)" } catch {}
}
function Set-Mini([bool]$on, [bool]$save = $true) {
  $morph = $save -and $script:perf.anim -and -not $Snapshot -and $window.IsLoaded
  $oldW = $ui.Shell.ActualWidth; $oldH = $ui.Shell.ActualHeight
  $prefs.mini = $on
  $ui.MenuMini.IsChecked = $on
  $ui.MinBtn.Text = if ($on) { [string][char]0xE923 } else { [string][char]0xE921 }
  $ui.MinHit.ToolTip = if ($on) { 'Restore' } else { 'Minimize' }
  $newW = if ($on) { 330 } else { 440 }
  # (Set-Mini also runs at startup, before the motion section defines $P_Width / $P_Height.)
  $ui.Shell.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $null)
  $ui.Shell.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $null)
  $ui.Shell.Width = $newW
  if ($save) { Save-Prefs; try { Update-View } catch {} }
  if ($morph) {
    $ui.Shell.Measure((New-Object System.Windows.Size($newW, [double]::PositiveInfinity)))
    $newH = $ui.Shell.DesiredSize.Height
    $ui.Shell.ClipToBounds = $true
    Set-PropAnim $ui.Shell $P_Width $oldW $newW 300 $true
    Set-PropAnim $ui.Shell $P_Height $oldH $newH 300 $true
    if (-not $on) { $ui.Sessions.BeginAnimation($P_Opacity, $null); $ui.Sessions.Opacity = 0; Move-To $ui.Sessions $P_Opacity 1 300 }
  }
}
# Affordance: a soft highlight under the button while the pointer is over it (150ms ease).
$ui.MinHit.Add_MouseEnter({ Move-To $ui.MinHover $P_Opacity 1 150; $ui.MinBtn.Foreground = $script:T.text })
$ui.MinHit.Add_MouseLeave({ Move-To $ui.MinHover $P_Opacity 0 150; $ui.MinBtn.Foreground = $script:T.muted })
$ui.MinHit.Add_MouseLeftButtonDown({ param($sender, $ev) $ev.Handled = $true; try { Set-Mini (-not $prefs.mini) } catch { Write-UiError $_ } })
$ui.MenuMini.Add_Click({ try { Set-Mini ([bool]$ui.MenuMini.IsChecked) } catch { Write-UiError $_ } })
$ui.Shell.Add_MouseLeftButtonDown({
  param($sender, $ev)
  if ($ev.ClickCount -eq 2) { try { Set-Mini (-not $prefs.mini) } catch { Write-UiError $_ }; return }
  try { $window.DragMove(); Save-Prefs } catch {}
})
if (-not $Snapshot) { Set-Mini ([bool]$prefs.mini) $false }
# Keep the window on screen as cards come and go.
$window.Add_SizeChanged({
  $wa = [System.Windows.SystemParameters]::WorkArea
  if ($window.Top + $window.ActualHeight -gt $wa.Bottom) { $window.Top = [math]::Max($wa.Top, $wa.Bottom - $window.ActualHeight - 4) }
})

# ---------- helpers ----------
function Format-Ms([double]$ms) {
  $t = [math]::Max(0, [math]::Round($ms / 1000))
  $m = [math]::Floor($t / 60)
  if ($m -gt 0) { return ('{0}m {1:00}s' -f $m, ($t % 60)) }
  return ('{0}s' -f $t)
}
function Get-List($x) { if ($null -eq $x) { return @() } return @($x) }

# A readable name for a chat: its folder, plus the start of the message that started this job.
function Get-ChatName($s) {
  $folder = if ($s.cwd) { ([string]$s.cwd -replace '[\\/]+$', '') -replace '^.*[\\/]', '' } else { '' }
  if (-not $folder -or $folder -like 'scratch-*') { $folder = 'No folder' }
  if ($s.title) { return "$folder  ·  $($s.title)" }
  return $folder
}

# ---------- motion ----------
# Data arrives every 500ms. Continuous values (bars, the growing timeline segment) are handed a
# target slightly AHEAD in time and glide to it linearly, so they move steadily instead of stepping.
# State changes (a re-estimate pulling a bar back, cards and notices entering or leaving) use a
# strong ease-out. With Windows animations turned off, movement is dropped and fades are kept.
$LEAD = 600   # ms ahead; a little over one refresh, so motion never stalls between refreshes
$script:reduce = -not [System.Windows.SystemParameters]::ClientAreaAnimation
$easeOut = New-Object System.Windows.Media.Animation.KeySpline(0.23, 1, 0.32, 1)
$P_Opacity = [System.Windows.UIElement]::OpacityProperty
$P_Width = [System.Windows.FrameworkElement]::WidthProperty
$P_ScaleX = [System.Windows.Media.ScaleTransform]::ScaleXProperty
$P_X = [System.Windows.Media.TranslateTransform]::XProperty
$P_Y = [System.Windows.Media.TranslateTransform]::YProperty

# Animates one property from wherever it is now. 'linear' for steady progress, 'out' for state changes.
function Move-To($target, $prop, [double]$to, [int]$ms, [string]$ease = 'out', [int]$delay = 0) {
  if ($Snapshot -or $ms -le 0 -or -not $script:perf.anim) { $target.BeginAnimation($prop, $null); $target.SetValue($prop, $to); return }
  if ($ease -eq 'linear') {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $to
    $a.Duration = [System.Windows.Duration]([TimeSpan]::FromMilliseconds($ms))
  } else {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $kt = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($ms))
    [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame($to, $kt, $easeOut)))
  }
  [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $script:perf.fps)
  if ($delay -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($delay) }
  $target.BeginAnimation($prop, $a)
}

# Fade in, rising $rise pixels (cards, notices). 220ms ease-out.
function Show-Element($el, [double]$rise, [int]$delay = 0) {
  $el.BeginAnimation($P_Opacity, $null); $el.Opacity = 0
  Move-To $el $P_Opacity 1 220 'out' $delay
  $tt = $el.RenderTransform
  if ($tt -is [System.Windows.Media.TransformGroup]) { $tt = @($tt.Children | Where-Object { $_ -is [System.Windows.Media.TranslateTransform] })[0] }
  if ($tt -is [System.Windows.Media.TranslateTransform]) {
    if ($script:reduce -or $rise -eq 0) { Move-To $tt $P_Y 0 0 } else { $tt.BeginAnimation($P_Y, $null); $tt.Y = $rise; Move-To $tt $P_Y 0 220 'out' $delay }
  }
}

# Fills the step bar. Moving forward it glides linearly to where it will be a moment from now;
# a re-estimate pulls it back with an ease-out. $null means no estimate yet: a gentle pulse.
# ---------- reveal / fold ----------
# Parts that appear (a step's bar, the notice, a detail line, a new card) grow open: height and
# opacity animate together with the strong ease-out, so everything below slides down instead of
# jumping. Parts that go away fold closed the same way, then collapse. Saver mode stays instant.
$P_Height = [System.Windows.FrameworkElement]::HeightProperty
$script:folding = @{}

# Animates Height from -> to. $release: hand back to automatic height when done.
function Set-HeightAnim($el, [double]$from, [double]$to, [int]$ms, [bool]$release, [int]$delay = 0) {
  Set-PropAnim $el $P_Height $from $to $ms $release $delay
}
# Animates any size property from -> to with the strong ease-out, optionally after a delay (stagger).
function Set-PropAnim($el, $prop, [double]$from, [double]$to, [int]$ms, [bool]$release, [int]$delay = 0) {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
  if ($delay -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($delay) }
  [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame($from, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero))))
  $kt = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($ms))
  [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame($to, $kt, $easeOut)))
  if ($release) { $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop }
  [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $script:perf.fps)
  $el.BeginAnimation($prop, $a)
}

# Height the element wants at its parent's width (without its margin).
function Get-NaturalHeight($el) {
  $pw = 0; if ($el.Parent -is [System.Windows.FrameworkElement]) { $pw = $el.Parent.ActualWidth }
  if ($pw -le 0) { $pw = 400 }
  # Its children may have just changed (shown, hidden, height animation removed): without this,
  # WPF hands back the size it measured last time.
  $el.InvalidateMeasure()
  $el.Measure((New-Object System.Windows.Size($pw, [double]::PositiveInfinity)))
  return [math]::Max(0, $el.DesiredSize.Height - $el.Margin.Top - $el.Margin.Bottom)
}

function Set-Shown($el, [bool]$show, [double]$now) {
  $id = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($el)
  $folding = $script:folding.ContainsKey($id)
  $instant = $Snapshot -or -not $script:perf.anim
  if ($show) {
    if ($el.Visibility -eq 'Visible' -and -not $folding) { return }
    $from = if ($el.Visibility -eq 'Visible') { $el.ActualHeight } else { 0 }
    if ($folding) { $script:folding.Remove($id) }
    $el.Visibility = 'Visible'
    $el.BeginAnimation($P_Height, $null)
    if ($instant) { $el.BeginAnimation($P_Opacity, $null); $el.Opacity = 1; return }
    $el.ClipToBounds = $true
    $to = Get-NaturalHeight $el
    if ($from -eq 0) { $el.BeginAnimation($P_Opacity, $null); $el.Opacity = 0 }
    Set-HeightAnim $el $from $to 240 $true
    Move-To $el $P_Opacity 1 240
  } else {
    if ($el.Visibility -ne 'Visible' -or $folding) { return }
    if ($instant) { $el.Visibility = 'Collapsed'; return }
    $el.ClipToBounds = $true
    Set-HeightAnim $el $el.ActualHeight 0 180 $false
    Move-To $el $P_Opacity 0 160
    $script:folding[$id] = @{ el = $el; at = $now + 200 }
  }
}

# ---------- a finished card minimises, then leaves ----------
# When a chat finishes while other cards are on screen, its card holds for a moment (so "Finished"
# registers), then folds calmly into a one-line "done" row with the finished timeline as a thin
# line; the cards below glide up. After DONE_MS the row fades, shrinks slightly and collapses.
# If the chat starts working again, everything opens back up from wherever it is.
$easeSoft = New-Object System.Windows.Media.Animation.KeySpline(0.25, 0.1, 0.25, 1)   # calm "ease": starts moving at once, settles slowly
$P_Margin = [System.Windows.FrameworkElement]::MarginProperty
$P_ScaleY = [System.Windows.Media.ScaleTransform]::ScaleYProperty
$HOLD_MS = 1200; $FOLD_MS = 900
# Animates a double property from -> to with the soft curve.
function Set-SoftAnim($el, $prop, [double]$from, [double]$to, [int]$ms, [int]$delay = 0, [bool]$release = $false) {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
  if ($delay -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($delay) }
  [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame($from, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero))))
  [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame($to, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($ms)), $easeSoft)))
  if ($release) { $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop }
  [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $script:perf.fps)
  $el.BeginAnimation($prop, $a)
}
# Animates an element's top margin with the soft curve (so gaps close and open smoothly instead of snapping).
function Set-MarginTop($el, [double]$to, [int]$ms, [int]$delay = 0) {
  $m = $el.Margin
  $target = New-Object System.Windows.Thickness($m.Left, $to, $m.Right, $m.Bottom)
  if ($ms -le 0) { $el.BeginAnimation($P_Margin, $null); $el.Margin = $target; return }
  $a = New-Object System.Windows.Media.Animation.ThicknessAnimationUsingKeyFrames
  [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineThicknessKeyFrame($target, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($ms)), $easeSoft)))
  if ($delay -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($delay) }
  [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $script:perf.fps)
  $el.BeginAnimation($P_Margin, $a)
}
function Get-FoldParts($card) { @($card.NowPanel, $card.JobHead, $card.TurnText, $card.TeamPanel, $card.StepPanel, $card.Notice, $card.DetailPanel) }

# Folds a finished card into its one-line "done" row.
function Enter-Compact($card, [double]$now) {
  $card.compact = $true
  $parts = Get-FoldParts $card
  # A card that has never been on screen (a new chat in "Show only progress") has nothing to animate
  # from: fold it instantly, so it grows in at the slim row's height instead of full size first.
  $unseen = -not $card.root.IsLoaded
  if ($unseen -or $Snapshot -or -not $script:perf.anim -or $script:reduce) {
    foreach ($p in $parts) { $p.BeginAnimation($P_Height, $null); $p.BeginAnimation($P_Opacity, $null); $p.Visibility = 'Collapsed' }
    $card.JobBarScale.BeginAnimation($P_ScaleY, $null); $card.JobBarScale.ScaleY = 0.25
    $card.JobPanel.Margin = '0,7,0,0'
    # Windows animations off: a quick fade instead of movement. Saver mode: instant.
    if ($script:reduce -and $script:perf.anim -and -not $Snapshot -and -not $unseen) { $card.root.BeginAnimation($P_Opacity, $null); $card.root.Opacity = 0; Move-To $card.root $P_Opacity 1 200 }
    $card.settleAt = 0
    return
  }
  # Every part above and below the timeline folds its own height and gap to zero on one curve, so
  # the timeline rises into place continuously and the card (and the cards below) follow on their own.
  $card.root.ClipToBounds = $true
  $card.foldMargins = @{}
  $i = 0
  # Details first, so the summary is the last thing to go.
  foreach ($p in @($card.DetailPanel, $card.StepPanel, $card.Notice, $card.TeamPanel, $card.NowPanel, $card.JobHead, $card.TurnText)) {
    if ($p.Visibility -eq 'Visible') {
      $card.foldMargins[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($p)] = $p.Margin.Top
      $p.ClipToBounds = $true
      # The fade starts with the height and lasts longer, so the card never shows as an empty shell.
      Set-SoftAnim $p $P_Opacity $p.Opacity 0 ([int]($FOLD_MS * 0.6)) ([math]::Min(60, $i * 15))
      Set-SoftAnim $p $P_Height $p.ActualHeight 0 $FOLD_MS
      Set-MarginTop $p 0 $FOLD_MS
    }
    $i++
  }
  Set-MarginTop $card.JobPanel 7 $FOLD_MS
  Set-SoftAnim $card.JobBarScale $P_ScaleY $card.JobBarScale.ScaleY 0.25 $FOLD_MS
  $card.Clock.Opacity = 0.2; Move-To $card.Clock $P_Opacity 1 260 'out' 140
  $card.settleAt = $now + $FOLD_MS + 40
}
# Once the fold has finished: collapse the folded parts and hand the height back to layout.
function Complete-Compact($card) {
  $card.settleAt = 0
  # The folded parts are already 0 tall with no gap: collapsing them now changes nothing on screen.
  foreach ($p in (Get-FoldParts $card)) { $p.Visibility = 'Collapsed' }
}
# A minimised card whose chat started working again opens back up from where it is.
function Exit-Compact($card) {
  $card.compact = $false; $card.settleAt = 0
  $root = $card.root
  $from = $root.ActualHeight
  # Give the parts their height and gap back, growing from zero on the same curve as the fold, so the
  # timeline moves down smoothly instead of being pushed out of view; the card glides open (Complete-Expand).
  $ms = if ($script:perf.anim -and -not $script:reduce) { 300 } else { 0 }
  foreach ($p in (Get-FoldParts $card)) {
    $p.BeginAnimation($P_Height, $null)
    $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($p)
    if ($card.foldMargins -and $card.foldMargins.ContainsKey($key)) { Set-MarginTop $p $card.foldMargins[$key] $ms }
  }
  Set-MarginTop $card.JobPanel 9 $ms
  foreach ($p in @($card.NowPanel, $card.JobHead, $card.TurnText)) {
    $p.Visibility = 'Visible'
    if ($ms -gt 0) { $p.ClipToBounds = $true; Set-SoftAnim $p $P_Height 0 (Get-NaturalHeight $p) $ms 0 $true }
  }
  $i = 0
  foreach ($p in (Get-FoldParts $card)) { if ($script:perf.anim) { Move-To $p $P_Opacity 1 220 'out' ($i * 40) } else { $p.BeginAnimation($P_Opacity, $null); $p.Opacity = 1 }; $i++ }
  if ($script:perf.anim) { Set-SoftAnim $card.JobBarScale $P_ScaleY $card.JobBarScale.ScaleY 1 300 } else { $card.JobBarScale.BeginAnimation($P_ScaleY, $null); $card.JobBarScale.ScaleY = 1 }
  $card.Clock.FontWeight = 'SemiBold'; $card.Clock.MaxWidth = [double]::PositiveInfinity
  if ($script:perf.anim) { $card.Clock.Opacity = 0.2; Move-To $card.Clock $P_Opacity 1 260 }
  $card.expandFrom = if ($script:perf.anim -and -not $script:reduce) { $from } else { -1 }
}
# Called after the card's content is filled in: glide from the old height to the new natural one.
function Complete-Expand($card) {
  if ($null -eq $card.expandFrom) { return }
  $from = $card.expandFrom; $card.expandFrom = $null
  $root = $card.root; $root.BeginAnimation($P_Height, $null)
  if ($from -lt 0) { return }
  $root.ClipToBounds = $true
  Set-SoftAnim $root $P_Height $from (Get-NaturalHeight $root) 300 0 $true   # same curve as the parts inside
}
# A card whose chat is no longer shown: fade, shrink a little from the top edge, and collapse
# (with the gap above it), slower and gentler than a snap. Returns ms until it can be removed.
function Start-Leave($card) {
  $root = $card.root
  if ($Snapshot -or -not $script:perf.anim) { $root.Opacity = 0; return 0 }
  if ($script:reduce) { Move-To $root $P_Opacity 0 300; return 320 }
  $full = -not $card.compact
  $root.ClipToBounds = $true
  Set-SoftAnim $root $P_Opacity $root.Opacity 0 420
  Set-SoftAnim $card.scale $P_ScaleX $card.scale.ScaleX 0.96 520
  Set-SoftAnim $card.scale $P_ScaleY $card.scale.ScaleY 0.96 520
  $root.BeginAnimation($P_Height, $null)
  # The row is mostly gone before the cards below start to move up.
  Set-SoftAnim $root $P_Height $root.ActualHeight 0 $(if ($full) { 600 } else { 540 }) 140
  Set-MarginTop $root 0 $(if ($full) { 600 } else { 540 }) 140
  return $(if ($full) { 780 } else { 720 })
}
# A leaving card whose chat came back: open back up from its current size, not from zero.
function Stop-Leave($card) {
  $root = $card.root
  $from = $root.ActualHeight
  $root.BeginAnimation($P_Height, $null)
  if (-not $script:perf.anim) { $root.BeginAnimation($P_Opacity, $null); $root.Opacity = 1; $card.scale.ScaleX = 1; $card.scale.ScaleY = 1; Set-MarginTop $root 10 0; return }
  Move-To $root $P_Opacity 1 280   # takes over from the current (fading) value: no flash
  Move-To $card.scale $P_ScaleX 1 280; Move-To $card.scale $P_ScaleY 1 280
  Set-MarginTop $root 10 280
  $card.expandFrom = $from
}

# Collapses parts whose fold has finished.
function Complete-Folds([double]$now) {
  foreach ($k in @($script:folding.Keys)) {
    $f = $script:folding[$k]
    if ($now -ge $f.at) { $f.el.Visibility = 'Collapsed'; $f.el.BeginAnimation($P_Height, $null); $script:folding.Remove($k) }
  }
}

function Set-StepFill($card, $pct, $pctAhead) {
  $fill = $card.StepFill
  $w = $card.StepTrack.ActualWidth; if ($w -le 0) { $w = 384 }
  if ($null -eq $pct) {
    if (-not $card.pulsing) {
      $fill.BeginAnimation($P_Width, $null); $fill.Width = $w
      if ($Snapshot -or $script:reduce -or -not $script:perf.anim) { $fill.Opacity = 0.5 } else {
        $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation(0.25, 0.75, [System.Windows.Duration]([TimeSpan]::FromMilliseconds(900)))
        $pulse.AutoReverse = $true; $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $pulse.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
        [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($pulse, [math]::Min(30, $script:perf.fps))
        $fill.BeginAnimation($P_Opacity, $pulse)
      }
      $card.pulsing = $true
    }
    return
  }
  if ($card.pulsing) { $fill.BeginAnimation($P_Opacity, $null); $fill.Opacity = 1; $fill.BeginAnimation($P_Width, $null); $fill.Width = 0; $card.pulsing = $false; $card.lastPct = 0 }
  $px = { param($p) [math]::Max(0, [math]::Min($w, $w * [double]$p / 100)) }
  if ([double]$pct + 0.5 -lt $card.lastPct) {
    Move-To $fill $P_Width (& $px $pct) 350 'out'      # re-estimated: visibly pulled back
    $card.lastPct = [double]$pct
  } else {
    Move-To $fill $P_Width (& $px $pctAhead) $LEAD 'linear'
    $card.lastPct = [double]$pctAhead
  }
}

# ---------- text that wraps well ----------
# Status lines are phrases joined by "  ·  ". Each phrase is kept whole (non-breaking spaces), so a
# line only ever wraps between phrases: no "(usually" on one line and "59s)" alone on the next.
$NBSP = [string][char]0xA0
function Join-Phrases([string]$s) { (($s -split '  ·  ') | ForEach-Object { $_.Trim() -replace ' ', $NBSP }) -join '  ·  ' }
# Sentences: keep (bracketed bits) whole and never leave the last word alone on a line.
function Format-NoWidow([string]$s) {
  $s = [regex]::Replace($s, '\([^)]*\)', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value -replace ' ', $NBSP })
  $i = $s.LastIndexOf(' ')
  if ($i -gt 0) { $s = $s.Substring(0, $i) + $NBSP + $s.Substring($i + 1) }
  return $s
}

# Adaptive estimates, kept per step id / turn id while the window runs.
$script:est = @{}
# Returns the current estimate (ms) for an id, raising it when the work runs past it.
function Get-Estimate($card, [string]$id, [double]$spent, $base, [string]$label, [double]$now) {
  if ($null -eq $base -or [double]$base -lt 1500) { return $null }
  if (-not $script:est.ContainsKey($id)) { $script:est[$id] = @{ value = [double]$base; original = [double]$base; bumps = 0 } }
  $e = $script:est[$id]
  if ($spent -ge $e.value * 0.95) {
    $old = $e.value
    $e.value = $spent * 1.35 + 3000
    $e.bumps++
    if ($label) {
      $card.noticeInfo = @{
        text  = (Format-NoWidow ('↻ {0} is running long (usually {3}). Added +{1}, about{4}{2}{4}left{4}now.' -f $label, (Format-Ms ($e.value - $old)), (Format-Ms ($e.value - $spent)), (Format-Ms $e.original), [char]0xA0))
        until = $now + 7000
      }
    }
  }
  return $e.value
}

# Builds timeline segments and activity rows for one turn.
function Get-Timeline($s, [double]$startAt, [double]$endAt, [double]$now, [bool]$running) {
  $items = @()
  foreach ($l in (Get-List $s.log)) { $items += [pscustomobject]@{ start = [double]$l.startedAt; end = [double]$l.endedAt; cat = $l.cat; label = $l.label; detail = $l.detail; ok = $l.ok; live = $false; id = ''; base = $null; agent = [bool]$l.agent } }
  if ($running -and $s.steps) {
    foreach ($p in $s.steps.PSObject.Properties) {
      $st = $p.Value
      $items += [pscustomobject]@{ start = [double]$st.startedAt; end = $now; cat = $st.cat; label = $st.label; detail = $st.detail; ok = $true; live = $true; id = $p.Name; base = $st.estimateMs; agent = [bool]$st.agent }
    }
  }
  $items = @($items | Sort-Object start)
  $segs = @(); $rows = @(); $cursor = $startAt
  foreach ($it in $items) {
    if ($it.start - $cursor -gt 800) {
      $segs += [pscustomobject]@{ start = $cursor; end = $it.start; cat = 'think' }
      if ($it.start - $cursor -gt 1500) { $rows += [pscustomobject]@{ start = $cursor; end = $it.start; cat = 'think'; label = 'Thinking / planning'; detail = ''; ok = $true; live = $false; id = '' } }
    }
    $st = [math]::Max($it.start, $cursor)
    if ($it.end -gt $st) { $segs += [pscustomobject]@{ start = $st; end = $it.end; cat = $it.cat } }
    $rows += $it
    $cursor = [math]::Max($cursor, $it.end)
  }
  $hasLive = @($items | Where-Object { $_.live }).Count -gt 0
  if (-not $hasLive -and $endAt - $cursor -gt 800) {
    $segs += [pscustomobject]@{ start = $cursor; end = $endAt; cat = 'think' }
    $label = if ($running) { 'Thinking / writing the reply' } else { 'Writing the reply' }
    $rows += [pscustomobject]@{ start = $cursor; end = $endAt; cat = 'think'; label = $label; detail = ''; ok = $true; live = $running; id = '' }
  }
  return @{ segs = $segs; rows = $rows; items = $items }
}

# Draws the timeline. Segments are kept between refreshes and moved with transforms (scale + slide),
# never rebuilt. A segment still running ($liveAt) is aimed $LEAD ms ahead so it grows steadily;
# when the job is re-estimated ($bump) everything eases into its new, shorter place.
function Draw-Segments($card, $segs, [double]$startAt, [double]$scale, [double]$liveAt = 0, [bool]$bump = $false) {
  $w = $card.Seg.ActualWidth; if ($w -le 0) { $w = 384 }
  if ([math]::Abs($w - $card.segW) -gt 0.5) {
    # Rounded ends, matching the track.
    $card.Seg.Clip = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(0, 0, $w, 12)), 5, 5)
    $card.segW = $w
  }
  $kids = $card.Seg.Children
  $i = 0
  foreach ($sg in $segs) {
    $end = [double]$sg.end
    $isLive = ($liveAt -gt 0 -and $end -ge $liveAt - 1)
    if ($isLive) { $end += $LEAD }
    $x = [math]::Min($w, ($sg.start - $startAt) / $scale * $w)
    $len = [math]::Min([math]::Max(2, ($end - $sg.start) / $scale * $w), [math]::Max(0, $w - $x))
    if ($i -lt $kids.Count) {
      $r = $kids[$i]
    } else {
      $r = New-Object System.Windows.Shapes.Rectangle
      $r.Width = 1; $r.Height = 12
      $tg = New-Object System.Windows.Media.TransformGroup
      $sc = New-Object System.Windows.Media.ScaleTransform(0, 1)
      $tr = New-Object System.Windows.Media.TranslateTransform($x, 0)
      [void]$tg.Children.Add($sc); [void]$tg.Children.Add($tr)
      $r.RenderTransform = $tg
      [void]$kids.Add($r)
    }
    $r.Fill = Get-CatBrush $sg.cat
    # Thinking time is drawn as a thinner band, so it reads as "time spent", not empty track.
    if ($sg.cat -eq 'think') { $r.Height = 6; [System.Windows.Controls.Canvas]::SetTop($r, 3) }
    else { $r.Height = 12; [System.Windows.Controls.Canvas]::SetTop($r, 0) }
    $sc = $r.RenderTransform.Children[0]; $tr = $r.RenderTransform.Children[1]
    # Nothing moved since last time: leave it alone (no animation, no redraw).
    $key = '{0:F1}|{1:F1}' -f $x, $len
    if ($r.Tag -eq $key) { $i++; continue }
    $r.Tag = $key
    if ($bump) {
      Move-To $sc $P_ScaleX $len 350 'out'; Move-To $tr $P_X $x 350 'out'
    } elseif ($isLive -or $liveAt -gt 0) {
      Move-To $sc $P_ScaleX $len $LEAD 'linear'; Move-To $tr $P_X $x $LEAD 'linear'
    } else {
      Move-To $sc $P_ScaleX $len 250 'out'; Move-To $tr $P_X $x 250 'out'
    }
    $i++
  }
  while ($kids.Count -gt $i) { $kids.RemoveAt($kids.Count - 1) }
}

# The activity list is rebuilt only when its rows change (a step starts, ends or fails);
# otherwise only the durations are updated in place. A newly added top row fades in.
function Draw-Activity($card, $rows, [int]$max) {
  $show = @($rows | Sort-Object start -Descending | Select-Object -First $max)
  $durText = {
    param($row)
    $spent = $row.end - $row.start
    if ($row.live -and $row.id -and $script:est.ContainsKey($row.id)) { '{0} / ~{1}' -f (Format-Ms $spent), (Format-Ms $script:est[$row.id].value) } else { Format-Ms $spent }
  }
  $sig = $script:themeName + '|' + (($show | ForEach-Object { '{0}/{1}/{2}/{3}/{4}/{5}' -f $_.start, $_.cat, $_.label, $_.detail, $_.ok, $_.live }) -join ';')
  if ($sig -eq $card.actSig -and $card.durs) {
    for ($i = 0; $i -lt $show.Count; $i++) { $card.durs[$i].Text = & $durText $show[$i] }
    return
  }
  $firstBuild = -not $card.actSig
  $newTop = ($card.actSig -and $show.Count -gt 0 -and [double]$show[0].start -ne $card.actTop)
  $card.actSig = $sig
  $card.actTop = if ($show.Count -gt 0) { [double]$show[0].start } else { 0 }
  $card.durs = New-Object System.Collections.ArrayList
  $card.Activity.Children.Clear()
  foreach ($row in $show) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,1,0,1'
    foreach ($wd in 'Auto','*','Auto') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $wd; [void]$g.ColumnDefinitions.Add($c) }
    $mark = New-Object System.Windows.Controls.TextBlock
    $mark.Width = 18; $mark.FontSize = 11; $mark.FontFamily = 'Segoe UI Symbol'; $mark.VerticalAlignment = 'Center'
    if ($row.live) { $mark.Text = '▶'; $mark.Foreground = Get-CatBrush $row.cat }
    elseif ($row.ok -eq $false) { $mark.Text = '✗'; $mark.Foreground = $script:T.fail }
    elseif ($row.cat -eq 'think') { $mark.Text = '●'; $mark.FontSize = 8; $mark.Foreground = Get-CatBrush 'think' }
    else { $mark.Text = '✓'; $mark.Foreground = Get-CatBrush $row.cat }
    $txt = New-Object System.Windows.Controls.TextBlock
    $txt.FontFamily = 'Segoe UI'; $txt.FontSize = 11.5; $txt.TextTrimming = 'CharacterEllipsis'; $txt.VerticalAlignment = 'Center'
    $txt.Foreground = if ($row.live) { $script:T.text } else { $script:T.sub }
    $txt.Text = if ($row.detail) { "$($row.label)  ·  $($row.detail)" } else { $row.label }
    $dur = New-Object System.Windows.Controls.TextBlock
    $dur.FontFamily = 'Segoe UI'; $dur.FontSize = 11; [System.Windows.Documents.Typography]::SetNumeralAlignment($dur, 'Tabular'); $dur.MinWidth = 64; $dur.TextAlignment = 'Right'; $dur.Margin = '8,0,0,0'; $dur.VerticalAlignment = 'Center'
    $dur.Foreground = $script:T.muted
    $dur.Text = & $durText $row
    [void]$card.durs.Add($dur)
    [System.Windows.Controls.Grid]::SetColumn($txt, 1); [System.Windows.Controls.Grid]::SetColumn($dur, 2)
    [void]$g.Children.Add($mark); [void]$g.Children.Add($txt); [void]$g.Children.Add($dur)
    [void]$card.Activity.Children.Add($g)
  }
  if ($newTop -and $card.Activity.Children.Count -gt 0) { Show-Element $card.Activity.Children[0] 0 }
  # Stagger: on a card's first appearance its rows fade in one after another, 40ms apart.
  if ($firstBuild -and $script:perf.anim -and -not $Snapshot) {
    for ($r = 0; $r -lt $card.Activity.Children.Count; $r++) { Show-Element $card.Activity.Children[$r] 3 (120 + $r * 40) }
  }
  $card.DetailPanel.Visibility = if ($prefs.details -and $show.Count -gt 0) { 'Visible' } else { 'Collapsed' }
}

# ---------- Team view: what each helper agent (subagent) is doing ----------
# role (set by hook.js) -> colour (a step category), icon (Segoe MDL2 Assets) and words.
$ROLES = @{
  design   = @{ cat = 'render'; icon = [char]0xE790; now = 'is designing';   done = 'finished designing' }
  review   = @{ cat = 'web';    icon = [char]0xE7B3; now = 'is checking';    done = 'finished checking' }
  test     = @{ cat = 'run';    icon = [char]0xEBE8; now = 'is testing';     done = 'finished testing' }
  plan     = @{ cat = 'agent';  icon = [char]0xE8FD; now = 'is planning';    done = 'finished planning' }
  research = @{ cat = 'read';   icon = [char]0xE721; now = 'is researching'; done = 'finished researching' }
  write    = @{ cat = 'edit';   icon = [char]0xE70F; now = 'is writing';     done = 'finished writing' }
  build    = @{ cat = 'edit';   icon = [char]0xE943; now = 'is building';    done = 'finished building' }
  security = @{ cat = 'run';    icon = [char]0xE72E; now = 'is securing';    done = 'finished securing' }
  manage   = @{ cat = 'agent';  icon = [char]0xE716; now = 'is coordinating'; done = 'finished coordinating' }
  game     = @{ cat = 'render'; icon = [char]0xE7FC; now = 'is making the game'; done = 'finished the game work' }
  academic = @{ cat = 'read';   icon = [char]0xE8F1; now = 'is studying';    done = 'finished studying' }
  teach    = @{ cat = 'read';   icon = [char]0xE7BE; now = 'is teaching';    done = 'finished teaching' }
  data     = @{ cat = 'web';    icon = [char]0xE9D2; now = 'is analysing';   done = 'finished analysing' }
  ops      = @{ cat = 'run';    icon = [char]0xE753; now = 'is deploying';   done = 'finished deploying' }
  marketing = @{ cat = 'render'; icon = [char]0xE789; now = 'is promoting';  done = 'finished promoting' }
  other    = @{ cat = 'agent';  icon = [char]0xE99A; now = 'is working';     done = 'finished' }
}
$MAX_TEAM = 5
function Get-AgentName([string]$t) {
  switch -CaseSensitive ($t) { 'general-purpose' { return 'Helper' } 'Explore' { return 'Explorer' } 'Plan' { return 'Planner' } }
  # "security-reviewer" -> "Security reviewer"; names with capitals ("UI Finish-Gate Reviewer") stay as they are.
  $t = $t -replace '_+', ' '
  if ($t -cnotmatch '[A-Z]') { $t = $t -replace '-+', ' ' }
  $t = $t.Trim()
  if (-not $t) { return 'Helper' }
  $t.Substring(0, 1).ToUpper() + $t.Substring(1)
}
# The helpers of this job, oldest first, each with its live step and how many steps it has done.
function Get-Team($s, [double]$now, [bool]$running) {
  $members = @(); $live = @(); $done = @{}
  foreach ($l in (Get-List $s.log)) {
    if ($l.by) { $done[[string]$l.by] = 1 + [int]$done[[string]$l.by] }
    if ($l.agent) { $members += [pscustomobject]@{ id = [string]$l.agent; v = $l; start = [double]$l.startedAt; end = [double]$l.endedAt; live = $false } }
  }
  if ($running -and $s.steps) {
    foreach ($p in $s.steps.PSObject.Properties) {
      $v = $p.Value
      if ($v.agent) { $members += [pscustomobject]@{ id = [string]$v.agent; v = $v; start = [double]$v.startedAt; end = $now; live = $true } }
      elseif ($v.by) { $live += $v }
    }
  }
  $members = @($members | Sort-Object start | Select-Object -Last $MAX_TEAM)
  foreach ($m in $members) {
    $who = if ($m.v.who) { [string]$m.v.who } elseif ([string]$m.v.label -match '\((.+)\)$') { $Matches[1] } else { '' }
    $role = if ($ROLES.ContainsKey([string]$m.v.role)) { [string]$m.v.role } else { 'other' }
    $cur = @($live | Where-Object { $_.by -eq $m.id } | Sort-Object { [double]$_.startedAt } -Descending | Select-Object -First 1)
    $m | Add-Member -NotePropertyMembers @{ name = Get-AgentName $who; role = $role; task = [string]$m.v.detail; ok = ($m.v.ok -ne $false); cur = $(if ($cur.Count) { $cur[0] } else { $null }); steps = [math]::Max([int]$done[$m.id], [int]($m.v.done -as [int])) }
  }
  return $members
}
function New-Text([string]$text, [double]$size, $brush) {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $text; $t.FontFamily = 'Segoe UI'; $t.FontSize = $size; $t.Foreground = $brush; $t.TextTrimming = 'CharacterEllipsis'
  $t
}
# Draws the team as a vertical pipeline: a role icon per helper, joined by a line in start order.
# Rebuilt only when something changes; otherwise only the timers are updated.
function Draw-Team($card, $s, [double]$now, [bool]$running) {
  $team = @(Get-Team $s $now $running)
  if ($team.Count -eq 0) { $card.TeamPanel.Visibility = 'Collapsed'; $card.teamSig = $null; return }
  $card.TeamPanel.Visibility = 'Visible'
  $working = @($team | Where-Object { $_.live }).Count
  $head = 'TEAM  ·  ' + $(if ($team.Count -eq 1) { '1 helper agent' } else { "$($team.Count) helper agents" })
  if ($working -and $working -lt $team.Count) { $head += "  ·  $working working" }
  $card.TeamHead.Text = $head
  $timeOf = { param($m) $(if ($m.live) { Format-Ms ($now - $m.start) } else { Format-Ms ($m.end - $m.start) }) }
  $sig = $script:themeName + '|' + (($team | ForEach-Object { '{0}/{1}/{2}/{3}/{4}/{5}' -f $_.id, $_.live, $_.ok, $_.steps, $(if ($_.cur) { $_.cur.label + $_.cur.detail } else { '' }), $_.task }) -join ';')
  if ($sig -eq $card.teamSig -and $card.teamDurs) {
    for ($i = 0; $i -lt $team.Count; $i++) { $card.teamDurs[$i].Text = & $timeOf $team[$i] }
    return
  }
  $card.teamSig = $sig
  $card.teamDurs = New-Object System.Collections.ArrayList
  $card.Team.Children.Clear()
  for ($i = 0; $i -lt $team.Count; $i++) {
    $m = $team[$i]; $r = $ROLES[$m.role]; $rb = Get-CatBrush $r.cat
    $g = New-Object System.Windows.Controls.Grid
    foreach ($wd in 'Auto', '*', 'Auto') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $wd; [void]$g.ColumnDefinitions.Add($c) }

    # Rail: the node, and a line down to the next helper.
    $rail = New-Object System.Windows.Controls.Grid
    $rail.Width = 24
    if ($i -lt $team.Count - 1) {
      $line = New-Object System.Windows.Shapes.Rectangle
      $line.Width = 2; $line.Fill = $script:T.divider; $line.HorizontalAlignment = 'Center'; $line.Margin = '0,24,0,-2'
      [void]$rail.Children.Add($line)
    }
    $node = New-Object System.Windows.Controls.Border
    $node.Width = 24; $node.Height = 24; $node.CornerRadius = 12; $node.VerticalAlignment = 'Top'; $node.BorderThickness = 1.5
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.FontFamily = 'Segoe MDL2 Assets'; $glyph.FontSize = 11; $glyph.HorizontalAlignment = 'Center'; $glyph.VerticalAlignment = 'Center'
    $tint = $rb.Clone(); $tint.Opacity = 0.18
    if ($m.live) { $node.Background = $tint; $node.BorderBrush = $rb; $glyph.Text = $r.icon; $glyph.Foreground = $rb }
    elseif (-not $m.ok) { $node.Background = $tint; $node.BorderBrush = $script:T.fail; $glyph.Text = [char]0xE711; $glyph.Foreground = $script:T.fail }
    else { $node.Background = $tint; $node.BorderBrush = $script:T.done; $glyph.Text = [char]0xE73E; $glyph.Foreground = $script:T.done }
    $node.Child = $glyph
    [void]$rail.Children.Add($node)

    # Who is doing what, the task, and the step it is on now.
    $body = New-Object System.Windows.Controls.StackPanel
    $body.Margin = '9,2,0,10'
    $l1 = New-Text '' 12 $script:T.text
    $nameRun = New-Object System.Windows.Documents.Run($m.name); $nameRun.FontWeight = 'SemiBold'
    $verbRun = New-Object System.Windows.Documents.Run('  ' + $(if ($m.live) { $r.now } elseif (-not $m.ok) { 'stopped with an error' } else { $r.done }))
    $verbRun.Foreground = if ($m.live) { $rb } else { $script:T.sub }
    [void]$l1.Inlines.Add($nameRun); [void]$l1.Inlines.Add($verbRun)
    [void]$body.Children.Add($l1)
    if ($m.task) { $t2 = New-Text $m.task 11.5 $script:T.sub; $t2.Margin = '0,1,0,0'; [void]$body.Children.Add($t2) }
    if ($m.live) {
      if ($m.cur) {
        $what = ([string]$m.cur.label -replace '^.*? › ', '') + $(if ($m.cur.detail) { "  ·  $($m.cur.detail)" } else { '' })
        $t3 = New-Text ('▶  ' + $what) 11 (Get-CatBrush $m.cur.cat)
      } else { $t3 = New-Text 'thinking…' 11 $script:T.muted }
      $t3.Margin = '0,2,0,0'; [void]$body.Children.Add($t3)
    } elseif ($m.steps) {
      $t3 = New-Text $(if ($m.steps -eq 1) { '1 step' } else { "$($m.steps) steps" }) 11 $script:T.muted
      $t3.Margin = '0,1,0,0'; [void]$body.Children.Add($t3)
    }
    $dur = New-Text (& $timeOf $m) 11 $script:T.muted
    [System.Windows.Documents.Typography]::SetNumeralAlignment($dur, 'Tabular'); $dur.Margin = '8,4,0,0'; $dur.VerticalAlignment = 'Top'
    [void]$card.teamDurs.Add($dur)
    [System.Windows.Controls.Grid]::SetColumn($body, 1); [System.Windows.Controls.Grid]::SetColumn($dur, 2)
    [void]$g.Children.Add($rail); [void]$g.Children.Add($body); [void]$g.Children.Add($dur)
    [void]$card.Team.Children.Add($g)
  }
}

# Fills one card for a chat that is working.
function Update-ActiveCard($card, $sid, $s, [double]$now, [int]$maxRows) {
  # Working again (or "Show only progress" turned off): open the card back up.
  if ($card.compact -and -not $prefs.progressOnly) { Exit-Compact $card }
  $card.finSeen = $null
  $card.Clock.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextMain')
  $t0 = [double]$s.turnStartedAt
  $spent = $now - $t0
  $tl = Get-Timeline $s $t0 $now $now $true
  $live = @($tl.items | Where-Object { $_.live } | Sort-Object start -Descending)

  $card.Dot.Fill = $script:T.accent
  $card.Chat.Text = Get-ChatName $s
  $card.Clock.Text = Format-Ms $spent

  $stepRemaining = 0
  if ($live.Count -gt 0) {
    $st = $live[0]
    $stepSpent = $now - $st.start
    $card.NowLabel.Text = if ($live.Count -gt 1) { "$($st.label)   (+$($live.Count - 1) more in parallel)" } else { $st.label }
    $card.NowLabel.Foreground = Get-CatBrush $st.cat
    $card.NowDetail.Text = $st.detail
    Set-Shown $card.NowDetail ([bool]$st.detail) $now
    Set-Shown $card.StepPanel $true $now
    $card.StepFill.Background = Get-CatBrush $st.cat
    $card.StepHead.Text = 'THIS STEP  ·  ' + (Get-CatName $st.cat).ToUpper()
    $stepEst = Get-Estimate $card $st.id $stepSpent $st.base $st.label $now
    if ($null -eq $stepEst) {
      Set-StepFill $card $null $null; $card.StepPct.Text = ''
      $card.StepText.Text = Join-Phrases ('{0} elapsed  ·  first time for this kind of step  ·  learning' -f (Format-Ms $stepSpent))
    } else {
      $pct = [math]::Min(99, $stepSpent / $stepEst * 100)
      $pctAhead = if ($Snapshot) { $pct } else { [math]::Min(99, ($stepSpent + $LEAD) / $stepEst * 100) }   # a still image shows the bar exactly at its number
      Set-StepFill $card $pct $pctAhead
      $card.StepPct.Text = ('{0}%' -f [math]::Floor($pct))
      $stepRemaining = $stepEst - $stepSpent
      $e = $script:est[$st.id]
      $extra = if ($e.bumps -gt 0) { ('  ·  re-estimated {0}x (usually {1})' -f $e.bumps, (Format-Ms $e.original)) } else { ('  ·  usually {0}' -f (Format-Ms $e.original)) }
      $card.StepText.Text = Join-Phrases ('{0} elapsed  ·  about {1} left{2}' -f (Format-Ms $stepSpent), (Format-Ms $stepRemaining), $extra)
    }
  } else {
    $card.NowLabel.Text = 'Thinking / writing the reply'
    $card.NowLabel.Foreground = $script:T.text
    Set-Shown $card.NowDetail $false $now
    Set-Shown $card.StepPanel $false $now
  }
  $card.NowPanel.Visibility = 'Visible'

  # Whole job
  $turnKey = "$sid-turn-$t0"
  $turnEst = Get-Estimate $card $turnKey $spent $s.turnEstimateMs $null $now
  if ($null -ne $turnEst -and $spent + $stepRemaining + 2000 -gt $turnEst) {
    # The current step alone needs more time than the job estimate has left: grow the job estimate.
    $turnEst = $spent + $stepRemaining + 2000
    $script:est[$turnKey].value = $turnEst
  }
  if ($null -eq $turnEst) {
    Draw-Segments $card $tl.segs $t0 ([math]::Max(($spent + $LEAD) * 1.15, 1000)) $now
    $card.lastScale = 0
    $card.jobPct = $null; $card.jobPctAhead = $null; $card.jobLeft = $null; $card.jobSpent = $spent
    $card.TurnPct.Text = ''
    $card.TurnText.Text = Join-Phrases ('{0} elapsed  ·  {1} steps done  ·  no estimate yet, it learns from each job' -f (Format-Ms $spent), (Get-List $s.log).Count)
  } else {
    $bump = ($card.lastScale -gt 0 -and $turnEst -gt $card.lastScale * 1.02)
    Draw-Segments $card $tl.segs $t0 $turnEst $now $bump
    $card.lastScale = $turnEst
    $pct = [math]::Min(99, $spent / $turnEst * 100)
    $card.jobPct = $pct; $card.jobPctAhead = [math]::Min(99, ($spent + $LEAD) / $turnEst * 100); $card.jobLeft = $turnEst - $spent; $card.jobSpent = $spent
    $card.TurnPct.Text = ('{0}%' -f [math]::Floor($pct))
    $te = $script:est[$turnKey]
    $note = if ($te.bumps -gt 0 -or $turnEst -gt $te.original + 1000) { ('  ·  re-estimated (usually {0})' -f (Format-Ms $te.original)) } else { '' }
    $card.TurnText.Text = Join-Phrases ('{0} elapsed  ·  about {1} left  ·  {2} steps done{3}' -f (Format-Ms $spent), (Format-Ms ($turnEst - $spent)), (Get-List $s.log).Count, $note)
  }
  # Helper agents (subagents) still working, including background ones after the reply is done.
  $helpers = 0
  if ($s.steps) { $helpers = @($s.steps.PSObject.Properties | Where-Object { $_.Value.agent }).Count }
  if ($helpers -gt 0 -and $s.waiting) {
    $word = if ($helpers -eq 1) { '1 helper agent' } else { "$helpers helper agents" }
    $card.TurnText.Text += Join-Phrases "  ·  reply done, waiting for $word"
  }
  Draw-Team $card $s $now $true
  Draw-Activity $card @($tl.rows | Where-Object { -not $_.agent }) $maxRows   # helpers are shown in the Team view

  # Notice: grows open while it applies, then folds away.
  if ($card.noticeInfo -and $now -lt $card.noticeInfo.until) {
    $card.NoticeText.Text = $card.noticeInfo.text
    Set-Shown $card.Notice $true $now
  } else {
    Set-Shown $card.Notice $false $now
  }
  if ($prefs.progressOnly) { Set-ProgressRow $card $spent $now }

  if (-not $card.wasBusy) { $card.busySince = $now }
  $card.wasBusy = $true
}

# The slim row's right-hand text: lighter than the chat name, and never more than 60% of the row,
# so the name always keeps room (it is cut with an ellipsis instead).
function Set-RowTextStyle($card) {
  $card.Clock.FontWeight = 'Normal'
  $card.Clock.TextTrimming = 'CharacterEllipsis'
  # A new card has no width yet on its first refresh: use the list's width instead.
  $w = $card.root.ActualWidth; if ($w -le 0) { $w = $ui.Sessions.ActualWidth }
  if ($w -gt 0) { $card.Clock.MaxWidth = [math]::Max(120, $w * 0.6) }
}

# "Show only progress": a working card as one slim row: the chat name, then what it is doing,
# the percentage and the time left, with the live coloured timeline as a thin line underneath.
# The card is filled in as usual first (so the numbers are current), then folded or kept folded.
function Set-ProgressRow($card, [double]$spent, [double]$now) {
  if (-not $card.compact) { Enter-Compact $card $now }
  elseif ($card.settleAt -and $now -ge $card.settleAt) { Complete-Compact $card }
  if (-not $card.settleAt) {
    # Filling the card in may have shown a part again (a new step, a notice): keep them folded.
    foreach ($p in (Get-FoldParts $card)) { if ($p.Visibility -ne 'Collapsed') { $p.BeginAnimation($P_Height, $null); $p.Visibility = 'Collapsed' } }
  }
  $step = ($card.NowLabel.Text -replace '\s+\(\+\d+ more in parallel\)$', '')
  # Short times in the slim row ("~1m" not "~1m 00s"), so the chat name keeps as much room as it can.
  $left = (Format-Ms $card.jobLeft) -replace ' 00s$', ''
  $nums = if ($null -ne $card.jobPct) { '{0}%  ·  ~{1} left' -f [math]::Floor($card.jobPct), $left } else { '{0}  ·  learning' -f ((Format-Ms $spent) -replace ' 00s$', '') }
  $card.Clock.Text = if ($step) { "$step  ·  $nums" } else { $nums }
  Set-RowTextStyle $card
}

# Fills one card for a chat that finished in the last two minutes.
function Update-FinishedCard($card, $s, [double]$now, [int]$maxRows, [bool]$others = $false) {
  if ($card.wasBusy -and $prefs.sound -and ($now - $card.busySince) -gt 30000) { [System.Media.SystemSounds]::Asterisk.Play() }
  $card.wasBusy = $false
  $t0 = [double]$s.lastTurnStartedAt; $t1 = [double]$s.finishedAt
  $tl = Get-Timeline $s $t0 $t1 $now $false
  $card.Dot.Fill = $script:T.done
  $card.Chat.Text = Get-ChatName $s
  $fails = @((Get-List $s.log) | Where-Object { $_.ok -eq $false }).Count
  # Minimise to a one-line "done" row when other cards are on screen (after a short hold, and only
  # if there is time left to see it). A card on its own keeps its full summary.
  # The hold counts from when this card first SHOWED "Finished" (in Saver mode that can be a refresh
  # or two after the chat actually finished), so the summary is always seen before it minimises.
  $age = $now - $t1
  if (-not $card.finSeen) { $card.finSeen = $now }
  if ($card.compact) { if ($card.settleAt -and $now -ge $card.settleAt) { Complete-Compact $card } }
  elseif ($prefs.progressOnly -or ($others -and ($now - $card.finSeen) -ge $HOLD_MS -and ($DONE_MS - $age) -gt 2000)) { Enter-Compact $card $now }
  if ($card.compact) {
    $card.Clock.Foreground = $script:T.sub   # the summary sits quieter than the chat name
    Set-RowTextStyle $card
    $card.Clock.Text = 'Done  ·  {0}  ·  {1} steps{2}' -f (Format-Ms ($t1 - $t0)), (Get-List $s.log).Count, $(if ($fails) { "  ·  $fails failed" } else { '' })
    Draw-Segments $card $tl.segs $t0 ([math]::Max($t1 - $t0, 1000))
    return
  }
  $card.Clock.Text = 'Done'
  $card.NowPanel.Visibility = 'Visible'
  $card.NowLabel.Text = 'Finished'
  $card.NowLabel.Foreground = $script:T.done
  Set-Shown $card.NowDetail $false $now
  Set-Shown $card.StepPanel $false $now
  Set-Shown $card.Notice $false $now
  Draw-Segments $card $tl.segs $t0 ([math]::Max($t1 - $t0, 1000))
  $card.TurnPct.Text = '100%'
  $card.TurnText.Text = Join-Phrases ('Took {0}  ·  {1} steps{2}' -f (Format-Ms ($t1 - $t0)), (Get-List $s.log).Count, $(if ($fails) { "  ·  $fails failed" } else { '' }))
  Draw-Team $card $s $now $false
  Draw-Activity $card @($tl.rows | Where-Object { -not $_.agent }) $maxRows   # helpers are shown in the Team view
}

# ---------- demo ----------
if ($Demo) {
  $hook = Join-Path $PSScriptRoot 'hook.js'
  $demoJs = Join-Path $PSScriptRoot 'demo.js'
  $env:CLAUDE_PROGRESS_DIR = $dataDir
  Start-Process -FilePath 'node' -ArgumentList @("`"$demoJs`"", "`"$hook`"") -WindowStyle Hidden
}

# ---------- refresh loop ----------
# When opened by hand while Claude is idle, show for a few seconds even if "Hide when idle" is on,
# so it's clear the app started.
$script:startedAt = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$GRACE = 6000
$DONE_MS = if ($Demo) { 120000 } else { 8000 }   # how long a finished chat's card stays (the demo keeps them to show the summary)
$script:cards = @{}
$script:seen = @{}; $script:seenN = 0   # the order cards first appeared in (see Update-View)
$script:order = ''
$MAX_CARDS = 10
$MAX_STATE_BYTES = 5MB
$script:lastGoodState = $null
# Install-timing check for testers: the installer writes when it started; the first live card
# after that adds when it appeared (install-timing.json, on this computer only).
# Only a Claude Code job (hooks, not a desktop chat) that started after the install counts, so
# leftover sessions or chats can't make the install look faster than it was.
$script:firstCardNoted = [bool]($Demo -or $Snapshot -or $SelfTest)
$script:installStartedAt = $null
function Set-FirstCard($active, [double]$now) {
  try {
    $f = Join-Path $script:root 'install-timing.json'   # $script: because Update-View has its own $root
    if ($null -eq $script:installStartedAt) {
      if (-not (Test-Path $f) -or (Get-Item $f).Length -gt 4KB) { $script:firstCardNoted = $true; return }
      $t = [IO.File]::ReadAllText($f) | ConvertFrom-Json
      if ($t.firstCardAt -or -not ($t.installerStartedAt -as [double])) { $script:firstCardNoted = $true; return }
      $script:installStartedAt = [double]$t.installerStartedAt
    }
    $fresh = @($active | Where-Object { -not ([string]$_.id).StartsWith('chat:') -and ($_.s.turnStartedAt -as [double]) -ge $script:installStartedAt })
    if ($fresh.Count -eq 0) { return }
    $script:firstCardNoted = $true
    $t = [IO.File]::ReadAllText($f) | ConvertFrom-Json
    if ($t.firstCardAt) { return }
    $t.firstCardAt = [int64]$now
    [IO.File]::WriteAllText($f, ($t | ConvertTo-Json -Compress))
  } catch { $script:firstCardNoted = $true }
}
$script:stateErrorLogged = $false
# Reads state.json without blocking hook.js from replacing it (share read, write and delete).
# If it can't be read or parsed, keep showing the last good state and log the reason once.
function Read-State {
  if (-not (Test-Path $stateFile)) { return $null }
  try {
    $fs = [System.IO.File]::Open($stateFile, 'Open', 'Read', [System.IO.FileShare]'ReadWrite, Delete')
    try {
      if ($fs.Length -gt $MAX_STATE_BYTES) { throw "state.json is too large ($($fs.Length) bytes)" }
      $text = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)).ReadToEnd()
    } finally { $fs.Dispose() }
    $script:lastGoodState = $text | ConvertFrom-Json
    $script:stateErrorLogged = $false
  } catch {
    if (-not $script:stateErrorLogged) {
      $script:stateErrorLogged = $true
      # Short message only: some parse errors quote the whole file, which may hold prompt text.
      $msg = ($_.Exception.Message -replace '\s+', ' '); if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
      try { Add-Content -Path (Join-Path $root 'window-errors.log') -Value "$(Get-Date -Format s) state.json: $msg" } catch {}
    }
  }
  return $script:lastGoodState
}

function Update-View {
  $now = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Complete-Folds $now
  $state = Read-State
  $active = @(); $finished = @()
  if ($state -and $state.sessions) {
    foreach ($p in $state.sessions.PSObject.Properties) {
      # One damaged session is skipped; it never stops the others from showing.
      try {
        $s = $p.Value
        $upd = $s.updatedAt -as [double]; $fin = $s.finishedAt -as [double]
        # A chat silent for 30 minutes is treated as stopped.
        if (($s.turnStartedAt -as [double]) -and $upd -and ($now - $upd) -lt 1800000) { $active += [pscustomobject]@{ id = $p.Name; s = $s } }
        # A finished chat shows "Finished" for a few seconds, then its card folds away.
        elseif ($fin -and ($s.lastTurnStartedAt -as [double]) -and ($now - $fin) -lt $DONE_MS) { $finished += [pscustomobject]@{ id = $p.Name; s = $s } }
      } catch {}
    }
  }
  $active = @($active | Sort-Object { $_.s.turnStartedAt -as [double] })
  if ($active.Count -gt 0 -and -not $script:firstCardNoted) { Set-FirstCard $active $now }
  $finished = @($finished | Sort-Object { $_.s.finishedAt -as [double] } -Descending)
  $shown = @(@($active) + @($finished) | Select-Object -First $MAX_CARDS)
  # Cards keep the place they first appeared in, so a chat that finishes (or starts again) minimises
  # or opens where it is instead of jumping to another position.
  foreach ($x in $shown) { if (-not $script:seen.ContainsKey($x.id)) { $script:seen[$x.id] = ++$script:seenN } }
  $shown = @($shown | Sort-Object { $script:seen[$_.id] })
  $maxRows = if ($shown.Count -gt 1) { 4 } else { 8 }

  # Create, update and order the cards. New cards fade in; cards that go away fade out first.
  $entering = @()
  foreach ($x in $shown) {
    if (-not $script:cards.ContainsKey($x.id)) { $script:cards[$x.id] = New-Card; $entering += $x.id }
    $card = $script:cards[$x.id]
    if ($card.leaving) { $card.leaving = $false; Stop-Leave $card }   # it came back while leaving
    if ($x.s.turnStartedAt) { Update-ActiveCard $card $x.id $x.s $now $maxRows } else { Update-FinishedCard $card $x.s $now $maxRows ($shown.Count -gt 1) }
    Complete-Expand $card
  }
  $ids = @($shown | ForEach-Object { $_.id })
  foreach ($k in @($script:cards.Keys)) {
    if ($ids -contains $k) { continue }
    $card = $script:cards[$k]
    if (-not $card.leaving) {
      # Fade, shrink slightly and fold closed (with the gap above it), so the cards below glide up.
      $card.leaving = $true; $card.removeAt = $now + (Start-Leave $card)
      # No animation (Saver mode): take it out now, not at the next refresh, so no empty gap lingers.
      if ($card.removeAt -le $now) { $script:cards.Remove($k); $script:seen.Remove($k) }
    } elseif ($now -ge $card.removeAt) {
      $script:cards.Remove($k); $script:seen.Remove($k)
    }
  }
  # Leaving cards keep their place until they have faded out.
  # Leaving cards keep their place too (not moved to the end), so they fade and fold where they are.
  $order = @($script:cards.Keys | Sort-Object { if ($script:seen.ContainsKey($_)) { $script:seen[$_] } else { [int]::MaxValue } })
  $orderKey = $order -join '|'
  if ($orderKey -ne $script:order) {
    $ui.Sessions.Children.Clear()
    foreach ($id in $order) { [void]$ui.Sessions.Children.Add($script:cards[$id].root) }
    $script:order = $orderKey
  }
  # Stagger: cards that appear together fade in 60ms apart; their space opens at once, so nothing jumps.
  $nth = 0
  foreach ($id in $entering) {
    $root = $script:cards[$id].root
    Show-Element $root 6 ($nth * 60)
    $nth++
    # Grow the new card open, so the window extends smoothly instead of jumping.
    if ($script:perf.anim -and -not $Snapshot) {
      $root.ClipToBounds = $true
      $root.BeginAnimation($P_Height, $null)
      Set-HeightAnim $root 0 (Get-NaturalHeight $root) 280 $true
    }
  }

  # Header
  if ($active.Count -gt 0) {
    $ui.Dot.Fill = $script:T.accent
    $ui.Title.Text = if ($active.Count -gt 1) { "Claude is working in $($active.Count) chats" } else { 'Claude is working' }
  } elseif ($finished.Count -gt 0) {
    $ui.Dot.Fill = $script:T.done
    $ui.Title.Text = 'Claude finished'
  } else {
    $ui.Dot.Fill = $script:T.done
    $ui.Title.Text = if ($Demo) { 'Demo finished - right-click to exit' }
      elseif ($prefs.hideIdle) { 'Claude is idle  ·  I''ll appear when Claude works' }
      else { 'Claude is idle' }
  }
  if ($prefs.mini) {
    # Minimized: header line + thin bar for the first working chat.
    $ui.Sessions.Visibility = 'Collapsed'; $ui.Legend.Visibility = 'Collapsed'
    $ui.Title.Text = if ($active.Count -gt 0) { 'Working' } elseif ($finished.Count -gt 0) { 'Finished' } else { 'Idle' }
    $tw = $ui.MiniTrack.ActualWidth; if ($tw -le 0) { $tw = 300 }
    $more = if ($active.Count -gt 1) { "$($active.Count) chats  ·  " } else { '' }
    if ($active.Count -gt 0) {
      $c = $script:cards[$active[0].id]
      $ui.MiniTrack.Visibility = 'Visible'
      if ($null -ne $c.jobPct) {
        $ui.Count.Text = ('{0}{1}%  ·  ~{2} left' -f $more, [math]::Floor($c.jobPct), (Format-Ms $c.jobLeft))
        Move-To $ui.MiniFill $P_Width ($tw * $c.jobPctAhead / 100) $LEAD 'linear'
      } else {
        $ui.Count.Text = ('{0}{1} elapsed  ·  learning' -f $more, (Format-Ms $c.jobSpent))
        Move-To $ui.MiniFill $P_Width ($tw * 0.15) 250
      }
    } elseif ($finished.Count -gt 0) {
      $ui.Count.Text = 'done'
      $ui.MiniTrack.Visibility = 'Visible'
      Move-To $ui.MiniFill $P_Width $tw 250
    } else {
      $ui.Count.Text = ''
      $ui.MiniTrack.Visibility = 'Collapsed'
    }
  } else {
    $ui.Sessions.Visibility = 'Visible'; $ui.MiniTrack.Visibility = 'Collapsed'
    # A done row that is still on its way out counts as done until it has gone.
    $doneN = $finished.Count + @($script:cards.Values | Where-Object { $_.leaving }).Count
    $ui.Count.Text = if ($shown.Count -gt 0 -or $doneN -gt 0) { "$($active.Count) working  ·  $doneN done" } else { '' }
    $ui.Legend.Visibility = if ($shown.Count -gt 0 -and $prefs.details) { 'Visible' } else { 'Collapsed' }
  }
  $justOpened = ($now - $script:startedAt) -lt $GRACE
  Set-WindowShown (-not ($shown.Count -eq 0 -and $prefs.hideIdle -and -not $Demo -and -not $justOpened)) $now
  if ($active.Count -eq 0) { $script:est = @{} }
}

# The window fades in (200ms) when Claude starts and out (180ms) when it hides while idle.
$script:winHideAt = $null
function Set-WindowShown([bool]$show, [double]$now) {
  if ($show) {
    if ($window.Visibility -ne 'Visible' -or $script:winHideAt) {
      $script:winHideAt = $null
      if ($window.Visibility -ne 'Visible') { $window.BeginAnimation($P_Opacity, $null); $window.Opacity = 0; $window.Visibility = 'Visible' }
      Move-To $window $P_Opacity 1 200
    }
  } elseif ($window.Visibility -eq 'Visible') {
    if (-not $script:winHideAt) { Move-To $window $P_Opacity 0 180; $script:winHideAt = $now + 200 }
    elseif ($now -ge $script:winHideAt) { $window.Visibility = 'Hidden'; $script:winHideAt = $null }
  }
}

# ---------- snapshot (preview pictures) ----------
if ($Snapshot) {
  New-Item -ItemType Directory -Force -Path $Snapshot | Out-Null
  $n = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $fake = @{ sessions = @{
    video = @{ cwd = 'C:\Projects\video-project'; title = 'Render the product intro video in 4K'; updatedAt = $n
      turnStartedAt = $n - 26000; turnEstimateMs = 40000
      steps = @{ v3 = @{ cat = 'render'; label = 'Rendering (ffmpeg)'; detail = 'Render frames into intro-4k.mp4'; startedAt = $n - 17000; estimateMs = 13000 } }
      log = @(
        @{ cat = 'read'; label = 'Reading'; detail = 'timeline.json'; startedAt = $n - 24500; endedAt = $n - 23000; ok = $true },
        @{ cat = 'edit'; label = 'Editing'; detail = 'render-settings.json'; startedAt = $n - 21000; endedAt = $n - 19500; ok = $true }) }
    form = @{ cwd = 'C:\Projects\website'; title = 'Fix the contact form validation'; updatedAt = $n
      turnStartedAt = $n - 15000; turnEstimateMs = 40000
      steps = @{ f5 = @{ cat = 'run'; label = 'Running npm'; detail = 'Run the test suite again'; startedAt = $n - 2500; estimateMs = 5000 } }
      log = @(
        @{ cat = 'read'; label = 'Searching code'; detail = 'validateEmail'; startedAt = $n - 13800; endedAt = $n - 12300; ok = $true },
        @{ cat = 'edit'; label = 'Editing'; detail = 'contact.js'; startedAt = $n - 10500; endedAt = $n - 8500; ok = $true },
        @{ cat = 'run'; label = 'Running npm'; detail = 'Run the test suite'; startedAt = $n - 8500; endedAt = $n - 4000; ok = $false },
        @{ cat = 'edit'; label = 'Editing'; detail = 'contact.js'; startedAt = $n - 4000; endedAt = $n - 2500; ok = $true }) }
  } }
  $stateFile = Join-Path $Snapshot 'sample-state.json'
  $fake | ConvertTo-Json -Depth 8 | Set-Content -Path $stateFile -Encoding utf8
  $window.ShowActivated = $false
  $window.Show()
  $backdrop = New-Object System.Windows.Media.LinearGradientBrush((New-Color '#FF3A4150'), (New-Color '#FF1C2029'), 90.0)
  foreach ($name in @($themes.Keys) + 'DADA-mini') {
    if ($name -eq 'DADA-mini') { Set-Theme 'DADA' $false; Set-Mini $true $false } else { Set-Mini $false $false; Set-Theme $name $false }
    $script:est = @{}
    foreach ($i in 1..3) { Update-View; $window.UpdateLayout() }
    # The whole window, glow margin included, on a transparent background (sits cleanly on light or dark pages).
    $w = [math]::Ceiling($window.ActualWidth); $h = [math]::Ceiling($window.ActualHeight)
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(($w * 2), ($h * 2), 192, 192, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($window)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $out = Join-Path $Snapshot "theme-$name.png"
    $fs = [System.IO.File]::Create($out); $enc.Save($fs); $fs.Close()
    Write-Output "Saved $out"
  }
  $window.Close()
  exit 0
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:lastError = $null
$timer.Add_Tick({
  # Opened again while already running: show the window (for the usual few seconds if Claude is idle).
  if ($script:showSignal -and $script:showSignal.WaitOne(0)) {
    $script:startedAt = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try { $window.Activate() | Out-Null } catch {}
  }
  try { Update-View } catch {
    $msg = "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
    if ($msg -ne $script:lastError) { $script:lastError = $msg; Add-Content -Path (Join-Path $root 'window-errors.log') -Value "$(Get-Date -Format s) $msg" }
  }
})

# ---------- performance modes ----------
# Frees memory the window is not using and hands it back to Windows.
function Invoke-Trim {
  [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers(); [System.GC]::Collect()
  [void][ClaudeProgress.Mem]::EmptyWorkingSet([System.Diagnostics.Process]::GetCurrentProcess().Handle)
}
$trimTimer = New-Object System.Windows.Threading.DispatcherTimer
$trimTimer.Add_Tick({ try { Invoke-Trim } catch {} })
function Set-Mode([string]$name, [bool]$save = $true) {
  if (-not $modes.Contains($name)) { $name = 'Neutral' }
  $m = $modes[$name]
  $script:perf = $m
  $script:LEAD = $m.refresh + 100
  $timer.Interval = [TimeSpan]::FromMilliseconds($m.refresh)
  if ($m.glow) { $ui.GlowLayer.Visibility = 'Visible' } else { $ui.GlowLayer.Visibility = 'Collapsed' }
  $trimTimer.Stop()
  if ($m.trim -gt 0) { $trimTimer.Interval = [TimeSpan]::FromSeconds($m.trim); $trimTimer.Start() }
  $ui.ModeSaver.IsChecked = ($name -eq 'Saver'); $ui.ModeNeutral.IsChecked = ($name -eq 'Neutral'); $ui.ModeFull.IsChecked = ($name -eq 'Full')
  # Restart the pulse with the new settings, and trim straight away when switching to Saver.
  foreach ($c in $script:cards.Values) { if ($c.pulsing) { $c.pulsing = $false } }
  if ($name -eq 'Saver') { try { Invoke-Trim } catch {} }
  if ($save) { $prefs.mode = $name; Save-Prefs }
}
$ui.ModeSaver.Add_Click({ Set-Mode 'Saver' })
$ui.ModeNeutral.Add_Click({ Set-Mode 'Neutral' })
$ui.ModeFull.Add_Click({ Set-Mode 'Full' })
Set-Mode ([string]$prefs.mode) $false
# A first trim once the window has settled.
# Heartbeat: hook.js checks this file and reopens the window if it stops being touched.
if (-not $Demo -and -not $Snapshot -and -not $SelfTest) {
  $aliveFile = Join-Path $root 'alive'
  $heart = New-Object System.Windows.Threading.DispatcherTimer
  $heart.Interval = [TimeSpan]::FromSeconds(5)
  $heart.Add_Tick({ try { [System.IO.File]::WriteAllText($aliveFile, '') } catch {} })
  $heart.Start()
  try { [System.IO.File]::WriteAllText($aliveFile, '') } catch {}
}

$firstTrim = New-Object System.Windows.Threading.DispatcherTimer
$firstTrim.Interval = [TimeSpan]::FromSeconds(5)
$firstTrim.Add_Tick({ $firstTrim.Stop(); if ($script:perf.trim -gt 0) { try { Invoke-Trim } catch {} } })
$firstTrim.Start()

# The demo also shows minimize: it folds down at ~22s and opens back up at ~27s.
if ($Demo) {
  $script:demoStep = 0
  $demoTimer = New-Object System.Windows.Threading.DispatcherTimer
  $demoTimer.Interval = [TimeSpan]::FromSeconds(22)
  $demoTimer.Add_Tick({
    try {
      if ($script:demoStep -eq 0) { Set-Mini $true; $demoTimer.Interval = [TimeSpan]::FromSeconds(5); $script:demoStep = 1 }
      else { Set-Mini $false; $demoTimer.Stop() }
    } catch { Write-UiError $_; $demoTimer.Stop() }
  })
  $demoTimer.Start()
}

$window.Add_Loaded({
  if ($null -ne $prefs.left -and $null -ne $prefs.top) { $window.Left = $prefs.left; $window.Top = $prefs.top } else { Move-ToCorner }
  try { Update-View } catch {}
  $timer.Start()
  try { Set-ChatWatch ([bool]$prefs.chats) } catch { Write-UiError $_ }
})
# On Exit, let go of the single-copy lock at once, so reopening straight away works.
$window.Add_Closed({
  $timer.Stop()
  if ($script:chatWatch -and -not $script:chatWatch.HasExited) { try { $script:chatWatch.Kill() } catch {} }
  if ($script:mutex) { try { $script:mutex.ReleaseMutex() } catch {}; try { $script:mutex.Dispose() } catch {}; $script:mutex = $null }
})

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnMainWindowClose'
# A mistake in any click, hover or menu handler is logged and the window keeps running.
$app.Add_DispatcherUnhandledException({
  param($sender, $ev)
  try { Add-Content -Path (Join-Path $root 'window-errors.log') -Value "$(Get-Date -Format s) handled: $($ev.Exception.Message)" } catch {}
  $ev.Handled = $true
})
[void]$app.Run($window)
