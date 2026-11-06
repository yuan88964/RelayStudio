param(
    [string]$DataRoot = (Join-Path $PSScriptRoot 'data'),
    [switch]$Preview,
    [switch]$NoShow,
    [switch]$StartMinimized,
    [string]$RenderPath = '',
    [string]$RenderAdvancedPath = '',
    [string]$RenderDetailPath = '',
    [string]$RenderArchivePath = ''
)
$ErrorActionPreference = 'Stop'
$script:earlyMutex = $null
$script:earlyRestoreEvent = $null
if (-not $NoShow -and -not $Preview -and -not $RenderPath -and -not $RenderAdvancedPath -and -not $RenderDetailPath -and -not $RenderArchivePath) {
    $earlyCreated = $false
    $script:earlyMutex = New-Object Threading.Mutex($true, 'Local\RelayStudio.OpenAI.ConnectionManager', [ref]$earlyCreated)
    $script:earlyRestoreEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\RelayStudio.OpenAI.RestoreEvent')
    if (-not $earlyCreated) {
        try { [void]$script:earlyRestoreEvent.Set() } catch { }
        Add-Type -Namespace Win32 -Name SingleInstanceRestore -MemberDefinition @'
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@ -ErrorAction SilentlyContinue
        try {
            $existingHwnd = [Win32.SingleInstanceRestore]::FindWindow($null, 'RelayStudio · 智能体接力与多栏工作台')
            if ($existingHwnd -ne [IntPtr]::Zero) {
                if ([Win32.SingleInstanceRestore]::IsIconic($existingHwnd)) {
                    [void][Win32.SingleInstanceRestore]::ShowWindow($existingHwnd, 9)
                }
                [void][Win32.SingleInstanceRestore]::SetForegroundWindow($existingHwnd)
            }
        } catch {}
        $script:earlyRestoreEvent.Dispose()
        $script:earlyMutex.Dispose()
        return
    }
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Security
Import-Module (Join-Path $PSScriptRoot 'ConnectionManager.psm1') -Force

$script:context = New-ConnectionContext -DataRoot $DataRoot -Isolated:$Preview
$script:settings = Read-ConnectionSettings $script:context
$script:layout = Get-WindowLayoutMemory $script:context
$script:profilesState = Get-ConnectionProfiles $script:context $script:settings
$script:initializing = $true
$script:busy = $false
$script:dirty = $false
$script:display = $null
$script:activeTab = 'Live'
$script:renamingSessionKey = ''
$script:renamingPaneId = 0
$script:detailSessionKey = ''
$script:lastDetailPanelSig = ''
$script:keyMasked = $true
$script:popoverOpen = $false
$script:popoverEditMode = $false
$script:reconnectNotice = '点击另一套卡片即可自动断开旧隧道并重连新隧道'
$script:notifiedStallKeys = @{}
$script:nextPaneId = 110
$script:launchpadPaneIds = @{}
$script:pickerPaneIds = @{}
foreach ($initP in @($script:layout.Panes)) {
    if ($initP -and $initP.id -and ([int]$initP.id + 1) -gt $script:nextPaneId) {
        $script:nextPaneId = [int]$initP.id + 1
    }
}
if ($script:layout.HiddenRightPane -and $script:layout.HiddenRightPane.id -and ([int]$script:layout.HiddenRightPane.id + 1) -gt $script:nextPaneId) {
    $script:nextPaneId = [int]$script:layout.HiddenRightPane.id + 1
}
$script:railDragCtx = $null
$script:paneDragCtx = $null
$script:railAnimTimer = $null
$script:paneAnimTimer = $null
$script:RAIL_MIN_WIDTH_PX = 200.0
$script:RAIL_MAX_WIDTH_PX = 360.0
$script:RAIL_SNAP_HIDE_PX = 95.0
$script:PANE_MIN_COMFORT_PX = 340.0
$script:PANE_SNAP_HIDE_PX = 140.0

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RelayStudio · 智能体接力与多栏工作台"
        Width="1180" Height="700" MinWidth="740" MinHeight="500"
        WindowStartupLocation="CenterScreen"
        Background="#F4F4F6"
        BorderBrush="#E4E4E7" BorderThickness="1"
        FontFamily="Source Han Serif SC VF, Source Han Serif SC, Noto Serif SC, Microsoft YaHei UI" FontSize="13.5"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
 <WindowChrome.WindowChrome>
  <WindowChrome CaptionHeight="0" ResizeBorderThickness="6" GlassFrameThickness="1" CornerRadius="10" UseAeroCaptionButtons="False"/>
 </WindowChrome.WindowChrome>
 <Window.Resources>
  <Style TargetType="TextBlock">
   <Setter Property="Foreground" Value="#18181B"/>
   <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style TargetType="TextBox">
   <Setter Property="Padding" Value="9,6"/>
   <Setter Property="Foreground" Value="#18181B"/>
   <Setter Property="CaretBrush" Value="#18181B"/>
   <Setter Property="Background" Value="#FFFFFF"/>
   <Setter Property="BorderBrush" Value="#E4E4E7"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>
  <Style TargetType="PasswordBox">
   <Setter Property="Padding" Value="9,6"/>
   <Setter Property="Foreground" Value="#18181B"/>
   <Setter Property="CaretBrush" Value="#18181B"/>
   <Setter Property="Background" Value="#FFFFFF"/>
   <Setter Property="BorderBrush" Value="#E4E4E7"/>
   <Setter Property="BorderThickness" Value="1"/>
  </Style>
  <!-- Flat Rounded CheckBox (eliminates classic Windows 3D sunken checkbox) -->
  <Style TargetType="CheckBox">
   <Setter Property="Foreground" Value="#3F3F46"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="VerticalAlignment" Value="Center"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="CheckBox">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Background="Transparent">
       <Border x:Name="ChkBox" Width="15" Height="15" CornerRadius="4" Background="#FFFFFF" BorderBrush="#D4D4D8" BorderThickness="1" VerticalAlignment="Center">
        <Path x:Name="ChkMark" Data="M2.5 7.5 L6 11 L12.5 4" Stroke="#FEFEFF" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
       </Border>
       <ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
      </StackPanel>
      <ControlTemplate.Triggers>
       <Trigger Property="IsMouseOver" Value="True">
        <Setter TargetName="ChkBox" Property="BorderBrush" Value="#93C5FD"/>
       </Trigger>
       <Trigger Property="IsChecked" Value="True">
        <Setter TargetName="ChkBox" Property="Background" Value="#2563EB"/>
        <Setter TargetName="ChkBox" Property="BorderBrush" Value="#2563EB"/>
        <Setter TargetName="ChkMark" Property="Visibility" Value="Visible"/>
       </Trigger>
       <MultiTrigger>
        <MultiTrigger.Conditions>
         <Condition Property="IsChecked" Value="True"/>
         <Condition Property="IsMouseOver" Value="True"/>
        </MultiTrigger.Conditions>
        <Setter TargetName="ChkBox" Property="Background" Value="#1D4ED8"/>
        <Setter TargetName="ChkBox" Property="BorderBrush" Value="#1D4ED8"/>
       </MultiTrigger>
      </ControlTemplate.Triggers>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <!-- Flat Rounded ComboBox & ComboBoxItem (eliminates Windows Aero 3D gray gradient dropdowns) -->
  <Style TargetType="ComboBoxItem">
   <Setter Property="Padding" Value="8,5"/>
   <Setter Property="Foreground" Value="#18181B"/>
   <Setter Property="FontSize" Value="11.5"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="ComboBoxItem">
      <Border x:Name="ItemBd" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}" Margin="0,1">
       <ContentPresenter VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
       <Trigger Property="IsHighlighted" Value="True">
        <Setter TargetName="ItemBd" Property="Background" Value="#F4F4F5"/>
       </Trigger>
       <Trigger Property="IsMouseOver" Value="True">
        <Setter TargetName="ItemBd" Property="Background" Value="#F4F4F5"/>
       </Trigger>
       <Trigger Property="IsSelected" Value="True">
        <Setter TargetName="ItemBd" Property="Background" Value="#EFF6FF"/>
        <Setter Property="Foreground" Value="#1D4ED8"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
       </Trigger>
      </ControlTemplate.Triggers>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <Style TargetType="ComboBox">
   <Setter Property="Foreground" Value="#3F3F46"/>
   <Setter Property="Background" Value="#FFFFFF"/>
   <Setter Property="BorderBrush" Value="#E4E4E7"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Padding" Value="8,3,6,3"/>
   <Setter Property="MinHeight" Value="24"/>
   <Setter Property="FontSize" Value="11"/>
   <Setter Property="FontWeight" Value="SemiBold"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Auto"/>
   <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="ComboBox">
      <Grid x:Name="MainGrid" SnapsToDevicePixels="True">
       <ToggleButton x:Name="ToggleButton" Grid.Column="0" Focusable="False" ClickMode="Press"
                     IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
        <ToggleButton.Template>
         <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="ComboBorder"
                  Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                  BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                  BorderThickness="{Binding BorderThickness, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                  CornerRadius="6" Padding="7,2,6,2">
           <Grid>
            <Grid.ColumnDefinitions>
             <ColumnDefinition Width="*"/>
             <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Path x:Name="Arrow" Grid.Column="1" Data="M1 1.5 L4.2 4.7 L7.4 1.5" Stroke="#71717A" StrokeThickness="1.5"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                  VerticalAlignment="Center" HorizontalAlignment="Center" Margin="4,1,1,0"/>
           </Grid>
          </Border>
          <ControlTemplate.Triggers>
           <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="ComboBorder" Property="Background" Value="#F8FAFC"/>
            <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#CBD5E1"/>
            <Setter TargetName="Arrow" Property="Stroke" Value="#18181B"/>
           </Trigger>
           <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="ComboBorder" Property="Background" Value="#FFFFFF"/>
            <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#3B82F6"/>
            <Setter TargetName="Arrow" Property="Stroke" Value="#2563EB"/>
           </Trigger>
          </ControlTemplate.Triggers>
         </ControlTemplate>
        </ToggleButton.Template>
       </ToggleButton>
       <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                         Content="{TemplateBinding SelectionBoxItem}"
                         ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                         ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                         Margin="7,2,18,2" VerticalAlignment="Center" HorizontalAlignment="Left"/>
       <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
              AllowsTransparency="True" Focusable="False" PopupAnimation="Fade" VerticalOffset="3">
        <Border x:Name="DropDownBorder" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1"
                CornerRadius="8" Padding="4" Margin="0,2,10,10"
                MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                MaxHeight="{TemplateBinding MaxDropDownHeight}">
         <Border.Effect>
          <DropShadowEffect BlurRadius="16" ShadowDepth="4" Opacity="0.10" Color="#09090B"/>
         </Border.Effect>
         <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
         </ScrollViewer>
        </Border>
       </Popup>
      </Grid>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <!-- Slim 6px Pill ScrollBar (eliminates chunky 17px classic Windows scrollbar & arrows) -->
  <Style TargetType="ScrollBar">
   <Setter Property="Width" Value="6"/>
   <Setter Property="MinWidth" Value="6"/>
   <Setter Property="Background" Value="Transparent"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="ScrollBar">
      <Grid Width="6" Background="Transparent">
       <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False">
        <Track.Thumb>
         <Thumb>
          <Thumb.Template>
           <ControlTemplate TargetType="Thumb">
            <Border x:Name="ThumbBar" Background="#2871717A" CornerRadius="3" Margin="1,2,1,2"/>
            <ControlTemplate.Triggers>
             <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="ThumbBar" Property="Background" Value="#6671717A"/>
             </Trigger>
            </ControlTemplate.Triggers>
           </ControlTemplate>
          </Thumb.Template>
         </Thumb>
        </Track.Thumb>
       </Track>
      </Grid>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <Style TargetType="Button">
   <Setter Property="Padding" Value="12,6"/>
   <Setter Property="MinHeight" Value="30"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Foreground" Value="#18181B"/>
   <Setter Property="Background" Value="#FFFFFF"/>
   <Setter Property="BorderBrush" Value="#E4E4E7"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="Button">
      <Border x:Name="Surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
       <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
       <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.88"/></Trigger>
       <Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.74"/></Trigger>
       <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <Style x:Key="LinkButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
   <Setter Property="Background" Value="Transparent"/>
   <Setter Property="BorderThickness" Value="0"/>
   <Setter Property="BorderBrush" Value="Transparent"/>
   <Setter Property="Foreground" Value="#1D4ED8"/>
   <Setter Property="Padding" Value="2,2"/>
   <Setter Property="MinHeight" Value="22"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="HorizontalAlignment" Value="Left"/>
  </Style>
  <Style x:Key="IconButton" TargetType="Button">
   <Setter Property="Width" Value="28"/>
   <Setter Property="Height" Value="28"/>
   <Setter Property="MinHeight" Value="26"/>
   <Setter Property="Padding" Value="0"/>
   <Setter Property="Background" Value="Transparent"/>
   <Setter Property="BorderBrush" Value="Transparent"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Foreground" Value="#71717A"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="Button">
      <Border x:Name="IconSurf" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
       <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
       <Trigger Property="IsMouseOver" Value="True">
        <Setter TargetName="IconSurf" Property="Background" Value="#EFEFF1"/>
        <Setter Property="Foreground" Value="#18181B"/>
       </Trigger>
      </ControlTemplate.Triggers>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <Style x:Key="TabButton" TargetType="Button">
   <Setter Property="Background" Value="Transparent"/>
   <Setter Property="BorderBrush" Value="Transparent"/>
   <Setter Property="BorderThickness" Value="0,0,0,2"/>
   <Setter Property="Padding" Value="4,6"/>
   <Setter Property="MinHeight" Value="30"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Foreground" Value="#71717A"/>
   <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
 </Window.Resources>

 <Grid x:Name="RootWindowGrid" Background="#F3F4F6">
  <Grid.RowDefinitions>
   <RowDefinition Height="38"/>
   <RowDefinition Height="*"/>
  </Grid.RowDefinitions>

  <!-- Row 0: Antigravity-Style Unified App Title Bar (Same #F3F4F6 Shell Color as Left Rail) -->
  <Border x:Name="AppTitleBarBorder" Grid.Row="0" Background="#F3F4F6" Padding="10,0,8,0">
   <Grid>
    <Grid.ColumnDefinitions>
     <ColumnDefinition Width="*"/>
     <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
     <Border Width="18" Height="18" CornerRadius="4.5" Background="#18181F" BorderBrush="#27272A" BorderThickness="1" VerticalAlignment="Center" Margin="0,0,6,0">
      <TextBlock Text="R" FontSize="11" FontWeight="Bold" Foreground="#FEFEFF" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-0.5,0,0"/>
     </Border>
     <TextBlock Text="RelayStudio" FontSize="13" FontWeight="Bold" Foreground="#18181B" VerticalAlignment="Center" Margin="0,0,6,0"/>
     <Button x:Name="ToggleRailButton" Style="{StaticResource IconButton}" Width="28" Height="28" Margin="0,0,2,0" ToolTip="展开 / 收起左侧任务栏（不改变窗口外框大小，也可向左拖拽竖线自动吸附隐藏）">
      <Viewbox Width="15" Height="15">
       <Canvas Width="24" Height="24">
        <Path Data="M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z M9 4v16" Stroke="#52525B" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
       </Canvas>
      </Viewbox>
     </Button>
     <Button x:Name="ThemeToggleButton" Style="{StaticResource IconButton}" Width="28" Height="28" Margin="0,0,0,0" ToolTip="一键切换深色 / 浅色模式 (Ctrl+Shift+D)&#x0a;右键点击：恢复「跟随系统」">
      <Viewbox Width="13" Height="13">
       <Canvas Width="24" Height="24">
        <Path x:Name="ThemeToggleIconPath" Data="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" Stroke="#52525B" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
       </Canvas>
      </Viewbox>
     </Button>
     <Button x:Name="GlobalSettingsButton" Style="{StaticResource IconButton}" Width="28" Height="28" Margin="20,0,4,0" ToolTip="通用设置（本地内核、自动归档、默认载体、CLI 智能体与外观）">
      <Viewbox Width="13.5" Height="13.5">
       <Canvas Width="24" Height="24">
        <Path Data="M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" Stroke="#52525B" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
       </Canvas>
      </Viewbox>
     </Button>
     <Border x:Name="TunnelCapsuleBorder" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="8" Padding="0" Margin="0,0,6,0" VerticalAlignment="Center">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
       <StackPanel x:Name="CapsuleSegmentsPanel" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="ConnIconBadgeButton" Padding="8,2" MinHeight="24" Background="Transparent" BorderBrush="Transparent" BorderThickness="0" ToolTip="点击打开「ChatGPT 隧道配置」切换隧道或管理 API Key">
         <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="TopStatusDot" Width="7" Height="7" Fill="#16A34A" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <Border x:Name="ConnProfileMiniTagBorder" Background="Transparent" CornerRadius="4" Padding="0" VerticalAlignment="Center">
           <TextBlock x:Name="ConnProfileMiniTagText" Text="ChatGPT · 主工作台 ▾" FontSize="11.5" FontWeight="SemiBold" Foreground="#18181B" TextWrapping="NoWrap"/>
          </Border>
         </StackPanel>
        </Button>
        <StackPanel x:Name="CapsuleExtraSegmentsPanel" Orientation="Horizontal" VerticalAlignment="Center"/>
       </StackPanel>
       <Border Width="1" Background="#E4E4E7" Margin="0,3,0,3"/>
       <Button x:Name="AddPlatformCellButton" Content="＋" Padding="7,2" MinWidth="24" MinHeight="24" Background="Transparent" BorderBrush="Transparent" BorderThickness="0" FontSize="12" FontWeight="Bold" Foreground="#71717A" ToolTip="添加或管理平台配置分栏"/>
      </StackPanel>
     </Border>
    </StackPanel>
    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
     <Border x:Name="TopHeartbeatPillBorder" Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="12" Padding="9,2" MinHeight="22" Margin="0,0,8,0" VerticalAlignment="Center" Visibility="Collapsed" Cursor="Hand" ToolTip="隧道或本地内核连接异常，点击打开配置面板排查">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
       <Ellipse x:Name="TopHeartbeatDot" Width="6" Height="6" Fill="#EF4444" VerticalAlignment="Center" Margin="0,0,5,0"/>
       <TextBlock x:Name="TopHeartbeatText" Text="隧道告警: 请检查连接" FontSize="11" FontWeight="SemiBold" Foreground="#B91C1C" TextWrapping="NoWrap"/>
      </StackPanel>
     </Border>
     <Button x:Name="AppMinButton" Style="{StaticResource IconButton}" Width="28" Height="26" Margin="0,0,2,0" ToolTip="最小化窗口">
      <Viewbox Width="12" Height="12">
       <Canvas Width="24" Height="24">
        <Path Data="M5 12h14" Stroke="#52525B" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
       </Canvas>
      </Viewbox>
     </Button>
     <Button x:Name="AppMaxButton" Style="{StaticResource IconButton}" Width="28" Height="26" Margin="0,0,2,0" ToolTip="最大化 / 还原窗口">
      <Viewbox Width="11.5" Height="11.5">
       <Canvas Width="24" Height="24">
        <Path Data="M5 5h14v14H5z" Stroke="#52525B" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
       </Canvas>
      </Viewbox>
     </Button>
     <Button x:Name="AppCloseButton" Style="{StaticResource IconButton}" Width="28" Height="26" ToolTip="最小化收进右下角系统托盘（后台内核与隧道保持运行，右键托盘可彻底退出）">
      <Viewbox Width="13" Height="13">
       <Canvas Width="24" Height="24">
        <Path x:Name="AppCloseIconPath" Data="M18 6L6 18 M6 6l12 12" Stroke="#52525B" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
       </Canvas>
      </Viewbox>
     </Button>
    </StackPanel>
   </Grid>
  </Border>

  <!-- Row 1: Main Two-Region Body (Seamless #F3F4F6 Left Rail + Elevated White #FFFFFF Task Workspace Below) -->
  <Grid x:Name="P3BodyGrid" Grid.Row="1" Background="#F3F4F6">
   <Grid.ColumnDefinitions>
    <ColumnDefinition x:Name="LeftRailColumn" Width="260"/>
    <ColumnDefinition x:Name="RailResizerColumn" Width="7"/>
    <ColumnDefinition x:Name="WorkspaceColumn" Width="*"/>
   </Grid.ColumnDefinitions>

   <!-- Column 0: Left Task Rail (Seamless #F3F4F6 matching Top Bar, ClipToBounds for fixed-width drawer slide) -->
   <Border x:Name="LeftTaskRail" Grid.Column="0" Background="#F3F4F6" BorderThickness="0" Padding="10,2,6,10" ClipToBounds="True">
    <Grid>
     <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
     </Grid.RowDefinitions>

     <!-- Legacy Collapsed Header Placeholder -->
     <Border x:Name="LeftRailHeaderBorder" Grid.Row="0" Visibility="Collapsed"/>

     <!-- Row 1: Compact Pulse Strip (Hidden in normal state per Impeccable distill; shown only on fault) -->
     <Border x:Name="PulseBannerBorder" Grid.Row="1" Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="6" Padding="8,6" Margin="0,0,0,8" Visibility="Collapsed">
      <StackPanel>
       <WrapPanel>
        <TextBlock x:Name="PulsePrefixLabel" Text="通道总览：" Foreground="#475569" FontSize="11.5"/>
        <TextBlock x:Name="SessionStatus" Text="等待连接后显示实时脉搏" FontWeight="SemiBold" FontSize="11.5"/>
       </WrapPanel>
       <StackPanel Orientation="Horizontal" Margin="0,3,0,0" Visibility="Collapsed">
        <TextBlock Text="核心：" Foreground="#71717A" FontSize="11"/>
        <TextBlock x:Name="CoreStatus" Text="正在检查…" Foreground="#3F3F46" FontSize="11" FontWeight="SemiBold" Margin="0,0,8,0"/>
        <TextBlock Text="隧道：" Foreground="#71717A" FontSize="11"/>
        <TextBlock x:Name="TunnelStatus" Text="尚未连接" Foreground="#3F3F46" FontSize="11" FontWeight="SemiBold"/>
       </StackPanel>
       <TextBlock x:Name="FilterSummaryText" Text="仅显示网页主对话 · 停工 >15m 自动清理" Foreground="#71717A" FontSize="10.5" Visibility="Collapsed"/>
       <StackPanel Orientation="Horizontal" Visibility="Collapsed">
        <Button x:Name="TabLiveButton" Content="实时网页主对话" Style="{StaticResource TabButton}"/>
        <Button x:Name="TabConfigButton" Content="隧道与密钥配置" Style="{StaticResource TabButton}"/>
       </StackPanel>
      </StackPanel>
     </Border>

     <!-- Row 2: Active & Archived Task Queues -->
     <ScrollViewer x:Name="LiveScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>
       <Grid Margin="4,2,4,6">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="ActiveQueueHeaderText" Text="进行中任务 (0)" FontSize="11.5" FontWeight="SemiBold" Foreground="#71717A" VerticalAlignment="Center"/>
        <Button x:Name="NewTaskRailButton" Grid.Column="1" Style="{StaticResource IconButton}" Width="22" Height="22" MinHeight="22" ToolTip="＋ 新建任务：在右侧打开新建任务面板，输入首句需求即可立项并下发">
         <Viewbox Width="13" Height="13">
          <Canvas Width="24" Height="24">
           <Path Data="M12 5v14 M5 12h14" Stroke="#2563EB" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
          </Canvas>
         </Viewbox>
        </Button>
       </Grid>

       <!-- Active Task Cards Container -->
       <StackPanel x:Name="SessionListPanel"/>

       <!-- Empty Active Tasks Placeholder -->
       <Border x:Name="EmptySessionBox" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="8" Padding="12,12" Margin="0,0,0,8">
        <StackPanel>
         <TextBlock Text="当前暂无进行中的任务" FontSize="12.5" FontWeight="SemiBold" Foreground="#18181B"/>
         <TextBlock Text="在右侧输入需求即可立项；ChatGPT 端直接发起的任务也会自动同步至此。" Foreground="#71717A" FontSize="11.5" Margin="0,4,0,6"/>
         <Button x:Name="GoConfigButton" Content="点击左上角连接徽标配置密钥 →" Style="{StaticResource LinkButton}" FontSize="11.5" FontWeight="SemiBold"/>
        </StackPanel>
       </Border>
      </StackPanel>
     </ScrollViewer>

     <!-- Row 3: Clean Minimal Rail Footer (matches prototype-ui.html) -->
     <Border Grid.Row="3" BorderBrush="#F1F1F4" BorderThickness="0,1,0,0" Padding="4,8,4,0" Margin="0,6,0,0">
      <StackPanel>
       <Border x:Name="UndoDeleteBorder" Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="6" Padding="8,5" Visibility="Collapsed" Margin="0,0,0,6">
        <Grid>
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock x:Name="UndoDeleteText" Text="已删除任务" Foreground="#991B1B" FontSize="11" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
         <Button x:Name="UndoDeleteButton" Grid.Column="1" Content="撤销" Style="{StaticResource LinkButton}" Foreground="#DC2626" FontWeight="Bold" FontSize="11" Margin="6,0,0,0"/>
         <Button x:Name="DismissUndoDeleteButton" Grid.Column="2" Content="×" Style="{StaticResource LinkButton}" Foreground="#991B1B" FontSize="12.5" FontWeight="Bold" Margin="6,0,0,0" ToolTip="关闭此通知"/>
        </Grid>
       </Border>
       <Border x:Name="FeedbackBox" Background="#EFF4FC" CornerRadius="6" Padding="8,5" Visibility="Collapsed" Margin="0,0,0,6">
        <Grid>
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock x:Name="FeedbackText" FontSize="11.5" TextWrapping="Wrap" VerticalAlignment="Center"/>
         <Button x:Name="FeedbackReconnectButton" Grid.Column="1" Content="立即连接" Style="{StaticResource LinkButton}" Foreground="#2563EB" FontWeight="Bold" FontSize="11.5" Margin="6,0,0,0" Visibility="Collapsed"/>
         <Button x:Name="DismissFeedbackButton" Grid.Column="2" Content="×" Style="{StaticResource LinkButton}" Foreground="#71717A" FontSize="12" Margin="6,0,0,0"/>
        </Grid>
       </Border>
       <Button x:Name="OpenArchiveDrawerButton" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" Padding="10,5" MinHeight="28" Margin="0,0,0,7" HorizontalContentAlignment="Stretch" ToolTip="打开独立归档管理抽屉，查看、还原或一键清空已归档会话">
        <Grid>
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock x:Name="ArchiveDrawerBtnText" Text="📦 归档管理 (0)" FontSize="11.5" FontWeight="SemiBold" Foreground="#3F3F46" VerticalAlignment="Center" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
         <TextBlock Grid.Column="1" Text="管理 ▸" FontSize="11" Foreground="#71717A" VerticalAlignment="Center" TextWrapping="NoWrap" Margin="6,0,0,0"/>
        </Grid>
       </Button>
       <TextBlock x:Name="DetailText" Text="先保存配置，再连接。" Foreground="#71717A" FontSize="11" Visibility="Collapsed"/>
       <WrapPanel Margin="0,0,0,3">
        <Button x:Name="OfficialButton" Content="打开官方面板 ↗" Style="{StaticResource LinkButton}" FontSize="11" Foreground="#71717A" Margin="0,0,10,0" Visibility="Collapsed"/>
        <Button x:Name="StatusButton" Content="隧道状态页 ↗" Style="{StaticResource LinkButton}" FontSize="11" Foreground="#71717A" Margin="0,0,10,0"/>
        <Button x:Name="BridgeExtButton" Content="浏览器扩展 ↗" Style="{StaticResource LinkButton}" FontSize="11" Foreground="#71717A" Margin="0,0,10,0" ToolTip="打开 browser-bridge 扩展目录，在 Chrome/Edge 扩展页点『加载已解压的扩展程序』选中即可"/>
        <Button x:Name="FolderButton" Content="配置文件夹 ↗" Style="{StaticResource LinkButton}" FontSize="11" Foreground="#71717A" Visibility="Collapsed"/>
        <Button x:Name="ResetLayoutButton" Content="重置默认尺寸" Style="{StaticResource LinkButton}" FontSize="11" Foreground="#71717A" Visibility="Collapsed"/>
       </WrapPanel>
       <TextBlock x:Name="MemoryFootprintText" Text="点右上角 × 收进托盘不掉线 · 尺寸已自动记忆" FontSize="10.5" Foreground="#A1A1AA"/>
      </StackPanel>
     </Border>

     <!-- Snap-to-Auto-Hide Warning Badge for Left Rail (< 145px) -->
     <Border x:Name="SnapHideRailBadge" Grid.RowSpan="4" Background="#18181F" CornerRadius="14" Padding="12,6" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
      <TextBlock Text="⬅ 松手自动隐藏左栏" Foreground="#FEFEFF" FontSize="12" FontWeight="SemiBold"/>
     </Border>
    </Grid>
   </Border>

   <!-- Column 1: Draggable Resizer Bar for Left Queue Rail -->
   <Border x:Name="RailResizerBar" Grid.Column="1" Background="#F3F4F6" Cursor="SizeWE" ToolTip="左右拖动调整左侧队列栏宽度（向左拖窄至 &lt;145px 松手自动隐藏；隐藏后向右拖可展开）">
    <Grid>
     <Border x:Name="RailResizerLine" Width="1" Background="Transparent" HorizontalAlignment="Center"/>
     <Border x:Name="RailResizerGrip" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="3" Padding="1,2" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7">
      <TextBlock Text="⋮" FontSize="10" Foreground="#A1A1AA"/>
     </Border>
    </Grid>
   </Border>

   <!-- Column 2: Elevated Pure White Task Workspace Card (Contrasts against #F3F4F6 Top Bar + Left Rail) -->
   <Border x:Name="WorkspaceOuterBorder" Grid.Column="2" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="10" Margin="0,0,7,7" ClipToBounds="True">
    <Grid x:Name="WorkspaceHostGrid" Background="#FFFFFF">
     <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
     </Grid.RowDefinitions>

     <!-- Inline Rename Bar (Shown when clicking ✎ 改名 on any conversation pane) -->
     <Border x:Name="RenameBar" Grid.Row="0" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="0,0,0,1" Padding="18,8" Visibility="Collapsed">
      <Grid>
       <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
       </Grid.ColumnDefinitions>
       <TextBlock Text="对齐网页左栏名称：" Foreground="#1E3A8A" FontWeight="SemiBold" FontSize="12.5" VerticalAlignment="Center" Margin="0,0,8,0"/>
       <TextBox x:Name="RenameInput" Grid.Column="1" Padding="8,4" FontSize="13" Margin="0,0,8,0" ToolTip="输入与 ChatGPT 网页左侧栏一致的对话标题；留空保存可恢复自动识别标题"/>
       <Button x:Name="SaveRenameButton" Grid.Column="2" Content="保存名称" Background="#2563EB" BorderBrush="#2563EB" BorderThickness="1" Foreground="#FEFEFF" Padding="10,4" MinHeight="26" FontSize="12" Margin="0,0,6,0"/>
       <Button x:Name="ResetRenameButton" Grid.Column="3" Content="恢复自动" Padding="10,4" MinHeight="26" FontSize="12" BorderThickness="1" Margin="0,0,6,0"/>
       <Button x:Name="CancelRenameButton" Grid.Column="4" Content="取消" Padding="8,4" MinHeight="26" FontSize="12" BorderThickness="1"/>
      </Grid>
     </Border>

     <!-- LiveTabPanel: Dynamic Multi-Pane Split Container -->
     <Grid x:Name="LiveTabPanel" Grid.Row="1" Visibility="Visible">
      <Grid x:Name="PanesHostGrid" Background="#FFFFFF"/>
     </Grid>
    </Grid>
   </Border>
  </Grid>

  <!-- Floating Left-Anchored Multi-Profile Tunnel & API Key Popover (Variant A) -->
  <Border x:Name="KeyPopoverBorder" Grid.RowSpan="2" Width="460" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="14,38,0,0" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="12" Padding="18,16" Visibility="Collapsed">
   <Border.Effect>
    <DropShadowEffect BlurRadius="28" ShadowDepth="8" Opacity="0.11" Color="#09090B"/>
   </Border.Effect>
   <StackPanel>
    <Grid Margin="0,0,0,8">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <TextBlock x:Name="PopoverHeaderTitle" Text="ChatGPT 隧道配置 (1)" FontSize="13.5" FontWeight="Bold" Foreground="#18181B" VerticalAlignment="Center"/>
     <Button x:Name="RemoveCapsulePlatformButton" Grid.Column="1" Content="移除此栏" Style="{StaticResource LinkButton}" Foreground="#71717A" FontSize="11.5" Margin="0,0,8,0" Visibility="Collapsed"/>
     <Button x:Name="AddProfileButton" Grid.Column="2" Content="+ 新增配置" Padding="9,3" MinHeight="25" FontSize="11.5" FontWeight="SemiBold" Background="#FFFFFF" BorderBrush="#E4E4E7" Margin="0,0,6,0"/>
     <Button x:Name="TogglePopoverEditButton" Grid.Column="3" Content="✎ 编辑当前" Style="{StaticResource LinkButton}" FontSize="12" FontWeight="SemiBold" Visibility="Collapsed"/>
     <Button x:Name="DismissKeyPopoverButton" Grid.Column="4" Content="×" Style="{StaticResource LinkButton}" FontSize="14" FontWeight="Bold" Foreground="#71717A" Padding="4,0" ToolTip="收起弹出面板"/>
    </Grid>

    <Border x:Name="AddPlatformPanelBorder" Background="#FAFAFA" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="8" Padding="10,8" Margin="0,0,0,8" Visibility="Collapsed">
     <StackPanel x:Name="AddPlatformListPanel"/>
    </Border>

    <!-- Dynamic Multi-Profile Strip + Inline Accordion Edit Container -->
    <ScrollViewer x:Name="ProfilesListScroll" MaxHeight="240" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,0,8">
     <StackPanel x:Name="ProfilesListPanel"/>
    </ScrollViewer>

    <!-- Hidden Legacy Elements for Backward Safety -->
    <Button x:Name="ProfilePrimaryButton" Visibility="Collapsed"/>
    <Button x:Name="ProfileBusinessButton" Visibility="Collapsed"/>
    <Border Visibility="Collapsed">
     <TextBlock x:Name="PopoverReconnectNoticeText" Text=""/>
    </Border>
    <Border x:Name="PopoverDetailCardBorder" Visibility="Collapsed">
     <StackPanel>
      <TextBlock x:Name="CurrentTunnelIdText" Text="tunnel_..."/>
      <Button x:Name="CopyTunnelIdButton" Content="复制"/>
      <TextBlock x:Name="MaskedKeyText" Text="sk-proj-••••"/>
      <Button x:Name="ToggleKeyMaskButton" Content="显示完整"/>
      <Button x:Name="CopyApiKeyButton" Content="复制"/>
      <Button x:Name="EditCurrentProfileLink" Content="编辑"/>
      <Button x:Name="ConfirmDetailButton" Content="确认"/>
     </StackPanel>
    </Border>

    <!-- Inline Accordion Edit Form (Dynamically hosted inside the expanded tunnel strip) -->
    <ScrollViewer x:Name="FormScroll" Visibility="Collapsed" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Margin="0,7,0,2">
     <Border Background="#FFFFFF" BorderBrush="#93C5FD" BorderThickness="1" CornerRadius="7" Padding="10,8">
      <StackPanel>
       <TextBlock Text="配置名称" FontSize="11" Foreground="#52525B" FontWeight="SemiBold" Margin="0,0,0,2"/>
       <TextBox x:Name="ProfileNameInput" AutomationProperties.Name="配置名称" FontSize="11.5" Padding="7,3" MinHeight="24" Margin="0,0,0,5"/>
       <TextBlock x:Name="TunnelInputLabel" Text="隧道编号或完整链接" FontSize="11" Foreground="#52525B" FontWeight="SemiBold" Margin="0,0,0,2"/>
       <TextBox x:Name="TunnelInput" AutomationProperties.Name="隧道编号或链接" FontFamily="Consolas, Cascadia Mono, Source Han Serif SC VF, Noto Serif SC" FontSize="11.5" Padding="7,3" MinHeight="24" Margin="0,0,0,5"/>
       <TextBlock x:Name="KeyInputLabel" Text="OpenAI API Key (仅用于拉起本地 MCP 隧道)" FontSize="11" Foreground="#52525B" FontWeight="SemiBold" Margin="0,0,0,2"/>
       <TextBox x:Name="KeyInput" AutomationProperties.Name="OpenAI API Key" FontFamily="Consolas, Cascadia Mono, Source Han Serif SC VF, Noto Serif SC" FontSize="11.5" Padding="7,3" MinHeight="24" Margin="0,0,0,5"/>
       <TextBlock x:Name="KeyHint" Foreground="#71717A" FontSize="10.5" Visibility="Collapsed"/>

       <!-- Hidden Advanced Expander (Paths are auto-resolved relative to app folder) -->
       <Expander x:Name="Advanced" Header="高级设置" IsExpanded="False" Visibility="Collapsed">
        <StackPanel>
         <TextBlock x:Name="EndpointText"/>
         <TextBox x:Name="BaseInput"/>
         <TextBox x:Name="RootInput"/>
         <TextBox x:Name="ClientInput"/>
        </StackPanel>
       </Expander>

       <Border BorderBrush="#E4E4E7" BorderThickness="0,1,0,0" Padding="0,7,0,0" Margin="0,2,0,0">
        <Grid>
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <Button x:Name="DeleteProfileButton" Grid.Column="0" Content="删除此配置" Style="{StaticResource LinkButton}" Foreground="#DC2626" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Left" VerticalAlignment="Center"/>
         <Button x:Name="CancelEditProfileButton" Grid.Column="1" Content="取消" Visibility="Collapsed"/>
         <Button x:Name="SaveButton" Grid.Column="2" Content="保存" Background="#2563EB" BorderBrush="#2563EB" Foreground="#FEFEFF" FontWeight="SemiBold" Padding="13,3" MinHeight="25" FontSize="11.5"/>
         <Button x:Name="ConnectButton" Content="保存并连接" Visibility="Collapsed"/>
        </Grid>
       </Border>
      </StackPanel>
     </Border>
    </ScrollViewer>

    <!-- Popover Footer: Left Platform Links + Right Action Buttons -->
    <Border x:Name="PopoverFooterBorder" BorderBrush="#F1F1F4" BorderThickness="0,1,0,0" Padding="0,10,0,0">
     <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <CheckBox x:Name="ShieldCheck" Content="内核直通" IsChecked="True" Visibility="Collapsed"/>
      <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
       <Button x:Name="ApiKeysButton" Content="获取或管理 API Key ↗" Style="{StaticResource LinkButton}" FontSize="11" Margin="0,0,10,0"/>
       <Button x:Name="PlatformButton" Content="打开 OpenAI 隧道设置 ↗" Style="{StaticResource LinkButton}" FontSize="11"/>
      </StackPanel>
      <Button x:Name="QuickConnectButton" Grid.Column="1" Content="▶ 启动隧道" Background="#2563EB" BorderBrush="#2563EB" Foreground="#FEFEFF" FontWeight="SemiBold" Padding="12,4" MinHeight="27" FontSize="11.5" Margin="0,0,6,0"/>
      <Button x:Name="DisconnectButton" Grid.Column="2" Content="断开隧道" Padding="9,4" MinHeight="27" FontSize="11.5"/>
      <Button x:Name="ClosePopoverButton" Grid.Column="3" Content="收起" Padding="10,4" MinHeight="27" FontSize="11.5" Visibility="Collapsed"/>
     </Grid>
    </Border>
   </StackPanel>
  </Border>

  <!-- Floating Trigger-Anchored Global & Local Engine Settings Popover (⚙) -->
  <Border x:Name="GlobalSettingsPopoverBorder" Grid.RowSpan="2" Width="460" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="14,38,0,0" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="12" Padding="18,16" Visibility="Collapsed">
   <Border.Effect>
    <DropShadowEffect BlurRadius="28" ShadowDepth="8" Opacity="0.11" Color="#09090B"/>
   </Border.Effect>
   <StackPanel x:Name="PopoverViewPanel" Visibility="Visible">
    <Grid Margin="0,0,0,10">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <TextBlock Text="⚙ 通用与本地引擎设置" FontSize="13.5" FontWeight="Bold" Foreground="#18181B" VerticalAlignment="Center"/>
     <Button x:Name="CloseGlobalSettingsButton" Grid.Column="1" Content="×" Style="{StaticResource LinkButton}" FontSize="14" FontWeight="Bold" Foreground="#71717A" ToolTip="收起通用设置"/>
    </Grid>

    <Border Background="#FAFAFA" BorderBrush="#D4D4D8" BorderThickness="1" CornerRadius="10" Padding="13,11">
     <StackPanel>
      <Grid Margin="0,0,0,9">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Ellipse x:Name="CoreInlineDot" Width="7" Height="7" Fill="#16A34A" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <TextBlock x:Name="CoreInlineStatusText" Text="本地内核：运行中 (127.0.0.1:8765)" FontSize="12" FontWeight="Bold" Foreground="#18181B" VerticalAlignment="Center"/>
       </StackPanel>
       <Button x:Name="RestartCoreButton" Grid.Column="1" Content="↻ 重启内核" Padding="8,2" MinHeight="22" FontSize="11" ToolTip="一键重启本地 RelayStudio 内核进程"/>
      </Grid>

      <Grid Margin="0,0,0,8">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <TextBlock Text="已完工任务自动归档：" FontSize="11.5" Foreground="#52525B" VerticalAlignment="Center"/>
       <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="AutoArchiveImmediateButton" Content="立即" Padding="6,2" MinHeight="22" FontSize="11" Margin="0,0,4,0"/>
        <Button x:Name="AutoArchive1dButton" Content="1 天" Padding="6,2" MinHeight="22" FontSize="11" Margin="0,0,4,0"/>
        <Button x:Name="AutoArchive3dButton" Content="3 天 (默认)" Padding="6,2" MinHeight="22" FontSize="11" Margin="0,0,4,0" Background="#EFF6FF" BorderBrush="#BFDBFE" Foreground="#1D4ED8" FontWeight="SemiBold"/>
        <Button x:Name="AutoArchive7dButton" Content="7 天" Padding="6,2" MinHeight="22" FontSize="11" Margin="0,0,4,0"/>
        <Button x:Name="AutoArchiveOffButton" Content="关闭" Padding="6,2" MinHeight="22" FontSize="11"/>
       </StackPanel>
      </Grid>

      <Grid Margin="0,0,0,8">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <TextBlock Text="新建任务默认载体：" FontSize="11.5" Foreground="#52525B" VerticalAlignment="Center"/>
       <ComboBox x:Name="DefaultCarrierCombo" Grid.Column="1" MinWidth="175" MaxWidth="220" FontSize="11.5"/>
      </Grid>

      <Grid Margin="0,0,0,8">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <TextBlock x:Name="AcpConcurrencyLabel" Text="CLI 智能体并发上限：4 个" FontSize="11.5" Foreground="#52525B" VerticalAlignment="Center"/>
       <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="AcpLimit0Button" Content="关闭" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,0"/>
        <Button x:Name="AcpLimit2Button" Content="2" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,0"/>
        <Button x:Name="AcpLimit4Button" Content="4 (推荐)" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,0" Background="#EFF6FF" BorderBrush="#BFDBFE" Foreground="#1D4ED8" FontWeight="SemiBold"/>
        <Button x:Name="AcpLimit6Button" Content="6" Padding="7,2" MinHeight="22" FontSize="11"/>
       </StackPanel>
      </Grid>

      <StackPanel Margin="0,0,0,8">
       <Grid Margin="0,0,0,5">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Text="默认 CLI 智能体：" FontSize="11.5" Foreground="#52525B" VerticalAlignment="Center"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
         <Button x:Name="AddCustomCliAgentButton" Content="+ 添加..." Padding="6,2" MinHeight="21" FontSize="10.5" Margin="0,0,4,0" ToolTip="手动选择本机自定义 CLI 智能体可执行文件 (.cmd / .exe)"/>
         <Button x:Name="RescanCliAgentsButton" Content="↻ 重新检测" Padding="6,2" MinHeight="21" FontSize="10.5" ToolTip="重新扫描本机已安装的 CLI 智能体"/>
        </StackPanel>
       </Grid>
       <WrapPanel x:Name="CliAgentsButtonPanel" Orientation="Horizontal">
        <Button x:Name="AcpProfileCodexButton" Content="Codex" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,4" Background="#EFF6FF" BorderBrush="#BFDBFE" Foreground="#1D4ED8" FontWeight="SemiBold"/>
        <Button x:Name="AcpProfileClaudeButton" Content="Claude" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,4"/>
       </WrapPanel>
      </StackPanel>

      <Grid Margin="0,0,0,8">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <TextBlock Text="浏览器自动化 (CDP)：" FontSize="11.5" Foreground="#52525B" VerticalAlignment="Center"/>
       <Button x:Name="BrowserCdpToggleButton" Grid.Column="1" Content="● 已开启" Padding="8,2" MinHeight="22" FontSize="11" Background="#F0FDF4" BorderBrush="#BBF7D0" Foreground="#15803D" FontWeight="SemiBold"/>
      </Grid>

      <Grid Margin="0,0,0,8">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <TextBlock Text="开机自动启动方式：" FontSize="11.5" Foreground="#52525B" VerticalAlignment="Center"/>
       <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="StartupPopupButton" Content="开机弹窗" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,0"/>
        <Button x:Name="StartupTrayButton" Content="静默托盘" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,0" Background="#EFF6FF" BorderBrush="#BFDBFE" Foreground="#1D4ED8" FontWeight="SemiBold"/>
        <Button x:Name="StartupOffButton" Content="不自启" Padding="7,2" MinHeight="22" FontSize="11"/>
       </StackPanel>
      </Grid>

      <Grid>
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <TextBlock Text="界面外观主题 (Ctrl+Shift+D)：" FontSize="11.5" Foreground="#52525B" VerticalAlignment="Center"/>
       <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="ThemeSystemButton" Content="跟随系统" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,0"/>
        <Button x:Name="ThemeLightButton" Content="☀ 浅色" Padding="7,2" MinHeight="22" FontSize="11" Margin="0,0,4,0"/>
        <Button x:Name="ThemeDarkButton" Content="🌙 深色" Padding="7,2" MinHeight="22" FontSize="11"/>
       </StackPanel>
      </Grid>
     </StackPanel>
    </Border>
   </StackPanel>
  </Border>

  <!-- Independent Archived Tasks Management Drawer / Modal (Q2=方式2 & Q3=方式1) -->
  <Border x:Name="ArchiveDrawerOverlay" Grid.RowSpan="2" Background="#6618181B" Padding="24,20" Visibility="Collapsed">
   <Border Background="#FFFFFF" BorderBrush="#D4D4D8" BorderThickness="1" CornerRadius="12" ClipToBounds="True" MaxWidth="620" MaxHeight="520" HorizontalAlignment="Center" VerticalAlignment="Center">
    <Grid>
     <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
     </Grid.RowDefinitions>
     <Border Grid.Row="0" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="0,0,0,1" Padding="18,12">
      <Grid>
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="ArchiveDrawerTitle" Text="📦 已归档会话管理 (0)" FontSize="14.5" FontWeight="SemiBold" Foreground="#18181B"/>
        <TextBlock Text="展示手动归档与已完工自动归档的任务（还原将同步恢复主会话，彻底删除将同时清除本机账本与云端对话）" FontSize="11.5" Foreground="#71717A" Margin="0,2,0,0"/>
       </StackPanel>
       <Button x:Name="ClearAllArchivedButton" Grid.Column="1" VerticalAlignment="Center" Height="28" Content="🗑 一键清空全部归档" Background="#FEF2F2" BorderBrush="#FECACA" Foreground="#DC2626" FontWeight="SemiBold" Padding="10,4" MinHeight="28" FontSize="12" BorderThickness="1" Margin="10,0,8,0"/>
       <Button x:Name="CloseArchiveDrawerButton" Grid.Column="2" VerticalAlignment="Center" Height="28" Content="× 关闭" Padding="10,4" MinHeight="28" FontSize="12" BorderThickness="1"/>
      </Grid>
     </Border>
     <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="16,12">
      <StackPanel x:Name="ArchiveDrawerListPanel"/>
     </ScrollViewer>
     <Border Grid.Row="2" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Padding="18,8">
      <TextBlock Text="展示手动归档与已完工自动归档的任务（还原将同步恢复主会话，彻底删除将同时清除本机账本与云端对话）" Foreground="#71717A" FontSize="11"/>
     </Border>
    </Grid>
   </Border>
  </Border>

  <!-- Sent Web Messages History Modal Overlay (M5: Single Latest Blue Box in Main View + Full History Modal) -->
  <Border x:Name="SentHistoryOverlay" Grid.RowSpan="2" Background="#6618181B" Padding="24,20" Visibility="Collapsed">
   <Border Background="#FFFFFF" BorderBrush="#D4D4D8" BorderThickness="1" CornerRadius="12" ClipToBounds="True" MaxWidth="660" MaxHeight="520" HorizontalAlignment="Center" VerticalAlignment="Center">
    <Grid>
     <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
     </Grid.RowDefinitions>
     <Border Grid.Row="0" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="0,0,0,1" Padding="18,12">
      <Grid>
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="SentHistoryTitle" Text="📜 历史发送记录 (0)" FontSize="14.5" FontWeight="SemiBold" Foreground="#18181B"/>
        <TextBlock Text="主界面仅展示最新 1 条蓝框记录以防刷屏；此处可查看发往网页端的全部历史指令与交接单" FontSize="11.5" Foreground="#71717A" Margin="0,2,0,0"/>
       </StackPanel>
       <Button x:Name="CloseSentHistoryButton" Grid.Column="1" VerticalAlignment="Center" Height="28" Content="× 关闭" Padding="10,4" MinHeight="28" FontSize="12" BorderThickness="1"/>
      </Grid>
     </Border>
     <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="16,12">
      <StackPanel x:Name="SentHistoryListPanel"/>
     </ScrollViewer>
     <Border Grid.Row="2" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Padding="18,8">
      <TextBlock Text="提示：点击任一记录右侧「复制全文」可将当时发送的完整交接单或指令复制到剪贴板。" Foreground="#71717A" FontSize="11"/>
     </Border>
    </Grid>
   </Border>
  </Border>

  <!-- Modal Popup Overlay: Conversation Progress Detail Report (Compatible with Open-SessionDetail & -RenderDetailPath) -->
  <Border x:Name="SessionDetailOverlay" Grid.RowSpan="2" Background="#9918181B" Padding="24,18" Visibility="Collapsed">
   <Border Background="#FFFFFF" BorderBrush="#D4D4D8" BorderThickness="1" CornerRadius="10" ClipToBounds="True" MaxWidth="760">
    <Grid>
     <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
     </Grid.RowDefinitions>
     <Border Grid.Row="0" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="0,0,0,1" Padding="18,12">
      <Grid>
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="DetailModalTitle" Text="对话详情" FontSize="15" FontWeight="SemiBold" Foreground="#18181B"/>
        <TextBlock x:Name="DetailModalGoal" Text="" FontSize="12" Foreground="#52525B" Margin="0,3,0,0" TextWrapping="Wrap" MaxHeight="36" TextTrimming="CharacterEllipsis"/>
       </StackPanel>
       <Border x:Name="DetailModalBadgeBorder" Grid.Column="1" Background="#DCFCE7" BorderBrush="#BBF7D0" BorderThickness="1" CornerRadius="12" Padding="10,3" VerticalAlignment="Center" Margin="10,0,10,0">
        <TextBlock x:Name="DetailModalBadgeText" Text="● 活跃运行中" Foreground="#166534" FontSize="12" FontWeight="SemiBold"/>
       </Border>
       <Button x:Name="CloseDetailButton" Grid.Column="2" VerticalAlignment="Center" Height="28" Content="× 关闭详情" Padding="10,4" MinHeight="28" FontSize="12" BorderThickness="1"/>
      </Grid>
     </Border>
     <ScrollViewer x:Name="DetailModalScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="18,14">
      <StackPanel>
       <Border Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="6" Padding="14,10" Margin="0,0,0,14">
        <StackPanel>
         <TextBlock x:Name="DetailDiagnosisText" Text="" Foreground="#1E3A8A" FontSize="12.5" FontWeight="SemiBold"/>
         <Grid Margin="0,8,0,4">
          <Border Background="#DBEAFE" Height="7" CornerRadius="3"/>
          <ProgressBar x:Name="DetailProgressBar" Minimum="0" Maximum="100" Value="0" Height="7" Background="Transparent" Foreground="#2563EB" BorderThickness="0"/>
         </Grid>
         <TextBlock x:Name="DetailProgressText" Text="" Foreground="#1E40AF" FontSize="11.5" Margin="0,2,0,0"/>
        </StackPanel>
       </Border>
       <TextBlock Text="一、阶段闯关进度（Steps）" FontSize="13" FontWeight="SemiBold" Foreground="#18181B" Margin="0,0,0,6"/>
       <Border Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="6" Margin="0,0,0,14">
        <StackPanel x:Name="DetailStepsPanel"/>
       </Border>
       <TextBlock Text="二、最新进展战报与代码库实时提交" FontSize="13" FontWeight="SemiBold" Foreground="#18181B" Margin="0,0,0,6"/>
       <Border Background="#FAFAFA" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="6" Padding="12,10" Margin="0,0,0,14">
        <StackPanel>
         <TextBlock Text="最新检查点摘要：" FontSize="12" FontWeight="SemiBold" Foreground="#3F3F46" Margin="0,0,0,3"/>
         <TextBlock x:Name="DetailLatestSummaryText" Text="" FontSize="12" Foreground="#52525B" Margin="0,0,0,8"/>
         <TextBlock Text="关联代码库最近 Git 提交（实时脉冲）：" FontSize="12" FontWeight="SemiBold" Foreground="#3F3F46" Margin="0,0,0,4"/>
         <StackPanel x:Name="DetailCommitsPanel"/>
        </StackPanel>
       </Border>
       <TextBlock Text="三、近期里程碑时间线（Checkpoints）" FontSize="13" FontWeight="SemiBold" Foreground="#18181B" Margin="0,0,0,6"/>
       <Border Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="6" Margin="0,0,0,6">
        <StackPanel x:Name="DetailCheckpointsPanel"/>
       </Border>
      </StackPanel>
     </ScrollViewer>
     <Border Grid.Row="2" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Padding="18,8">
      <Grid>
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <TextBlock x:Name="DetailModalMetaText" Text="每 2 秒自动同步最新任务进度与代码库提交" Foreground="#71717A" FontSize="11.5" VerticalAlignment="Center"/>
       <Button x:Name="RefreshDetailButton" Grid.Column="1" Content="立即刷新" Padding="10,4" MinHeight="26" FontSize="12" BorderThickness="1"/>
      </Grid>
     </Border>
    </Grid>
   </Border>
  </Border>

  <!-- Quick Toast Pill Banner -->
  <Border x:Name="QuickToastBorder" Grid.RowSpan="2" Background="#18181F" CornerRadius="16" Padding="14,7" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,10,0,0" Visibility="Collapsed">
   <StackPanel Orientation="Horizontal">
    <Ellipse Width="7" Height="7" Fill="#22C55E" VerticalAlignment="Center" Margin="0,0,7,0"/>
    <TextBlock x:Name="QuickToastText" Text="" Foreground="#FEFEFF" FontSize="12.5" FontWeight="SemiBold"/>
   </StackPanel>
  </Border>
 </Grid>
</Window>
'@
$script:themeBrushes = @{}
$script:xamlThemeHexKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:smoothAnimatedButtons = New-Object 'System.Collections.Generic.List[Windows.Controls.Button]'
$script:effectiveTheme = Resolve-EffectiveTheme -ThemeMode ([string]$script:layout.ThemeMode)

$themedXamlRaw = $xaml.OuterXml
$themedXamlRaw = [regex]::Replace($themedXamlRaw, '(Background|BorderBrush|Foreground|CaretBrush|Stroke|Fill)="(#[0-9A-Fa-f]{6,8})"', {
    param($m)
    $propName = $m.Groups[1].Value
    $hexVal = $m.Groups[2].Value.ToUpperInvariant()
    [void]$script:xamlThemeHexKeys.Add($hexVal)
    $resKey = 'ThemeBrush_' + $hexVal.TrimStart('#')
    return ($propName + '="{DynamicResource ' + $resKey + '}"')
})
$themedXamlRaw = [regex]::Replace($themedXamlRaw, '(<Setter[^>]*Property="(?:Background|BorderBrush|Foreground|CaretBrush|Stroke|Fill)"[^>]*Value=")(#[0-9A-Fa-f]{6,8})(")', {
    param($m)
    $hexVal = $m.Groups[2].Value.ToUpperInvariant()
    [void]$script:xamlThemeHexKeys.Add($hexVal)
    $resKey = 'ThemeBrush_' + $hexVal.TrimStart('#')
    return ($m.Groups[1].Value + '{DynamicResource ' + $resKey + '}' + $m.Groups[3].Value)
})
$brushNodesBuilder = New-Object System.Text.StringBuilder
foreach ($hexKey in $script:xamlThemeHexKeys) {
    $resKey = 'ThemeBrush_' + $hexKey.TrimStart('#')
    $initHex = Resolve-ThemeColorHex -Hex $hexKey -Theme $script:effectiveTheme
    [void]$brushNodesBuilder.AppendLine('<SolidColorBrush x:Key="' + $resKey + '" Color="' + $initHex + '"/>')
}
$themedXamlRaw = $themedXamlRaw.Replace('<Window.Resources>', '<Window.Resources>' + "`n" + $brushNodesBuilder.ToString())
[xml]$themedXamlDoc = $themedXamlRaw
$reader = New-Object Xml.XmlNodeReader $themedXamlDoc
$script:window = [Windows.Markup.XamlReader]::Load($reader)
$script:window.Width = [double]$script:layout.WinWidth
$script:window.Height = [double]$script:layout.WinHeight
$availableHeight = [Windows.SystemParameters]::WorkArea.Height - 32
$availableWidth = [Windows.SystemParameters]::WorkArea.Width - 32
if ($availableHeight -gt 0) {
    $script:window.Height = [Math]::Min($script:window.Height, $availableHeight)
    $script:window.MinHeight = [Math]::Min($script:window.MinHeight, $script:window.Height)
}
if ($availableWidth -gt 0) {
    $script:window.Width = [Math]::Min($script:window.Width, $availableWidth)
    $script:window.MinWidth = [Math]::Min($script:window.MinWidth, $script:window.Width)
}
$script:controls = @{}
foreach ($match in [regex]::Matches($xaml.OuterXml, 'x:Name="([^"]+)"')) {
    $script:controls[$match.Groups[1].Value] = $script:window.FindName($match.Groups[1].Value)
}
$script:brushConverter = [Windows.Media.BrushConverter]::new()
$script:lastDeletedTask = $null
$script:taskComposerState = @{}
$script:suppressComposerEvents = $false
$script:composerPodCache = @{}
$script:sessionQueueBannerBorders = @{}
$script:openQueueModalSessionKey = ''
$script:deferredPaneRebuildWhileTyping = $false
$script:pollInFlight = $false
$script:lastQueueRev = ''
$script:lastQueueActionUtc = [DateTime]::MinValue
$script:queueFastTimer = $null

function Get-TaskDraftState([string]$TaskKey) {
    $k = if ($TaskKey) { $TaskKey } else { '__new_task__' }
    if (-not $script:taskComposerState.ContainsKey($k)) {
        $script:taskComposerState[$k] = [pscustomobject]@{
            DraftText = ''
        }
    }
    return $script:taskComposerState[$k]
}

function ConvertTo-Brush([string]$Hex) {
    if (-not $Hex) { return $script:brushConverter.ConvertFromString('Transparent') }
    $key = $Hex.Trim().ToUpperInvariant()
    if ($key -eq 'TRANSPARENT') {
        return $script:brushConverter.ConvertFromString('Transparent')
    }
    if ($key -eq 'WHITE') { $key = '#FFFFFF' }
    if (-not $script:themeBrushes.ContainsKey($key)) {
        $resolved = Resolve-ThemeColorHex -Hex $key -Theme $script:effectiveTheme
        $script:themeBrushes[$key] = $script:brushConverter.ConvertFromString($resolved).Clone()
    }
    return $script:themeBrushes[$key]
}

function Ensure-GpuBitmapCache {
    param([Windows.UIElement]$Element)
    if (-not $Element) { return }
    try {
        if ($null -eq $Element.CacheMode) {
            $Element.CacheMode = New-Object Windows.Media.BitmapCache
        }
    } catch {}
}

function Start-SmoothEnterAnimation {
    param(
        [Windows.UIElement]$Element,
        [double]$FromY = -6.0,
        [int]$DurationMs = 145,
        [double]$FromX = 0.0
    )
    if (-not $Element) { return }
    if ($Element.Effect) {
        Ensure-GpuBitmapCache $Element
    }
    if ($NoShow) {
        $Element.Opacity = 1.0
        $Element.RenderTransform = [Windows.Media.TranslateTransform]::new(0, 0)
        return
    }
    try {
        $trans = New-Object Windows.Media.TranslateTransform($FromX, $FromY)
        $Element.RenderTransform = $trans
        $ease = New-Object Windows.Media.Animation.CubicEase
        $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
        $dur = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($DurationMs))

        $fadeAnim = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $dur)
        $fadeAnim.EasingFunction = $ease
        $Element.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeAnim)

        if ($FromX -ne 0.0) {
            $slideXAnim = New-Object Windows.Media.Animation.DoubleAnimation($FromX, 0.0, $dur)
            $slideXAnim.EasingFunction = $ease
            $trans.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $slideXAnim)
        }
        if ($FromY -ne 0.0) {
            $slideYAnim = New-Object Windows.Media.Animation.DoubleAnimation($FromY, 0.0, $dur)
            $slideYAnim.EasingFunction = $ease
            $trans.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slideYAnim)
        }
    } catch {
        $Element.Opacity = 1.0
    }
}

function Set-SmoothButtonAppearance {
    param(
        [Windows.Controls.Button]$Button,
        [string]$BgHex,
        [string]$BorderHex
    )
    if (-not $Button) { return }
    $Button.Resources['__RelayThemeBgHex'] = $BgHex
    $Button.Resources['__RelayThemeBdHex'] = $BorderHex
    if (-not $script:smoothAnimatedButtons.Contains($Button)) {
        [void]$script:smoothAnimatedButtons.Add($Button)
    }
    if ($NoShow) {
        $Button.Background = ConvertTo-Brush $BgHex
        $Button.BorderBrush = ConvertTo-Brush $BorderHex
        return
    }
    try {
        $resolvedBg = Resolve-ThemeColorHex -Hex $BgHex -Theme $script:effectiveTheme
        $resolvedBd = Resolve-ThemeColorHex -Hex $BorderHex -Theme $script:effectiveTheme
        $targetBgColor = [Windows.Media.ColorConverter]::ConvertFromString($resolvedBg)
        $targetBdColor = [Windows.Media.ColorConverter]::ConvertFromString($resolvedBd)
        $curBgColor = if ($Button.Background -is [Windows.Media.SolidColorBrush]) { $Button.Background.Color } else { $targetBgColor }
        $curBdColor = if ($Button.BorderBrush -is [Windows.Media.SolidColorBrush]) { $Button.BorderBrush.Color } else { $targetBdColor }

        $animBgBrush = New-Object Windows.Media.SolidColorBrush($curBgColor)
        $animBdBrush = New-Object Windows.Media.SolidColorBrush($curBdColor)
        $Button.Background = $animBgBrush
        $Button.BorderBrush = $animBdBrush

        $dur = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(140))
        $ease = New-Object Windows.Media.Animation.CubicEase
        $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut

        $bgAnim = New-Object Windows.Media.Animation.ColorAnimation($targetBgColor, $dur)
        $bgAnim.EasingFunction = $ease
        $bdAnim = New-Object Windows.Media.Animation.ColorAnimation($targetBdColor, $dur)
        $bdAnim.EasingFunction = $ease

        $animBgBrush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $bgAnim)
        $animBdBrush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $bdAnim)
    } catch {
        $Button.Background = ConvertTo-Brush $BgHex
        $Button.BorderBrush = ConvertTo-Brush $BorderHex
    }
}

function Attach-WindowTitleDrag([Windows.UIElement]$HeaderElement) {
    if (-not $HeaderElement) { return }
    $HeaderElement.Add_MouseLeftButtonDown({
        param($sender, $e)
        $curr = $e.OriginalSource
        while ($null -ne $curr -and $curr -ne $sender) {
            if ($curr -is [Windows.Controls.Primitives.ButtonBase] -or $curr -is [Windows.Controls.TextBox] -or $curr -is [Windows.Controls.ComboBox]) {
                return
            }
            $curr = if ($curr -is [Windows.Media.Visual] -or $curr -is [Windows.Media.Media3D.Visual3D]) {
                [Windows.Media.VisualTreeHelper]::GetParent($curr)
            } else { $null }
        }
        if ($e.ClickCount -eq 2) {
            $script:window.WindowState = if ($script:window.WindowState -eq [Windows.WindowState]::Maximized) {
                [Windows.WindowState]::Normal
            } else {
                [Windows.WindowState]::Maximized
            }
            $e.Handled = $true
            return
        }
        if ($e.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) {
            try { $script:window.DragMove() } catch { }
        }
    })
}

function New-VectorIcon([string]$Kind, [double]$Size = 14, [string]$ColorHex = '#71717A', [double]$StrokeWidth = 1.8) {
    $data = switch ($Kind) {
        'plug'         { 'M12 2v4 M8 2v4 M16 2v4 M6 6h12v5a6 6 0 0 1-12 0V6z M12 17v5' }
        'sidebar'      { 'M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z M9 4v16' }
        'list'         { 'M8 6h13 M8 12h13 M8 18h13 M3 6h.01 M3 12h.01 M3 18h.01' }
        'split'        { 'M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z M12 4v16' }
        'close'        { 'M18 6L6 18 M6 6l12 12' }
        'minimize'     { 'M5 12h14' }
        'maximize'     { 'M5 5h14v14H5z' }
        'edit'         { 'M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z' }
        'archive'      { 'M3 4h18v4H3z M5 8v11a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8 M10 12h4' }
        'restore'      { 'M3 7v6h6 M3 13a9 9 0 1 0 2.5-6.3L3 9' }
        'trash'        { 'M3 6h18 M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2 M19 6v13a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V6 M10 11v5 M14 11v5' }
        'send'         { 'M22 2L11 13 M22 2l-7 20-4-9-9-4 20-7z' }
        'arrowDown'    { 'M12 5v14 M19 12l-7 7-7-7' }
        'externalLink' { 'M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6 M15 3h6v6 M10 14L21 3' }
        default        { 'M12 12h.01' }
    }
    $vb = New-Object Windows.Controls.Viewbox
    $vb.Width = $Size
    $vb.Height = $Size
    $vb.VerticalAlignment = 'Center'
    $vb.HorizontalAlignment = 'Center'
    $canvas = New-Object Windows.Controls.Canvas
    $canvas.Width = 24
    $canvas.Height = 24
    $path = New-Object Windows.Shapes.Path
    $path.Data = [Windows.Media.Geometry]::Parse($data)
    $path.Stroke = ConvertTo-Brush $ColorHex
    $path.StrokeThickness = $StrokeWidth
    $path.StrokeStartLineCap = [Windows.Media.PenLineCap]::Round
    $path.StrokeEndLineCap = [Windows.Media.PenLineCap]::Round
    $path.StrokeLineJoin = [Windows.Media.PenLineJoin]::Round
    [void]$canvas.Children.Add($path)
    $vb.Child = $canvas
    return $vb
}

function New-QuietIconButton {
    param(
        [string]$Kind,
        [Alias('ToolTip')][string]$TooltipText = '',
        [int]$BoxSize = 24,
        [double]$IconSize = 13.5,
        [bool]$IsDanger = $false,
        $Tag = $null
    )
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $script:window.Resources['IconButton']
    $btn.Width = $BoxSize
    $btn.Height = $BoxSize
    $btn.MinHeight = $BoxSize
    $btn.ToolTip = $TooltipText
    if ($null -ne $Tag) { $btn.Tag = $Tag }
    $colorHex = if ($IsDanger) { '#A1A1AA' } else { '#71717A' }
    $btn.Content = New-VectorIcon -Kind $Kind -Size $IconSize -ColorHex $colorHex
    if ($IsDanger) {
        $btn.Add_MouseEnter({
            param($s, $e)
            $s.Content = New-VectorIcon -Kind 'trash' -Size 13.5 -ColorHex '#DC2626'
            $s.Background = ConvertTo-Brush '#FEF2F2'
        })
        $btn.Add_MouseLeave({
            param($s, $e)
            $s.Content = New-VectorIcon -Kind 'trash' -Size 13.5 -ColorHex '#A1A1AA'
            $s.Background = ConvertTo-Brush 'Transparent'
        })
    }
    return $btn
}

function Show-QuickToast([string]$Message) {
    if (-not $Message) { return }
    $script:controls.QuickToastText.Text = $Message
    $script:controls.QuickToastBorder.Visibility = 'Visible'
    Start-SmoothEnterAnimation $script:controls.QuickToastBorder -FromY -8 -DurationMs 155
    if (-not $script:toastTimer) {
        $script:toastTimer = New-Object Windows.Threading.DispatcherTimer
        $script:toastTimer.Interval = [TimeSpan]::FromMilliseconds(2200)
        $script:toastTimer.Add_Tick({
            $script:toastTimer.Stop()
            $script:controls.QuickToastBorder.Visibility = 'Collapsed'
        })
    }
    $script:toastTimer.Stop()
    $script:toastTimer.Start()
}

function Sync-LayoutMemory {
    if ($script:initializing) { return }
    $script:layout.WinWidth = [int][Math]::Round($script:window.Width)
    $script:layout.WinHeight = [int][Math]::Round($script:window.Height)
    Save-WindowLayoutMemory -Context $script:context -Layout $script:layout
    Update-MemoryFootprintLabel
}

function Request-DeferredLayoutSync {
    if ($script:initializing) { return }
    $script:layout.WinWidth = [int][Math]::Round($script:window.Width)
    $script:layout.WinHeight = [int][Math]::Round($script:window.Height)
    Update-MemoryFootprintLabel
    if ($NoShow) {
        Save-WindowLayoutMemory -Context $script:context -Layout $script:layout
        return
    }
    if (-not $script:deferredLayoutSyncTimer) {
        $script:deferredLayoutSyncTimer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
        $script:deferredLayoutSyncTimer.Interval = [TimeSpan]::FromMilliseconds(220)
        $script:deferredLayoutSyncTimer.Add_Tick({
            $script:deferredLayoutSyncTimer.Stop()
            Save-WindowLayoutMemory -Context $script:context -Layout $script:layout
        })
    }
    $script:deferredLayoutSyncTimer.Stop()
    $script:deferredLayoutSyncTimer.Start()
}

function Update-OptionButtonGroupState($Pairs, $SelectedValue) {
    foreach ($pair in @($Pairs)) {
        if (-not $pair -or -not $pair.Btn) { continue }
        if ($pair.Val -eq $SelectedValue) {
            $pair.Btn.Background = ConvertTo-Brush '#EFF6FF'
            $pair.Btn.BorderBrush = ConvertTo-Brush '#BFDBFE'
            $pair.Btn.Foreground = ConvertTo-Brush '#1D4ED8'
            $pair.Btn.FontWeight = 'SemiBold'
        } else {
            $pair.Btn.Background = ConvertTo-Brush '#FFFFFF'
            $pair.Btn.BorderBrush = ConvertTo-Brush '#E4E4E7'
            $pair.Btn.Foreground = ConvertTo-Brush '#52525B'
            $pair.Btn.FontWeight = 'Normal'
        }
    }
}

function Apply-WindowTheme([string]$ThemeMode = '') {
    if ($ThemeMode) {
        $script:layout.ThemeMode = Resolve-NormalizedThemeMode $ThemeMode
    }
    if (-not ($script:layout.PSObject.Properties.Name -contains 'ThemeMode') -or -not $script:layout.ThemeMode) {
        $script:layout | Add-Member -NotePropertyName 'ThemeMode' -NotePropertyValue 'system' -Force
    } else {
        $script:layout.ThemeMode = Resolve-NormalizedThemeMode ([string]$script:layout.ThemeMode)
    }
    $script:effectiveTheme = Resolve-EffectiveTheme -ThemeMode ([string]$script:layout.ThemeMode)
    $isDark = ($script:effectiveTheme -eq 'dark')

    foreach ($hexKey in $script:xamlThemeHexKeys) {
        $resKey = 'ThemeBrush_' + $hexKey.TrimStart('#')
        $targetHex = Resolve-ThemeColorHex -Hex $hexKey -Theme $script:effectiveTheme
        $script:window.Resources[$resKey] = $script:brushConverter.ConvertFromString($targetHex)
    }
    foreach ($k in @($script:themeBrushes.Keys)) {
        $targetHex = Resolve-ThemeColorHex -Hex $k -Theme $script:effectiveTheme
        $script:themeBrushes[$k].Color = ($script:brushConverter.ConvertFromString($targetHex)).Color
    }
    foreach ($btn in @($script:smoothAnimatedButtons)) {
        if (-not $btn) { continue }
        $bgH = [string]$btn.Resources['__RelayThemeBgHex']
        $bdH = [string]$btn.Resources['__RelayThemeBdHex']
        if ($bgH) { $btn.Background = ConvertTo-Brush $bgH }
        if ($bdH) { $btn.BorderBrush = ConvertTo-Brush $bdH }
    }

    if ($script:controls.ThemeToggleIconPath) {
        $iconData = if ($isDark) {
            'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z M12 2v2 M12 20v2 M4.93 4.93l1.41 1.41 M17.66 17.66l1.41 1.41 M2 12h2 M20 12h2 M6.34 17.66l-1.41 1.41 M19.07 4.93l-1.41 1.41'
        } else {
            'M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z'
        }
        $script:controls.ThemeToggleIconPath.Data = [Windows.Media.Geometry]::Parse($iconData)
    }
    if ($script:controls.ThemeToggleButton) {
        $curModeLabel = switch ([string]$script:layout.ThemeMode) {
            'dark'   { '深色模式' }
            'light'  { '浅色模式' }
            default  { '跟随系统（当前' + $(if ($isDark) { '深色' } else { '浅色' }) + '）' }
        }
        $nextLabel = if ($isDark) { '浅色模式' } else { '深色模式' }
        $script:controls.ThemeToggleButton.ToolTip = "当前主题：$curModeLabel`n左键点击（或 Ctrl+Shift+D）：一键切换为「$nextLabel」`n右键点击：恢复「跟随系统」"
    }

    Update-OptionButtonGroupState @(
        @{ Btn = $script:controls.ThemeSystemButton; Val = 'system' },
        @{ Btn = $script:controls.ThemeLightButton;  Val = 'light' },
        @{ Btn = $script:controls.ThemeDarkButton;   Val = 'dark' }
    ) ([string]$script:layout.ThemeMode)

    if ($script:trayMenu) {
        try {
            $trayBg = if ($isDark) { [System.Drawing.Color]::FromArgb(24, 24, 27) } else { [System.Drawing.Color]::FromArgb(255, 255, 255) }
            $trayFg = if ($isDark) { [System.Drawing.Color]::FromArgb(244, 244, 245) } else { [System.Drawing.Color]::FromArgb(24, 24, 27) }
            $script:trayMenu.BackColor = $trayBg
            $script:trayMenu.ForeColor = $trayFg
            foreach ($it in $script:trayMenu.Items) {
                $it.BackColor = $trayBg
                $it.ForeColor = $trayFg
            }
            if ($script:trayItemThemeToggle) {
                $script:trayItemThemeToggle.Text = if ($isDark) { '☀ 切换为浅色模式 (Ctrl+Shift+D)' } else { '🌙 切换为深色模式 (Ctrl+Shift+D)' }
            }
            if ($script:trayItemThemeSystem) {
                $script:trayItemThemeSystem.Checked = ([string]$script:layout.ThemeMode -eq 'system')
            }
        } catch {}
    }
}

function Invoke-QuickThemeToggle([string]$Action = 'invert') {
    $nextMode = Step-QuickThemeToggle -CurrentThemeMode ([string]$script:layout.ThemeMode) -EffectiveTheme ([string]$script:effectiveTheme) -Action $Action
    $script:layout.ThemeMode = $nextMode
    Apply-WindowTheme -ThemeMode $nextMode
    Save-WindowLayoutMemory -Context $script:context -Layout $script:layout
    $msg = switch ($nextMode) {
        'system' { '已恢复「跟随系统」主题' }
        'dark'   { '已切换为「深色模式」' }
        default  { '已切换为「浅色模式」' }
    }
    Show-QuickToast $msg
}

function Update-MemoryFootprintLabel {
    $script:controls.MemoryFootprintText.Text = '关闭窗口不断开隧道 · 尺寸已自动记忆'
}

function Apply-LeftRailGeometry {
    if ($script:railAnimTimer -and $script:railAnimTimer.IsEnabled) {
        $script:railAnimTimer.Stop()
    }
    if ($script:controls.LeftTaskRail.Child -is [Windows.FrameworkElement]) {
        $script:controls.LeftTaskRail.Child.Width = [Double]::NaN
        $script:controls.LeftTaskRail.Child.HorizontalAlignment = 'Stretch'
    }
    if ($script:layout.RailCollapsed) {
        $script:controls.LeftRailColumn.Width = [Windows.GridLength]::new(0)
        $script:controls.LeftTaskRail.Visibility = 'Collapsed'
        if ($script:controls.WorkspaceOuterBorder) {
            $script:controls.WorkspaceOuterBorder.Margin = [Windows.Thickness]::new(4, 0, 7, 7)
        }
    } else {
        $w = [Math]::Min($script:RAIL_MAX_WIDTH_PX, [Math]::Max($script:RAIL_MIN_WIDTH_PX, [double]$script:layout.RailWidth))
        $script:layout.RailWidth = [int][Math]::Round($w)
        $script:controls.LeftRailColumn.Width = [Windows.GridLength]::new($w)
        $script:controls.LeftTaskRail.Visibility = 'Visible'
        if ($script:controls.WorkspaceOuterBorder) {
            $script:controls.WorkspaceOuterBorder.Margin = [Windows.Thickness]::new(0, 0, 7, 7)
        }
    }
    $script:controls.SnapHideRailBadge.Visibility = 'Collapsed'
    $script:controls.LeftTaskRail.Opacity = 1.0
    Update-MemoryFootprintLabel
}

function Start-LeftRailDrawerAnimation([double]$FromW, [double]$ToW, [int]$DurationMs = 150) {
    if ($script:railAnimTimer -and $script:railAnimTimer.IsEnabled) {
        $script:railAnimTimer.Stop()
    }
    $script:railAnimCtx = $null
    Apply-LeftRailGeometry
    if ($NoShow) { return }
    if ($ToW -gt $FromW) {
        Start-SmoothEnterAnimation -Element $script:controls.LeftTaskRail -FromX -14.0 -FromY 0.0 -DurationMs $DurationMs
    } else {
        Start-SmoothEnterAnimation -Element $script:controls.WorkspaceOuterBorder -FromX -8.0 -FromY 0.0 -DurationMs 135
    }
}

function Test-HasUnsavedFormEdits {
    # Systematic unsaved-input check: only returns $true when the user has the Config edit form open
    # AND the current input fields actually differ from the saved profile/settings on disk.
    if (-not $script:controls.FormScroll -or $script:controls.FormScroll.Visibility -ne 'Visible') {
        return $false
    }
    if (-not $script:dirty) {
        return $false
    }
    $allProfs = @(if ($script:profilesState -and $script:profilesState.Profiles) { $script:profilesState.Profiles })
    $viewProf = $allProfs | Where-Object { $_.Id -eq $script:viewingProfileId } | Select-Object -First 1
    if ($script:viewingProfileId -eq 'new') {
        return (($script:controls.TunnelInput.Text.Trim().Length -gt 0) -or ($script:controls.KeyInput.Text.Trim().Length -gt 0))
    }
    $savedName = if ($viewProf -and $viewProf.Name) { [string]$viewProf.Name.Trim() } else { '' }
    $curName = if ($script:controls.ProfileNameInput) { [string]$script:controls.ProfileNameInput.Text.Trim() } else { $savedName }
    $savedTunnel = if ($viewProf -and $viewProf.TunnelId) { [string]$viewProf.TunnelId.Trim() } elseif ($script:settings.tunnel_id) { [string]$script:settings.tunnel_id.Trim() } else { '' }
    $curTunnel = [string]$script:controls.TunnelInput.Text.Trim()
    $savedKey = if ($viewProf -and $viewProf.PlainKey) { [string]$viewProf.PlainKey.Trim() } else { '' }
    $curKey = [string]$script:controls.KeyInput.Text.Trim()
    $hasSecret = ($curKey -ne $savedKey)
    $advDiff = ([string]$script:controls.BaseInput.Text.Trim() -ne [string]$script:settings.api_base_url.Trim()) -or
               ([string]$script:controls.RootInput.Text.Trim() -ne [string]$script:settings.runtime_root.Trim()) -or
               ([string]$script:controls.ClientInput.Text.Trim() -ne [string]$script:settings.tunnel_client.Trim()) -or
               ([bool]$script:controls.ShieldCheck.IsChecked -ne [bool]$script:settings.readonly_shield)
    return (($curName -ne $savedName) -or ($curTunnel -ne $savedTunnel) -or $hasSecret -or $advDiff)
}

function Toggle-LeftRail {
    # Outer window width & height NEVER change when toggling left rail!
    $wasCollapsed = [bool]$script:layout.RailCollapsed
    $script:layout.RailCollapsed = -not $wasCollapsed
    if ([double]$script:layout.RailWidth -lt $script:RAIL_MIN_WIDTH_PX) {
        $script:layout.RailWidth = 260
    }
    $targetW = [Math]::Min($script:RAIL_MAX_WIDTH_PX, [Math]::Max($script:RAIL_MIN_WIDTH_PX, [double]$script:layout.RailWidth))
    Request-DeferredLayoutSync
    if ($NoShow) {
        Apply-LeftRailGeometry
        Render-PanesWorkspace
    } else {
        if ($script:layout.RailCollapsed) {
            Start-LeftRailDrawerAnimation -FromW $targetW -ToW 0.0 -DurationMs 145
        } else {
            Start-LeftRailDrawerAnimation -FromW 0.0 -ToW $targetW -DurationMs 145
        }
    }
}

function Reset-DefaultWindowLayout {
    $prevTheme = if ($script:layout -and ($script:layout.PSObject.Properties.Name -contains 'ThemeMode')) { [string]$script:layout.ThemeMode } else { 'system' }
    $script:layout = Reset-WindowLayoutMemory $script:context
    $script:layout.ThemeMode = Resolve-NormalizedThemeMode $prevTheme
    Save-WindowLayoutMemory -Context $script:context -Layout $script:layout
    $script:window.Width = [double]$script:layout.WinWidth
    $script:window.Height = [double]$script:layout.WinHeight
    Apply-WindowTheme -ThemeMode $script:layout.ThemeMode
    Apply-LeftRailGeometry
    Render-PanesWorkspace
    Show-QuickToast '已重置为默认窗口尺寸与分栏比例'
}

$script:popoverExpandedProfileId = ''
$script:globalSettingsOpen = $false
$script:suppressDefaultCarrierComboEvent = $false
$script:capsuleSegmentButtons = @{}
$script:lastTestedApiKeyProfileId = ''

function Sync-PopoverAnchorAndAnimate {
    param(
        [Windows.Controls.Border]$PopoverBorder,
        [Windows.FrameworkElement]$TriggerElement = $null,
        [bool]$WasAlreadyOpen = $false
    )
    if (-not $PopoverBorder) { return }
    if (-not ($PopoverBorder.CacheMode -is [Windows.Media.BitmapCache])) { try { $PopoverBorder.CacheMode = New-Object Windows.Media.BitmapCache } catch {} }
    try {
        if ($script:window -and $script:window.Content -is [Windows.UIElement]) {
            $rootEl = [Windows.UIElement]$script:window.Content
            $winW = if ($script:window.ActualWidth -gt 0) { [double]$script:window.ActualWidth } elseif ($script:window.Width -gt 0) { [double]$script:window.Width } else { 1180.0 }
            $winH = if ($script:window.ActualHeight -gt 0) { [double]$script:window.ActualHeight } elseif ($script:window.Height -gt 0) { [double]$script:window.Height } else { 740.0 }
            if (-not $TriggerElement -or $TriggerElement.ActualWidth -le 0) {
                $rootEl.Measure([Windows.Size]::new($winW, $winH))
                $rootEl.Arrange([Windows.Rect]::new(0, 0, $winW, $winH))
                $rootEl.UpdateLayout()
            }
            $popW = if ($PopoverBorder.Width -gt 0) { [double]$PopoverBorder.Width } elseif ($PopoverBorder.ActualWidth -gt 0) { [double]$PopoverBorder.ActualWidth } else { 460.0 }
            $prevLeft = [double]$PopoverBorder.Margin.Left
            $targetLeft = $prevLeft
            if ($TriggerElement) {
                $pt = $TriggerElement.TranslatePoint([Windows.Point]::new(0, 0), $rootEl)
                $maxLeft = [Math]::Max(14.0, $winW - $popW - 14.0)
                $targetLeft = [Math]::Round([Math]::Max(14.0, [Math]::Min($maxLeft, $pt.X)))
            }
            $PopoverBorder.HorizontalAlignment = 'Left'
            $PopoverBorder.Margin = [Windows.Thickness]::new($targetLeft, 38, 0, 0)

            $scaleTrans = New-Object Windows.Media.ScaleTransform(1.0, 1.0)
            $transTrans = New-Object Windows.Media.TranslateTransform(0.0, 0.0)
            $tGroup = New-Object Windows.Media.TransformGroup
            [void]$tGroup.Children.Add($scaleTrans)
            [void]$tGroup.Children.Add($transTrans)
            $PopoverBorder.RenderTransformOrigin = [Windows.Point]::new(0.15, 0.0)
            $PopoverBorder.RenderTransform = $tGroup

            if (-not $NoShow) {
                $dur = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))
                $ease = New-Object Windows.Media.Animation.QuarticEase
                $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
                if ($WasAlreadyOpen -and [Math]::Abs($prevLeft - $targetLeft) -gt 2.0) {
                    $deltaX = [double]($prevLeft - $targetLeft)
                    $animX = New-Object Windows.Media.Animation.DoubleAnimation($deltaX, 0.0, $dur)
                    $animX.EasingFunction = $ease
                    $transTrans.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $animX)
                } else {
                    $animOp = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $dur)
                    $animOp.EasingFunction = $ease
                    $PopoverBorder.BeginAnimation([Windows.UIElement]::OpacityProperty, $animOp)
                    $animY = New-Object Windows.Media.Animation.DoubleAnimation(-7.0, 0.0, $dur)
                    $animY.EasingFunction = $ease
                    $transTrans.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $animY)
                    $animSX = New-Object Windows.Media.Animation.DoubleAnimation(0.975, 1.0, $dur)
                    $animSX.EasingFunction = $ease
                    $scaleTrans.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $animSX)
                    $animSY = New-Object Windows.Media.Animation.DoubleAnimation(0.975, 1.0, $dur)
                    $animSY.EasingFunction = $ease
                    $scaleTrans.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $animSY)
                }
            } else {
                $PopoverBorder.Opacity = 1.0
            }
        }
    } catch { }
}

function Close-AllTopPopovers {
    $script:popoverOpen = $false
    $script:addPlatformPickerOpen = $false
    $script:globalSettingsOpen = $false
    $script:popoverExpandedProfileId = ''
    $script:popoverEditMode = $false
    if ($script:controls.AddPlatformPanelBorder) { $script:controls.AddPlatformPanelBorder.Visibility = 'Collapsed' }
    if ($script:controls.KeyPopoverBorder) { $script:controls.KeyPopoverBorder.Visibility = 'Collapsed' }
    if ($script:controls.GlobalSettingsPopoverBorder) { $script:controls.GlobalSettingsPopoverBorder.Visibility = 'Collapsed' }
    if ($script:activeTab -eq 'Config') {
        Select-WindowTab 'Live'
    }
}

function Select-WindowTab([string]$TabName) {
    $script:activeTab = if ($TabName -eq 'Config') { 'Config' } else { 'Live' }
    if ($script:activeTab -eq 'Live') {
        $script:dirty = $false
        $script:popoverOpen = $false
        $script:addPlatformPickerOpen = $false
        $script:popoverEditMode = $false
        $script:popoverExpandedProfileId = ''
        $script:controls.KeyPopoverBorder.Visibility = 'Collapsed'
        $script:controls.LiveTabPanel.Visibility = 'Visible'
        $script:controls.FormScroll.Visibility = 'Collapsed'
        if ($script:controls.PopoverDetailCardBorder) { $script:controls.PopoverDetailCardBorder.Visibility = 'Collapsed' }
        $script:controls.PopoverViewPanel.Visibility = 'Visible'
        $script:controls.TabLiveButton.BorderBrush = ConvertTo-Brush '#2563EB'
        $script:controls.TabLiveButton.Foreground = ConvertTo-Brush '#2563EB'
        $script:controls.TabConfigButton.BorderBrush = ConvertTo-Brush 'Transparent'
        $script:controls.TabConfigButton.Foreground = ConvertTo-Brush '#71717A'
    } else {
        $script:globalSettingsOpen = $false
        $script:addPlatformPickerOpen = $false
        if ($script:controls.GlobalSettingsPopoverBorder) { $script:controls.GlobalSettingsPopoverBorder.Visibility = 'Collapsed' }
        $wasOpen = [bool]$script:popoverOpen
        $script:popoverOpen = $true
        $script:popoverEditMode = $true
        if (-not $script:popoverExpandedProfileId) {
            $script:popoverExpandedProfileId = if ($script:viewingProfileId) { $script:viewingProfileId } else { 'prof_primary' }
        }
        $script:controls.KeyPopoverBorder.Visibility = 'Visible'
        $script:controls.LiveTabPanel.Visibility = 'Visible'
        if ($script:controls.PopoverDetailCardBorder) { $script:controls.PopoverDetailCardBorder.Visibility = 'Collapsed' }
        $script:controls.FormScroll.Visibility = 'Visible'
        $script:controls.PopoverViewPanel.Visibility = 'Visible'
        $script:controls.TabConfigButton.BorderBrush = ConvertTo-Brush '#2563EB'
        $script:controls.TabConfigButton.Foreground = ConvertTo-Brush '#2563EB'
        $script:controls.TabLiveButton.BorderBrush = ConvertTo-Brush 'Transparent'
        $script:controls.TabLiveButton.Foreground = ConvertTo-Brush '#71717A'
        Refresh-ProfilePopoverState
        $trig = if ($script:activeCapsulePlatform -and $script:activeCapsulePlatform -notin @('openai', 'chatgpt') -and $script:capsuleSegmentButtons[$script:activeCapsulePlatform]) {
            $script:capsuleSegmentButtons[$script:activeCapsulePlatform]
        } else {
            $script:controls.ConnIconBadgeButton
        }
        Sync-PopoverAnchorAndAnimate -PopoverBorder $script:controls.KeyPopoverBorder -TriggerElement $trig -WasAlreadyOpen $wasOpen
    }
}

function Toggle-KeyPopover {
    $script:popoverOpen = -not $script:popoverOpen
    if ($script:popoverOpen) {
        $script:globalSettingsOpen = $false
        $script:addPlatformPickerOpen = $false
        if ($script:controls.GlobalSettingsPopoverBorder) { $script:controls.GlobalSettingsPopoverBorder.Visibility = 'Collapsed' }
        $script:popoverEditMode = $false
        $script:popoverExpandedProfileId = ''
        $script:controls.LiveTabPanel.Visibility = 'Visible'
        if ($script:controls.PopoverDetailCardBorder) { $script:controls.PopoverDetailCardBorder.Visibility = 'Collapsed' }
        $script:controls.FormScroll.Visibility = 'Collapsed'
        $script:controls.PopoverViewPanel.Visibility = 'Visible'
        $script:controls.KeyPopoverBorder.Visibility = 'Visible'
        Refresh-ProfilePopoverState
        $trig = if ($script:activeCapsulePlatform -and $script:activeCapsulePlatform -notin @('openai', 'chatgpt') -and $script:capsuleSegmentButtons[$script:activeCapsulePlatform]) {
            $script:capsuleSegmentButtons[$script:activeCapsulePlatform]
        } else {
            $script:controls.ConnIconBadgeButton
        }
        Sync-PopoverAnchorAndAnimate -PopoverBorder $script:controls.KeyPopoverBorder -TriggerElement $trig -WasAlreadyOpen $false
    } else {
        Close-AllTopPopovers
    }
}

function Toggle-GlobalSettingsPopover {
    $script:globalSettingsOpen = -not $script:globalSettingsOpen
    if ($script:globalSettingsOpen) {
        $script:popoverOpen = $false
        $script:addPlatformPickerOpen = $false
        $script:popoverExpandedProfileId = ''
        $script:popoverEditMode = $false
        if ($script:controls.KeyPopoverBorder) { $script:controls.KeyPopoverBorder.Visibility = 'Collapsed' }
        if ($script:controls.GlobalSettingsPopoverBorder) {
            $script:controls.GlobalSettingsPopoverBorder.Visibility = 'Visible'
        }
        Refresh-ProfilePopoverState
        Sync-PopoverAnchorAndAnimate -PopoverBorder $script:controls.GlobalSettingsPopoverBorder -TriggerElement $script:controls.GlobalSettingsButton -WasAlreadyOpen $false
    } else {
        if ($script:controls.GlobalSettingsPopoverBorder) {
            $script:controls.GlobalSettingsPopoverBorder.Visibility = 'Collapsed'
        }
    }
}

function Select-DefaultCliAgent([string]$AgentId, [string]$DisplayName = '') {
    if (-not $AgentId) { return }
    $cfg = Get-CoreEngineConfig $script:context
    $script:settings = (Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile $AgentId -BrowserEnabled ([bool]$cfg.BrowserEnabled) -StartupMode ([string]$cfg.StartupMode) -ApplyStartup:(-not $script:context.Isolated)).Settings
    if (-not $script:context.Isolated) { [void](Restart-LocalCoreEngine $script:context $script:settings) }
    Refresh-ProfilePopoverState
    Refresh-FormState
    $label = if ($DisplayName) { $DisplayName } else { $AgentId }
    Show-QuickToast "已将默认 CLI 智能体切换为 $label"
}

function Invoke-AddCustomCliAgentDialog {
    $chosenPath = ''
    $ovVar = Get-Variable -Name 'CustomCliPathOverride' -Scope Script -ErrorAction SilentlyContinue
    if ($ovVar -and $ovVar.Value) {
        $chosenPath = [string]$ovVar.Value
    } else {
        $noShowVar = Get-Variable -Name 'NoShow' -ErrorAction SilentlyContinue
        if ($noShowVar -and [bool]$noShowVar.Value) { return }
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = '选择本机 CLI 智能体可执行文件 (.cmd / .exe)'
        $dlg.Filter = 'CLI 可执行文件 (*.cmd;*.exe;*.bat)|*.cmd;*.exe;*.bat|所有文件 (*.*)|*.*'
        if ($dlg.ShowDialog() -eq $true) {
            $chosenPath = [string]$dlg.FileName
        }
    }
    if (-not $chosenPath) { return }
    try {
        $res = Add-CustomCliAgent -Context $script:context -CommandPath $chosenPath
        $script:settings = $res.Settings
        Refresh-ProfilePopoverState
        Show-QuickToast "✓ 已添加 CLI 智能体「$($res.AddedAgent.display_name)」"
    } catch {
        Show-QuickToast $_.Exception.Message
    }
}

function Invoke-RescanCliAgents {
    $agents = @(Get-DetectedCliAgents -ForceRescan -Settings $script:settings -Context $script:context)
    Refresh-ProfilePopoverState
    Show-QuickToast "✓ 已重新检测本机 CLI 智能体（共发现 $($agents.Count) 个）"
}

function Get-CapsulePlatformMeta([string]$Platform = 'chatgpt') {
    $p = if ($Platform) { $Platform.Trim().ToLowerInvariant() } else { 'chatgpt' }
    if ($p -eq 'openai') { $p = 'chatgpt' }
    switch ($p) {
        'claude' {
            return [pscustomobject]@{
                Code = 'claude'; Title = 'Claude'; Kind = 'public_tunnel'
                DefaultUrl = ''
                PurposeDesc = '共享公网 MCP 隧道 · 连接 Claude 云端会话房间'
                SecondLabel = '固定 HTTPS 域名（选填，留空使用临时隧道）'; KeyLabel = 'Cloudflare 隧道凭证（选填）'
                ApiKeysUrl = 'https://developers.cloudflare.com/tunnel/get-started/'
                PlatText = '网页端 Connectors ↗'; PlatUrl = 'https://claude.ai/settings/connectors'
            }
        }
        'gemini' {
            return [pscustomobject]@{
                Code = 'gemini'; Title = 'Gemini'; Kind = 'public_tunnel'
                DefaultUrl = ''
                PurposeDesc = '共享公网 MCP 隧道 · 连接 Gemini 云端会话房间'
                SecondLabel = '固定 HTTPS 域名（选填，留空使用临时隧道）'; KeyLabel = 'Cloudflare 隧道凭证（选填）'
                ApiKeysUrl = 'https://developers.cloudflare.com/tunnel/get-started/'
                PlatText = '已关联的应用 ↗'; PlatUrl = 'https://gemini.google.com/extensions'
            }
        }
        default {
            return [pscustomobject]@{
                Code = 'chatgpt'; Title = 'ChatGPT'; Kind = 'tunnel'
                DefaultUrl = 'https://api.openai.com'
                PurposeDesc = 'MCP 反向隧道连接与 API Key · 供 ChatGPT 网页端操控本地电脑'
                SecondLabel = '隧道编号或完整链接'; KeyLabel = 'OpenAI API Key (仅用于拉起本地 MCP 隧道)'
                ApiKeysUrl = 'https://platform.openai.com/settings/organization/api-keys'
                PlatText = '打开 OpenAI 隧道设置 ↗'; PlatUrl = 'https://platform.openai.com/settings/organization/tunnels'
            }
        }
    }
}

function Select-CapsulePlatform([string]$Platform = 'chatgpt', [Windows.FrameworkElement]$TriggerButton = $null) {
    $p = if ($Platform) { $Platform.Trim().ToLowerInvariant() } else { 'chatgpt' }
    if ($p -eq 'openai') { $p = 'chatgpt' }
    if ($script:popoverOpen -and (-not $script:addPlatformPickerOpen) -and $script:activeCapsulePlatform -eq $p) {
        Close-AllTopPopovers
        return
    }
    $wasOpen = [bool]$script:popoverOpen
    $script:activeCapsulePlatform = $p
    $script:addPlatformPickerOpen = $false
    if ($script:controls.AddPlatformPanelBorder) {
        $script:controls.AddPlatformPanelBorder.Visibility = 'Collapsed'
    }
    $script:globalSettingsOpen = $false
    if ($script:controls.GlobalSettingsPopoverBorder) {
        $script:controls.GlobalSettingsPopoverBorder.Visibility = 'Collapsed'
    }
    $script:popoverEditMode = $false
    $script:popoverExpandedProfileId = ''
    if ($script:controls.FormScroll) { $script:controls.FormScroll.Visibility = 'Collapsed' }
    $script:profilesState = Get-ConnectionProfiles $script:context $script:settings
    $platProfs = @($script:profilesState.Profiles | Where-Object {
        $pl = if ($_.PSObject.Properties['Platform'] -and $_.Platform) { ([string]$_.Platform).ToLowerInvariant() } else { 'chatgpt' }
        if ($pl -eq 'openai') { $pl = 'chatgpt' }
        $pl -eq $p
    })
    $actProf = $platProfs | Where-Object { $_.IsActive } | Select-Object -First 1
    if (-not $actProf -and $platProfs.Count -gt 0) { $actProf = $platProfs[0] }
    $script:viewingProfileId = if ($actProf) { [string]$actProf.Id } else { '' }
    $script:popoverOpen = $true
    if ($script:controls.KeyPopoverBorder) {
        $script:controls.KeyPopoverBorder.Visibility = 'Visible'
    }
    Refresh-ProfilePopoverState
    $resolvedTrigger = if ($p -in @('openai', 'chatgpt')) {
        $script:controls.ConnIconBadgeButton
    } elseif ($script:capsuleSegmentButtons -and $script:capsuleSegmentButtons[$p]) {
        $script:capsuleSegmentButtons[$p]
    } elseif ($TriggerButton) {
        $TriggerButton
    } else {
        $script:controls.ConnIconBadgeButton
    }
    Sync-PopoverAnchorAndAnimate -PopoverBorder $script:controls.KeyPopoverBorder -TriggerElement $resolvedTrigger -WasAlreadyOpen $wasOpen
}

function Toggle-AddPlatformPopover {
    $script:globalSettingsOpen = $false
    if ($script:controls.GlobalSettingsPopoverBorder) {
        $script:controls.GlobalSettingsPopoverBorder.Visibility = 'Collapsed'
    }
    if ($script:popoverOpen -and $script:addPlatformPickerOpen) {
        Close-AllTopPopovers
        return
    }
    $wasOpen = [bool]$script:popoverOpen
    $script:popoverOpen = $true
    $script:addPlatformPickerOpen = $true
    $script:popoverEditMode = $false
    $script:popoverExpandedProfileId = ''
    if ($script:controls.FormScroll) { $script:controls.FormScroll.Visibility = 'Collapsed' }
    if ($script:controls.KeyPopoverBorder) {
        $script:controls.KeyPopoverBorder.Visibility = 'Visible'
    }
    Refresh-ProfilePopoverState
    Sync-PopoverAnchorAndAnimate -PopoverBorder $script:controls.KeyPopoverBorder -TriggerElement $script:controls.AddPlatformCellButton -WasAlreadyOpen $wasOpen
}

function Invoke-SelectOrAddCapsulePlatform([string]$Platform) {
    $p = if ($Platform) { $Platform.Trim().ToLowerInvariant() } else { 'chatgpt' }
    if ($p -eq 'openai') { $p = 'chatgpt' }
    $script:profilesState = Add-CapsulePlatform -Context $script:context -Platform $p -Settings $script:settings
    Select-CapsulePlatform $p
    Update-SessionCards
}

function Invoke-RemoveCurrentCapsulePlatform {
    $curPlat = if ($script:activeCapsulePlatform) { $script:activeCapsulePlatform.Trim().ToLowerInvariant() } else { 'chatgpt' }
    if ($curPlat -in @('openai', 'chatgpt')) { return }
    $script:profilesState = Remove-CapsulePlatform -Context $script:context -Platform $curPlat -Settings $script:settings
    $script:activeCapsulePlatform = 'chatgpt'
    $script:addPlatformPickerOpen = $false
    $script:viewingProfileId = $script:profilesState.ActiveProfileId
    Refresh-ProfilePopoverState
    if ($script:popoverOpen -and $script:controls.KeyPopoverBorder) {
        Sync-PopoverAnchorAndAnimate -PopoverBorder $script:controls.KeyPopoverBorder -TriggerElement $script:controls.ConnIconBadgeButton -WasAlreadyOpen $true
    }
    Update-SessionCards
}

function Refresh-ProfilePopoverState {
    $script:profilesState = Get-ConnectionProfiles $script:context $script:settings
    $allProfs = @($script:profilesState.Profiles)
    $enabledPlats = @(if ($script:profilesState.PSObject.Properties['EnabledPlatforms'] -and $script:profilesState.EnabledPlatforms) {
        $script:profilesState.EnabledPlatforms | ForEach-Object {
            $epCode = ([string]$_).Trim().ToLowerInvariant()
            if ($epCode -eq 'openai') { 'chatgpt' } else { $epCode }
        }
    } else { @('chatgpt') })
    if ($script:activeCapsulePlatform -eq 'openai') { $script:activeCapsulePlatform = 'chatgpt' }
    if (-not $script:activeCapsulePlatform -or ($enabledPlats -notcontains $script:activeCapsulePlatform)) {
        $script:activeCapsulePlatform = 'chatgpt'
    }
    $curPlat = $script:activeCapsulePlatform
    $publicTunnel = Get-PublicMcpTunnelState $script:context
    $platMeta = Get-CapsulePlatformMeta $curPlat

    $openaiProfs = @($allProfs | Where-Object { (-not $_.PSObject.Properties['Platform']) -or (-not $_.Platform) -or ([string]$_.Platform).ToLowerInvariant() -in @('openai', 'chatgpt') })
    $openaiActiveProf = $openaiProfs | Where-Object { $_.IsActive } | Select-Object -First 1
    if (-not $openaiActiveProf -and $openaiProfs.Count -gt 0) { $openaiActiveProf = $openaiProfs[0] }

    $platProfs = @($allProfs | Where-Object {
        $pl = if ($_.PSObject.Properties['Platform'] -and $_.Platform) { ([string]$_.Platform).ToLowerInvariant() } else { 'chatgpt' }
        if ($pl -eq 'openai') { $pl = 'chatgpt' }
        $pl -eq $curPlat
    })
    $activeProf = $platProfs | Where-Object { $_.IsActive } | Select-Object -First 1
    if (-not $activeProf -and $platProfs.Count -gt 0) {
        $activeProf = $platProfs[0]
    }
    if (-not $script:viewingProfileId -or ($script:viewingProfileId -ne 'new' -and -not ($platProfs | Where-Object { $_.Id -eq $script:viewingProfileId }))) {
        $script:viewingProfileId = if ($activeProf) { $activeProf.Id } else { '' }
    }
    $viewProf = $platProfs | Where-Object { $_.Id -eq $script:viewingProfileId } | Select-Object -First 1
    if (-not $viewProf -and $script:viewingProfileId -ne 'new') { $viewProf = $activeProf }

    $tunRunning = [bool]($script:display -and $script:display.Running)
    $activeShortName = if ($openaiActiveProf -and $openaiActiveProf.Name) {
        ($openaiActiveProf.Name -replace '\s*(主力隧道|主力号|隧道|配置).*$', '').Trim()
    } else { '未配置' }
    if (-not $activeShortName) { $activeShortName = '主力隧道' }
    if ($activeShortName.Length -gt 12) { $activeShortName = $activeShortName.Substring(0, 12) }
    $script:controls.ConnProfileMiniTagText.Text = $(if ($enabledPlats.Count -gt 1) { "ChatGPT · $activeShortName ▾" } else { "$activeShortName ▾" })

    if ($script:controls.CapsuleExtraSegmentsPanel) {
        $script:controls.CapsuleExtraSegmentsPanel.Children.Clear()
        $script:capsuleSegmentButtons = @{}
        foreach ($ep in @($enabledPlats | Where-Object { $_ -notin @('openai', 'chatgpt') })) {
            $div = New-Object Windows.Controls.Border
            $div.Width = 1
            $div.Background = ConvertTo-Brush '#E4E4E7'
            $div.Margin = [Windows.Thickness]::new(0, 3, 0, 3)
            [void]$script:controls.CapsuleExtraSegmentsPanel.Children.Add($div)

            $epMeta = Get-CapsulePlatformMeta $ep
            $epAct = $allProfs | Where-Object { ([string]$_.Platform).ToLowerInvariant() -eq $ep -and $_.IsActive } | Select-Object -First 1
            if (-not $epAct) {
                $epAct = $allProfs | Where-Object { ([string]$_.Platform).ToLowerInvariant() -eq $ep } | Select-Object -First 1
            }
            $epShort = if ($epAct -and $epAct.Name) { [string]$epAct.Name } else { '默认' }
            $epReady = [bool](Get-PublicMcpTunnelState $script:context).Running
            $segBtn = New-Object Windows.Controls.Button
            $segBtn.Padding = [Windows.Thickness]::new(8, 2, 8, 2)
            $segBtn.MinHeight = 24
            $segBtn.Background = ConvertTo-Brush 'Transparent'
            $segBtn.BorderBrush = ConvertTo-Brush 'Transparent'
            $segBtn.BorderThickness = [Windows.Thickness]::new(0)
            $segBtn.Tag = $ep
            $segStack = New-Object Windows.Controls.StackPanel
            $segStack.Orientation = 'Horizontal'
            $segStack.VerticalAlignment = 'Center'
            $segDot = New-Object Windows.Shapes.Ellipse
            $segDot.Width = 7; $segDot.Height = 7
            $segDot.Fill = ConvertTo-Brush $(if ($epReady) { '#16A34A' } else { '#A1A1AA' })
            $segDot.VerticalAlignment = 'Center'
            $segDot.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
            [void]$segStack.Children.Add($segDot)
            $segTxt = New-Object Windows.Controls.TextBlock
            $segTxt.Text = "$($epMeta.Title) · $epShort ▾"
            $segTxt.FontSize = 11.5
            $segTxt.FontWeight = 'SemiBold'
            $segTxt.Foreground = ConvertTo-Brush '#18181B'
            $segTxt.VerticalAlignment = 'Center'
            [void]$segStack.Children.Add($segTxt)
            $segBtn.Content = $segStack
            $segBtn.Add_Click({
                param($s, $e)
                if ($s.Tag) { Select-CapsulePlatform ([string]$s.Tag) $s }
            })
            $script:capsuleSegmentButtons[$ep] = $segBtn
            [void]$script:controls.CapsuleExtraSegmentsPanel.Children.Add($segBtn)
        }
    }

    if ($script:controls.AddPlatformPanelBorder -and $script:controls.AddPlatformListPanel) {
        $script:controls.AddPlatformPanelBorder.Visibility = $(if ($script:addPlatformPickerOpen) { 'Visible' } else { 'Collapsed' })
        $script:controls.AddPlatformListPanel.Children.Clear()
        foreach ($presetCode in @('chatgpt', 'gemini', 'claude')) {
            $pm = Get-CapsulePlatformMeta $presetCode
            $isAdded = ($enabledPlats -contains $presetCode)
            $pBtn = New-Object Windows.Controls.Button
            $pBtn.HorizontalContentAlignment = 'Stretch'
            $pBtn.Padding = [Windows.Thickness]::new(11, 7, 11, 7)
            $pBtn.MinHeight = 42
            $pBtn.Margin = [Windows.Thickness]::new(0, 0, 0, 5)
            $pBtn.Background = ConvertTo-Brush '#FFFFFF'
            $pBtn.BorderBrush = ConvertTo-Brush $(if ($isAdded) { '#BBF7D0' } else { '#E4E4E7' })
            $pBtn.BorderThickness = [Windows.Thickness]::new(1)
            $pBtn.Tag = $presetCode
            $pGrid = New-Object Windows.Controls.Grid
            $pc0 = New-Object Windows.Controls.ColumnDefinition; $pc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $pc1 = New-Object Windows.Controls.ColumnDefinition; $pc1.Width = [Windows.GridLength]::Auto
            [void]$pGrid.ColumnDefinitions.Add($pc0); [void]$pGrid.ColumnDefinitions.Add($pc1)
            $leftStack = New-Object Windows.Controls.StackPanel
            $leftStack.VerticalAlignment = 'Center'
            $pNameTxt = New-Object Windows.Controls.TextBlock
            $pNameTxt.Text = $pm.Title
            $pNameTxt.FontSize = 12.5
            $pNameTxt.FontWeight = 'SemiBold'
            $pNameTxt.Foreground = ConvertTo-Brush '#18181B'
            [void]$leftStack.Children.Add($pNameTxt)
            $pDescTxt = New-Object Windows.Controls.TextBlock
            $pDescTxt.Text = $pm.PurposeDesc
            $pDescTxt.FontSize = 10.5
            $pDescTxt.Foreground = ConvertTo-Brush '#71717A'
            $pDescTxt.Margin = [Windows.Thickness]::new(0, 2, 8, 0)
            [void]$leftStack.Children.Add($pDescTxt)
            [Windows.Controls.Grid]::SetColumn($leftStack, 0)
            [void]$pGrid.Children.Add($leftStack)
            $pRightTxt = New-Object Windows.Controls.TextBlock
            $pRightTxt.Text = $(if ($isAdded) { '已添加' } else { '+ 添加' })
            $pRightTxt.FontSize = 11.5
            $pRightTxt.FontWeight = 'SemiBold'
            $pRightTxt.Foreground = ConvertTo-Brush $(if ($isAdded) { '#16A34A' } else { '#2563EB' })
            $pRightTxt.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($pRightTxt, 1)
            [void]$pGrid.Children.Add($pRightTxt)
            $pBtn.Content = $pGrid
            $pBtn.Add_Click({
                param($s, $e)
                if ($s.Tag) { Invoke-SelectOrAddCapsulePlatform ([string]$s.Tag) }
            })
            [void]$script:controls.AddPlatformListPanel.Children.Add($pBtn)
        }
    }

    if ($script:addPlatformPickerOpen) {
        if ($script:controls.PopoverHeaderTitle) { $script:controls.PopoverHeaderTitle.Text = '添加平台通道' }
        if ($script:controls.RemoveCapsulePlatformButton) { $script:controls.RemoveCapsulePlatformButton.Visibility = 'Collapsed' }
        if ($script:controls.AddProfileButton) { $script:controls.AddProfileButton.Visibility = 'Collapsed' }
        if ($script:controls.TogglePopoverEditButton) { $script:controls.TogglePopoverEditButton.Visibility = 'Collapsed' }
        if ($script:controls.ProfilesListScroll) { $script:controls.ProfilesListScroll.Visibility = 'Collapsed' }
        if ($script:controls.FormScroll) { $script:controls.FormScroll.Visibility = 'Collapsed' }
        if ($script:controls.PopoverFooterBorder) { $script:controls.PopoverFooterBorder.Visibility = 'Collapsed' }
    } else {
        if ($script:controls.PopoverHeaderTitle) {
            $script:controls.PopoverHeaderTitle.Text = if ($curPlat -in @('openai', 'chatgpt')) {
                "ChatGPT 隧道配置 ($($platProfs.Count))"
            } else {
                "$($platMeta.Title) 接入配置 ($($platProfs.Count))"
            }
        }
        if ($script:controls.RemoveCapsulePlatformButton) {
            $script:controls.RemoveCapsulePlatformButton.Visibility = $(if ($curPlat -in @('openai', 'chatgpt')) { 'Collapsed' } else { 'Visible' })
        }
        if ($script:controls.AddProfileButton) { $script:controls.AddProfileButton.Visibility = 'Visible' }
        if ($script:controls.ProfilesListScroll) {
            $script:controls.ProfilesListScroll.Visibility = 'Visible'
            $script:controls.ProfilesListScroll.MaxHeight = if ($script:popoverEditMode) { 450 } else { 250 }
        }
        if ($script:controls.PopoverFooterBorder) { $script:controls.PopoverFooterBorder.Visibility = 'Visible' }
    }
    if ($script:controls.TunnelInputLabel) {
        $script:controls.TunnelInputLabel.Text = $platMeta.SecondLabel
    }
    if ($script:controls.KeyInputLabel) {
        $script:controls.KeyInputLabel.Text = $platMeta.KeyLabel
    }
    $script:controls.ApiKeysButton.Content = $(if ($curPlat -in @('openai', 'chatgpt')) { '获取或管理 API Key ↗' } else { '公网隧道设置帮助 ↗' })
    if ($script:controls.PlatformButton) {
        $script:controls.PlatformButton.Content = $platMeta.PlatText
    }

    foreach ($legacyControl in @('MaskedKeyText','ToggleKeyMaskButton','CopyApiKeyButton')) {
        if ($script:controls[$legacyControl]) { $script:controls[$legacyControl].Visibility = $(if ($curPlat -in @('openai', 'chatgpt')) { 'Visible' } else { 'Collapsed' }) }
    }
    # Detach FormScroll before rebuilding ProfilesListPanel so it can be embedded inline inside the expanded strip
    if ($script:controls.FormScroll -and $script:controls.FormScroll.Parent) {
        try { [void]$script:controls.FormScroll.Parent.Children.Remove($script:controls.FormScroll) } catch { }
    }

    if ($script:controls.ProfilesListPanel) {
        $script:controls.ProfilesListPanel.Children.Clear()
        foreach ($prof in $platProfs) {
            $isProfActive = ($activeProf -and $prof.Id -eq $activeProf.Id)
            $isProfViewing = ($viewProf -and $prof.Id -eq $viewProf.Id)
            $isProfExpanded = ($script:popoverEditMode -and $script:popoverExpandedProfileId -eq $prof.Id)

            $bgHex = if ($isProfActive) { '#F0FDF4' } elseif ($isProfViewing) { '#EFF6FF' } else { '#FFFFFF' }
            $bdHex = if ($isProfActive) { '#86EFAC' } elseif ($isProfViewing) { '#60A5FA' } else { '#E4E4E7' }
            $bdWidth = if ($isProfActive -or $isProfViewing) { 1.5 } else { 1.0 }

            $rowBorder = New-Object Windows.Controls.Border
            $rowBorder.Background = ConvertTo-Brush $bgHex
            $rowBorder.BorderBrush = ConvertTo-Brush $bdHex
            $rowBorder.BorderThickness = [Windows.Thickness]::new($bdWidth)
            $rowBorder.CornerRadius = [Windows.CornerRadius]::new(8)
            $rowBorder.Padding = [Windows.Thickness]::new(11, 7, 11, 7)
            $rowBorder.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
            $rowBorder.Cursor = [Windows.Input.Cursors]::Hand
            $rowBorder.ToolTip = '点击选中此账号（点击最右侧箭头展开编辑框）'
            $rowBorder.Tag = $prof.Id
            $rowBorder.Add_MouseLeftButtonUp({
                param($sender, $e)
                if ($e.OriginalSource -is [Windows.DependencyObject]) {
                    $cur = $e.OriginalSource
                    while ($null -ne $cur -and $cur -ne $sender) {
                        if ($cur -eq $script:controls.FormScroll -or $cur -is [Windows.Controls.Primitives.ButtonBase] -or $cur -is [Windows.Controls.Primitives.TextBoxBase] -or $cur -is [Windows.Controls.PasswordBox]) {
                            return
                        }
                        $cur = [Windows.Media.VisualTreeHelper]::GetParent($cur)
                    }
                }
                if ($sender.Tag) { Select-ProfileCard ([string]$sender.Tag) }
            })

            $cardStack = New-Object Windows.Controls.StackPanel

            # Line 1: Dot + Name (Left) | Status Tag + Expand Toggle Icon (Right)
            $rGrid = New-Object Windows.Controls.Grid
            $rc0 = New-Object Windows.Controls.ColumnDefinition; $rc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $rc1 = New-Object Windows.Controls.ColumnDefinition; $rc1.Width = [Windows.GridLength]::Auto
            [void]$rGrid.ColumnDefinitions.Add($rc0); [void]$rGrid.ColumnDefinitions.Add($rc1)

            $nameRow = New-Object Windows.Controls.StackPanel
            $nameRow.Orientation = 'Horizontal'
            $nameRow.VerticalAlignment = 'Center'
            $isChatGptPlat = ($curPlat -in @('openai', 'chatgpt'))
            $isApiKeyProfReady = (-not $isChatGptPlat) -and [bool]$prof.Enabled -and [bool]$prof.HasKey
            $dot = New-Object Windows.Shapes.Ellipse
            $dot.Width = 7; $dot.Height = 7
            $dot.Fill = ConvertTo-Brush $(if (-not $isChatGptPlat) {
                if ($isApiKeyProfReady) { '#16A34A' } elseif ($isProfViewing) { '#2563EB' } else { '#A1A1AA' }
            } elseif ($isProfActive -and $tunRunning) { '#16A34A' } elseif ($isProfActive) { '#22C55E' } elseif ($isProfViewing) { '#2563EB' } else { '#A1A1AA' })
            $dot.VerticalAlignment = 'Center'
            $dot.Margin = [Windows.Thickness]::new(0, 0, 7, 0)
            [void]$nameRow.Children.Add($dot)

            $nTxt = New-Object Windows.Controls.TextBlock
            $nTxt.Text = $prof.Name
            $nTxt.FontSize = 12.5
            $nTxt.FontWeight = 'SemiBold'
            $nTxt.Foreground = ConvertTo-Brush $(if (($isChatGptPlat -and $isProfActive) -or $isApiKeyProfReady) { '#14532D' } else { '#18181B' })
            $nTxt.VerticalAlignment = 'Center'
            [void]$nameRow.Children.Add($nTxt)
            [Windows.Controls.Grid]::SetColumn($nameRow, 0)
            [void]$rGrid.Children.Add($nameRow)

            $rightStack = New-Object Windows.Controls.StackPanel
            $rightStack.Orientation = 'Horizontal'
            $rightStack.VerticalAlignment = 'Center'

            if (-not $isChatGptPlat) {
                $actTag = New-Object Windows.Controls.Border
                $actTag.Background = ConvertTo-Brush $(if ($isApiKeyProfReady) { '#DCFCE7' } else { '#F4F4F5' })
                $actTag.CornerRadius = [Windows.CornerRadius]::new(4)
                $actTag.Padding = [Windows.Thickness]::new(6, 2, 6, 2)
                $actTag.VerticalAlignment = 'Center'
                $actTxt = New-Object Windows.Controls.TextBlock
                $actTxt.Text = $(if ($isApiKeyProfReady) { '已启用' } else { '待配置密钥' })
                $actTxt.FontSize = 10.5
                $actTxt.FontWeight = 'SemiBold'
                $actTxt.Foreground = ConvertTo-Brush $(if ($isApiKeyProfReady) { '#15803D' } else { '#71717A' })
                $actTag.Child = $actTxt
                [void]$rightStack.Children.Add($actTag)
            } elseif ($isProfActive) {
                $actTag = New-Object Windows.Controls.Border
                $actTag.Background = ConvertTo-Brush '#DCFCE7'
                $actTag.CornerRadius = [Windows.CornerRadius]::new(4)
                $actTag.Padding = [Windows.Thickness]::new(6, 2, 6, 2)
                $actTag.VerticalAlignment = 'Center'
                $actTxt = New-Object Windows.Controls.TextBlock
                $actTxt.Text = $(if ($tunRunning) { '当前生效' } else { '当前默认' })
                $actTxt.FontSize = 10.5
                $actTxt.FontWeight = 'Bold'
                $actTxt.Foreground = ConvertTo-Brush '#15803D'
                $actTag.Child = $actTxt
                [void]$rightStack.Children.Add($actTag)
            } elseif ($isProfViewing) {
                $selTag = New-Object Windows.Controls.Border
                $selTag.Background = ConvertTo-Brush '#DBEAFE'
                $selTag.CornerRadius = [Windows.CornerRadius]::new(4)
                $selTag.Padding = [Windows.Thickness]::new(6, 2, 6, 2)
                $selTag.VerticalAlignment = 'Center'
                $selTxt = New-Object Windows.Controls.TextBlock
                $selTxt.Text = '已选中'
                $selTxt.FontSize = 10.5
                $selTxt.FontWeight = 'SemiBold'
                $selTxt.Foreground = ConvertTo-Brush '#1D4ED8'
                $selTag.Child = $selTxt
                [void]$rightStack.Children.Add($selTag)
            }

            $expandBtn = New-Object Windows.Controls.Button
            $expandBtn.Style = $script:window.Resources['LinkButton']
            $expandBtn.Content = $(if ($isProfExpanded) { '▴' } else { '▾' })
            $expandBtn.FontSize = 12.5
            $expandBtn.FontWeight = 'Bold'
            $expandBtn.Padding = [Windows.Thickness]::new(6, 1, 4, 1)
            $expandBtn.MinHeight = 20
            $expandBtn.Margin = [Windows.Thickness]::new(4, 0, 0, 0)
            $expandBtn.Foreground = ConvertTo-Brush $(if ($isProfActive) { '#15803D' } elseif ($isProfViewing) { '#2563EB' } else { '#71717A' })
            $expandBtn.ToolTip = $(if ($isProfExpanded) { '收起编辑框' } else { '展开修改配置名称、固定域名与隧道凭证' })
            $expandBtn.Tag = $prof.Id
            $expandBtn.Add_Click({
                param($s, $e)
                $e.Handled = $true
                if ($s.Tag) { Toggle-ProfileInlineEdit ([string]$s.Tag) }
            })
            [void]$rightStack.Children.Add($expandBtn)

            [Windows.Controls.Grid]::SetColumn($rightStack, 1)
            [void]$rGrid.Children.Add($rightStack)
            [void]$cardStack.Children.Add($rGrid)

            # Line 2: Small Font Masked Endpoint/Tunnel ID + API Key + Inline Copy Links
            $rawEndpointOrTid = if (-not $isChatGptPlat) {
                [string]$publicTunnel.Url
            } else {
                [string]$prof.TunnelId
            }
            $shortEndpointOrTid = if (-not $isChatGptPlat) {
                if ($rawEndpointOrTid.Length -gt 28) { "$($rawEndpointOrTid.Substring(0, 25))..." } elseif ($rawEndpointOrTid) { $rawEndpointOrTid } else { '默认官方接口' }
            } else {
                if ($rawEndpointOrTid.Length -gt 18) {
                    "$($rawEndpointOrTid.Substring(0, 11))...$($rawEndpointOrTid.Substring($rawEndpointOrTid.Length - 5))"
                } elseif ($rawEndpointOrTid.Length -gt 0) {
                    $rawEndpointOrTid
                } else {
                    '未填写'
                }
            }
            $rawPlain = [string]$prof.PlainKey
            $shortKey = if ($rawPlain.Length -ge 12) {
                "$($rawPlain.Substring(0, 8))••••$($rawPlain.Substring($rawPlain.Length - 4))"
            } elseif ($rawPlain.Length -gt 0) {
                'sk-••••'
            } else {
                '未填写'
            }

            $subRow = New-Object Windows.Controls.WrapPanel
            $subRow.Margin = [Windows.Thickness]::new(14, 3, 0, 0)

            $tunLbl = New-Object Windows.Controls.TextBlock
            $tunLbl.Text = $(if (-not $isChatGptPlat) { "公网 MCP ($($publicTunnel.Status)): $rawEndpointOrTid " } else { "隧道: $shortEndpointOrTid " })
            $tunLbl.FontSize = 10.5
            $tunLbl.Foreground = ConvertTo-Brush '#71717A'
            $tunLbl.FontFamily = New-Object Windows.Media.FontFamily('Consolas, Cascadia Mono, Microsoft YaHei UI')
            $tunLbl.VerticalAlignment = 'Center'
            [void]$subRow.Children.Add($tunLbl)

            $copyTunBtn = New-Object Windows.Controls.Button
            $copyTunBtn.Style = $script:window.Resources['LinkButton']
            $copyTunBtn.Content = '复制'
            $copyTunBtn.FontSize = 10.5
            $copyTunBtn.Padding = [Windows.Thickness]::new(2, 0, 2, 0)
            $copyTunBtn.MinHeight = 16
            $copyTunBtn.VerticalAlignment = 'Center'
            $copyTunBtn.Tag = [pscustomobject]@{ Val = $rawEndpointOrTid; IsTunnel = $isChatGptPlat }
            $copyTunBtn.Add_Click({
                param($s, $e)
                $e.Handled = $true
                $tagObj = $s.Tag
                $val = if ($tagObj) { [string]$tagObj.Val } else { '' }
                $isTun = if ($tagObj) { [bool]$tagObj.IsTunnel } else { $true }
                if ($val) {
                    try { [Windows.Clipboard]::SetText($val) } catch { }
                    $s.Content = '✓ 已复制'
                    $s.Foreground = ConvertTo-Brush '#16A34A'
                    Show-QuickToast ($(if ($isTun) { '已复制隧道编号到剪贴板' } else { '已复制接口地址到剪贴板' }))
                } else {
                    Show-QuickToast ($(if ($isTun) { '当前配置尚未填写隧道编号' } else { '当前配置尚未填写接口地址' }))
                }
            })
            [void]$subRow.Children.Add($copyTunBtn)

            $sepLbl = New-Object Windows.Controls.TextBlock
            $sepLbl.Text = "   ·   Key: $shortKey "
            $sepLbl.FontSize = 10.5
            $sepLbl.Foreground = ConvertTo-Brush '#71717A'
            $sepLbl.FontFamily = New-Object Windows.Media.FontFamily('Consolas, Cascadia Mono, Microsoft YaHei UI')
            $sepLbl.VerticalAlignment = 'Center'
            if ($isChatGptPlat) { [void]$subRow.Children.Add($sepLbl) }

            $copyKeyBtn = New-Object Windows.Controls.Button
            $copyKeyBtn.Style = $script:window.Resources['LinkButton']
            $copyKeyBtn.Content = '复制'
            $copyKeyBtn.FontSize = 10.5
            $copyKeyBtn.Padding = [Windows.Thickness]::new(2, 0, 2, 0)
            $copyKeyBtn.MinHeight = 16
            $copyKeyBtn.VerticalAlignment = 'Center'
            $copyKeyBtn.Tag = $rawPlain
            $copyKeyBtn.Add_Click({
                param($s, $e)
                $e.Handled = $true
                $val = [string]$s.Tag
                if ($val) {
                    try { [Windows.Clipboard]::SetText($val) } catch { }
                    $s.Content = '✓ 已复制'
                    $s.Foreground = ConvertTo-Brush '#16A34A'
                    Show-QuickToast '已复制完整 API Key 到剪贴板'
                } else {
                    Show-QuickToast '当前配置尚未保存 API Key'
                }
            })
            if ($isChatGptPlat) { [void]$subRow.Children.Add($copyKeyBtn) }
            [void]$cardStack.Children.Add($subRow)

            # Inline Accordion Edit Box directly below this strip when expanded
            if ($isProfExpanded -and $script:controls.FormScroll) {
                $script:controls.FormScroll.Visibility = 'Visible'
                [void]$cardStack.Children.Add($script:controls.FormScroll)
            }

            $rowBorder.Child = $cardStack
            [void]$script:controls.ProfilesListPanel.Children.Add($rowBorder)
        }
    }

    if ($script:controls.PopoverDetailCardBorder) {
        $script:controls.PopoverDetailCardBorder.Visibility = 'Collapsed'
    }
    if ($script:controls.FormScroll -and (-not $script:popoverEditMode -or -not $script:popoverExpandedProfileId)) {
        $script:controls.FormScroll.Visibility = 'Collapsed'
    }

    # Always show DeleteProfileButton regardless of profile count
    if ($script:controls.DeleteProfileButton) {
        $script:controls.DeleteProfileButton.Visibility = 'Visible'
    }

    # Bottom Start / Reconnect / Test / Disable Button State
    $isCurChatGpt = ($curPlat -in @('openai', 'chatgpt'))
    if ($script:controls.QuickConnectButton) {
        if (-not $isCurChatGpt) {
            $script:controls.QuickConnectButton.Content = $(if ($publicTunnel.Running) { '复制 MCP 网址' } elseif ($publicTunnel.ProcessId) { '↻ 查看连接状态' } else { '▶ 启动 HTTPS 隧道' })
        } elseif ($viewProf -and $activeProf -and $viewProf.Id -ne $activeProf.Id) {
            $script:controls.QuickConnectButton.Content = "▶ 启动此隧道"
            $script:controls.QuickConnectButton.Background = ConvertTo-Brush '#2563EB'
            $script:controls.QuickConnectButton.BorderBrush = ConvertTo-Brush '#2563EB'
            $script:controls.QuickConnectButton.Foreground = ConvertTo-Brush '#FEFEFF'
        } elseif (-not $tunRunning) {
            $script:controls.QuickConnectButton.Content = "▶ 启动隧道"
            $script:controls.QuickConnectButton.Background = ConvertTo-Brush '#2563EB'
            $script:controls.QuickConnectButton.BorderBrush = ConvertTo-Brush '#2563EB'
            $script:controls.QuickConnectButton.Foreground = ConvertTo-Brush '#FEFEFF'
        } else {
            $script:controls.QuickConnectButton.Content = "↻ 重新连接"
            $script:controls.QuickConnectButton.Background = ConvertTo-Brush '#EFF6FF'
            $script:controls.QuickConnectButton.BorderBrush = ConvertTo-Brush '#BFDBFE'
            $script:controls.QuickConnectButton.Foreground = ConvertTo-Brush '#2563EB'
        }
    }
    if ($script:controls.DisconnectButton) {
        if (-not $isCurChatGpt) {
            $script:controls.DisconnectButton.Visibility = 'Visible'
            $script:controls.DisconnectButton.Content = '断开共享隧道'
            $script:controls.DisconnectButton.IsEnabled = [bool]$publicTunnel.ProcessId
        } else {
            $coreReady = ($script:display -and $script:display.Core -eq '已准备好')
            $legacy = ($script:display -and $script:display.Tunnel -eq '旧脚本连接仍在运行')
            $script:controls.DisconnectButton.Content = '断开隧道'
            $script:controls.DisconnectButton.IsEnabled = [bool]($script:display -and $script:display.Running)
            $script:controls.DisconnectButton.Visibility = $(if ($coreReady -and $legacy) { 'Collapsed' } else { 'Visible' })
        }
    }

    $isPrimaryViewing = $isCurChatGpt -and ((-not $viewProf) -or ($viewProf.Id -eq 'prof_primary'))
    $plainKey = if ($viewProf -and $viewProf.PlainKey) { $viewProf.PlainKey } elseif ($isPrimaryViewing) { Get-SavedOpenAIKeyPlaintext $script:context } else { '' }
    $maskedKey = Format-MaskedApiKey $plainKey
    $script:controls.MaskedKeyText.Text = if ($script:keyMasked) { $maskedKey } elseif ($plainKey) { $plainKey } else { '尚未保存密钥（请点击编辑粘贴）' }
    $script:controls.ToggleKeyMaskButton.Content = if ($script:keyMasked) { '显示完整' } else { '隐藏明文' }
    # Note: CurrentTunnelIdText / TunnelInput retain their XAML contract names for test compatibility; local variable uses neutral endpointOrTunnelText
    $endpointOrTunnelText = if (-not $isCurChatGpt) {
        $(if ($viewProf -and $viewProf.BaseUrl) { [string]$viewProf.BaseUrl } else { $platMeta.DefaultUrl })
    } elseif ($viewProf -and $viewProf.TunnelId) {
        $viewProf.TunnelId
    } elseif ($isPrimaryViewing -and $script:settings.tunnel_id) {
        $script:settings.tunnel_id
    } else {
        '尚未配置隧道编号'
    }
    $script:controls.CurrentTunnelIdText.Text = $endpointOrTunnelText

    if (-not $script:dirty -and $viewProf -and $script:controls.ProfileNameInput) {
        $prevInit = $script:initializing
        $script:initializing = $true
        try {
            $script:controls.ProfileNameInput.Text = [string]$viewProf.Name
            $script:controls.TunnelInput.Text = $(if ($isCurChatGpt) { [string]$viewProf.TunnelId } else { [string]$viewProf.BaseUrl })
            $script:controls.KeyInput.Text = [string]$plainKey
        } finally {
            $script:initializing = $prevInit
        }
    }

    $acpLim = Get-AcpConcurrencyLimit $script:context
    $script:controls.AcpConcurrencyLabel.Text = if ($acpLim -eq 0) { "CLI 智能体并发上限：已关闭" } else { "CLI 智能体并发上限：$acpLim 个" }
    Update-OptionButtonGroupState @(
        @{ Btn = $script:controls.AcpLimit0Button; Val = 0 },
        @{ Btn = $script:controls.AcpLimit2Button; Val = 2 },
        @{ Btn = $script:controls.AcpLimit4Button; Val = 4 },
        @{ Btn = $script:controls.AcpLimit6Button; Val = 6 }
    ) $acpLim

    # Refresh Absorbed RelayStudio Core & Startup Controls
    $coreCfg = Get-CoreEngineConfig $script:context
    $coreReadyNow = ($script:display -and $script:display.Core -eq '已准备好')
    if ($script:controls.CoreInlineDot) {
        $script:controls.CoreInlineDot.Fill = ConvertTo-Brush $(if ($coreReadyNow) { '#16A34A' } else { '#F59E0B' })
    }
    if ($script:controls.CoreInlineStatusText) {
        $script:controls.CoreInlineStatusText.Text = if ($coreReadyNow) {
            "本地内核：运行中 (127.0.0.1:$($coreCfg.CorePort))"
        } else {
            "本地内核：待启动 (端口 $($coreCfg.CorePort))"
        }
    }
    Update-OptionButtonGroupState @(
        @{ Btn = $script:controls.AutoArchiveImmediateButton; Val = 'immediate' },
        @{ Btn = $script:controls.AutoArchive1dButton;        Val = '1d' },
        @{ Btn = $script:controls.AutoArchive3dButton;        Val = '3d' },
        @{ Btn = $script:controls.AutoArchive7dButton;        Val = '7d' },
        @{ Btn = $script:controls.AutoArchiveOffButton;       Val = 'off' }
    ) $coreCfg.AutoArchiveCompletedMode

    if ($script:controls.DefaultCarrierCombo -and (-not $script:controls.DefaultCarrierCombo.IsDropDownOpen)) {
        $script:suppressDefaultCarrierComboEvent = $true
        try {
            $availCarriers = @(Get-AvailableBrowserProfiles -Context $script:context)
            $script:controls.DefaultCarrierCombo.Items.Clear()
            $selCarrierIdx = 0
            for ($ci = 0; $ci -lt $availCarriers.Count; $ci++) {
                $cp = $availCarriers[$ci]
                $cItem = New-Object Windows.Controls.ComboBoxItem
                $rawCLbl = ([string]$cp.Label -replace '\s*\(Web[^)]*\)', '').Trim()
                $cItem.Content = if ($rawCLbl -match '^(💻|🌐)') { $rawCLbl } else { "🌐 $rawCLbl" }
                $cItem.Tag = [string]$cp.Id
                [void]$script:controls.DefaultCarrierCombo.Items.Add($cItem)
                if ([string]$cp.Id -eq [string]$coreCfg.DefaultBrowserProfile) {
                    $selCarrierIdx = $ci
                }
            }
            if ($script:controls.DefaultCarrierCombo.Items.Count -gt 0) {
                $script:controls.DefaultCarrierCombo.SelectedIndex = $selCarrierIdx
            }
        } finally {
            $script:suppressDefaultCarrierComboEvent = $false
        }
    }

    if ($script:controls.CliAgentsButtonPanel) {
        $detectedCliAgents = @(Get-DetectedCliAgents -Settings $script:settings -Context $script:context)
        $script:controls.CliAgentsButtonPanel.Children.Clear()
        $cliBtnPairs = New-Object 'System.Collections.Generic.List[object]'
        if ($detectedCliAgents.Count -eq 0) {
            foreach ($fallbackPair in @(
                @{ Btn = $script:controls.AcpProfileCodexButton; Val = 'codex' },
                @{ Btn = $script:controls.AcpProfileClaudeButton; Val = 'claude' }
            )) {
                if ($fallbackPair.Btn) {
                    [void]$script:controls.CliAgentsButtonPanel.Children.Add($fallbackPair.Btn)
                    [void]$cliBtnPairs.Add($fallbackPair)
                }
            }
        } else {
            foreach ($ag in $detectedCliAgents) {
                $agId = [string]$ag.id
                $agDisp = [string]$ag.display_name
                $btnElem = if ($agId -eq 'codex' -and $script:controls.AcpProfileCodexButton) {
                    $script:controls.AcpProfileCodexButton
                } elseif ($agId -eq 'claude' -and $script:controls.AcpProfileClaudeButton) {
                    $script:controls.AcpProfileClaudeButton
                } else {
                    $dynBtn = New-Object Windows.Controls.Button
                    $dynBtn.Content = $agDisp
                    $dynBtn.Padding = [Windows.Thickness]::new(7, 2, 7, 2)
                    $dynBtn.MinHeight = 22
                    $dynBtn.FontSize = 11
                    $dynBtn.Margin = [Windows.Thickness]::new(0, 0, 4, 4)
                    $dynBtn.ToolTip = [string]$ag.command
                    $dynBtn.Tag = [pscustomobject]@{ Id = $agId; Name = $agDisp }
                    $dynBtn.Add_Click({
                        param($s, $e)
                        if ($s.Tag) { Select-DefaultCliAgent ([string]$s.Tag.Id) ([string]$s.Tag.Name) }
                    })
                    $dynBtn
                }
                if ($btnElem) {
                    if ($btnElem.Parent -is [Windows.Controls.Panel]) {
                        [void]$btnElem.Parent.Children.Remove($btnElem)
                    }
                    [void]$script:controls.CliAgentsButtonPanel.Children.Add($btnElem)
                    [void]$cliBtnPairs.Add(@{ Btn = $btnElem; Val = $agId })
                }
            }
        }
        Update-OptionButtonGroupState ($cliBtnPairs.ToArray()) $coreCfg.AcpDefaultProfile
    } else {
        Update-OptionButtonGroupState @(
            @{ Btn = $script:controls.AcpProfileCodexButton; Val = 'codex' },
            @{ Btn = $script:controls.AcpProfileClaudeButton; Val = 'claude' }
        ) $coreCfg.AcpDefaultProfile
    }

    if ($script:controls.BrowserCdpToggleButton) {
        if ($coreCfg.BrowserEnabled) {
            $script:controls.BrowserCdpToggleButton.Content = '● 已开启'
            $script:controls.BrowserCdpToggleButton.Background = ConvertTo-Brush '#F0FDF4'
            $script:controls.BrowserCdpToggleButton.BorderBrush = ConvertTo-Brush '#BBF7D0'
            $script:controls.BrowserCdpToggleButton.Foreground = ConvertTo-Brush '#15803D'
            $script:controls.BrowserCdpToggleButton.FontWeight = 'SemiBold'
        } else {
            $script:controls.BrowserCdpToggleButton.Content = '○ 已关闭'
            $script:controls.BrowserCdpToggleButton.Background = ConvertTo-Brush '#FFFFFF'
            $script:controls.BrowserCdpToggleButton.BorderBrush = ConvertTo-Brush '#E4E4E7'
            $script:controls.BrowserCdpToggleButton.Foreground = ConvertTo-Brush '#71717A'
            $script:controls.BrowserCdpToggleButton.FontWeight = 'Normal'
        }
    }
    Update-OptionButtonGroupState @(
        @{ Btn = $script:controls.StartupPopupButton; Val = 'popup' },
        @{ Btn = $script:controls.StartupTrayButton; Val = 'tray' },
        @{ Btn = $script:controls.StartupOffButton; Val = 'off' }
    ) $coreCfg.StartupMode
    Apply-WindowTheme
}

function Enter-ProfileEditMode([string]$ProfileId = '') {
    if ($ProfileId) { $script:viewingProfileId = $ProfileId }
    $script:profilesState = Get-ConnectionProfiles $script:context $script:settings
    $viewProf = $script:profilesState.Profiles | Where-Object { $_.Id -eq $script:viewingProfileId } | Select-Object -First 1
    if ($viewProf) {
        $pPlat = if ($viewProf.PSObject.Properties['Platform'] -and $viewProf.Platform) { ([string]$viewProf.Platform).ToLowerInvariant() } else { 'chatgpt' }
        if ($pPlat -eq 'openai') { $pPlat = 'chatgpt' }
        $script:initializing = $true
        try {
            if ($script:controls.ProfileNameInput) { $script:controls.ProfileNameInput.Text = [string]$viewProf.Name }
            $script:controls.TunnelInput.Text = $(if ($pPlat -eq 'chatgpt') { [string]$viewProf.TunnelId } else { [string]$viewProf.BaseUrl })
            $script:controls.KeyInput.Text = [string]$viewProf.PlainKey
        } finally {
            $script:initializing = $false
        }
    }
    $script:dirty = $false
    $script:popoverExpandedProfileId = $script:viewingProfileId
    $script:popoverEditMode = $true
    Select-WindowTab 'Config'
}

function Toggle-ProfileInlineEdit([string]$ProfileId) {
    if ($script:popoverExpandedProfileId -eq $ProfileId -and $script:popoverEditMode) {
        $script:dirty = $false
        $script:popoverExpandedProfileId = ''
        $script:popoverEditMode = $false
        $script:activeTab = 'Live'
        if ($script:controls.FormScroll) { $script:controls.FormScroll.Visibility = 'Collapsed' }
        Refresh-ProfilePopoverState
    } else {
        Enter-ProfileEditMode $ProfileId
    }
}

function Select-ProfileCard([string]$ProfileId) {
    # Clicking the tunnel strip body ONLY selects this profile (never auto-connects, never opens edit drawer)
    $script:viewingProfileId = $ProfileId
    $script:profilesState = Get-ConnectionProfiles $script:context $script:settings
    $viewProf = $script:profilesState.Profiles | Where-Object { $_.Id -eq $ProfileId } | Select-Object -First 1
    if ($viewProf -and -not $script:popoverEditMode) {
        $pPlat = if ($viewProf.PSObject.Properties['Platform'] -and $viewProf.Platform) { ([string]$viewProf.Platform).ToLowerInvariant() } else { 'chatgpt' }
        if ($pPlat -eq 'openai') { $pPlat = 'chatgpt' }
        $script:initializing = $true
        try {
            if ($script:controls.ProfileNameInput) { $script:controls.ProfileNameInput.Text = [string]$viewProf.Name }
            $script:controls.TunnelInput.Text = $(if ($pPlat -eq 'chatgpt') { [string]$viewProf.TunnelId } else { [string]$viewProf.BaseUrl })
            $script:controls.KeyInput.Text = [string]$viewProf.PlainKey
        } finally {
            $script:initializing = $false
        }
    }
    Refresh-ProfilePopoverState
}

function Start-NewProfileForm {
    $script:profilesState = Get-ConnectionProfiles $script:context $script:settings
    $curPlat = if ($script:activeCapsulePlatform) { $script:activeCapsulePlatform.Trim().ToLowerInvariant() } else { 'chatgpt' }
    if ($curPlat -eq 'openai') { $curPlat = 'chatgpt' }
    $platProfs = @($script:profilesState.Profiles | Where-Object {
        $pl = if ($_.PSObject.Properties['Platform'] -and $_.Platform) { ([string]$_.Platform).ToLowerInvariant() } else { 'chatgpt' }
        if ($pl -eq 'openai') { $pl = 'chatgpt' }
        $pl -eq $curPlat
    })
    $countNext = $platProfs.Count + 1
    $defName = if ($curPlat -eq 'chatgpt') { "新隧道配置 #$countNext" } else { "新配置 #$countNext" }
    $savedState = Save-ConnectionProfile -Context $script:context -Settings $script:settings -ProfileId 'new' -Name $defName -TunnelId '' -ApiKey '' -Platform $curPlat -SetActive:$false
    $newId = if ($savedState -and $savedState.PSObject.Properties['LastSavedProfileId'] -and $savedState.LastSavedProfileId) {
        [string]$savedState.LastSavedProfileId
    } else {
        [string]($savedState.Profiles[-1].Id)
    }
    Enter-ProfileEditMode $newId
    if ($script:controls.ProfileNameInput) {
        [void]$script:controls.ProfileNameInput.Focus()
        $script:controls.ProfileNameInput.SelectAll()
    }
}

function Invoke-DeleteCurrentProfile {
    if (-not $script:viewingProfileId) { return }
    try {
        $viewProf = $script:profilesState.Profiles | Where-Object { $_.Id -eq $script:viewingProfileId } | Select-Object -First 1
        $delName = if ($viewProf) { $viewProf.Name } else { $script:viewingProfileId }
        $script:profilesState = Remove-ConnectionProfile -Context $script:context -Settings $script:settings -ProfileId $script:viewingProfileId
        $script:viewingProfileId = $script:profilesState.ActiveProfileId
        $script:popoverExpandedProfileId = ''
        $script:popoverEditMode = $false
        $script:activeTab = 'Live'
        Refresh-ProfilePopoverState
        Show-QuickToast "已删除配置「$delName」"
    } catch {
        Show-Feedback $_.Exception.Message $true
    }
}

function Invoke-PopoverQuickConnect {
    try {
        $curPlat = if ($script:activeCapsulePlatform) { $script:activeCapsulePlatform.Trim().ToLowerInvariant() } else { 'chatgpt' }
        if ($curPlat -eq 'openai') { $curPlat = 'chatgpt' }
        if (-not $script:viewingProfileId) {
            $script:viewingProfileId = $(if ($curPlat -eq 'chatgpt') { 'prof_primary' } else { "prof_${curPlat}_default" })
        }
        if ($script:controls.FormScroll.Visibility -eq 'Visible') {
            Save-Form
        }
        $script:popoverExpandedProfileId = ''
        $script:popoverEditMode = $false
        if ($curPlat -ne 'chatgpt') {
            $prof = $script:profilesState.Profiles | Where-Object Id -eq $script:viewingProfileId | Select-Object -First 1
            $current = Get-PublicMcpTunnelState $script:context
            if ($current.Running) {
                [Windows.Clipboard]::SetText($current.Url)
                Show-QuickToast '已复制公网 MCP 网址'
                return
            }
            if (-not $script:context.Isolated) {
                $port = [int]$script:settings.shield_port
                $probe = Invoke-ConnectionProbe "http://127.0.0.1:$port/shieldz"
                if ($probe.Status -ne 200 -or $probe.Body -notmatch '"ok"\s*:\s*true') {
                    if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { throw '本地桥接服务未就绪，请检查连接状态。' }
                    [void](Start-ReadOnlyShield $script:context $script:settings (Get-OfficialCoreEndpoint $script:settings))
                }
            }
            $state = Start-PublicMcpTunnel -Context $script:context -FixedDomain $prof.BaseUrl -Token $prof.PlainKey -Port $script:settings.shield_port
            if ($state.Running -and $state.Url) { [Windows.Clipboard]::SetText($state.Url) }
            Refresh-ProfilePopoverState
            Show-QuickToast $(if ($state.Running) { '已复制公网 MCP 网址' } else { '隧道正在连接，再次点击查看状态' })
            return
        }
        $res = Select-ConnectionProfile -Context $script:context -Settings $script:settings -ProfileId $script:viewingProfileId -AutoReconnect:(-not $script:context.Isolated)
        $script:settings = $res.Settings
        $script:controls.TunnelInput.Text = $script:settings.tunnel_id
        $script:reconnectNotice = $res.Message
        Refresh-ProfilePopoverState
        Refresh-FormState
        Show-Feedback $res.Message
        Show-QuickToast "✓ 已启动「$($res.ActiveProfile.Name)」隧道"
    } catch {
        $script:lastTestedApiKeyProfileId = ''
        $script:lastTestedApiKeyProfileSig = ''
        $script:popoverOpen = $true
        $script:controls.KeyPopoverBorder.Visibility = 'Visible'
        Refresh-ProfilePopoverState
        Select-WindowTab 'Config'
        Show-Feedback $_.Exception.Message $true
    }
}

function Open-SessionRename([string]$SessionKey, [string]$CurrentTitle) {
    if (-not $SessionKey) { return }
    $script:renamingSessionKey = $SessionKey
    $script:controls.RenameInput.Text = $CurrentTitle
    $script:controls.RenameBar.Visibility = 'Visible'
    [void]$script:controls.RenameInput.Focus()
    $script:controls.RenameInput.SelectAll()
}

function Close-SessionRename {
    $script:renamingSessionKey = ''
    $script:controls.RenameBar.Visibility = 'Collapsed'
}
function Get-AllAvailableSessions {
    $active = @(if ($script:display -and $script:display.PSObject.Properties.Name -contains 'Sessions' -and $script:display.Sessions) { $script:display.Sessions })
    $archived = @(if ($script:display -and $script:display.PSObject.Properties.Name -contains 'ArchivedSessions' -and $script:display.ArchivedSessions) { $script:display.ArchivedSessions })
    return @($active) + @($archived)
}

function Get-NextUniquePaneId {
    $maxExisting = [Math]::Max(109, [int]$script:nextPaneId - 1)
    foreach ($p in @($script:layout.Panes)) {
        if ($p -and $p.id -and [int]$p.id -gt $maxExisting) {
            $maxExisting = [int]$p.id
        }
    }
    if ($script:layout.HiddenRightPane -and $script:layout.HiddenRightPane.id -and [int]$script:layout.HiddenRightPane.id -gt $maxExisting) {
        $maxExisting = [int]$script:layout.HiddenRightPane.id
    }
    $script:nextPaneId = $maxExisting + 2
    return ($maxExisting + 1)
}

function Normalize-PaneWeights {
    $panes = @($script:layout.Panes)
    if ($panes.Count -eq 0) {
        $script:layout.Panes = @(
            [pscustomobject]@{ id = 101; session_key = ''; width_weight = 100; show_summary = $true }
        )
        return
    }
    $seenIds = @{}
    $maxId = 100
    foreach ($p in $panes) {
        if ($p.id -and [int]$p.id -gt $maxId) { $maxId = [int]$p.id }
    }
    foreach ($p in $panes) {
        $cid = if ($p.id) { [int]$p.id } else { $maxId + 1 }
        if ($seenIds.ContainsKey($cid)) {
            $maxId++
            $cid = $maxId
            $p.id = $cid
        }
        $seenIds[$cid] = $true
        if ($cid -gt $maxId) { $maxId = $cid }
    }
    $sum = 0.0
    foreach ($p in $panes) { $sum += [Math]::Max(10.0, [double]$p.width_weight) }
    if ($sum -le 0) { $sum = 100.0 }
    foreach ($p in $panes) {
        $p.width_weight = [Math]::Max(15.0, [Math]::Round(([double]$p.width_weight / $sum) * 100.0, 1))
    }
}

function Start-PaneDrawerOpenAnimation([int]$PaneId, [double]$TargetWeight, [int]$DurationMs = 150) {
    if ($script:paneAnimTimer -and $script:paneAnimTimer.IsEnabled) {
        $script:paneAnimTimer.Stop()
    }
    $script:paneAnimCtx = $null
    if ($NoShow) { return }
    $hostGrid = $script:controls.PanesHostGrid
    if (-not $hostGrid) { return }
    $targetBorder = $null
    foreach ($ch in $hostGrid.Children) {
        if ($ch -is [Windows.Controls.Border] -and $ch.Tag -and $ch.Tag.PSObject.Properties.Name -contains 'PaneId' -and [int]$ch.Tag.PaneId -eq $PaneId) {
            $targetBorder = $ch
            break
        }
    }
    if (-not $targetBorder) { return }
    Start-SmoothEnterAnimation -Element $targetBorder -FromX 18.0 -FromY 0.0 -DurationMs $DurationMs
}

function Ensure-PaneAnimTimer {
    # Retained as no-op compatibility shim; split/close transitions now run on the WPF GPU composition thread.
}

function Split-PaneAfter([int]$PaneId) {
    $panes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($p in @($script:layout.Panes)) { $panes.Add($p) }
    if ($panes.Count -ge 4) {
        Show-QuickToast '最多同时横拆 4 个会话分栏'
        return
    }
    $targetCount = $panes.Count + 1
    if (-not $NoShow -and $targetCount -ge 3) {
        $neededWorkspaceW = $targetCount * $script:PANE_MIN_COMFORT_PX
        $curAvailW = [double]$script:window.Width - $(if ($script:layout.RailCollapsed) { 16.0 } else { [double]$script:layout.RailWidth + 16.0 })
        if ($curAvailW -lt $neededWorkspaceW -and -not $script:layout.RailCollapsed) {
            $script:layout.RailCollapsed = $true
            Apply-LeftRailGeometry
            $curAvailW = [double]$script:window.Width - 16.0
        }
        if ($curAvailW -lt $neededWorkspaceW) {
            $maxScreenW = [Math]::Max(1180.0, [Windows.SystemParameters]::WorkArea.Width - 24.0)
            $desiredWinW = [Math]::Min($maxScreenW, $neededWorkspaceW + $(if ($script:layout.RailCollapsed) { 20.0 } else { [double]$script:layout.RailWidth + 24.0 }))
            if ($desiredWinW -gt $script:window.Width) {
                $script:suppressSizeChangedRebuild = $true
                try {
                    $script:window.Width = $desiredWinW
                } finally {
                    $script:suppressSizeChangedRebuild = $false
                }
            }
        }
    }
    $idx = -1
    for ($i = 0; $i -lt $panes.Count; $i++) {
        if ([int]$panes[$i].id -eq $PaneId) { $idx = $i; break }
    }
    if ($idx -lt 0) { $idx = $panes.Count - 1 }
    $newWeight = [Math]::Max(25.0, [Math]::Round(100.0 / ($panes.Count + 1), 1))
    $newPaneId = (Get-NextUniquePaneId)
    $script:launchpadPaneIds.Remove([int]$newPaneId)
    $script:pickerPaneIds[[int]$newPaneId] = $true
    $newPane = [pscustomobject]@{
        id = $newPaneId
        session_key = ''
        width_weight = $newWeight
        show_summary = $false
    }
    $panes.Insert($idx + 1, $newPane)
    $script:layout.Panes = $panes.ToArray()
    Normalize-PaneWeights
    Request-DeferredLayoutSync
    Render-PanesWorkspace
    Start-PaneDrawerOpenAnimation -PaneId ([int]$newPane.id) -TargetWeight ([double]$newPane.width_weight) -DurationMs 150
}

function Close-PaneById([int]$PaneId) {
    $panes = @($script:layout.Panes)
    if ($panes.Count -le 1) { return }
    $closedIdx = -1
    for ($i = 0; $i -lt $panes.Count; $i++) {
        if ([int]$panes[$i].id -eq $PaneId) { $closedIdx = $i; break }
    }
    $remaining = @($panes | Where-Object { [int]$_.id -ne $PaneId })
    if ($remaining.Count -eq 0) { return }
    if ($script:paneAnimTimer -and $script:paneAnimTimer.IsEnabled) {
        $script:paneAnimTimer.Stop()
    }
    $script:paneAnimCtx = $null
    $script:layout.HiddenRightPane = $null
    $script:layout.Panes = $remaining
    Normalize-PaneWeights
    Request-DeferredLayoutSync
    Render-PanesWorkspace
    if (-not $NoShow -and $script:controls.PanesHostGrid) {
        $survivingIdx = [Math]::Max(0, [Math]::Min($remaining.Count - 1, $(if ($closedIdx -gt 0) { $closedIdx - 1 } else { 0 })))
        $survivingId = [int]$remaining[$survivingIdx].id
        foreach ($ch in $script:controls.PanesHostGrid.Children) {
            if ($ch -is [Windows.Controls.Border] -and $ch.Tag -and $ch.Tag.PSObject.Properties.Name -contains 'PaneId' -and [int]$ch.Tag.PaneId -eq $survivingId) {
                Start-SmoothEnterAnimation -Element $ch -FromX $(if ($closedIdx -gt 0) { 10.0 } else { -10.0 }) -FromY 0.0 -DurationMs 135
                break
            }
        }
    }
}

function Restore-HiddenRightPane {
    if (-not $script:layout.HiddenRightPane) { return }
    $panes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($p in @($script:layout.Panes)) { $panes.Add($p) }
    if ($panes.Count -lt 4) {
        $hp = $script:layout.HiddenRightPane
        $panes.Add([pscustomobject]@{
            id = (Get-NextUniquePaneId)
            session_key = [string]$hp.session_key
            width_weight = 38.0
            show_summary = [bool]$hp.show_summary
        })
    }
    $script:layout.HiddenRightPane = $null
    $script:layout.Panes = $panes.ToArray()
    Normalize-PaneWeights
    Sync-LayoutMemory
    Render-PanesWorkspace
    Show-QuickToast '已恢复右侧对话栏'
}

function Toggle-PaneSummary([int]$PaneId) {
    $newVisible = $false
    foreach ($p in @($script:layout.Panes)) {
        if ([int]$p.id -eq $PaneId) {
            $p.show_summary = -not [bool]$p.show_summary
            $newVisible = [bool]$p.show_summary
            break
        }
    }
    Sync-LayoutMemory
    $updatedInPlace = $false
    if ($script:controls -and $script:controls.PanesHostGrid) {
        foreach ($ch in $script:controls.PanesHostGrid.Children) {
            if ($ch -is [Windows.Controls.Border] -and $ch.Tag -and $ch.Tag.PSObject.Properties['PaneId'] -and [int]$ch.Tag.PaneId -eq $PaneId) {
                $t = $ch.Tag
                if ($t.PSObject.Properties['SummaryCard'] -and $t.SummaryCard) {
                    $t.SummaryCard.Visibility = $(if ($newVisible) { 'Visible' } else { 'Collapsed' })
                    if ($newVisible -and -not $NoShow) {
                        Start-SmoothEnterAnimation $t.SummaryCard -FromY -6 -DurationMs 160
                    }
                    $updatedInPlace = $true
                }
                if ($t.PSObject.Properties['SummaryButton'] -and $t.SummaryButton) {
                    $isDark = ($script:effectiveTheme -eq 'dark')
                    if ($isDark) {
                        $t.SummaryButton.Background = ConvertTo-Brush $(if ($newVisible) { '#1E293B' } else { '#18181B' })
                        $t.SummaryButton.BorderBrush = ConvertTo-Brush $(if ($newVisible) { '#1D4ED8' } else { '#27272A' })
                        $t.SummaryButton.Foreground = ConvertTo-Brush $(if ($newVisible) { '#60A5FA' } else { '#D4D4D8' })
                    } else {
                        $t.SummaryButton.Background = ConvertTo-Brush $(if ($newVisible) { '#EFF6FF' } else { '#FFFFFF' })
                        $t.SummaryButton.BorderBrush = ConvertTo-Brush $(if ($newVisible) { '#BFDBFE' } else { '#E4E4E7' })
                        $t.SummaryButton.Foreground = ConvertTo-Brush $(if ($newVisible) { '#2563EB' } else { '#3F3F46' })
                    }
                }
                break
            }
        }
    }
    if (-not $updatedInPlace) {
        Render-PanesWorkspace
    }
}

function Switch-PaneToPicker([int]$PaneId) {
    foreach ($p in @($script:layout.Panes)) {
        if ([int]$p.id -eq $PaneId) {
            $p.session_key = ''
            $p.show_summary = $false
            $script:launchpadPaneIds.Remove([int]$p.id)
            $script:pickerPaneIds[[int]$p.id] = $true
            break
        }
    }
    Sync-LayoutMemory
    Render-PanesWorkspace
}

function Assign-TaskToPane([int]$PaneId, [string]$SessionKey) {
    foreach ($p in @($script:layout.Panes)) {
        if ([int]$p.id -eq $PaneId) {
            $p.session_key = $SessionKey
            $script:launchpadPaneIds.Remove([int]$p.id)
            $script:pickerPaneIds.Remove([int]$p.id)
            break
        }
    }
    Sync-LayoutMemory
    $script:lastCardsSig = ''
    Update-SessionCards
}

function Enter-NewTaskLaunchpad([int]$PaneId = 0) {
    # Spec v4.1 NewTaskLaunchpadUI: switch one pane to the "new task launchpad" (composer + first-sentence send).
    $panes = @($script:layout.Panes)
    if ($panes.Count -eq 0) { Normalize-PaneWeights; $panes = @($script:layout.Panes) }
    $target = $null
    if ($PaneId -gt 0) { $target = $panes | Where-Object { [int]$_.id -eq $PaneId } | Select-Object -First 1 }
    if (-not $target) { $target = $panes | Where-Object { -not $_.session_key } | Select-Object -First 1 }
    if (-not $target) { $target = $panes[0] }
    $target.session_key = ''
    $target.show_summary = $false
    $script:pickerPaneIds.Remove([int]$target.id)
    $script:launchpadPaneIds[[int]$target.id] = $true
    Sync-LayoutMemory
    $script:lastCardsSig = ''
    Update-SessionCards
}

function Open-TaskFromRail([string]$SessionKey) {
    if (-not $SessionKey) { return }
    $panes = @($script:layout.Panes)
    if ($panes.Count -eq 0) { Normalize-PaneWeights; $panes = @($script:layout.Panes) }
    $emptyPane = $panes | Where-Object { -not $_.session_key } | Select-Object -First 1
    $assigned = if ($emptyPane) { $emptyPane } else { $panes[0] }
    $assigned.session_key = $SessionKey
    $script:launchpadPaneIds.Remove([int]$assigned.id)
    $script:pickerPaneIds.Remove([int]$assigned.id)
    Sync-LayoutMemory
    $script:lastCardsSig = ''
    Update-SessionCards
}

function Resolve-LaunchpadSelectedBrowserProfile([int]$PaneId = 0) {
    $chosenId = ''
    $chosenProvider = 'chatgpt'
    if ($script:composerPodCache -and $script:composerPodCache.Count -gt 0) {
        if ($PaneId -gt 0) {
            foreach ($k in @($script:composerPodCache.Keys)) {
                if ([string]$k -like "$PaneId|__new_task__|*") {
                    $pod = $script:composerPodCache[$k]
                    if ($pod -and $pod.Tag) {
                        if ($pod.Tag.PSObject.Properties['Provider'] -and $pod.Tag.Provider) {
                            $chosenProvider = ([string]$pod.Tag.Provider).ToLowerInvariant()
                        }
                        if ($pod.Tag.ProfCombo -and $pod.Tag.ProfCombo.SelectedItem -and $pod.Tag.ProfCombo.SelectedItem.Tag) {
                            $chosenId = [string]$pod.Tag.ProfCombo.SelectedItem.Tag
                            break
                        }
                    }
                }
            }
        }
        if (-not $chosenId) {
            foreach ($k in @($script:composerPodCache.Keys)) {
                if ([string]$k -like "*|__new_task__|*") {
                    $pod = $script:composerPodCache[$k]
                    if ($pod -and $pod.Tag) {
                        if ($pod.Tag.PSObject.Properties['Provider'] -and $pod.Tag.Provider) {
                            $chosenProvider = ([string]$pod.Tag.Provider).ToLowerInvariant()
                        }
                        if ($pod.Tag.ProfCombo -and $pod.Tag.ProfCombo.SelectedItem -and $pod.Tag.ProfCombo.SelectedItem.Tag) {
                            $chosenId = [string]$pod.Tag.ProfCombo.SelectedItem.Tag
                            break
                        }
                    }
                }
            }
        }
    }
    if (-not $chosenId) {
        $wb = Get-WebBridgeState $script:context
        if ($wb -and $wb.session_bindings -and $wb.session_bindings.PSObject.Properties['__new_task__']) {
            $nt = $wb.session_bindings.__new_task__
            if ($nt) {
                $chosenProvider = Get-WebRoomProvider $nt
                if ($nt.PSObject.Properties['carrier_by_provider'] -and $nt.carrier_by_provider -and $nt.carrier_by_provider.PSObject.Properties[$chosenProvider] -and $nt.carrier_by_provider.$chosenProvider) {
                    $chosenId = [string]$nt.carrier_by_provider.$chosenProvider
                } elseif ($nt.PSObject.Properties['user_locked_browser'] -and $nt.user_locked_browser -and $nt.PSObject.Properties['browser_profile'] -and $nt.browser_profile) {
                    $chosenId = [string]$nt.browser_profile
                }
            }
        }
    }
    if ($chosenProvider -eq 'openai') { $chosenProvider = 'chatgpt' }
    $profs = @(Get-AvailableBrowserProfiles -Context $script:context)
    if ($chosenProvider -in @('gemini', 'claude')) {
        $profs = @($profs | Where-Object { ([string]$_.Id -notlike 'Desktop:*') -and ([string]$_.Label -notmatch 'ChatGPT 桌面端') })
    }
    if (-not $chosenId -or ($chosenProvider -in @('gemini', 'claude') -and $chosenId -like 'Desktop:*')) {
        $def = $profs | Where-Object { $_.IsDefault } | Select-Object -First 1
        if (-not $def -and $profs.Count -gt 0) { $def = $profs[0] }
        $chosenId = if ($def -and $def.Id) { [string]$def.Id } elseif ($chosenProvider -in @('gemini', 'claude')) { 'Edge:Default' } else { 'Desktop:ChatGPT' }
    }
    $chosenId = Resolve-RelayBrowserProfile $chosenId $script:context
    if ($chosenProvider -in @('gemini', 'claude') -and $chosenId -like 'Desktop:*') {
        $chosenId = if ($profs.Count -gt 0) { [string]$profs[0].Id } else { 'Edge:Default' }
    }
    $matchedProf = $profs | Where-Object { $_.Id -eq $chosenId } | Select-Object -First 1
    $cleanLabel = if ($matchedProf -and $matchedProf.Label) { ([string]$matchedProf.Label -replace '^(💻|🌐)\s*', '').Trim() } else { $chosenId }
    return [pscustomobject]@{
        Id = $chosenId
        Label = $cleanLabel
        Provider = $chosenProvider
    }
}

function Invoke-OpenChatGptHome([int]$PaneId = 0) {
    # User-initiated "open page": strictly honors the platform + browser/desktop selected in the Launchpad dropdown.
    try {
        $sel = Resolve-LaunchpadSelectedBrowserProfile -PaneId $PaneId
        $profId = [string]$sel.Id
        $profLabel = [string]$sel.Label
        $prov = if ($sel.PSObject.Properties['Provider'] -and $sel.Provider) { ([string]$sel.Provider).ToLowerInvariant() } else { 'chatgpt' }
        $homeUrl = switch ($prov) {
            'gemini' { 'https://gemini.google.com/app' }
            'claude' { 'https://claude.ai/new' }
            default  { 'https://chatgpt.com/' }
        }
        $platTitle = switch ($prov) {
            'gemini' { 'Gemini' }
            'claude' { 'Claude' }
            default  { 'ChatGPT' }
        }
        if (-not $script:context.Isolated) { [void](Open-BridgeHandoverWindow -Url $homeUrl -BrowserProfile $profId -Context $script:context) }
        Show-QuickToast "↗ 已打开 $platTitle（$profLabel）"
    } catch {
        Show-QuickToast $_.Exception.Message
    }
}

function Show-UndoDeleteBanner {
    if ($script:controls.UndoDeleteBorder) {
        $script:controls.UndoDeleteBorder.Visibility = 'Collapsed'
    }
}

function Confirm-PurgeArchivedDialog([string]$TargetTitle = '', [switch]$IsBatch, [int]$BatchCount = 0) {
    $ovVar = Get-Variable -Name 'PurgeConfirmOverride' -Scope Script -ErrorAction SilentlyContinue
    if ($ovVar -and $ovVar.Value -is [scriptblock]) {
        return [bool](& $ovVar.Value $TargetTitle ([bool]$IsBatch) $BatchCount)
    }
    $noShowVar = Get-Variable -Name 'NoShow' -ErrorAction SilentlyContinue
    if ($noShowVar -and [bool]$noShowVar.Value) {
        return $true
    }
    $label = if ($IsBatch) { "全部 $BatchCount 条已归档任务" } elseif ($TargetTitle) { "「$TargetTitle」" } else { '该归档任务' }
    $msg = "确定要彻底删除 $label 吗？`r`n`r`n将从本软件及对应网页端永久删除此任务关联的全部会话（含本机任务账本 tsk_*.json 与云端对话），不可恢复。"
    $ans = [Windows.MessageBox]::Show($msg, 'RelayStudio · 彻底删除确认', [Windows.MessageBoxButton]::OKCancel, [Windows.MessageBoxImage]::Warning)
    return ($ans -eq [Windows.MessageBoxResult]::OK)
}

function Invoke-ArchiveSession([string]$SessionKey) {
    if (-not $SessionKey) { return }
    $cleanName = $SessionKey
    try {
        $hitSess = @($script:display.Sessions | Where-Object { $_ -and [string]$_.SessionKey -eq $SessionKey } | Select-Object -First 1)
        if ($hitSess.Count -gt 0 -and $hitSess[0]) {
            $hitTitle = if ($hitSess[0].PSObject.Properties['ShortTitle'] -and $hitSess[0].ShortTitle) { [string]$hitSess[0].ShortTitle } elseif ($hitSess[0].PSObject.Properties['Title']) { [string]$hitSess[0].Title } else { '' }
            if ($hitTitle) { $cleanName = $hitTitle }
        }
    } catch { }
    Set-TaskArchiveState -Context $script:context -TaskId $SessionKey -State 'archived'
    foreach ($p in @($script:layout.Panes)) {
        if ($p.session_key -eq $SessionKey) { $p.session_key = '' }
    }
    $script:lastDeletedTask = $null
    if ($script:controls.UndoDeleteBorder) {
        $script:controls.UndoDeleteBorder.Visibility = 'Collapsed'
    }
    Sync-LayoutMemory
    Refresh-FormState
    if ($script:controls.ArchiveDrawerOverlay -and $script:controls.ArchiveDrawerOverlay.Visibility -eq 'Visible') {
        Update-ArchiveDrawerModal
    }
    Show-QuickToast "📦 已归档「$cleanName」并同步归档云端会话"
}

function Invoke-RestoreSession([string]$SessionKey, [int]$TargetPaneId = 0) {
    if (-not $SessionKey) { return }
    Set-TaskArchiveState -Context $script:context -TaskId $SessionKey -State 'active'
    if ($TargetPaneId -gt 0) {
        foreach ($p in @($script:layout.Panes)) {
            if ([int]$p.id -eq $TargetPaneId) { $p.session_key = $SessionKey; $script:launchpadPaneIds.Remove([int]$p.id); $script:pickerPaneIds.Remove([int]$p.id); break }
        }
    } else {
        $panes = @($script:layout.Panes)
        if ($panes.Count -eq 0) { Normalize-PaneWeights; $panes = @($script:layout.Panes) }
        $emptyPane = $panes | Where-Object { -not $_.session_key } | Select-Object -First 1
        $assigned = if ($emptyPane) { $emptyPane } else { $panes[0] }
        $assigned.session_key = $SessionKey
        $script:launchpadPaneIds.Remove([int]$assigned.id)
        $script:pickerPaneIds.Remove([int]$assigned.id)
    }
    Sync-LayoutMemory
    $script:lastCardsSig = ''
    Refresh-FormState
    if ($script:controls.ArchiveDrawerOverlay -and $script:controls.ArchiveDrawerOverlay.Visibility -eq 'Visible') {
        Update-ArchiveDrawerModal
    }
    Show-QuickToast '已将该对话还原至进行中队列'
}

function Invoke-DeleteSession([string]$SessionKey, [string]$Title = '', [switch]$PhysicalPurge) {
    if (-not $SessionKey) { return $false }
    $cleanName = if ($Title) { $Title } else { $SessionKey }
    if (-not (Confirm-PurgeArchivedDialog -TargetTitle $cleanName)) {
        return $false
    }
    [void](Invoke-PurgeArchivedSession -Context $script:context -SessionKey $SessionKey -PhysicalPurge -Settings $script:settings)
    foreach ($p in @($script:layout.Panes)) {
        if ($p.session_key -eq $SessionKey) { $p.session_key = '' }
    }
    $script:lastDeletedTask = $null
    if ($script:controls.UndoDeleteBorder) {
        $script:controls.UndoDeleteBorder.Visibility = 'Collapsed'
    }
    Sync-LayoutMemory
    Refresh-FormState
    if ($script:controls.ArchiveDrawerOverlay -and $script:controls.ArchiveDrawerOverlay.Visibility -eq 'Visible') {
        Update-ArchiveDrawerModal
    }
    Show-QuickToast "✓ 已彻底粉碎归档会话「$cleanName」及本机任务文件"
    return $true
}

function Invoke-ClearAllArchivedSessions {
    $archivedSessions = @(if ($script:display -and $script:display.PSObject.Properties.Name -contains 'ArchivedSessions' -and $script:display.ArchivedSessions) { $script:display.ArchivedSessions })
    if ($archivedSessions.Count -eq 0) {
        Show-QuickToast '当前没有已归档的会话记录'
        return $false
    }
    if (-not (Confirm-PurgeArchivedDialog -TargetTitle "全部 $($archivedSessions.Count) 条归档" -IsBatch -BatchCount $archivedSessions.Count)) {
        return $false
    }
    $res = Invoke-PurgeAllArchivedSessions -Context $script:context -ArchivedSessions $archivedSessions -PhysicalPurge -Settings $script:settings
    $script:lastDeletedTask = $null
    if ($script:controls.UndoDeleteBorder) {
        $script:controls.UndoDeleteBorder.Visibility = 'Collapsed'
    }
    Refresh-FormState
    if ($script:controls.ArchiveDrawerOverlay -and $script:controls.ArchiveDrawerOverlay.Visibility -eq 'Visible') {
        Update-ArchiveDrawerModal
    }
    Show-QuickToast "✓ 已一键清空全部 $($res.ClearedCount) 条归档及本机账本"
    return $true
}

function Dismiss-UndoDeleteBanner {
    $script:lastDeletedTask = $null
    if ($script:controls.UndoDeleteBorder) {
        $script:controls.UndoDeleteBorder.Visibility = 'Collapsed'
    }
}

function Invoke-UndoDeleteSession {
    if (-not $script:lastDeletedTask) { return }
    $last = $script:lastDeletedTask
    $script:lastDeletedTask = $null
    $script:controls.UndoDeleteBorder.Visibility = 'Collapsed'
    if ($last.PSObject.Properties['IsBatch'] -and $last.IsBatch -and $last.PreviousStates) {
        foreach ($k in $last.PreviousStates.Keys) {
            $st = [string]$last.PreviousStates[$k]
            Set-TaskArchiveState -Context $script:context -TaskId $k -State $(if ($st -in @('archived','active','auto')) { $st } else { 'auto' })
        }
    } elseif ($last.Key) {
        $prevSt = if ($last.PSObject.Properties['PrevState'] -and $last.PrevState -in @('archived','active','auto')) { [string]$last.PrevState } else { 'auto' }
        Set-TaskArchiveState -Context $script:context -TaskId ([string]$last.Key) -State $prevSt
    }
    Refresh-FormState
    if ($script:controls.ArchiveDrawerOverlay -and $script:controls.ArchiveDrawerOverlay.Visibility -eq 'Visible') {
        Update-ArchiveDrawerModal
    }
    Show-QuickToast "已恢复刚才删除的「$($last.Title)」"
}

function Invoke-OpenSessionWebPage($SessionObj) {
    if (-not $SessionObj) { return }
    if ($SessionObj -is [string]) {
        $all = @(Get-AllAvailableSessions)
        $SessionObj = $all | Where-Object { $_.SessionKey -eq $SessionObj } | Select-Object -First 1
        if (-not $SessionObj) { return }
    }
    try {
        $sessProv = Get-WebRoomProvider $SessionObj
        if ($script:composerPodCache) {
            foreach ($podEntry in $script:composerPodCache.Values) {
                if ($podEntry -and $podEntry.Tag -and $podEntry.Tag.TaskKey -eq [string]$SessionObj.SessionKey -and $podEntry.Tag.PSObject.Properties['Provider'] -and $podEntry.Tag.Provider) {
                    $sessProv = ([string]$podEntry.Tag.Provider).ToLowerInvariant()
                    break
                }
            }
        }
        $res = Open-SessionWebPage -Context $script:context -Session $SessionObj -Provider $sessProv -RequireBoundConversation
        # Success copy only when the window was verified visible on screen; otherwise an honest warning.
        Show-QuickToast (Get-OpenWebPageToastText -Result $res)
    } catch {
        Show-QuickToast $_.Exception.Message
    }
}

function Update-ArchiveDrawerModal {
    if (-not $script:controls.ArchiveDrawerListPanel) { return }
    $archivedSessions = @(if ($script:display -and $script:display.PSObject.Properties.Name -contains 'ArchivedSessions' -and $script:display.ArchivedSessions) { $script:display.ArchivedSessions })
    $archCount = $archivedSessions.Count
    if ($script:controls.ArchiveDrawerTitle) {
        $script:controls.ArchiveDrawerTitle.Text = "📦 已归档会话管理 ($archCount)"
    }
    if ($script:controls.ClearAllArchivedButton) {
        $script:controls.ClearAllArchivedButton.IsEnabled = ($archCount -gt 0)
        $script:controls.ClearAllArchivedButton.Opacity = if ($archCount -gt 0) { 1.0 } else { 0.45 }
    }
    $script:controls.ArchiveDrawerListPanel.Children.Clear()
    if ($archCount -eq 0) {
        $emptyBox = New-Object Windows.Controls.Border
        $emptyBox.Background = ConvertTo-Brush '#FAFAFA'
        $emptyBox.BorderBrush = ConvertTo-Brush '#E4E4E7'
        $emptyBox.BorderThickness = [Windows.Thickness]::new(1)
        $emptyBox.CornerRadius = [Windows.CornerRadius]::new(8)
        $emptyBox.Padding = [Windows.Thickness]::new(18, 22, 18, 22)
        $emptyTxt = New-Object Windows.Controls.TextBlock
        $emptyTxt.Text = '当前没有已归档的会话记录。'
        $emptyTxt.FontSize = 13
        $emptyTxt.Foreground = ConvertTo-Brush '#71717A'
        $emptyTxt.HorizontalAlignment = 'Center'
        $emptyBox.Child = $emptyTxt
        [void]$script:controls.ArchiveDrawerListPanel.Children.Add($emptyBox)
        return
    }
    foreach ($ar in $archivedSessions) {
        $card = New-Object Windows.Controls.Border
        $card.Background = ConvertTo-Brush '#FFFFFF'
        $card.BorderBrush = ConvertTo-Brush '#E4E4E7'
        $card.BorderThickness = [Windows.Thickness]::new(1)
        $card.CornerRadius = [Windows.CornerRadius]::new(8)
        $card.Padding = [Windows.Thickness]::new(12, 9, 12, 9)
        $card.Margin = [Windows.Thickness]::new(0, 0, 0, 7)

        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::Auto
        [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)

        $leftSt = New-Object Windows.Controls.StackPanel
        $leftSt.VerticalAlignment = 'Center'
        $tRow = New-Object Windows.Controls.StackPanel
        $tRow.Orientation = 'Horizontal'
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 7; $dot.Height = 7
        $dot.Fill = ConvertTo-Brush '#A1A1AA'
        $dot.VerticalAlignment = 'Center'
        $dot.Margin = [Windows.Thickness]::new(0, 0, 7, 0)
        [void]$tRow.Children.Add($dot)

        $titleTxt = New-Object Windows.Controls.TextBlock
        $titleTxt.Text = $(if ($ar.ShortTitle) { $ar.ShortTitle } else { $ar.Title })
        $titleTxt.FontSize = 13
        $titleTxt.FontWeight = 'SemiBold'
        $titleTxt.Foreground = ConvertTo-Brush '#18181B'
        $titleTxt.TextTrimming = 'CharacterEllipsis'
        $titleTxt.TextWrapping = 'NoWrap'
        [void]$tRow.Children.Add($titleTxt)
        [void]$leftSt.Children.Add($tRow)

        $subTxt = New-Object Windows.Controls.TextBlock
        $subTxt.Text = "$($ar.ArchiveReason) · $($ar.StepCountText)"
        $subTxt.FontSize = 11.5
        $subTxt.Foreground = ConvertTo-Brush '#71717A'
        $subTxt.Margin = [Windows.Thickness]::new(14, 2, 0, 0)
        [void]$leftSt.Children.Add($subTxt)
        [Windows.Controls.Grid]::SetColumn($leftSt, 0)
        [void]$g.Children.Add($leftSt)

        $btnRow = New-Object Windows.Controls.StackPanel
        $btnRow.Orientation = 'Horizontal'
        $btnRow.VerticalAlignment = 'Center'
        $btnRow.Margin = [Windows.Thickness]::new(10, 0, 0, 0)

        $webBtn = New-Object Windows.Controls.Button
        $webBtn.Content = '🌐 打开网页 ↗'
        $webBtn.Padding = [Windows.Thickness]::new(8, 3, 8, 3)
        $webBtn.MinHeight = 25
        $webBtn.FontSize = 11.5
        $webBtn.Background = ConvertTo-Brush '#FFFFFF'
        $webBtn.BorderBrush = ConvertTo-Brush '#E4E4E7'
        $webBtn.Foreground = ConvertTo-Brush '#3F3F46'
        $webBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
        $webBtn.Tag = $ar
        $webBtn.Add_Click({
            param($sender, $e)
            if ($sender.Tag) { Invoke-OpenSessionWebPage $sender.Tag }
        })
        [void]$btnRow.Children.Add($webBtn)

        $restBtn = New-Object Windows.Controls.Button
        $restBtn.Content = '↺ 还原'
        $restBtn.Padding = [Windows.Thickness]::new(8, 3, 8, 3)
        $restBtn.MinHeight = 25
        $restBtn.FontSize = 11.5
        $restBtn.Background = ConvertTo-Brush '#EFF6FF'
        $restBtn.BorderBrush = ConvertTo-Brush '#BFDBFE'
        $restBtn.Foreground = ConvertTo-Brush '#1D4ED8'
        $restBtn.FontWeight = 'SemiBold'
        $restBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
        $restBtn.Tag = $ar.SessionKey
        $restBtn.Add_Click({
            param($sender, $e)
            if ($sender.Tag) { Invoke-RestoreSession ([string]$sender.Tag) }
        })
        [void]$btnRow.Children.Add($restBtn)

        $delBtn = New-Object Windows.Controls.Button
        $delBtn.Content = '🗑 彻底删除'
        $delBtn.Padding = [Windows.Thickness]::new(8, 3, 8, 3)
        $delBtn.MinHeight = 25
        $delBtn.FontSize = 11.5
        $delBtn.Background = ConvertTo-Brush '#FEF2F2'
        $delBtn.BorderBrush = ConvertTo-Brush '#FECACA'
        $delBtn.Foreground = ConvertTo-Brush '#DC2626'
        $delBtn.FontWeight = 'SemiBold'
        $delBtn.Tag = [pscustomobject]@{ Key = $ar.SessionKey; Title = $(if ($ar.ShortTitle) { $ar.ShortTitle } else { $ar.Title }) }
        $delBtn.Add_Click({
            param($sender, $e)
            $info = $sender.Tag
            if ($info) { Invoke-DeleteSession $info.Key $info.Title -PhysicalPurge }
        })
        [void]$btnRow.Children.Add($delBtn)

        [Windows.Controls.Grid]::SetColumn($btnRow, 1)
        [void]$g.Children.Add($btnRow)
        $card.Child = $g
        [void]$script:controls.ArchiveDrawerListPanel.Children.Add($card)
    }
}

function Open-ArchiveDrawer {
    Update-ArchiveDrawerModal
    if ($script:controls.ArchiveDrawerOverlay) {
        $script:controls.ArchiveDrawerOverlay.Visibility = 'Visible'
        if ($script:controls.ArchiveDrawerOverlay.Child) {
            Start-SmoothEnterAnimation $script:controls.ArchiveDrawerOverlay.Child -FromY 8 -DurationMs 170
        }
    }
}

function Close-ArchiveDrawer {
    if ($script:controls.ArchiveDrawerOverlay) {
        $script:controls.ArchiveDrawerOverlay.Visibility = 'Collapsed'
    }
}

function Format-WebMessageStageText($MsgObj) {
    if (-not $MsgObj) { return '⏳ 已加入待发队列（等当前回合停稳后自动发送）' }
    $st = if ($MsgObj.PSObject.Properties['Status']) { [string]$MsgObj.Status } else { 'pending' }
    switch ($st) {
        'delivered'   { return '✓ 网页已确认接收并启动对话流' }
        'claimed'     { return '⏳ 网页已就绪，正在填入并提交指令' }
        'unconfirmed' { return '⚠ 未确认网页接收，请检查会话' }
        default {
            if ($MsgObj.PSObject.Properties['DeferUntilStopped'] -and $MsgObj.DeferUntilStopped) {
                return '⏳ 已加入待发队列（等原网页本轮停稳后自动换新窗接力）'
            }
            return '⏳ 已加入待发队列（等当前回合停稳后自动发送）'
        }
    }
}

function Update-QueueBannerBorder($BannerBorder, $SessionObj) {
    if (-not $BannerBorder) { return }
    if (-not $SessionObj) {
        $BannerBorder.Visibility = 'Collapsed'
        $BannerBorder.Child = $null
        return
    }
    $rawSentMsgs = @(if (($null -ne $SessionObj.PSObject.Properties['SentWebMessages']) -and $SessionObj.SentWebMessages) {
        $SessionObj.SentWebMessages | Where-Object { $_ -and $_.Status -notin @('superseded', 'cancelled') }
    })
    $hasPendingProp = ($null -ne $SessionObj.PSObject.Properties['PendingQueue'])
    $pendingQ = @(if ($hasPendingProp) {
        if ($SessionObj.PendingQueue) {
            $SessionObj.PendingQueue | Where-Object { $_ -and $_.Status -eq 'pending' }
        }
    } else {
        $rawSentMsgs | Where-Object { $_ -and $_.Status -eq 'pending' }
    })
    $nonPendingSent = @($rawSentMsgs | Where-Object { $_ -and $_.Status -ne 'pending' })
    if ($pendingQ.Count -eq 0 -and $nonPendingSent.Count -eq 0) {
        $BannerBorder.Visibility = 'Collapsed'
        $BannerBorder.Child = $null
        return
    }

    $isShowingPending = ($pendingQ.Count -gt 0)
    $wm = if ($isShowingPending) { $pendingQ[0] } else { $nonPendingSent[0] }
    $totalQueueAndHistory = $pendingQ.Count + $nonPendingSent.Count

    $BannerBorder.Visibility = 'Visible'
    $BannerBorder.Background = ConvertTo-Brush $(if ($isShowingPending) { '#FFFBEB' } else { '#EFF6FF' })
    $BannerBorder.BorderBrush = ConvertTo-Brush $(if ($isShowingPending) { '#FDE68A' } else { '#BFDBFE' })
    $BannerBorder.BorderThickness = [Windows.Thickness]::new(1)
    $BannerBorder.CornerRadius = [Windows.CornerRadius]::new(8)
    $BannerBorder.Padding = [Windows.Thickness]::new(12, 9, 12, 9)
    $BannerBorder.Margin = [Windows.Thickness]::new(0, 0, 0, 14)

    $bStack = New-Object Windows.Controls.StackPanel
    $bHead = New-Object Windows.Controls.Grid
    $bc0 = New-Object Windows.Controls.ColumnDefinition; $bc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $bc1 = New-Object Windows.Controls.ColumnDefinition; $bc1.Width = [Windows.GridLength]::Auto
    $bc2 = New-Object Windows.Controls.ColumnDefinition; $bc2.Width = [Windows.GridLength]::Auto
    $bc3 = New-Object Windows.Controls.ColumnDefinition; $bc3.Width = [Windows.GridLength]::Auto
    [void]$bHead.ColumnDefinitions.Add($bc0); [void]$bHead.ColumnDefinitions.Add($bc1); [void]$bHead.ColumnDefinitions.Add($bc2); [void]$bHead.ColumnDefinitions.Add($bc3)
    $bHead.Margin = [Windows.Thickness]::new(0, 0, 0, 4)

    $bLeft = New-Object Windows.Controls.TextBlock
    $statusLabel = if ($isShowingPending) {
        if ($wm.PSObject.Properties['DeferUntilStopped'] -and $wm.DeferUntilStopped) {
            "⏳ 待发队列 ($($pendingQ.Count)) · 等原网页本轮停稳后自动换新窗接力"
        } else {
            "⏳ 待发队列 ($($pendingQ.Count)) · 等当前回合停稳后自动发送"
        }
    } else {
        Format-WebMessageStageText $wm
    }
    $bLeft.Text = $statusLabel
    $bLeft.FontSize = 11.5
    $bLeft.FontWeight = 'SemiBold'
    $bLeft.Foreground = ConvertTo-Brush $(if ($isShowingPending) { '#B45309' } elseif ($wm.Status -eq 'unconfirmed') { '#D97706' } else { '#2563EB' })
    $bLeft.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($bLeft, 0)
    [void]$bHead.Children.Add($bLeft)

    $bTime = New-Object Windows.Controls.TextBlock
    $bTime.Text = [string]$wm.TimeText
    $bTime.FontSize = 11
    $bTime.Foreground = ConvertTo-Brush $(if ($isShowingPending) { '#92400E' } else { '#3B82F6' })
    $bTime.VerticalAlignment = 'Center'
    $bTime.Margin = [Windows.Thickness]::new(8, 0, 8, 0)
    [Windows.Controls.Grid]::SetColumn($bTime, 1)
    [void]$bHead.Children.Add($bTime)

    if ($isShowingPending) {
        $cancelPendingBtn = New-Object Windows.Controls.Button
        $cancelPendingBtn.Content = '× 撤回待发'
        $cancelPendingBtn.Padding = [Windows.Thickness]::new(8, 2, 8, 2)
        $cancelPendingBtn.MinHeight = 22
        $cancelPendingBtn.FontSize = 11
        $cancelPendingBtn.FontWeight = 'SemiBold'
        $cancelPendingBtn.Background = ConvertTo-Brush '#FEF2F2'
        $cancelPendingBtn.BorderBrush = ConvertTo-Brush '#FECACA'
        $cancelPendingBtn.Foreground = ConvertTo-Brush '#DC2626'
        $cancelPendingBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
        $cancelPendingBtn.Tag = [pscustomobject]@{
            SessionKey = [string]$SessionObj.SessionKey
            MsgId = $(if ($wm.PSObject.Properties['Id']) { [string]$wm.Id } else { '' })
            Session = $SessionObj
        }
        $cancelPendingBtn.ToolTip = '从待发队列撤回当前队首指令，不再发往网页端'
        $cancelPendingBtn.Add_Click({
            param($sender, $e)
            if ($sender.Tag -and $sender.Tag.MsgId) {
                Invoke-CancelQueuedWebMessage $sender.Tag.SessionKey $sender.Tag.MsgId $sender.Tag.Session
            }
        })
        [Windows.Controls.Grid]::SetColumn($cancelPendingBtn, 2)
        [void]$bHead.Children.Add($cancelPendingBtn)
    }

    $histBtn = New-Object Windows.Controls.Button
    $histBtn.Content = "📜 发送与待发队列 ($totalQueueAndHistory) ↗"
    $histBtn.Padding = [Windows.Thickness]::new(8, 2, 8, 2)
    $histBtn.MinHeight = 22
    $histBtn.FontSize = 11
    $histBtn.FontWeight = 'SemiBold'
    $histBtn.Background = ConvertTo-Brush '#DBEAFE'
    $histBtn.BorderBrush = ConvertTo-Brush '#93C5FD'
    $histBtn.Foreground = ConvertTo-Brush '#1D4ED8'
    $histBtn.Tag = $SessionObj
    $histBtn.ToolTip = '查看和管理该任务的待发队列（支持上移/下移/删除）及历史已发送记录'
    $histBtn.Add_Click({
        param($sender, $e)
        if ($sender.Tag) { Open-SentHistoryModal $sender.Tag }
    })
    [Windows.Controls.Grid]::SetColumn($histBtn, 3)
    [void]$bHead.Children.Add($histBtn)
    [void]$bStack.Children.Add($bHead)

    $bBody = New-Object Windows.Controls.TextBlock
    $bBody.Text = "「$($wm.Text)」"
    $bBody.FontSize = 12.5
    $bBody.FontWeight = 'Medium'
    $bBody.Foreground = ConvertTo-Brush '#18181B'
    $bBody.TextWrapping = 'Wrap'
    $bBody.MaxHeight = 64
    $bBody.TextTrimming = 'CharacterEllipsis'
    [void]$bStack.Children.Add($bBody)

    if ($SessionObj.PSObject.Properties['VitalHintText'] -and $SessionObj.VitalHintText -and [string]$SessionObj.VitalHintText -ne '本机执行中') {
        $bHint = New-Object Windows.Controls.TextBlock
        $bHint.Text = "↳ $([string]$SessionObj.VitalHintText)"
        $bHint.FontSize = 11
        $bHint.Foreground = ConvertTo-Brush '#52525B'
        $bHint.Margin = [Windows.Thickness]::new(0, 4, 0, 0)
        [void]$bStack.Children.Add($bHint)
    }

    $BannerBorder.Child = $bStack
}

function Find-DisplaySessionByKey([string]$SessionKey) {
    if (-not $SessionKey) { return $null }
    if ($script:display -and ($null -ne $script:display.PSObject.Properties['Sessions']) -and $script:display.Sessions) {
        foreach ($ds in @($script:display.Sessions)) {
            if ($ds -and ([string]$ds.SessionKey -eq $SessionKey -or ($ds.PSObject.Properties['WfrId'] -and [string]$ds.WfrId -eq $SessionKey))) {
                return $ds
            }
        }
    }
    return $null
}

function Update-SessionQueueUI([string]$SessionKey, $FallbackSession = $null) {
    $effSess = Find-DisplaySessionByKey $SessionKey
    if (-not $effSess) { $effSess = $FallbackSession }
    if (-not $effSess) { return }
    $effKey = if ($SessionKey) { $SessionKey } else { [string]$effSess.SessionKey }
    if ($effKey -and $script:sessionQueueBannerBorders.ContainsKey($effKey)) {
        $bArr = [object[]]$script:sessionQueueBannerBorders[$effKey]
        for ($bi = 0; $bi -lt $bArr.Count; $bi++) {
            $bBorder = $bArr[$bi]
            if ($bBorder) {
                Update-QueueBannerBorder -BannerBorder $bBorder -SessionObj $effSess
            }
        }
    }
    if ($script:controls.SentHistoryOverlay -and $script:controls.SentHistoryOverlay.Visibility -eq 'Visible') {
        if (-not $script:openQueueModalSessionKey -or $script:openQueueModalSessionKey -eq $effKey) {
            Open-SentHistoryModal $effSess
        }
    }
}

function Apply-SessionQueueSlice([string]$SessionKey, $QueueSlice, $FallbackSession = $null) {
    if (-not $QueueSlice) { return }
    $dispSess = Find-DisplaySessionByKey $SessionKey
    $effKey = if ($SessionKey) { $SessionKey } elseif ($FallbackSession) { [string]$FallbackSession.SessionKey } else { '' }
    $newPending = @(if (($null -ne $QueueSlice.PSObject.Properties['PendingQueue']) -and $QueueSlice.PendingQueue) {
        $QueueSlice.PendingQueue | Where-Object { $_ -and $_.Status -eq 'pending' }
    })
    $sliceSent = @(if (($null -ne $QueueSlice.PSObject.Properties['SentWebMessages']) -and $QueueSlice.SentWebMessages) {
        $QueueSlice.SentWebMessages | Where-Object { $_ -and $_.Status -notin @('superseded', 'cancelled') }
    })
    $seenIds = @{}
    $mergedList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($sm in $sliceSent) {
        if (-not $sm) { continue }
        $sid = if ($sm.PSObject.Properties['Id'] -and $sm.Id) { [string]$sm.Id } else { '' }
        if ($sid) { $seenIds[$sid] = $true }
        [void]$mergedList.Add($sm)
    }
    $priorSource = if ($dispSess) { $dispSess } else { $FallbackSession }
    if ($priorSource -and ($null -ne $priorSource.PSObject.Properties['SentWebMessages']) -and $priorSource.SentWebMessages) {
        foreach ($oldM in @($priorSource.SentWebMessages)) {
            if (-not $oldM -or $oldM.Status -notin @('delivered', 'unconfirmed')) { continue }
            $oid = if ($oldM.PSObject.Properties['Id'] -and $oldM.Id) { [string]$oldM.Id } else { '' }
            if ($oid -and (-not $seenIds.ContainsKey($oid))) {
                $seenIds[$oid] = $true
                [void]$mergedList.Add($oldM)
            }
        }
    }
    $mergedSent = @($mergedList.ToArray() | Select-Object -First 20)
    foreach ($tObj in @($dispSess, $FallbackSession)) {
        if (-not $tObj) { continue }
        $tObj | Add-Member -NotePropertyName 'PendingQueue' -NotePropertyValue $newPending -Force
        $tObj | Add-Member -NotePropertyName 'PendingQueueCount' -NotePropertyValue $newPending.Count -Force
        $tObj | Add-Member -NotePropertyName 'SentWebMessages' -NotePropertyValue $mergedSent -Force
    }
    Update-SessionQueueUI -SessionKey $effKey -FallbackSession $(if ($dispSess) { $dispSess } else { $FallbackSession })
}

function Test-HasActiveQueueWork {
    if ($script:controls.SentHistoryOverlay -and $script:controls.SentHistoryOverlay.Visibility -eq 'Visible') {
        return $true
    }
    if ($script:lastQueueActionUtc -gt [DateTime]::MinValue -and (([DateTime]::UtcNow - $script:lastQueueActionUtc).TotalSeconds -lt 12.0)) {
        return $true
    }
    if ($script:display -and ($null -ne $script:display.PSObject.Properties['Sessions']) -and $script:display.Sessions) {
        foreach ($s in @($script:display.Sessions)) {
            if (-not $s) { continue }
            if (($null -ne $s.PSObject.Properties['PendingQueueCount']) -and [int]$s.PendingQueueCount -gt 0) {
                return $true
            }
            if (($null -ne $s.PSObject.Properties['SentWebMessages']) -and $s.SentWebMessages) {
                foreach ($m in @($s.SentWebMessages)) {
                    if ($m -and $m.Status -in @('pending', 'claimed')) { return $true }
                }
            }
        }
    }
    return $false
}

function Sync-QueueFastPollingState {
    if (-not $script:queueFastTimer) { return }
    if ($script:context.Isolated) {
        if ($script:queueFastTimer.IsEnabled) { $script:queueFastTimer.Stop() }
        return
    }
    $canRunUi = Test-ShouldRunUiRefreshTimer -IsVisible ([bool]$script:window.IsVisible) -WindowState $script:window.WindowState -IsActive ([bool]$script:window.IsActive) -Busy $false
    if ((-not $canRunUi) -or (-not (Test-HasActiveQueueWork))) {
        if ($script:queueFastTimer.IsEnabled) { $script:queueFastTimer.Stop() }
        return
    }
    if (-not $script:queueFastTimer.IsEnabled) {
        $script:queueFastTimer.Start()
    }
}

function Invoke-CancelQueuedWebMessage([string]$SessionKey, [string]$MessageId, $ModalSession = $null) {
    if (-not $MessageId) { return }
    try {
        $res = Remove-WebBridgeQueuedMessage -Context $script:context -SessionKey $SessionKey -MessageId $MessageId
        $effSk = if ($SessionKey) {
            $SessionKey
        } elseif ($res -and $res.PSObject.Properties['session_key'] -and $res.session_key) {
            [string]$res.session_key
        } elseif ($ModalSession) {
            [string]$ModalSession.SessionKey
        } else { '' }
        $qSlice = if ($res -and $res.PSObject.Properties['queue_slice'] -and $res.queue_slice) {
            $res.queue_slice
        } elseif ($res -and $res.PSObject.Properties['QueueSlice'] -and $res.QueueSlice) {
            $res.QueueSlice
        } else { $null }
        if ($qSlice -and $effSk) {
            Apply-SessionQueueSlice -SessionKey $effSk -QueueSlice $qSlice -FallbackSession $ModalSession
        } else {
            $dispSess = Find-DisplaySessionByKey $effSk
            foreach ($tObj in @($dispSess, $ModalSession)) {
                if (-not $tObj) { continue }
                $curPend = @(if (($null -ne $tObj.PSObject.Properties['PendingQueue']) -and $tObj.PendingQueue) {
                    $tObj.PendingQueue | Where-Object { $_ -and [string]$_.Id -ne $MessageId }
                })
                $curSent = @(if (($null -ne $tObj.PSObject.Properties['SentWebMessages']) -and $tObj.SentWebMessages) {
                    $tObj.SentWebMessages | Where-Object { $_ -and [string]$_.Id -ne $MessageId }
                })
                $tObj | Add-Member -NotePropertyName 'PendingQueue' -NotePropertyValue $curPend -Force
                $tObj | Add-Member -NotePropertyName 'PendingQueueCount' -NotePropertyValue $curPend.Count -Force
                $tObj | Add-Member -NotePropertyName 'SentWebMessages' -NotePropertyValue $curSent -Force
            }
            Update-SessionQueueUI -SessionKey $effSk -FallbackSession $ModalSession
        }
        $script:lastQueueActionUtc = [DateTime]::UtcNow
        Reset-ConnectionInfraCache
        Sync-QueueFastPollingState
        if ($res -and $res.changed) {
            Show-QuickToast '✓ 已从待发队列撤回该条指令'
        }
    } catch {
        Show-QuickToast $_.Exception.Message
    }
}

function Invoke-MoveQueuedWebMessage([string]$SessionKey, [string]$MessageId, [string]$Direction, $ModalSession = $null) {
    if (-not $MessageId) { return }
    try {
        $res = Move-WebBridgeQueuedMessage -Context $script:context -SessionKey $SessionKey -MessageId $MessageId -Direction $Direction
        $effSk = if ($SessionKey) {
            $SessionKey
        } elseif ($res -and $res.PSObject.Properties['session_key'] -and $res.session_key) {
            [string]$res.session_key
        } elseif ($ModalSession) {
            [string]$ModalSession.SessionKey
        } else { '' }
        $qSlice = if ($res -and $res.PSObject.Properties['queue_slice'] -and $res.queue_slice) {
            $res.queue_slice
        } elseif ($res -and $res.PSObject.Properties['QueueSlice'] -and $res.QueueSlice) {
            $res.QueueSlice
        } else { $null }
        if ($qSlice -and $effSk) {
            Apply-SessionQueueSlice -SessionKey $effSk -QueueSlice $qSlice -FallbackSession $ModalSession
        } elseif ($res -and $res.changed -and $ModalSession -and ($null -ne $ModalSession.PSObject.Properties['PendingQueue'])) {
            $arr = @($ModalSession.PendingQueue)
            for ($idx = 0; $idx -lt $arr.Count; $idx++) {
                if ([string]$arr[$idx].Id -eq $MessageId) {
                    if ($Direction -eq 'up' -and $idx -gt 0) {
                        $tmp = $arr[$idx]; $arr[$idx] = $arr[$idx - 1]; $arr[$idx - 1] = $tmp
                    } elseif ($Direction -eq 'down' -and $idx -lt ($arr.Count - 1)) {
                        $tmp = $arr[$idx]; $arr[$idx] = $arr[$idx + 1]; $arr[$idx + 1] = $tmp
                    }
                    break
                }
            }
            $ModalSession.PendingQueue = $arr
            Update-SessionQueueUI -SessionKey $effSk -FallbackSession $ModalSession
        }
        $script:lastQueueActionUtc = [DateTime]::UtcNow
        Reset-ConnectionInfraCache
        Sync-QueueFastPollingState
    } catch {
        Show-QuickToast $_.Exception.Message
    }
}

function Open-SentHistoryModal($SessionObj) {
    if (-not $SessionObj -or -not $script:controls.SentHistoryOverlay) { return }
    $sessKey = [string]$SessionObj.SessionKey
    $wasAlreadyVisible = ($script:controls.SentHistoryOverlay.Visibility -eq 'Visible' -and $script:openQueueModalSessionKey -eq $sessKey)
    $script:openQueueModalSessionKey = $sessKey
    $rawMsgs = @(if (($null -ne $SessionObj.PSObject.Properties['SentWebMessages']) -and $SessionObj.SentWebMessages) { $SessionObj.SentWebMessages })
    $hasPendingProp = ($null -ne $SessionObj.PSObject.Properties['PendingQueue'])
    $pendingItems = @(if ($hasPendingProp) {
        if ($SessionObj.PendingQueue) {
            $SessionObj.PendingQueue | Where-Object { $_ -and $_.Status -eq 'pending' }
        }
    } else {
        $rawMsgs | Where-Object { $_ -and $_.Status -eq 'pending' }
    })
    $historyItems = @($rawMsgs | Where-Object { $_.Status -notin @('pending', 'superseded', 'cancelled') })
    $titleStr = if ($SessionObj.ShortTitle) { $SessionObj.ShortTitle } else { $SessionObj.Title }
    $script:controls.SentHistoryTitle.Text = if ($pendingItems.Count -gt 0) {
        "📜 发送与待发队列 (待发 $($pendingItems.Count) · 历史 $($historyItems.Count)) · $titleStr"
    } else {
        "📜 发送与待发队列 ($($historyItems.Count)) · $titleStr"
    }
    $script:controls.SentHistoryListPanel.Children.Clear()
    if ($pendingItems.Count -eq 0 -and $historyItems.Count -eq 0) {
        $emptyTxt = New-Object Windows.Controls.TextBlock
        $emptyTxt.Text = '当前任务暂无待发队列与历史发送记录。'
        $emptyTxt.FontSize = 12.5
        $emptyTxt.Foreground = ConvertTo-Brush '#71717A'
        $emptyTxt.Margin = [Windows.Thickness]::new(8, 12, 8, 12)
        [void]$script:controls.SentHistoryListPanel.Children.Add($emptyTxt)
    } else {
        for ($pi = 0; $pi -lt $pendingItems.Count; $pi++) {
            $pm = $pendingItems[$pi]
            $pCard = New-Object Windows.Controls.Border
            $pCard.Background = ConvertTo-Brush '#FFFBEB'
            $pCard.BorderBrush = ConvertTo-Brush '#FDE68A'
            $pCard.BorderThickness = [Windows.Thickness]::new(1)
            $pCard.CornerRadius = [Windows.CornerRadius]::new(8)
            $pCard.Padding = [Windows.Thickness]::new(12, 9, 12, 9)
            $pCard.Margin = [Windows.Thickness]::new(0, 0, 0, 8)

            $pStack = New-Object Windows.Controls.StackPanel
            $pHead = New-Object Windows.Controls.Grid
            $pc0 = New-Object Windows.Controls.ColumnDefinition; $pc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $pc1 = New-Object Windows.Controls.ColumnDefinition; $pc1.Width = [Windows.GridLength]::Auto
            $pc2 = New-Object Windows.Controls.ColumnDefinition; $pc2.Width = [Windows.GridLength]::Auto
            [void]$pHead.ColumnDefinitions.Add($pc0); [void]$pHead.ColumnDefinitions.Add($pc1); [void]$pHead.ColumnDefinitions.Add($pc2)
            $pHead.Margin = [Windows.Thickness]::new(0, 0, 0, 4)

            $pSub = if ($pm.PSObject.Properties['DeferUntilStopped'] -and $pm.DeferUntilStopped) { '等原网页停稳后自动换新窗接力' } else { '等当前回合停稳后自动发送' }
            $pLeft = New-Object Windows.Controls.TextBlock
            $pLeft.Text = "【待发 #$($pi + 1)】⏳ $pSub"
            $pLeft.FontSize = 11.5
            $pLeft.FontWeight = 'SemiBold'
            $pLeft.Foreground = ConvertTo-Brush '#B45309'
            $pLeft.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($pLeft, 0)
            [void]$pHead.Children.Add($pLeft)

            $pTime = New-Object Windows.Controls.TextBlock
            $pTime.Text = [string]$pm.TimeText
            $pTime.FontSize = 11
            $pTime.Foreground = ConvertTo-Brush '#92400E'
            $pTime.Margin = [Windows.Thickness]::new(8, 0, 8, 0)
            $pTime.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($pTime, 1)
            [void]$pHead.Children.Add($pTime)

            $pBtns = New-Object Windows.Controls.StackPanel
            $pBtns.Orientation = 'Horizontal'
            $pBtns.VerticalAlignment = 'Center'

            $msgIdVal = if ($pm.PSObject.Properties['Id']) { [string]$pm.Id } else { '' }
            $upBtn = New-Object Windows.Controls.Button
            $upBtn.Content = '↑ 上移'
            $upBtn.Style = $script:window.Resources['LinkButton']
            $upBtn.FontSize = 11
            $upBtn.IsEnabled = ($pi -gt 0 -and [bool]$msgIdVal)
            $upBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
            $upBtn.Tag = [pscustomobject]@{ SessionKey = [string]$SessionObj.SessionKey; MsgId = $msgIdVal; Session = $SessionObj }
            $upBtn.Add_Click({
                param($sender, $e)
                if ($sender.Tag) { Invoke-MoveQueuedWebMessage $sender.Tag.SessionKey $sender.Tag.MsgId 'up' $sender.Tag.Session }
            })
            [void]$pBtns.Children.Add($upBtn)

            $dnBtn = New-Object Windows.Controls.Button
            $dnBtn.Content = '↓ 下移'
            $dnBtn.Style = $script:window.Resources['LinkButton']
            $dnBtn.FontSize = 11
            $dnBtn.IsEnabled = ($pi -lt ($pendingItems.Count - 1) -and [bool]$msgIdVal)
            $dnBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
            $dnBtn.Tag = [pscustomobject]@{ SessionKey = [string]$SessionObj.SessionKey; MsgId = $msgIdVal; Session = $SessionObj }
            $dnBtn.Add_Click({
                param($sender, $e)
                if ($sender.Tag) { Invoke-MoveQueuedWebMessage $sender.Tag.SessionKey $sender.Tag.MsgId 'down' $sender.Tag.Session }
            })
            [void]$pBtns.Children.Add($dnBtn)

            $rmBtn = New-Object Windows.Controls.Button
            $rmBtn.Content = '× 删除'
            $rmBtn.Style = $script:window.Resources['LinkButton']
            $rmBtn.FontSize = 11
            $rmBtn.Foreground = ConvertTo-Brush '#DC2626'
            $rmBtn.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
            $rmBtn.Tag = [pscustomobject]@{ SessionKey = [string]$SessionObj.SessionKey; MsgId = $msgIdVal; Session = $SessionObj }
            $rmBtn.Add_Click({
                param($sender, $e)
                if ($sender.Tag) { Invoke-CancelQueuedWebMessage $sender.Tag.SessionKey $sender.Tag.MsgId $sender.Tag.Session }
            })
            [void]$pBtns.Children.Add($rmBtn)

            $pCopyBtn = New-Object Windows.Controls.Button
            $pCopyBtn.Content = '复制全文'
            $pCopyBtn.Style = $script:window.Resources['LinkButton']
            $pCopyBtn.FontSize = 11
            $pCopyBtn.Tag = $(if ($pm.PSObject.Properties['Prompt'] -and $pm.Prompt) { [string]$pm.Prompt } else { [string]$pm.Text })
            $pCopyBtn.Add_Click({
                param($sender, $e)
                if ($sender.Tag) {
                    try { [Windows.Clipboard]::SetText([string]$sender.Tag) } catch { }
                    Show-QuickToast '✓ 已复制该条待发指令全文到剪贴板'
                }
            })
            [void]$pBtns.Children.Add($pCopyBtn)

            [Windows.Controls.Grid]::SetColumn($pBtns, 2)
            [void]$pHead.Children.Add($pBtns)
            [void]$pStack.Children.Add($pHead)

            $pBody = New-Object Windows.Controls.TextBlock
            $pBody.Text = "「$($pm.Text)」"
            $pBody.FontSize = 12.5
            $pBody.Foreground = ConvertTo-Brush '#18181B'
            $pBody.TextWrapping = 'Wrap'
            [void]$pStack.Children.Add($pBody)

            $pCard.Child = $pStack
            [void]$script:controls.SentHistoryListPanel.Children.Add($pCard)
        }

        for ($i = 0; $i -lt $historyItems.Count; $i++) {
            $m = $historyItems[$i]
            $card = New-Object Windows.Controls.Border
            $card.Background = ConvertTo-Brush $(if ($i -eq 0 -and $pendingItems.Count -eq 0) { '#EFF6FF' } else { '#FAFAFA' })
            $card.BorderBrush = ConvertTo-Brush $(if ($i -eq 0 -and $pendingItems.Count -eq 0) { '#BFDBFE' } else { '#E4E4E7' })
            $card.BorderThickness = [Windows.Thickness]::new(1)
            $card.CornerRadius = [Windows.CornerRadius]::new(8)
            $card.Padding = [Windows.Thickness]::new(12, 9, 12, 9)
            $card.Margin = [Windows.Thickness]::new(0, 0, 0, 8)

            $cStack = New-Object Windows.Controls.StackPanel
            $headG = New-Object Windows.Controls.Grid
            $hc0 = New-Object Windows.Controls.ColumnDefinition; $hc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $hc1 = New-Object Windows.Controls.ColumnDefinition; $hc1.Width = [Windows.GridLength]::Auto
            $hc2 = New-Object Windows.Controls.ColumnDefinition; $hc2.Width = [Windows.GridLength]::Auto
            [void]$headG.ColumnDefinitions.Add($hc0); [void]$headG.ColumnDefinitions.Add($hc1); [void]$headG.ColumnDefinitions.Add($hc2)
            $headG.Margin = [Windows.Thickness]::new(0, 0, 0, 4)

            $tagStr = if ($i -eq 0) { '【最新发送】' } else { "第 $($historyItems.Count - $i) 条 · " }
            $statusStr = switch ([string]$m.Status) {
                'delivered'   { '✓ 已送达网页端' }
                'claimed'     { '⏳ 网页已就绪，正在填入并提交指令' }
                'unconfirmed' { '⚠ 未确认网页接收，请检查会话' }
                default       { '⏳ 待发队列中' }
            }
            $hLeft = New-Object Windows.Controls.TextBlock
            $hLeft.Text = "$tagStr$statusStr"
            $hLeft.FontSize = 11.5
            $hLeft.FontWeight = 'SemiBold'
            $hLeft.Foreground = ConvertTo-Brush $(if ($m.Status -eq 'unconfirmed') { '#D97706' } elseif ($i -eq 0) { '#2563EB' } else { '#52525B' })
            [Windows.Controls.Grid]::SetColumn($hLeft, 0)
            [void]$headG.Children.Add($hLeft)

            $hTime = New-Object Windows.Controls.TextBlock
            $hTime.Text = [string]$m.TimeText
            $hTime.FontSize = 11
            $hTime.Foreground = ConvertTo-Brush '#71717A'
            $hTime.Margin = [Windows.Thickness]::new(8, 0, 8, 0)
            $hTime.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($hTime, 1)
            [void]$headG.Children.Add($hTime)

            $copyBtn = New-Object Windows.Controls.Button
            $copyBtn.Content = '复制全文'
            $copyBtn.Style = $script:window.Resources['LinkButton']
            $copyBtn.FontSize = 11
            $copyBtn.Tag = $(if ($m.PSObject.Properties['Prompt'] -and $m.Prompt) { [string]$m.Prompt } else { [string]$m.Text })
            $copyBtn.Add_Click({
                param($sender, $e)
                if ($sender.Tag) {
                    try { [Windows.Clipboard]::SetText([string]$sender.Tag) } catch { }
                    Show-QuickToast '✓ 已复制该条历史指令全文到剪贴板'
                }
            })
            [Windows.Controls.Grid]::SetColumn($copyBtn, 2)
            [void]$headG.Children.Add($copyBtn)
            [void]$cStack.Children.Add($headG)

            $bodyTxt = New-Object Windows.Controls.TextBlock
            $bodyTxt.Text = "「$($m.Text)」"
            $bodyTxt.FontSize = 12.5
            $bodyTxt.Foreground = ConvertTo-Brush '#18181B'
            $bodyTxt.TextWrapping = 'Wrap'
            [void]$cStack.Children.Add($bodyTxt)

            $card.Child = $cStack
            [void]$script:controls.SentHistoryListPanel.Children.Add($card)
        }
    }
    $script:controls.SentHistoryOverlay.Visibility = 'Visible'
    if ((-not $wasAlreadyVisible) -and $script:controls.SentHistoryOverlay.Child) {
        Start-SmoothEnterAnimation $script:controls.SentHistoryOverlay.Child -FromY 8 -DurationMs 170
    }
    Sync-QueueFastPollingState
}

function Close-SentHistoryModal {
    $script:openQueueModalSessionKey = ''
    if ($script:controls.SentHistoryOverlay) {
        $script:controls.SentHistoryOverlay.Visibility = 'Collapsed'
    }
    Sync-QueueFastPollingState
}

function Confirm-LiveNewWindowHandover($SessionObj) {
    $ovVar = Get-Variable -Name 'LiveHandoverPromptOverride' -Scope Script -ErrorAction SilentlyContinue
    if ($ovVar -and $ovVar.Value -is [scriptblock]) {
        return (& $ovVar.Value $SessionObj)
    }
    $noShowVar = Get-Variable -Name 'NoShow' -ErrorAction SilentlyContinue
    if ($noShowVar -and [bool]$noShowVar.Value) {
        return 'defer'
    }
    $script:liveHandoverChoice = 'cancel'
    $dlg = New-Object Windows.Window
    if ($script:window -and $script:window.FontFamily) { $dlg.FontFamily = $script:window.FontFamily }
    $dlg.Title = '原网页仍在运行中 · 选择新窗口交接方式'
    $dlg.Width = 470
    $dlg.SizeToContent = 'Height'
    $dlg.WindowStartupLocation = if ($script:window -and $script:window.IsVisible) { 'CenterOwner' } else { 'CenterScreen' }
    if ($script:window -and $script:window.IsVisible) { $dlg.Owner = $script:window }
    $dlg.ResizeMode = 'NoResize'
    $dlg.Background = ConvertTo-Brush '#FFFFFF'

    $root = New-Object Windows.Controls.StackPanel
    $root.Margin = [Windows.Thickness]::new(22, 18, 22, 18)

    $hTxt = New-Object Windows.Controls.TextBlock
    $hTxt.Text = '检测到原 ChatGPT 网页当前仍在运行中'
    $hTxt.FontSize = 15
    $hTxt.FontWeight = 'Bold'
    $hTxt.Foreground = ConvertTo-Brush '#18181B'
    $hTxt.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
    [void]$root.Children.Add($hTxt)

    $descTxt = New-Object Windows.Controls.TextBlock
    $descTxt.Text = '直接再开新窗口会导致两个会话同时跑同一份任务并双倍消耗额度。请选择交接方式：'
    $descTxt.FontSize = 12.5
    $descTxt.Foreground = ConvertTo-Brush '#52525B'
    $descTxt.TextWrapping = 'Wrap'
    $descTxt.Margin = [Windows.Thickness]::new(0, 0, 0, 14)
    [void]$root.Children.Add($descTxt)

    $btnDefer = New-Object Windows.Controls.Button
    $btnDefer.Content = '⏳ 等原网页本轮停稳后自动换新窗接力（推荐）'
    $btnDefer.Padding = [Windows.Thickness]::new(14, 9, 14, 9)
    $btnDefer.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
    $btnDefer.FontSize = 12.5
    $btnDefer.FontWeight = 'SemiBold'
    $btnDefer.Background = ConvertTo-Brush '#2563EB'
    $btnDefer.BorderBrush = ConvertTo-Brush '#1D4ED8'
    $btnDefer.Foreground = ConvertTo-Brush '#FEFEFF'
    $btnDefer.IsDefault = $true
    $btnDefer.Add_Click({
        $script:liveHandoverChoice = 'defer'
        $dlg.Close()
    })
    [void]$root.Children.Add($btnDefer)

    $btnStop = New-Object Windows.Controls.Button
    $btnStop.Content = '⏹ 立即停止原网页并换新窗'
    $btnStop.Padding = [Windows.Thickness]::new(14, 8, 14, 8)
    $btnStop.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
    $btnStop.FontSize = 12.5
    $btnStop.FontWeight = 'SemiBold'
    $btnStop.Background = ConvertTo-Brush '#FEF2F2'
    $btnStop.BorderBrush = ConvertTo-Brush '#FECACA'
    $btnStop.Foreground = ConvertTo-Brush '#DC2626'
    $btnStop.Add_Click({
        $script:liveHandoverChoice = 'stop_and_retire'
        $dlg.Close()
    })
    [void]$root.Children.Add($btnStop)

    $btnCancel = New-Object Windows.Controls.Button
    $btnCancel.Content = '取消（保留当前输入草稿）'
    $btnCancel.Padding = [Windows.Thickness]::new(12, 6, 12, 6)
    $btnCancel.FontSize = 12
    $btnCancel.Background = ConvertTo-Brush '#FAFAFA'
    $btnCancel.BorderBrush = ConvertTo-Brush '#E4E4E7'
    $btnCancel.Foreground = ConvertTo-Brush '#52525B'
    $btnCancel.IsCancel = $true
    $btnCancel.Add_Click({
        $script:liveHandoverChoice = 'cancel'
        $dlg.Close()
    })
    [void]$root.Children.Add($btnCancel)

    $dlg.Content = $root
    [void]$dlg.ShowDialog()
    return $script:liveHandoverChoice
}

function Invoke-SendWebBridgeMessage($SessionObj, [string]$Mode = 'follow_window', [string]$CustomText = '', [int]$PaneId = 0, [string]$BrowserProfile = '', [string]$TargetModel = '', [string]$ReasoningEffort = '', [string]$Provider = '') {
    try {
        $effectiveMode = if (-not $SessionObj) { 'new_window_handover' } else { $Mode }
        $hasPendingHandoverPioneer = $false
        if ($SessionObj -and $SessionObj.PSObject.Properties['PendingQueue'] -and $SessionObj.PendingQueue) {
            foreach ($pq in @($SessionObj.PendingQueue)) {
                if ($pq -and [string]$pq.Mode -eq 'new_window_handover') {
                    $hasPendingHandoverPioneer = $true
                    break
                }
            }
        }
        $deferUntilStopped = $false
        $stopAndRetire = $false
        $needHandoverDialog = (-not $hasPendingHandoverPioneer) -or ($null -ne $script:LiveHandoverPromptOverride)
        if ($SessionObj -and $effectiveMode -eq 'new_window_handover' -and $needHandoverDialog -and $SessionObj.PSObject.Properties['VitalState'] -and [string]$SessionObj.VitalState -eq 'LIVE') {
            $choice = Confirm-LiveNewWindowHandover $SessionObj
            if ($choice -eq 'cancel') {
                Show-QuickToast '已取消新窗口交接（原网页继续运行，草稿已保留）'
                return $false
            } elseif ($choice -eq 'stop_and_retire') {
                $stopAndRetire = $true
            } else {
                $deferUntilStopped = $true
            }
        }
        $effProf = if ($BrowserProfile) { $BrowserProfile } elseif ($SessionObj -and $SessionObj.PSObject.Properties['BrowserProfile'] -and $SessionObj.BrowserProfile) { [string]$SessionObj.BrowserProfile } else { '' }
        $effMod  = if ($TargetModel) { $TargetModel } elseif ($SessionObj -and $SessionObj.PSObject.Properties['TargetModel'] -and $SessionObj.TargetModel) { [string]$SessionObj.TargetModel } else { '' }
        $effEff  = if ($ReasoningEffort) { $ReasoningEffort } elseif ($SessionObj -and $SessionObj.PSObject.Properties['ReasoningEffort'] -and $SessionObj.ReasoningEffort) { [string]$SessionObj.ReasoningEffort } else { '' }
        $effProv = if ($Provider) { $Provider } elseif ($SessionObj) { Get-WebRoomProvider $SessionObj } else { '' }

        # Q4: a send from a single pane replaces the old task; with several panes the old tasks stay side by side.
        $isSinglePane = (@($script:layout.Panes).Count -le 1)
        $res = Send-WebBridgeMessage -Context $script:context -Session $SessionObj -Mode $effectiveMode -CustomUserText $CustomText -BrowserProfile $effProf -TargetModel $effMod -ReasoningEffort $effEff -Provider $effProv -DeferUntilStopped:$deferUntilStopped -StopAndRetire:$stopAndRetire -OpenBrowserOnHandover:($effectiveMode -eq 'new_window_handover' -and (-not $deferUntilStopped)) -IsSinglePaneReplace $isSinglePane
        if ($res -and $res.Prompt) {
            try { [Windows.Clipboard]::SetText($res.Prompt) } catch { }
        }
        $script:lastQueueActionUtc = [DateTime]::UtcNow
        if (-not $SessionObj) {
            $script:lastCardsSig = ''
            Reset-ConnectionInfraCache
            try { Refresh-FormState } catch { }
        } else {
            $qSlice = if ($res -and $res.PSObject.Properties['QueueSlice'] -and $res.QueueSlice) {
                $res.QueueSlice
            } elseif ($res -and $res.PSObject.Properties['queue_slice'] -and $res.queue_slice) {
                $res.queue_slice
            } else { $null }
            $effSk = if ($res -and $res.PSObject.Properties['SessionKey'] -and $res.SessionKey) { [string]$res.SessionKey } else { [string]$SessionObj.SessionKey }
            if ($qSlice) {
                Apply-SessionQueueSlice -SessionKey $effSk -QueueSlice $qSlice -FallbackSession $SessionObj
            }
            Sync-QueueFastPollingState
        }
        if (-not $SessionObj) {
            if ($res -and $res.PSObject.Properties['CreatedTask'] -and $res.CreatedTask -and ([string]$res.SessionKey) -like 'tsk_*') {
                $targetPane = if ($PaneId -gt 0) { $PaneId } else { [int]@($script:layout.Panes)[0].id }
                Assign-TaskToPane $targetPane ([string]$res.SessionKey)
                Show-QuickToast "🚀 已在本机立项 $($res.SessionKey) 并下发到网页 / 桌面端（同时已复制到剪贴板）"
            } else {
                Show-QuickToast '🚀 已在选定浏览器发起新任务并加入自动填入队列（同时已复制到剪贴板）'
            }
        } elseif ($deferUntilStopped) {
            Show-QuickToast '⏳ 已加入待发队列：等原网页本轮停稳后将自动开启新窗接力'
        } elseif ($stopAndRetire) {
            Show-QuickToast '⏹ 已请求停止并归档原网页，同时开启新窗口接力'
        } elseif ($res -and $res.Mode -eq 'new_window_handover') {
            Show-QuickToast '🚀 已发起新窗口交接并复制完整交接指令到剪贴板'
        } else {
            Show-QuickToast "⚡ 已向网页端「$($SessionObj.ShortTitle)」投递消息（同时已复制到剪贴板）"
        }
        return $true
    } catch {
        Show-QuickToast $_.Exception.Message
        return $false
    }
}

function Invoke-ToggleAutoWakeup([string]$SessionKey, [bool]$Enabled) {
    if (-not $SessionKey) { return }
    Set-SessionAutoWakeup -Context $script:context -SessionKey $SessionKey -Enabled $Enabled
    Refresh-FormState
    Show-QuickToast $(if ($Enabled) { '✓ 已开启「停顿超 3 分钟自动发继续唤醒与新窗口交接」' } else { '已关闭自动续跑唤醒' })
}

function Update-CodexSummaryCardContent($Card, $PaneObj, $SessionObj) {
    if (-not $Card -or -not $SessionObj) { return }
    $steps = @(if ($SessionObj.PSObject.Properties.Name -contains 'Steps' -and $SessionObj.Steps) { $SessionObj.Steps })
    $stepSummaryTxt = if ($SessionObj.PSObject.Properties.Name -contains 'StepCountText' -and $SessionObj.StepCountText) { $SessionObj.StepCountText } else { $SessionObj.ProgressText }
    $stepsSig = (@($steps | Select-Object -Last 8 | ForEach-Object { "$($_.Id):$($_.Title):$($_.Status):$($_.UpdatedText)" }) -join '|') + "||$stepSummaryTxt||$($SessionObj.IsStalled)"
    if ($Card.Tag -and [string]$Card.Tag -eq $stepsSig -and $Card.Child) { return }
    $Card.Tag = $stepsSig

    $stack = New-Object Windows.Controls.StackPanel
    $headGrid = New-Object Windows.Controls.Grid
    $hc0 = New-Object Windows.Controls.ColumnDefinition; $hc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $hc1 = New-Object Windows.Controls.ColumnDefinition; $hc1.Width = [Windows.GridLength]::Auto
    [void]$headGrid.ColumnDefinitions.Add($hc0); [void]$headGrid.ColumnDefinitions.Add($hc1)
    $headGrid.Margin = [Windows.Thickness]::new(0, 0, 0, 8)

    $hLeft = New-Object Windows.Controls.StackPanel
    $hTitle = New-Object Windows.Controls.TextBlock
    $hTitle.Text = '步骤与进展摘要'
    $hTitle.FontSize = 12.5
    $hTitle.FontWeight = 'Bold'
    $hTitle.Foreground = ConvertTo-Brush '#18181B'
    [void]$hLeft.Children.Add($hTitle)

    $hSub = New-Object Windows.Controls.TextBlock
    $hSub.Text = "$stepSummaryTxt"
    $hSub.FontSize = 11.5
    $hSub.Foreground = ConvertTo-Brush '#71717A'
    [void]$hLeft.Children.Add($hSub)
    [Windows.Controls.Grid]::SetColumn($hLeft, 0)
    [void]$headGrid.Children.Add($hLeft)

    $closeBtn = New-QuietIconButton -Kind 'close' -TooltipText '收起摘要卡片' -BoxSize 24 -IconSize 13
    $closeBtn.Tag = [int]$PaneObj.id
    $closeBtn.Add_Click({
        param($sender, $e)
        Toggle-PaneSummary ([int]$sender.Tag)
    })
    [Windows.Controls.Grid]::SetColumn($closeBtn, 1)
    [void]$headGrid.Children.Add($closeBtn)
    [void]$stack.Children.Add($headGrid)

    $sep = New-Object Windows.Controls.Border
    $sep.Height = 1
    $sep.Background = ConvertTo-Brush '#F1F1F4'
    $sep.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
    [void]$stack.Children.Add($sep)

    if ($steps.Count -eq 0) {
        $emptyTxt = New-Object Windows.Controls.TextBlock
        $emptyTxt.Text = '当前对话直接通过 MCP 转发工具指令（未创建分步契约）。'
        $emptyTxt.FontSize = 11.5
        $emptyTxt.Foreground = ConvertTo-Brush '#71717A'
        [void]$stack.Children.Add($emptyTxt)
    } else {
        foreach ($st in ($steps | Select-Object -Last 8)) {
            $rowG = New-Object Windows.Controls.Grid
            $rc0 = New-Object Windows.Controls.ColumnDefinition; $rc0.Width = [Windows.GridLength]::Auto
            $rc1 = New-Object Windows.Controls.ColumnDefinition; $rc1.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $rc2 = New-Object Windows.Controls.ColumnDefinition; $rc2.Width = [Windows.GridLength]::Auto
            [void]$rowG.ColumnDefinitions.Add($rc0); [void]$rowG.ColumnDefinitions.Add($rc1); [void]$rowG.ColumnDefinitions.Add($rc2)
            $rowG.Margin = [Windows.Thickness]::new(0, 3, 0, 3)

            $iconTxt = New-Object Windows.Controls.TextBlock
            $iconTxt.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
            $iconTxt.FontSize = 12
            $iconTxt.FontWeight = 'Bold'
            if ($st.Status -eq 'completed') {
                $iconTxt.Text = '✓'
                $iconTxt.Foreground = ConvertTo-Brush '#16A34A'
            } elseif ($st.Status -eq 'quarantined') {
                $iconTxt.Text = '⊘'
                $iconTxt.Foreground = ConvertTo-Brush '#D97706'
            } elseif ($st.Status -eq 'in_progress') {
                $iconTxt.Text = '●'
                $iconTxt.Foreground = ConvertTo-Brush $(if ($SessionObj.IsStalled) { '#D97706' } else { '#2563EB' })
            } else {
                $iconTxt.Text = '○'
                $iconTxt.Foreground = ConvertTo-Brush '#A1A1AA'
            }
            [Windows.Controls.Grid]::SetColumn($iconTxt, 0)
            [void]$rowG.Children.Add($iconTxt)

            $stTxt = New-Object Windows.Controls.TextBlock
            $stTxt.Text = "步骤 $($st.Id)：$($st.Title)"
            $stTxt.FontSize = 12
            $stTxt.FontWeight = $(if ($st.Status -eq 'in_progress') { 'SemiBold' } else { 'Normal' })
            $stTxt.Foreground = ConvertTo-Brush $(if ($st.Status -eq 'in_progress') { '#18181B' } else { '#52525B' })
            [Windows.Controls.Grid]::SetColumn($stTxt, 1)
            [void]$rowG.Children.Add($stTxt)

            $metaTxt = New-Object Windows.Controls.TextBlock
            $metaTxt.Text = $(if ($st.UpdatedText) { $st.UpdatedText } elseif ($st.Status -eq 'completed') { '已通过' } elseif ($st.Status -eq 'quarantined') { '已隔离' } elseif ($st.Status -eq 'in_progress') { '执行中' } else { '待开始' })
            $metaTxt.FontSize = 11
            $metaTxt.Foreground = ConvertTo-Brush '#A1A1AA'
            $metaTxt.Margin = [Windows.Thickness]::new(6, 0, 0, 0)
            [Windows.Controls.Grid]::SetColumn($metaTxt, 2)
            [void]$rowG.Children.Add($metaTxt)

            [void]$stack.Children.Add($rowG)
        }
    }
    $Card.Child = $stack
}

function Build-CodexSummaryCard($PaneObj, $SessionObj) {
    $card = New-Object Windows.Controls.Border
    $card.Width = 286
    $card.HorizontalAlignment = 'Right'
    $card.VerticalAlignment = 'Top'
    $card.Margin = [Windows.Thickness]::new(0, 52, 16, 0)
    $card.Background = ConvertTo-Brush '#FFFFFF'
    $card.BorderBrush = ConvertTo-Brush '#E4E4E7'
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(12)
    $card.Padding = [Windows.Thickness]::new(15, 13, 15, 13)
    $shadow = New-Object Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 24; $shadow.ShadowDepth = 4; $shadow.Opacity = 0.08; $shadow.Color = [Windows.Media.Color]::FromRgb(24, 24, 27)
    $card.Effect = $shadow
    [Windows.Controls.Panel]::SetZIndex($card, 80)
    Update-CodexSummaryCardContent -Card $card -PaneObj $PaneObj -SessionObj $SessionObj
    if ($PaneObj -and $PaneObj.PSObject.Properties['show_summary'] -and [bool]$PaneObj.show_summary) {
        Start-SmoothEnterAnimation $card -FromY -6 -DurationMs 160
    }
    return $card
}
function Build-PaneTaskPicker($PaneObj) {
    $activeSessions = @(if ($script:display -and $script:display.Sessions) { $script:display.Sessions })
    $archSessions = @(if ($script:display -and $script:display.PSObject.Properties.Name -contains 'ArchivedSessions' -and $script:display.ArchivedSessions) { $script:display.ArchivedSessions })
    $paneIdInt = if ($PaneObj -and $PaneObj.PSObject.Properties['id']) { [int]$PaneObj.id } else { 0 }
    $showNewTaskComposer = $script:launchpadPaneIds.ContainsKey($paneIdInt) -or ($activeSessions.Count -eq 0 -and (-not $script:pickerPaneIds.ContainsKey($paneIdInt)))
    if ($showNewTaskComposer) {
        $hasArch = ($archSessions.Count -gt 0)
        $hubGrid = New-Object Windows.Controls.Grid
        $hubGrid.Background = ConvertTo-Brush '#FFFFFF'
        $hr0 = New-Object Windows.Controls.RowDefinition
        $hr0.Height = [Windows.GridLength]::new($(if ($hasArch) { 0.36 } else { 0.56 }), [Windows.GridUnitType]::Star)
        $hr1 = New-Object Windows.Controls.RowDefinition
        $hr1.Height = [Windows.GridLength]::new($(if ($hasArch) { 1.64 } else { 1.44 }), [Windows.GridUnitType]::Star)
        [void]$hubGrid.RowDefinitions.Add($hr0); [void]$hubGrid.RowDefinitions.Add($hr1)

        $hubScroll = New-Object Windows.Controls.ScrollViewer
        $hubScroll.Name = 'StreamScrollHost'
        $hubScroll.Tag = 'StreamScrollHost'
        $hubScroll.VerticalScrollBarVisibility = 'Disabled'
        $hubScroll.HorizontalScrollBarVisibility = 'Disabled'
        $hubScroll.Background = ConvertTo-Brush '#FFFFFF'
        $hubScroll.VerticalAlignment = 'Bottom'
        $hubScroll.Padding = [Windows.Thickness]::new(22, 16, 22, 10)

        $hubStack = New-Object Windows.Controls.StackPanel
        $hubStack.MaxWidth = 760
        $hubStack.HorizontalAlignment = 'Stretch'

        # Centered Hero Header: Left Title ("新建任务"), Right Readiness Pill + Host Quick-Open Button
        $heroHeaderGrid = New-Object Windows.Controls.Grid
        $hhc0 = New-Object Windows.Controls.ColumnDefinition; $hhc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $hhc1 = New-Object Windows.Controls.ColumnDefinition; $hhc1.Width = [Windows.GridLength]::Auto
        [void]$heroHeaderGrid.ColumnDefinitions.Add($hhc0); [void]$heroHeaderGrid.ColumnDefinitions.Add($hhc1)
        $heroHeaderGrid.Margin = [Windows.Thickness]::new(0, 0, 0, 2)

        $heroTitle = New-Object Windows.Controls.TextBlock
        $heroTitle.Text = '新建任务'
        $heroTitle.FontSize = 20
        $heroTitle.FontWeight = 'Bold'
        $heroTitle.Foreground = ConvertTo-Brush '#18181B'
        $heroTitle.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($heroTitle, 0)
        [void]$heroHeaderGrid.Children.Add($heroTitle)

        $heroRightStack = New-Object Windows.Controls.StackPanel
        $heroRightStack.Orientation = 'Horizontal'
        $heroRightStack.VerticalAlignment = 'Center'

        $openGptBtn = New-Object Windows.Controls.Button
        $openGptBtn.Content = '🌐 打开宿主窗口 ↗'
        $openGptBtn.Padding = [Windows.Thickness]::new(10, 4, 10, 4)
        $openGptBtn.MinHeight = 27
        $openGptBtn.FontSize = 11.5
        $openGptBtn.FontWeight = 'SemiBold'
        $openGptBtn.Background = ConvertTo-Brush '#FFFFFF'
        $openGptBtn.BorderBrush = ConvertTo-Brush '#E4E4E7'
        $openGptBtn.Foreground = ConvertTo-Brush '#18181B'
        $openGptBtn.VerticalAlignment = 'Center'
        $openGptBtn.ToolTip = '打开下方当前选定的 ChatGPT 桌面端或网页窗口'
        $openGptBtn.Tag = [int]$PaneObj.id
        $openGptBtn.Add_Click({
            param($sender, $e)
            try {
                $targetPaneId = if ($sender -and $null -ne $sender.Tag) { [int]$sender.Tag } else { 0 }
                Invoke-OpenChatGptHome -PaneId $targetPaneId
            } catch { }
        })
        [void]$heroRightStack.Children.Add($openGptBtn)

        [Windows.Controls.Grid]::SetColumn($heroRightStack, 1)
        [void]$heroHeaderGrid.Children.Add($heroRightStack)
        [void]$hubStack.Children.Add($heroHeaderGrid)

        $hubScroll.Content = $hubStack
        [Windows.Controls.Grid]::SetRow($hubScroll, 0)
        [void]$hubGrid.Children.Add($hubScroll)

        $zeroCompose = Build-PlanBComposerPod -SessionObj $null -IsNarrow (@($script:layout.Panes).Count -ge 2) -IsZeroTask $true -PaneId $paneIdInt
        if ($zeroCompose -and $zeroCompose.Tag -and $zeroCompose.Tag.PSObject.Properties['ZeroFooterHost'] -and $zeroCompose.Tag.ZeroFooterHost) {
            $footerHost = $zeroCompose.Tag.ZeroFooterHost
            $footerHost.Children.Clear()
            if ($hasArch) {
                $footerHost.Visibility = 'Visible'
                $recentHdr = New-Object Windows.Controls.TextBlock
                $recentHdr.Text = "最近归档 ($($archSessions.Count))"
                $recentHdr.FontSize = 12
                $recentHdr.FontWeight = 'SemiBold'
                $recentHdr.Foreground = ConvertTo-Brush '#71717A'
                $recentHdr.Margin = [Windows.Thickness]::new(2, 0, 0, 8)
                [void]$footerHost.Children.Add($recentHdr)

                foreach ($ar in ($archSessions | Select-Object -First 3)) {
                    $arCard = New-Object Windows.Controls.Border
                    $arCard.Background = ConvertTo-Brush '#FAFAFA'
                    $arCard.BorderBrush = ConvertTo-Brush '#E4E4E7'
                    $arCard.BorderThickness = [Windows.Thickness]::new(1)
                    $arCard.CornerRadius = [Windows.CornerRadius]::new(8)
                    $arCard.Padding = [Windows.Thickness]::new(14, 9, 14, 9)
                    $arCard.Margin = [Windows.Thickness]::new(0, 0, 0, 7)

                    $ag = New-Object Windows.Controls.Grid
                    $ac0 = New-Object Windows.Controls.ColumnDefinition; $ac0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
                    $ac1 = New-Object Windows.Controls.ColumnDefinition; $ac1.Width = [Windows.GridLength]::Auto
                    [void]$ag.ColumnDefinitions.Add($ac0); [void]$ag.ColumnDefinitions.Add($ac1)

                    $aTitle = New-Object Windows.Controls.TextBlock
                    $aTitle.Text = $(if ($ar.ShortTitle) { $ar.ShortTitle } else { $ar.Title })
                    $aTitle.FontSize = 13
                    $aTitle.FontWeight = 'SemiBold'
                    $aTitle.Foreground = ConvertTo-Brush '#18181B'
                    $aTitle.VerticalAlignment = 'Center'
                    $aTitle.TextTrimming = 'CharacterEllipsis'
                    $aTitle.TextWrapping = 'NoWrap'
                    $aTitle.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
                    [Windows.Controls.Grid]::SetColumn($aTitle, 0)
                    [void]$ag.Children.Add($aTitle)

                    $aBtnRow = New-Object Windows.Controls.StackPanel
                    $aBtnRow.Orientation = 'Horizontal'
                    $aBtnRow.VerticalAlignment = 'Center'

                    $aDetBtn = New-Object Windows.Controls.Button
                    $aDetBtn.Content = '查看详情'
                    $aDetBtn.Padding = [Windows.Thickness]::new(9, 4, 9, 4)
                    $aDetBtn.MinHeight = 26
                    $aDetBtn.FontSize = 11.5
                    $aDetBtn.FontWeight = 'SemiBold'
                    $aDetBtn.Background = ConvertTo-Brush '#FFFFFF'
                    $aDetBtn.BorderBrush = ConvertTo-Brush '#E4E4E7'
                    $aDetBtn.Foreground = ConvertTo-Brush '#52525B'
                    $aDetBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
                    $aDetBtn.Tag = $ar.SessionKey
                    $aDetBtn.Add_Click({
                        param($sender, $e)
                        if ($sender.Tag) { Open-SessionDetail ([string]$sender.Tag) }
                    })
                    [void]$aBtnRow.Children.Add($aDetBtn)

                    $aBtn = New-Object Windows.Controls.Button
                    $aBtn.Content = '↺ 还原'
                    $aBtn.Padding = [Windows.Thickness]::new(10, 4, 10, 4)
                    $aBtn.MinHeight = 26
                    $aBtn.FontSize = 11.5
                    $aBtn.FontWeight = 'SemiBold'
                    $aBtn.Background = ConvertTo-Brush '#EFF6FF'
                    $aBtn.BorderBrush = ConvertTo-Brush '#BFDBFE'
                    $aBtn.Foreground = ConvertTo-Brush '#1D4ED8'
                    $aBtn.Tag = [pscustomobject]@{ PaneId = $paneIdInt; Key = $ar.SessionKey }
                    $aBtn.Add_Click({
                        param($sender, $e)
                        $info = $sender.Tag
                        if ($info) { Invoke-RestoreSession $info.Key $info.PaneId }
                    })
                    [void]$aBtnRow.Children.Add($aBtn)

                    [Windows.Controls.Grid]::SetColumn($aBtnRow, 1)
                    [void]$ag.Children.Add($aBtnRow)

                    $arCard.Child = $ag
                    [void]$footerHost.Children.Add($arCard)
                }
            } else {
                $footerHost.Visibility = 'Collapsed'
            }
        }
        [Windows.Controls.Grid]::SetRow($zeroCompose, 1)
        [void]$hubGrid.Children.Add($zeroCompose)
        return $hubGrid
    }

    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Background = ConvertTo-Brush '#FCFCFD'
    $scroll.Padding = [Windows.Thickness]::new(24, 22, 24, 24)

    $stack = New-Object Windows.Controls.StackPanel

    $newTaskBtn = New-Object Windows.Controls.Button
    $newTaskBtn.Content = '🚀 新建任务'
    $newTaskBtn.Padding = [Windows.Thickness]::new(14, 8, 14, 8)
    $newTaskBtn.FontSize = 12.5
    $newTaskBtn.FontWeight = 'SemiBold'
    $newTaskBtn.Background = ConvertTo-Brush '#2563EB'
    $newTaskBtn.BorderBrush = ConvertTo-Brush '#1D4ED8'
    $newTaskBtn.Foreground = ConvertTo-Brush '#FEFEFF'
    $newTaskBtn.HorizontalAlignment = 'Left'
    $newTaskBtn.Margin = [Windows.Thickness]::new(0, 0, 0, 18)
    $newTaskBtn.ToolTip = '打开新建任务面板：输入首句需求即在本机立项并下发到网页 / 桌面端'
    $newTaskBtn.Tag = $paneIdInt
    $newTaskBtn.Add_Click({
        param($sender, $e)
        Enter-NewTaskLaunchpad ([int]$sender.Tag)
    })
    [void]$stack.Children.Add($newTaskBtn)

    $activeTitle = New-Object Windows.Controls.TextBlock
    $activeTitle.Text = "进行中任务 ($($activeSessions.Count))"
    $activeTitle.FontSize = 12.5
    $activeTitle.FontWeight = 'SemiBold'
    $activeTitle.Foreground = ConvertTo-Brush '#52525B'
    $activeTitle.Margin = [Windows.Thickness]::new(0, 0, 0, 10)
    [void]$stack.Children.Add($activeTitle)

    if ($activeSessions.Count -eq 0) {
        $noAct = New-Object Windows.Controls.TextBlock
        $noAct.Text = '暂无进行中任务'
        $noAct.FontSize = 12
        $noAct.Foreground = ConvertTo-Brush '#A1A1AA'
        $noAct.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
        [void]$stack.Children.Add($noAct)
    } else {
        $wrapActive = New-Object Windows.Controls.WrapPanel
        $wrapActive.Margin = [Windows.Thickness]::new(0, 0, 0, 14)
        foreach ($act in $activeSessions) {
            $cardBtn = New-Object Windows.Controls.Button
            $cardBtn.Width = 225
            $cardBtn.Margin = [Windows.Thickness]::new(0, 0, 10, 10)
            $cardBtn.Padding = [Windows.Thickness]::new(12, 10, 12, 10)
            $cardBtn.HorizontalContentAlignment = 'Left'
            $cardBtn.Background = ConvertTo-Brush '#FFFFFF'
            $cardBtn.BorderBrush = ConvertTo-Brush '#E4E4E7'
            $cardBtn.Tag = [pscustomobject]@{ PaneId = $paneIdInt; Key = $act.SessionKey }
            $cardBtn.Add_Click({
                param($sender, $e)
                $info = $sender.Tag
                if ($info) { Assign-TaskToPane $info.PaneId $info.Key }
            })
            $cStack = New-Object Windows.Controls.StackPanel
            $topRow = New-Object Windows.Controls.StackPanel
            $topRow.Orientation = 'Horizontal'
            $dot = New-Object Windows.Shapes.Ellipse
            $dot.Width = 7; $dot.Height = 7
            $dot.Fill = ConvertTo-Brush $act.DotColor
            $dot.Margin = [Windows.Thickness]::new(0, 0, 7, 0)
            $dot.VerticalAlignment = 'Center'
            [void]$topRow.Children.Add($dot)
            $tTxt = New-Object Windows.Controls.TextBlock
            $tTxt.Text = $(if ($act.ShortTitle) { $act.ShortTitle } else { $act.Title })
            $tTxt.FontSize = 13
            $tTxt.FontWeight = 'SemiBold'
            $tTxt.Foreground = ConvertTo-Brush '#18181B'
            $tTxt.MaxWidth = 182
            $tTxt.TextTrimming = 'CharacterEllipsis'
            $tTxt.TextWrapping = 'NoWrap'
            [void]$topRow.Children.Add($tTxt)
            [void]$cStack.Children.Add($topRow)

            if ($act.StepCountText) {
                $subTxt = New-Object Windows.Controls.TextBlock
                $subTxt.Text = [string]$act.StepCountText
                $subTxt.FontSize = 11.5
                $subTxt.Foreground = ConvertTo-Brush '#71717A'
                $subTxt.Margin = [Windows.Thickness]::new(14, 4, 0, 0)
                $subTxt.TextTrimming = 'CharacterEllipsis'
                $subTxt.TextWrapping = 'NoWrap'
                [void]$cStack.Children.Add($subTxt)
            }

            $cardBtn.Content = $cStack
            [void]$wrapActive.Children.Add($cardBtn)
        }
        [void]$stack.Children.Add($wrapActive)
    }

    if ($archSessions.Count -gt 0) {
        $archTitle = New-Object Windows.Controls.TextBlock
        $archTitle.Text = "已归档任务 ($($archSessions.Count))"
        $archTitle.FontSize = 12.5
        $archTitle.FontWeight = 'SemiBold'
        $archTitle.Foreground = ConvertTo-Brush '#52525B'
        $archTitle.Margin = [Windows.Thickness]::new(0, 2, 0, 10)
        [void]$stack.Children.Add($archTitle)

        $wrapArch = New-Object Windows.Controls.WrapPanel
        foreach ($ar in $archSessions) {
            $aBtn = New-Object Windows.Controls.Button
            $aBtn.Width = 225
            $aBtn.Margin = [Windows.Thickness]::new(0, 0, 10, 10)
            $aBtn.Padding = [Windows.Thickness]::new(12, 10, 12, 10)
            $aBtn.HorizontalContentAlignment = 'Left'
            $aBtn.Background = ConvertTo-Brush '#FFFFFF'
            $aBtn.BorderBrush = ConvertTo-Brush '#E4E4E7'
            $aBtn.Tag = [pscustomobject]@{ PaneId = $paneIdInt; Key = $ar.SessionKey }
            $aBtn.Add_Click({
                param($sender, $e)
                $info = $sender.Tag
                if ($info) { Invoke-RestoreSession $info.Key $info.PaneId }
            })
            $aStack = New-Object Windows.Controls.StackPanel
            $aTop = New-Object Windows.Controls.StackPanel
            $aTop.Orientation = 'Horizontal'
            $aDot = New-Object Windows.Shapes.Ellipse
            $aDot.Width = 7; $aDot.Height = 7
            $aDot.Fill = ConvertTo-Brush '#A1A1AA'
            $aDot.Margin = [Windows.Thickness]::new(0, 0, 7, 0)
            $aDot.VerticalAlignment = 'Center'
            [void]$aTop.Children.Add($aDot)
            $aTxt = New-Object Windows.Controls.TextBlock
            $aTxt.Text = $(if ($ar.ShortTitle) { $ar.ShortTitle } else { $ar.Title })
            $aTxt.FontSize = 12.5
            $aTxt.FontWeight = 'SemiBold'
            $aTxt.Foreground = ConvertTo-Brush '#52525B'
            $aTxt.MaxWidth = 182
            $aTxt.TextTrimming = 'CharacterEllipsis'
            $aTxt.TextWrapping = 'NoWrap'
            [void]$aTop.Children.Add($aTxt)
            [void]$aStack.Children.Add($aTop)

            if ($ar.StepCountText) {
                $aSub = New-Object Windows.Controls.TextBlock
                $aSub.Text = [string]$ar.StepCountText
                $aSub.FontSize = 11
                $aSub.Foreground = ConvertTo-Brush '#A1A1AA'
                $aSub.Margin = [Windows.Thickness]::new(14, 4, 0, 0)
                $aSub.TextTrimming = 'CharacterEllipsis'
                $aSub.TextWrapping = 'NoWrap'
                [void]$aStack.Children.Add($aSub)
            }

            $aBtn.Content = $aStack
            [void]$wrapArch.Children.Add($aBtn)
        }
        [void]$stack.Children.Add($wrapArch)
    }

    $scroll.Content = $stack
    return $scroll
}

function New-MilestoneBlockElement($ms) {
    $mBlock = New-Object Windows.Controls.StackPanel
    $mBlock.Margin = [Windows.Thickness]::new(0, 0, 0, 18)

    $mHead = New-Object Windows.Controls.Grid
    $mc0 = New-Object Windows.Controls.ColumnDefinition; $mc0.Width = [Windows.GridLength]::Auto
    $mc1 = New-Object Windows.Controls.ColumnDefinition; $mc1.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $mc2 = New-Object Windows.Controls.ColumnDefinition; $mc2.Width = [Windows.GridLength]::Auto
    $mc3 = New-Object Windows.Controls.ColumnDefinition; $mc3.Width = [Windows.GridLength]::Auto
    [void]$mHead.ColumnDefinitions.Add($mc0); [void]$mHead.ColumnDefinitions.Add($mc1); [void]$mHead.ColumnDefinitions.Add($mc2); [void]$mHead.ColumnDefinitions.Add($mc3)
    $mHead.Margin = [Windows.Thickness]::new(0, 0, 0, 5)

    $mDot = New-Object Windows.Shapes.Ellipse
    $mDot.Width = 8; $mDot.Height = 8
    $mDot.Fill = ConvertTo-Brush $(if ($ms.IsSuccess) { '#16A34A' } else { '#D97706' })
    $mDot.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
    $mDot.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($mDot, 0)
    [void]$mHead.Children.Add($mDot)

    $mTitle = New-Object Windows.Controls.TextBlock
    $mTitle.Text = $ms.Title
    $mTitle.FontSize = 14
    $mTitle.FontWeight = 'Bold'
    $mTitle.Foreground = ConvertTo-Brush '#18181B'
    $mTitle.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($mTitle, 1)
    [void]$mHead.Children.Add($mTitle)

    if ($ms.TimeText) {
        $mTime = New-Object Windows.Controls.TextBlock
        $mTime.Text = $ms.TimeText
        $mTime.FontSize = 11.5
        $mTime.Foreground = ConvertTo-Brush '#A1A1AA'
        $mTime.Margin = [Windows.Thickness]::new(8, 0, 8, 0)
        $mTime.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($mTime, 2)
        [void]$mHead.Children.Add($mTime)
    }

    $rawBox = New-Object Windows.Controls.Border
    $rawBox.Background = ConvertTo-Brush '#FAFAFA'
    $rawBox.BorderBrush = ConvertTo-Brush '#E4E4E7'
    $rawBox.BorderThickness = [Windows.Thickness]::new(1)
    $rawBox.CornerRadius = [Windows.CornerRadius]::new(6)
    $rawBox.Padding = [Windows.Thickness]::new(10, 8, 10, 8)
    $rawBox.Margin = [Windows.Thickness]::new(16, 6, 0, 0)
    $rawBox.Visibility = 'Collapsed'
    $rawTxt = New-Object Windows.Controls.TextBlock
    $rawTxt.Text = $ms.RawText
    $rawTxt.FontFamily = New-Object Windows.Media.FontFamily('Consolas, Cascadia Mono, Source Han Serif SC VF, Noto Serif SC')
    $rawTxt.FontSize = 11.5
    $rawTxt.Foreground = ConvertTo-Brush '#52525B'
    $rawBox.Child = $rawTxt

    if ($ms.RawText) {
        $rawBtn = New-Object Windows.Controls.Button
        $rawBtn.Content = '原文'
        $rawBtn.Style = $script:window.Resources['LinkButton']
        $rawBtn.FontSize = 11.5
        $rawBtn.Foreground = ConvertTo-Brush '#A1A1AA'
        $rawBtn.Tag = $rawBox
        $rawBtn.Add_Click({
            param($sender, $e)
            $box = $sender.Tag
            if ($box) {
                $box.Visibility = if ($box.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
            }
        })
        [Windows.Controls.Grid]::SetColumn($rawBtn, 3)
        [void]$mHead.Children.Add($rawBtn)
    }

    [void]$mBlock.Children.Add($mHead)

    $mProse = New-Object Windows.Controls.TextBlock
    $mProse.Text = $ms.Prose
    $mProse.FontSize = 13.5
    $mProse.Foreground = ConvertTo-Brush '#3F3F46'
    $mProse.LineHeight = 22
    $mProse.MaxWidth = 680
    $mProse.Margin = [Windows.Thickness]::new(16, 0, 0, 0)
    $mProse.HorizontalAlignment = 'Left'
    [void]$mBlock.Children.Add($mProse)
    [void]$mBlock.Children.Add($rawBox)

    if ($ms.PSObject.Properties.Name -contains 'TraceText' -and $ms.TraceText) {
        $trLine = New-Object Windows.Controls.TextBlock
        $trLine.Text = $ms.TraceText
        $trLine.FontSize = 12.5
        $trLine.Foreground = ConvertTo-Brush '#71717A'
        $trLine.Margin = [Windows.Thickness]::new(16, 5, 0, 0)
        [void]$mBlock.Children.Add($trLine)
    }
    return $mBlock
}

function Get-VitalSubstateVisual($SessionObj) {
    # Spec v4.7 §3.4: locally derive the fine-grained StatusBadge / colors from the hub's VitalSubstate.
    # LIVE / CONFIRMED_STOPPED / missing field return $null so callers keep their legacy rendering.
    if (-not $SessionObj -or -not $SessionObj.PSObject.Properties['VitalSubstate']) { return $null }
    $sub = ([string]$SessionObj.VitalSubstate).Trim().ToUpperInvariant()
    switch ($sub) {
        'PSEUDO_STOPPED' {
            return [pscustomobject]@{ Substate = $sub; Badge = '假停保护中'; Bg = '#EFF6FF'; Border = '#BFDBFE'; Dot = '#2563EB'; Fg = '#1D4ED8'; PillText = '网页断流 · 本机工具活跃保护中' }
        }
        'WAITING_CONFIRM' {
            $cd = if ($SessionObj.PSObject.Properties['SilenceCountdownSec'] -and $null -ne $SessionObj.SilenceCountdownSec -and "$($SessionObj.SilenceCountdownSec)" -match '^\d+(\.\d+)?$') { [int][Math]::Ceiling([double]$SessionObj.SilenceCountdownSec) } else { -1 }
            $cdText = if ($cd -gt 0) { "约 $cd 秒后自动催工" } else { '等待静默确认后自动催工' }
            return [pscustomobject]@{ Substate = $sub; Badge = '疑似中断'; Bg = '#FFFBEB'; Border = '#FDE68A'; Dot = '#D97706'; Fg = '#B45309'; PillText = "疑似中断 · $cdText" }
        }
        'NETWORK_HOLD' {
            return [pscustomobject]@{ Substate = $sub; Badge = '断网保号中'; Bg = '#FFF7ED'; Border = '#FED7AA'; Dot = '#EA580C'; Fg = '#C2410C'; PillText = '代理/网络断连保号 · 等待恢复中' }
        }
        'DUAL_STREAM' {
            return [pscustomobject]@{ Substate = $sub; Badge = '双流告警'; Bg = '#F5F3FF'; Border = '#DDD6FE'; Dot = '#7C3AED'; Fg = '#6D28D9'; PillText = '双流并发告警 · 已暂停自动派单' }
        }
    }
    return $null
}

function Build-PaneStreamContent($PaneObj, $SessionObj, [bool]$IsNarrow = $false) {
    $hostContainer = New-Object Windows.Controls.Grid
    $rStream = New-Object Windows.Controls.RowDefinition; $rStream.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $rCompose = New-Object Windows.Controls.RowDefinition; $rCompose.Height = [Windows.GridLength]::Auto
    [void]$hostContainer.RowDefinitions.Add($rStream)
    [void]$hostContainer.RowDefinitions.Add($rCompose)

    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Background = ConvertTo-Brush '#FFFFFF'
    $scroll.Padding = if ($IsNarrow) { [Windows.Thickness]::new(18, 16, 18, 22) } else { [Windows.Thickness]::new(28, 20, 28, 28) }

    $stack = New-Object Windows.Controls.StackPanel
    $effAutoWakeup = if ($SessionObj.PSObject.Properties['AutoResendEnabled'] -and $null -ne $SessionObj.AutoResendEnabled) { [bool]$SessionObj.AutoResendEnabled }
                     elseif ($SessionObj.PSObject.Properties['AutoWakeupEnabled'] -and $null -ne $SessionObj.AutoWakeupEnabled) { [bool]$SessionObj.AutoWakeupEnabled }
                     else { $false }
    $taskStallMins = if ($SessionObj.PSObject.Properties['StallMinutes'] -and [double]$SessionObj.StallMinutes -gt 0) { [double]$SessionObj.StallMinutes } else { 3 }
    $taskStallSecs = if ($SessionObj.PSObject.Properties['StallSeconds'] -and [int]$SessionObj.StallSeconds -gt 0 -and [int]$SessionObj.StallSeconds -lt 60) {
        [int]$SessionObj.StallSeconds
    } elseif ($SessionObj.PSObject.Properties['StallMinutes'] -and [double]$SessionObj.StallMinutes -gt 0) {
        [int][Math]::Round([double]$SessionObj.StallMinutes * 60)
    } elseif ($SessionObj.PSObject.Properties['StallSeconds'] -and [int]$SessionObj.StallSeconds -gt 0) {
        [int]$SessionObj.StallSeconds
    } else {
        [int][Math]::Round($taskStallMins * 60)
    }
    $stallDisplayUnit = if ($taskStallSecs -lt 60) { "$taskStallSecs 秒" } else { "$([int][Math]::Max(1, [Math]::Round($taskStallSecs / 60.0))) 分钟" }
    $stallTriggerUnit = if ($taskStallSecs -lt 60) { ">${taskStallSecs}秒静默触发" } else { ">$([int][Math]::Max(1, [Math]::Round($taskStallSecs / 60.0)))分钟静默触发" }
    $taskMaxRetries = if ($SessionObj.PSObject.Properties['MaxRetries'] -and [int]$SessionObj.MaxRetries -gt 0) { [int]$SessionObj.MaxRetries } else { 1 }

    # Title Row (Grid: Left * Title, Right Auto Action Bar matching prototype-variants.html)
    $titleRowGrid = New-Object Windows.Controls.Grid
    $trc0 = New-Object Windows.Controls.ColumnDefinition; $trc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $trc1 = New-Object Windows.Controls.ColumnDefinition; $trc1.Width = [Windows.GridLength]::Auto
    [void]$titleRowGrid.ColumnDefinitions.Add($trc0); [void]$titleRowGrid.ColumnDefinitions.Add($trc1)
    $titleRowGrid.Margin = [Windows.Thickness]::new(0, 0, 0, 10)

    $h1 = New-Object Windows.Controls.TextBlock
    $h1.Text = $SessionObj.Title
    $h1.FontSize = if ($IsNarrow) { 15.5 } else { 18 }
    $h1.FontWeight = 'Bold'
    $h1.Foreground = ConvertTo-Brush '#18181B'
    $h1.TextTrimming = 'CharacterEllipsis'
    $h1.TextWrapping = 'NoWrap'
    $h1.VerticalAlignment = 'Center'
    $h1.ToolTip = $SessionObj.Title
    [Windows.Controls.Grid]::SetColumn($h1, 0)
    [void]$titleRowGrid.Children.Add($h1)

    $titleActionsStack = New-Object Windows.Controls.StackPanel
    $titleActionsStack.Orientation = 'Horizontal'
    $titleActionsStack.VerticalAlignment = 'Center'
    $titleActionsStack.Margin = [Windows.Thickness]::new($(if ($IsNarrow) { 8 } else { 12 }), 0, 0, 0)

    $openWebBtn = New-Object Windows.Controls.Button
    $openWebBtn.Content = if ($IsNarrow) { '🌐 网页 ↗' } else { '🌐 打开网页 ↗' }
    $openWebBtn.Padding = if ($IsNarrow) { [Windows.Thickness]::new(8, 3, 8, 3) } else { [Windows.Thickness]::new(10, 4, 10, 4) }
    $openWebBtn.MinHeight = 27
    $openWebBtn.FontSize = 11.5
    $openWebBtn.FontWeight = 'SemiBold'
    $openWebBtn.Background = ConvertTo-Brush '#FFFFFF'
    $openWebBtn.BorderBrush = ConvertTo-Brush '#E4E4E7'
    $openWebBtn.Foreground = ConvertTo-Brush '#18181B'
    $openWebBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
    $openWebBtn.VerticalAlignment = 'Center'
    $openWebBtn.ToolTip = '一键激活并切换到浏览器中已打开的对应 ChatGPT 网页标签页（若已关闭则在绑定浏览器中直接打开该会话）'
    $openWebBtn.Tag = $SessionObj
    $openWebBtn.Add_Click({
        param($sender, $e)
        if ($sender.Tag) { Invoke-OpenSessionWebPage $sender.Tag }
    })
    [void]$titleActionsStack.Children.Add($openWebBtn)

    $detBtn = New-Object Windows.Controls.Button
    $detBtn.Content = '详情'
    $detBtn.Padding = [Windows.Thickness]::new(10, 4, 10, 4)
    $detBtn.MinHeight = 27
    $detBtn.FontSize = 11.5
    $detBtn.FontWeight = 'SemiBold'
    $detBtn.Background = ConvertTo-Brush '#FFFFFF'
    $detBtn.BorderBrush = ConvertTo-Brush '#E4E4E7'
    $detBtn.Foreground = ConvertTo-Brush '#52525B'
    $detBtn.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
    $detBtn.VerticalAlignment = 'Center'
    $detBtn.ToolTip = '打开完整步骤与代码提交详情报告'
    $detBtn.Tag = $SessionObj.SessionKey
    $detBtn.Add_Click({
        param($sender, $e)
        if ($sender.Tag) { Open-SessionDetail ([string]$sender.Tag) }
    })
    [void]$titleActionsStack.Children.Add($detBtn)

    $renBtn = New-QuietIconButton -Kind 'edit' -TooltipText '修改本地会话名称（对齐网页左栏）' -BoxSize 26 -IconSize 13.5
    $renBtn.Margin = [Windows.Thickness]::new(0, 0, 2, 0)
    $renBtn.Tag = [pscustomobject]@{ Key = $SessionObj.SessionKey; Title = $SessionObj.Title }
    $renBtn.Add_Click({
        param($sender, $e)
        $info = $sender.Tag
        if ($info) { Open-SessionRename $info.Key $info.Title }
    })
    [void]$titleActionsStack.Children.Add($renBtn)

    if ($SessionObj.IsArchived) {
        $restBtn = New-QuietIconButton -Kind 'restore' -TooltipText '还原此对话至进行中队列' -BoxSize 26 -IconSize 13.5
        $restBtn.Margin = [Windows.Thickness]::new(0, 0, 2, 0)
        $restBtn.Tag = $SessionObj.SessionKey
        $restBtn.Add_Click({
            param($sender, $e)
            if ($sender.Tag) { Invoke-RestoreSession ([string]$sender.Tag) }
        })
        [void]$titleActionsStack.Children.Add($restBtn)
    } else {
        $archBtn = New-QuietIconButton -Kind 'archive' -TooltipText '归档此对话' -BoxSize 26 -IconSize 13.5
        $archBtn.Margin = [Windows.Thickness]::new(0, 0, 2, 0)
        $archBtn.Tag = $SessionObj.SessionKey
        $archBtn.Add_Click({
            param($sender, $e)
            if ($sender.Tag) { Invoke-ArchiveSession ([string]$sender.Tag) }
        })
        [void]$titleActionsStack.Children.Add($archBtn)
    }

    [Windows.Controls.Grid]::SetColumn($titleActionsStack, 1)
    [void]$titleRowGrid.Children.Add($titleActionsStack)
    [void]$stack.Children.Add($titleRowGrid)

    # Style C3 Full-Pill Subtitle Capsule Row: [Mini Progress Bar + Step Count] + [Unified Execution & Auto-Resend Status Capsule]
    $capsuleWrap = New-Object Windows.Controls.WrapPanel
    $capsuleWrap.Margin = [Windows.Thickness]::new(0, 0, 0, 0)

    # Capsule 1: Step Badge with Embedded Mini Progress Bar (Full Pill CornerRadius=12)
    $stepPill = New-Object Windows.Controls.Border
    $stepPill.Background = ConvertTo-Brush '#F4F4F5'
    $stepPill.BorderBrush = ConvertTo-Brush '#E4E4E7'
    $stepPill.BorderThickness = [Windows.Thickness]::new(1)
    $stepPill.CornerRadius = [Windows.CornerRadius]::new(12)
    $stepPill.Padding = [Windows.Thickness]::new(10, 4, 11, 4)
    $stepPill.Margin = [Windows.Thickness]::new(0, 0, 8, 4)

    $stepPillStack = New-Object Windows.Controls.StackPanel
    $stepPillStack.Orientation = 'Horizontal'
    $stepPillStack.VerticalAlignment = 'Center'

    $progPctVal = if ($null -ne $SessionObj.ProgressPercent) { [Math]::Max(0, [Math]::Min(100, [int]$SessionObj.ProgressPercent)) } else { 100 }
    $miniTrack = New-Object Windows.Controls.Border
    $miniTrack.Width = 44
    $miniTrack.Height = 6
    $miniTrack.Background = ConvertTo-Brush '#E4E4E7'
    $miniTrack.CornerRadius = [Windows.CornerRadius]::new(3)
    $miniTrack.Margin = [Windows.Thickness]::new(0, 0, 7, 0)
    $miniTrack.VerticalAlignment = 'Center'
    $miniTrack.ClipToBounds = $true

    $miniFill = New-Object Windows.Controls.Border
    $miniFill.HorizontalAlignment = 'Left'
    $miniFill.Height = 6
    $miniFill.CornerRadius = [Windows.CornerRadius]::new(3)
    $miniFill.Background = ConvertTo-Brush '#16A34A'
    $miniFill.Width = [Math]::Max(4.0, [Math]::Round(($progPctVal / 100.0) * 44.0, 1))
    $miniTrack.Child = $miniFill
    [void]$stepPillStack.Children.Add($miniTrack)

    $stepPillTxt = New-Object Windows.Controls.TextBlock
    $stepsCount = @(if ($SessionObj.PSObject.Properties['Steps'] -and $SessionObj.Steps) { $SessionObj.Steps }).Count
    $stepPillTxt.Text = if ($stepsCount -gt 0) {
        "已完成 $($SessionObj.StepCountText -replace '\s*步已完成',' 步') ($progPctVal%)"
    } else {
        "$($SessionObj.StepCountText)"
    }
    $stepPillTxt.FontSize = 11.5
    $stepPillTxt.FontWeight = 'SemiBold'
    $stepPillTxt.Foreground = ConvertTo-Brush '#3F3F46'
    $stepPillTxt.VerticalAlignment = 'Center'
    [void]$stepPillStack.Children.Add($stepPillTxt)
    $stepPill.Child = $stepPillStack
    [void]$capsuleWrap.Children.Add($stepPill)

    # Capsule 2: Unified Execution & Auto-Resend Status Capsule (Full Pill CornerRadius=12)
    $statusPill = New-Object Windows.Controls.Border
    $statusPill.CornerRadius = [Windows.CornerRadius]::new(12)
    $statusPill.Padding = [Windows.Thickness]::new(10, 4, 11, 4)
    $statusPill.BorderThickness = [Windows.Thickness]::new(1)
    $statusPill.Margin = [Windows.Thickness]::new(0, 0, 0, 4)

    $statusPillStack = New-Object Windows.Controls.StackPanel
    $statusPillStack.Orientation = 'Horizontal'
    $statusPillStack.VerticalAlignment = 'Center'

    $sDot = New-Object Windows.Shapes.Ellipse
    $sDot.Width = 7; $sDot.Height = 7
    $sDot.VerticalAlignment = 'Center'
    $sDot.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
    [void]$statusPillStack.Children.Add($sDot)

    $sLabel = New-Object Windows.Controls.TextBlock
    $sLabel.FontSize = 11.5
    $sLabel.FontWeight = 'SemiBold'
    $sLabel.VerticalAlignment = 'Center'

    $paneVital = if (-not $SessionObj.IsArchived) { Get-VitalSubstateVisual $SessionObj } else { $null }
    if ($paneVital) {
        # Spec v4.7 §3.4: VitalSubstate semantic colors; keeps the >X分钟静默触发 / >X秒静默触发 suffix
        $statusPill.Background = ConvertTo-Brush $paneVital.Bg
        $statusPill.BorderBrush = ConvertTo-Brush $paneVital.Border
        $sDot.Fill = ConvertTo-Brush $paneVital.Dot
        $sLabel.Foreground = ConvertTo-Brush $paneVital.Fg
        $guardPart = if ($effAutoWakeup) { "自动重发守护已就绪 ($stallTriggerUnit)" } else { '自动重发已关闭' }
        $sLabel.Text = "$($paneVital.PillText) · $guardPart"
    } elseif ($SessionObj.IsStalled) {
        $statusPill.Background = ConvertTo-Brush '#FFFBEB'
        $statusPill.BorderBrush = ConvertTo-Brush '#FDE68A'
        $sDot.Fill = ConvertTo-Brush '#D97706'
        $sLabel.Foreground = ConvertTo-Brush '#B45309'
        if (-not $effAutoWakeup) {
            $sLabel.Text = "网页已停顿 $stallDisplayUnit · 自动重发已关闭"
        } else {
            $rawBm = if ($SessionObj.PSObject.Properties['BreakerMessage'] -and $SessionObj.BreakerMessage) { [string]$SessionObj.BreakerMessage } else { '' }
            $retryPart = if ($rawBm -and $rawBm -notmatch '闭环守护待命中|自动重发已关闭') {
                $rawBm
            } else {
                "已自动重发 $($SessionObj.RetryCount)/$taskMaxRetries 次"
            }
            $sLabel.Text = "网页已停顿 $stallDisplayUnit · $retryPart"
        }
    } elseif ($SessionObj.IsArchived) {
        $statusPill.Background = ConvertTo-Brush '#F4F4F5'
        $statusPill.BorderBrush = ConvertTo-Brush '#E4E4E7'
        $sDot.Fill = ConvertTo-Brush '#A1A1AA'
        $sLabel.Foreground = ConvertTo-Brush '#52525B'
        $sLabel.Text = "已归档会话 · $($SessionObj.ArchiveReason)"
    } elseif ($SessionObj.PSObject.Properties['VitalState'] -and [string]$SessionObj.VitalState -eq 'UNKNOWN') {
        $statusPill.Background = ConvertTo-Brush '#EFF6FF'
        $statusPill.BorderBrush = ConvertTo-Brush '#BFDBFE'
        $sDot.Fill = ConvertTo-Brush '#2563EB'
        $sLabel.Foreground = ConvertTo-Brush '#1D4ED8'
        $guardPart = if ($effAutoWakeup) { "自动重发守护已就绪 ($stallTriggerUnit)" } else { '自动重发已关闭' }
        $vHint = if ($SessionObj.PSObject.Properties['VitalHintText'] -and $SessionObj.VitalHintText) { [string]$SessionObj.VitalHintText } else { '正在核实网页运行状态' }
        $sLabel.Text = "$vHint · $guardPart"
    } else {
        $statusPill.Background = ConvertTo-Brush '#F0FDF4'
        $statusPill.BorderBrush = ConvertTo-Brush '#BBF7D0'
        $sDot.Fill = ConvertTo-Brush '#16A34A'
        $sLabel.Foreground = ConvertTo-Brush '#15803D'
        $guardPart = if ($effAutoWakeup) { "自动重发守护已就绪 ($stallTriggerUnit)" } else { '自动重发已关闭' }
        $vPrefix = if ($SessionObj.PSObject.Properties['VitalHintText'] -and $SessionObj.VitalHintText) { [string]$SessionObj.VitalHintText } else { '本机执行中' }
        $sLabel.Text = "$vPrefix · $guardPart"
    }
    [void]$statusPillStack.Children.Add($sLabel)
    $statusPill.Child = $statusPillStack
    [void]$capsuleWrap.Children.Add($statusPill)
    [void]$stack.Children.Add($capsuleWrap)

    # Crisp 1px Horizontal Divider below Subtitle Capsules (matches prototype-variants.html)
    $headDivider = New-Object Windows.Controls.Border
    $headDivider.Height = 1
    $headDivider.Background = ConvertTo-Brush '#F1F1F4'
    $headDivider.Margin = [Windows.Thickness]::new(0, 12, 0, 18)
    [void]$stack.Children.Add($headDivider)

    # Readable Milestones (Chronological stream: show latest 3 by default, with optional expander for older ones)
    $diagTxt = $null
    $rCkpts = @(if ($SessionObj.PSObject.Properties.Name -contains 'ReadableCheckpoints' -and $SessionObj.ReadableCheckpoints) { $SessionObj.ReadableCheckpoints })
    if ($rCkpts.Count -eq 0) {
        $diagBlock = New-Object Windows.Controls.Border
        $diagBlock.Background = ConvertTo-Brush '#FAFAFA'
        $diagBlock.BorderBrush = ConvertTo-Brush '#E4E4E7'
        $diagBlock.BorderThickness = [Windows.Thickness]::new(1)
        $diagBlock.CornerRadius = [Windows.CornerRadius]::new(8)
        $diagBlock.Padding = [Windows.Thickness]::new(14, 12, 14, 12)
        $diagBlock.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
        $diagTxt = New-Object Windows.Controls.TextBlock
        $diagTxt.Text = $(if ($SessionObj.HumanDiagnosis) { $SessionObj.HumanDiagnosis } else { $SessionObj.LatestSummary })
        $diagTxt.FontSize = 13.5
        $diagTxt.Foreground = ConvertTo-Brush '#3F3F46'
        $diagTxt.LineHeight = 22
        $diagBlock.Child = $diagTxt
        [void]$stack.Children.Add($diagBlock)
    } else {
        $chronological = @($rCkpts)
        [Array]::Reverse($chronological)
        if ($chronological.Count -gt 3) {
            $olderCount = $chronological.Count - 3
            $olderItems = @($chronological[0..($olderCount - 1)])
            $recentItems = @($chronological[$olderCount..($chronological.Count - 1)])

            $olderPanel = New-Object Windows.Controls.StackPanel
            $olderPanel.Visibility = 'Collapsed'
            foreach ($oldMs in $olderItems) {
                [void]$olderPanel.Children.Add((New-MilestoneBlockElement $oldMs))
            }

            $moreBtn = New-Object Windows.Controls.Button
            $moreBtn.Content = "展开更早的 $olderCount 条阶段记录 ▾"
            $moreBtn.Style = $script:window.Resources['LinkButton']
            $moreBtn.FontSize = 12
            $moreBtn.Foreground = ConvertTo-Brush '#71717A'
            $moreBtn.Margin = [Windows.Thickness]::new(0, 0, 0, 14)
            $moreBtn.Tag = [pscustomobject]@{ Panel = $olderPanel; Count = $olderCount }
            $moreBtn.Add_Click({
                param($sender, $e)
                $info = $sender.Tag
                if ($info -and $info.Panel) {
                    if ($info.Panel.Visibility -eq 'Visible') {
                        $info.Panel.Visibility = 'Collapsed'
                        $sender.Content = "展开更早的 $($info.Count) 条阶段记录 ▾"
                    } else {
                        $info.Panel.Visibility = 'Visible'
                        $sender.Content = "收起更早的 $($info.Count) 条阶段记录 ▴"
                    }
                }
            })
            [void]$stack.Children.Add($moreBtn)
            [void]$stack.Children.Add($olderPanel)

            foreach ($ms in $recentItems) {
                [void]$stack.Children.Add((New-MilestoneBlockElement $ms))
            }
        } else {
            foreach ($ms in $chronological) {
                [void]$stack.Children.Add((New-MilestoneBlockElement $ms))
            }
        }
    }

    # Sent Web-Bridge Message Bubble (Spec v4.2: 4-Stage Delivery Feedback + FIFO Pending Queue Withdraw + History Modal)
    $msgBubble = New-Object Windows.Controls.Border
    Update-QueueBannerBorder -BannerBorder $msgBubble -SessionObj $SessionObj
    $sessKeyForBanner = if ($SessionObj -and $SessionObj.PSObject.Properties['SessionKey'] -and $SessionObj.SessionKey) { [string]$SessionObj.SessionKey } else { '' }
    if ($sessKeyForBanner) {
        if ($script:sessionQueueBannerBorders.ContainsKey($sessKeyForBanner) -and $script:sessionQueueBannerBorders[$sessKeyForBanner]) {
            $prevArr = [object[]]$script:sessionQueueBannerBorders[$sessKeyForBanner]
            $nextArr = New-Object 'object[]' ($prevArr.Length + 1)
            [Array]::Copy($prevArr, $nextArr, $prevArr.Length)
            $nextArr[$prevArr.Length] = $msgBubble
            $script:sessionQueueBannerBorders[$sessKeyForBanner] = $nextArr
        } else {
            $singleArr = New-Object 'object[]' 1
            $singleArr[0] = $msgBubble
            $script:sessionQueueBannerBorders[$sessKeyForBanner] = $singleArr
        }
    }
    [void]$stack.Children.Add($msgBubble)

    $streamScrollHost = New-Object Windows.Controls.Grid
    $streamScrollHost.Name = 'StreamScrollHost'
    $streamScrollHost.Tag = 'StreamScrollHost'

    $scroll.Content = $stack
    [void]$streamScrollHost.Children.Add($scroll)

    # Floating [↓ 回到最新进展] Pill (Appears when scrolled up > 42px)
    $scrollPill = New-Object Windows.Controls.Button
    $scrollPill.HorizontalAlignment = 'Center'
    $scrollPill.VerticalAlignment = 'Bottom'
    $scrollPill.Margin = [Windows.Thickness]::new(0, 0, 0, 14)
    $scrollPill.Padding = [Windows.Thickness]::new(14, 6, 14, 6)
    $scrollPill.MinHeight = 30
    $scrollPill.Background = ConvertTo-Brush '#E618181B'
    $scrollPill.BorderBrush = ConvertTo-Brush '#33FFFFFF'
    $scrollPill.Foreground = ConvertTo-Brush '#FEFEFF'
    $scrollPill.Visibility = 'Collapsed'
    [Windows.Controls.Panel]::SetZIndex($scrollPill, 85)
    $pillShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $pillShadow.BlurRadius = 16; $pillShadow.ShadowDepth = 3; $pillShadow.Opacity = 0.16; $pillShadow.Color = [Windows.Media.Color]::FromRgb(24, 24, 27)
    $scrollPill.Effect = $pillShadow

    $pillStack = New-Object Windows.Controls.StackPanel
    $pillStack.Orientation = 'Horizontal'
    $pillIcon = New-VectorIcon -Kind 'arrowDown' -Size 13 -ColorHex '#FEFEFF' -StrokeWidth 2.2
    $pillIcon.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
    [void]$pillStack.Children.Add($pillIcon)
    $pillTxt = New-Object Windows.Controls.TextBlock
    $pillTxt.Text = '回到最新进展'
    $pillTxt.FontSize = 12
    $pillTxt.FontWeight = 'SemiBold'
    $pillTxt.Foreground = ConvertTo-Brush '#FEFEFF'
    [void]$pillStack.Children.Add($pillTxt)
    $scrollPill.Content = $pillStack
    $scrollPill.Tag = $scroll
    $scrollPill.Add_Click({
        param($sender, $e)
        $sv = $sender.Tag
        if ($sv) { $sv.ScrollToBottom() }
    })

    $scroll.Tag = $scrollPill
    $scroll.Add_ScrollChanged({
        param($sender, $e)
        $pill = $sender.Tag
        if ($pill) {
            $dist = $sender.ScrollableHeight - $sender.VerticalOffset
            $pill.Visibility = if ($dist -gt 42) { 'Visible' } else { 'Collapsed' }
        }
    })
    [void]$streamScrollHost.Children.Add($scrollPill)
    [Windows.Controls.Grid]::SetRow($streamScrollHost, 0)
    [void]$hostContainer.Children.Add($streamScrollHost)

    $composeBorder = Build-PlanBComposerPod -SessionObj $SessionObj -IsNarrow $IsNarrow -IsZeroTask $false -PaneId $(if ($PaneObj -and $PaneObj.PSObject.Properties['id']) { [int]$PaneObj.id } else { 0 })
    [Windows.Controls.Grid]::SetRow($composeBorder, 1)
    [void]$hostContainer.Children.Add($composeBorder)

    $hostContainer.Tag = [pscustomobject]@{
        TitleBlock = $h1
        OpenWebButton = $openWebBtn
        StepFillBar = $miniFill
        StepPillText = $stepPillTxt
        StatusPill = $statusPill
        StatusDot = $sDot
        StatusLabel = $sLabel
        DiagTextBlock = $diagTxt
        QueueBanner = $msgBubble
        StreamStack = $stack
        IsNarrow = $IsNarrow
    }

    return $hostContainer
}

function Update-PaneStatusPillVisual($StatusPill, $SDot, $SLabel, $SessionObj) {
    if (-not $StatusPill -or -not $SDot -or -not $SLabel -or -not $SessionObj) { return }
    $effAutoWakeup = if ($SessionObj.PSObject.Properties['AutoResendEnabled'] -and $null -ne $SessionObj.AutoResendEnabled) { [bool]$SessionObj.AutoResendEnabled }
                     elseif ($SessionObj.PSObject.Properties['AutoWakeupEnabled'] -and $null -ne $SessionObj.AutoWakeupEnabled) { [bool]$SessionObj.AutoWakeupEnabled }
                     else { $false }
    $taskStallMins = if ($SessionObj.PSObject.Properties['StallMinutes'] -and [double]$SessionObj.StallMinutes -gt 0) { [double]$SessionObj.StallMinutes } else { 3 }
    $taskStallSecs = if ($SessionObj.PSObject.Properties['StallSeconds'] -and [int]$SessionObj.StallSeconds -gt 0 -and [int]$SessionObj.StallSeconds -lt 60) {
        [int]$SessionObj.StallSeconds
    } elseif ($SessionObj.PSObject.Properties['StallMinutes'] -and [double]$SessionObj.StallMinutes -gt 0) {
        [int][Math]::Round([double]$SessionObj.StallMinutes * 60)
    } elseif ($SessionObj.PSObject.Properties['StallSeconds'] -and [int]$SessionObj.StallSeconds -gt 0) {
        [int]$SessionObj.StallSeconds
    } else {
        [int][Math]::Round($taskStallMins * 60)
    }
    $stallDisplayUnit = if ($taskStallSecs -lt 60) { "$taskStallSecs 秒" } else { "$([int][Math]::Max(1, [Math]::Round($taskStallSecs / 60.0))) 分钟" }
    $stallTriggerUnit = if ($taskStallSecs -lt 60) { ">${taskStallSecs}秒静默触发" } else { ">$([int][Math]::Max(1, [Math]::Round($taskStallSecs / 60.0)))分钟静默触发" }
    $taskMaxRetries = if ($SessionObj.PSObject.Properties['MaxRetries'] -and [int]$SessionObj.MaxRetries -gt 0) { [int]$SessionObj.MaxRetries } else { 1 }

    $paneVital = if (-not $SessionObj.IsArchived) { Get-VitalSubstateVisual $SessionObj } else { $null }
    if ($paneVital) {
        $StatusPill.Background = ConvertTo-Brush $paneVital.Bg
        $StatusPill.BorderBrush = ConvertTo-Brush $paneVital.Border
        $SDot.Fill = ConvertTo-Brush $paneVital.Dot
        $SLabel.Foreground = ConvertTo-Brush $paneVital.Fg
        $guardPart = if ($effAutoWakeup) { "自动重发守护已就绪 ($stallTriggerUnit)" } else { '自动重发已关闭' }
        $SLabel.Text = "$($paneVital.PillText) · $guardPart"
    } elseif ($SessionObj.IsStalled) {
        $StatusPill.Background = ConvertTo-Brush '#FFFBEB'
        $StatusPill.BorderBrush = ConvertTo-Brush '#FDE68A'
        $SDot.Fill = ConvertTo-Brush '#D97706'
        $SLabel.Foreground = ConvertTo-Brush '#B45309'
        if (-not $effAutoWakeup) {
            $SLabel.Text = "网页已停顿 $stallDisplayUnit · 自动重发已关闭"
        } else {
            $rawBm = if ($SessionObj.PSObject.Properties['BreakerMessage'] -and $SessionObj.BreakerMessage) { [string]$SessionObj.BreakerMessage } else { '' }
            $retryPart = if ($rawBm -and $rawBm -notmatch '闭环守护待命中|自动重发已关闭') {
                $rawBm
            } else {
                "已自动重发 $($SessionObj.RetryCount)/$taskMaxRetries 次"
            }
            $SLabel.Text = "网页已停顿 $stallDisplayUnit · $retryPart"
        }
    } elseif ($SessionObj.IsArchived) {
        $StatusPill.Background = ConvertTo-Brush '#F4F4F5'
        $StatusPill.BorderBrush = ConvertTo-Brush '#E4E4E7'
        $SDot.Fill = ConvertTo-Brush '#A1A1AA'
        $SLabel.Foreground = ConvertTo-Brush '#52525B'
        $SLabel.Text = "已归档会话 · $($SessionObj.ArchiveReason)"
    } elseif ($SessionObj.PSObject.Properties['VitalState'] -and [string]$SessionObj.VitalState -eq 'UNKNOWN') {
        $StatusPill.Background = ConvertTo-Brush '#EFF6FF'
        $StatusPill.BorderBrush = ConvertTo-Brush '#BFDBFE'
        $SDot.Fill = ConvertTo-Brush '#2563EB'
        $SLabel.Foreground = ConvertTo-Brush '#1D4ED8'
        $guardPart = if ($effAutoWakeup) { "自动重发守护已就绪 ($stallTriggerUnit)" } else { '自动重发已关闭' }
        $vHint = if ($SessionObj.PSObject.Properties['VitalHintText'] -and $SessionObj.VitalHintText) { [string]$SessionObj.VitalHintText } else { '正在核实网页运行状态' }
        $SLabel.Text = "$vHint · $guardPart"
    } else {
        $StatusPill.Background = ConvertTo-Brush '#F0FDF4'
        $StatusPill.BorderBrush = ConvertTo-Brush '#BBF7D0'
        $SDot.Fill = ConvertTo-Brush '#16A34A'
        $SLabel.Foreground = ConvertTo-Brush '#15803D'
        $guardPart = if ($effAutoWakeup) { "自动重发守护已就绪 ($stallTriggerUnit)" } else { '自动重发已关闭' }
        $vPrefix = if ($SessionObj.PSObject.Properties['VitalHintText'] -and $SessionObj.VitalHintText) { [string]$SessionObj.VitalHintText } else { '本机执行中' }
        $SLabel.Text = "$vPrefix · $guardPart"
    }
}

function Update-ComposerPodState($StateInfo) {
    if (-not $StateInfo) { return }
    $hasText = ($StateInfo.InputBox -and $StateInfo.InputBox.Text.Trim().Length -gt 0)
    $isNewWin = ($StateInfo.TargetMode -eq 'new_window') -or [bool]$StateInfo.IsZeroTask
    if ($StateInfo.PSObject.Properties['SegGroup'] -and $StateInfo.SegGroup) {
        $StateInfo.SegGroup.Visibility = if ($StateInfo.IsZeroTask) { 'Collapsed' } else { 'Visible' }
    }
    if ($StateInfo.Placeholder) {
        $StateInfo.Placeholder.Visibility = if ($StateInfo.InputBox -and $StateInfo.InputBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
        $StateInfo.Placeholder.Text = if ($StateInfo.IsZeroTask) {
            '输入新任务目标或问题（按 Enter 立项并下发，Shift+Enter 换行）...'
        } elseif ($isNewWin) {
            '输入追加指令（留空点击右侧按钮直接携带本任务进度账本开启新窗口交接）...'
        } else {
            '输入发往当前 ChatGPT 网页的消息（留空点击右侧按钮直接发“请继续”）...'
        }
    }
    if ($StateInfo.BtnFollowSeg -and $StateInfo.BtnNewWinSeg) {
        $StateInfo.BtnFollowSeg.FontWeight = $(if (-not $isNewWin) { 'SemiBold' } else { 'Normal' })
        $StateInfo.BtnFollowSeg.Background = ConvertTo-Brush $(if (-not $isNewWin) { '#FFFFFF' } else { 'Transparent' })
        $StateInfo.BtnFollowSeg.BorderBrush = ConvertTo-Brush $(if (-not $isNewWin) { '#E4E4E7' } else { 'Transparent' })
        $StateInfo.BtnFollowSeg.Foreground = ConvertTo-Brush $(if (-not $isNewWin) { '#18181B' } else { '#71717A' })

        $StateInfo.BtnNewWinSeg.FontWeight = $(if ($isNewWin) { 'SemiBold' } else { 'Normal' })
        $StateInfo.BtnNewWinSeg.Background = ConvertTo-Brush $(if ($isNewWin) { '#2563EB' } else { 'Transparent' })
        $StateInfo.BtnNewWinSeg.BorderBrush = ConvertTo-Brush $(if ($isNewWin) { '#1D4ED8' } else { 'Transparent' })
        $StateInfo.BtnNewWinSeg.Foreground = ConvertTo-Brush $(if ($isNewWin) { '#FEFEFF' } else { '#71717A' })
    }
    if ($StateInfo.SendButton -and $StateInfo.SendLabel) {
        if ($StateInfo.IsZeroTask) {
            Set-SmoothButtonAppearance $StateInfo.SendButton '#2563EB' '#1D4ED8'
            $StateInfo.SendLabel.Text = '🚀 在网页发起新任务 ↗'
        } elseif ($isNewWin) {
            Set-SmoothButtonAppearance $StateInfo.SendButton '#2563EB' '#1D4ED8'
            $StateInfo.SendLabel.Text = if ($hasText) { '🚀 新建交接并发送 ↗' } else { '🚀 新建网页交接 ↗' }
        } else {
            if ($hasText) {
                Set-SmoothButtonAppearance $StateInfo.SendButton '#18181F' '#18181F'
                $StateInfo.SendLabel.Text = '⚡ 发送消息 ↗'
            } else {
                Set-SmoothButtonAppearance $StateInfo.SendButton '#D97706' '#B45309'
                $StateInfo.SendLabel.Text = '⚡ 发送“请继续” ↗'
            }
        }
    }
}

function Set-SessionPropSafe($SessionObj, [string]$PropName, $Value) {
    if ($null -eq $SessionObj -or -not $PropName) { return }
    try {
        if ($SessionObj -is [System.Collections.IDictionary]) {
            $SessionObj[$PropName] = $Value
        } elseif ($SessionObj.PSObject.Properties[$PropName]) {
            $SessionObj.$PropName = $Value
        } else {
            $SessionObj | Add-Member -NotePropertyName $PropName -NotePropertyValue $Value -Force
        }
    } catch { }
}

function Resolve-UiPlatformCode([string]$Platform = 'chatgpt') {
    $p = if ($Platform) { $Platform.Trim().ToLowerInvariant() } else { 'chatgpt' }
    if ($p -in @('', 'openai', 'chatgpt')) { return 'chatgpt' }
    return $p
}

function Register-ComposerOptimisticMutation($StateInfo) {
    if (-not $StateInfo) { return }
    $nowUtc = [DateTime]::UtcNow
    Set-SessionPropSafe $StateInfo 'MutationEpoch' $nowUtc
    $script:lastComposerMutationEpoch = $nowUtc
}

function Test-ComposerOptimisticLockActive($StateInfo, [double]$LockSeconds = 3.0) {
    if (-not $StateInfo) { return $false }
    if ($StateInfo.PSObject.Properties['MutationEpoch'] -and $StateInfo.MutationEpoch -is [DateTime]) {
        $elapsed = ([DateTime]::UtcNow - [DateTime]$StateInfo.MutationEpoch).TotalSeconds
        if ($elapsed -ge 0 -and $elapsed -lt $LockSeconds) { return $true }
    }
    return $false
}

function Invoke-TaskComposerConfigAsync {
    param(
        $Context = $null,
        [hashtable]$Params = @{}
    )
    if (-not $Params -or $Params.Count -eq 0) { return $null }
    $effCtx = if ($Context) { $Context } else { $script:context }
    $noShowVar = Get-Variable -Name 'NoShow' -ErrorAction SilentlyContinue
    $isNoShow = ($noShowVar -and [bool]$noShowVar.Value)
    $isIso = ($effCtx -and $effCtx.PSObject.Properties['Isolated'] -and [bool]$effCtx.Isolated)
    $modPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'ConnectionManager.psm1' } else { '' }
    if ($isNoShow -or $isIso -or (-not $modPath) -or (-not (Test-Path -LiteralPath $modPath))) {
        return (Set-TaskComposerConfig @Params)
    }
    try {
        $psBg = [powershell]::Create()
        [void]$psBg.AddScript({
            param($ModulePath, $CallParams)
            try {
                Import-Module $ModulePath -Force
                [void](Set-TaskComposerConfig @CallParams)
            } catch { }
        }).AddArgument($modPath).AddArgument($Params)
        $handle = $psBg.BeginInvoke()
        return [pscustomobject]@{ DispatchedAsync = $true; Handle = $handle; PowerShell = $psBg }
    } catch {
        return (Set-TaskComposerConfig @Params)
    }
}

function Invoke-ComposerPersistence($StateInfo, [hashtable]$Params) {
    if (-not $Params -or $Params.Count -eq 0) { return $null }
    Register-ComposerOptimisticMutation $StateInfo
    if ($StateInfo -and $StateInfo.PSObject.Properties['UseAsyncPersistence'] -and [bool]$StateInfo.UseAsyncPersistence) {
        return (Invoke-TaskComposerConfigAsync -Context $Params['Context'] -Params $Params)
    }
    $noShowVar = Get-Variable -Name 'NoShow' -ErrorAction SilentlyContinue
    $isNoShow = ($noShowVar -and [bool]$noShowVar.Value)
    $effCtx = $Params['Context']
    $isIso = ($effCtx -and $effCtx.PSObject.Properties['Isolated'] -and [bool]$effCtx.Isolated)
    if ($isNoShow -or (-not $effCtx) -or $isIso) {
        return (Set-TaskComposerConfig @Params)
    }
    return (Invoke-TaskComposerConfigAsync -Context $effCtx -Params $Params)
}

function Toggle-ComposerModelGroupFold($StateInfo, [string]$Provider) {
    if (-not $StateInfo -or -not $StateInfo.ModelCombo) { return }
    $normProv = Resolve-UiPlatformCode $Provider
    if (-not ($StateInfo.PSObject.Properties['CollapsedProviders'] -and $StateInfo.CollapsedProviders -is [hashtable])) {
        Set-SessionPropSafe $StateInfo 'CollapsedProviders' @{}
    }
    $newCollapsed = -not [bool]$StateInfo.CollapsedProviders[$normProv]
    $StateInfo.CollapsedProviders[$normProv] = $newCollapsed
    $arrow = if ($newCollapsed) { '▸' } else { '▾' }
    $childVis = if ($newCollapsed) { 'Collapsed' } else { 'Visible' }
    foreach ($it in @($StateInfo.ModelCombo.Items)) {
        if (-not $it) { continue }
        $itTag = [string]$it.Tag
        if ($itTag -eq "__group_$normProv" -or ($normProv -eq 'chatgpt' -and $itTag -eq '__group_openai')) {
            $rawContent = [string]$it.Content
            $stripped = ($rawContent -replace '^[▾▸]\s*', '').Trim()
            $it.Content = "$arrow $stripped"
        } elseif ((Resolve-UiPlatformCode ([string]$it.ToolTip)) -eq $normProv) {
            $it.Visibility = $childVis
        }
    }
}

function Sync-ComposerCarrierCombo($StateInfo, $AvailCarriers = $null, [string]$PreferredCarrier = '') {
    if (-not $StateInfo -or -not $StateInfo.PSObject.Properties['ProfCombo'] -or -not $StateInfo.ProfCombo) { return '' }
    $profCombo = $StateInfo.ProfCombo
    $previousSuppress = [bool]$script:suppressComposerEvents
    $script:suppressComposerEvents = $true
    try {
        $activeProv = Resolve-UiPlatformCode $(if ($StateInfo.PSObject.Properties['Provider'] -and $StateInfo.Provider) { [string]$StateInfo.Provider } else { 'chatgpt' })
        Set-SessionPropSafe $StateInfo 'Provider' $activeProv
        if (-not ($StateInfo.PSObject.Properties['CarrierByProvider'] -and $StateInfo.CarrierByProvider -is [hashtable])) {
            $seededMap = @{}
            if ($StateInfo.PSObject.Properties['CarrierByProvider'] -and $StateInfo.CarrierByProvider) {
                foreach ($kp in $StateInfo.CarrierByProvider.PSObject.Properties) {
                    if ($kp.Name -and $kp.Value) { $seededMap[(Resolve-UiPlatformCode $kp.Name)] = [string]$kp.Value }
                }
            }
            Set-SessionPropSafe $StateInfo 'CarrierByProvider' $seededMap
        }
        $carriersRaw = @(if ($null -ne $AvailCarriers) {
            $AvailCarriers
        } elseif ($StateInfo.PSObject.Properties['AvailableCarriers'] -and $StateInfo.AvailableCarriers) {
            $StateInfo.AvailableCarriers
        } elseif (Get-Command Get-AvailableBrowserProfiles -ErrorAction SilentlyContinue) {
            Get-AvailableBrowserProfiles -Context $script:context
        })
        $filteredCarriers = @(foreach ($c in $carriersRaw) {
            if (-not $c) { continue }
            $cId = [string]$c.Id
            $cLbl = [string]$c.Label
            if ($activeProv -in @('gemini', 'claude') -and ($cId -like 'Desktop:*' -or $cLbl -match 'ChatGPT 桌面端')) {
                continue
            }
            $c
        })
        $remembered = if ($StateInfo.CarrierByProvider.ContainsKey($activeProv) -and $StateInfo.CarrierByProvider[$activeProv]) {
            [string]$StateInfo.CarrierByProvider[$activeProv]
        } else { '' }
        $candidateIds = @($filteredCarriers | ForEach-Object { [string]$_.Id })
        $resolvedCarrier = if ($remembered -and ($candidateIds -contains $remembered)) {
            $remembered
        } elseif ($PreferredCarrier -and ($candidateIds -contains $PreferredCarrier)) {
            $PreferredCarrier
        } elseif ($StateInfo.PSObject.Properties['BrowserProfile'] -and $StateInfo.BrowserProfile -and ($candidateIds -contains [string]$StateInfo.BrowserProfile)) {
            [string]$StateInfo.BrowserProfile
        } else {
            $defC = $filteredCarriers | Where-Object { $_.PSObject.Properties['IsDefault'] -and [bool]$_.IsDefault } | Select-Object -First 1
            if ($defC -and $defC.Id) { [string]$defC.Id }
            elseif ($candidateIds.Count -gt 0) { [string]$candidateIds[0] }
            else { '' }
        }
        if ($resolvedCarrier) {
            $StateInfo.CarrierByProvider[$activeProv] = $resolvedCarrier
            Set-SessionPropSafe $StateInfo 'BrowserProfile' $resolvedCarrier
        }
        if (-not $profCombo.IsDropDownOpen) {
            $profCombo.Items.Clear()
            $selIdx = 0
            for ($ci = 0; $ci -lt $filteredCarriers.Count; $ci++) {
                $cp = $filteredCarriers[$ci]
                $pItem = New-Object Windows.Controls.ComboBoxItem
                $rawProfLbl = ([string]$cp.Label -replace '\s*\(Web[^)]*\)', '').Trim()
                $pItem.Content = if ($rawProfLbl -match '^(💻|🌐)') { $rawProfLbl } else { "🌐 $rawProfLbl" }
                $pItem.Tag = [string]$cp.Id
                [void]$profCombo.Items.Add($pItem)
                if ([string]$cp.Id -eq $resolvedCarrier) { $selIdx = $ci }
            }
            if ($profCombo.Items.Count -gt 0) {
                $profCombo.SelectedIndex = $selIdx
            }
        }
        return $resolvedCarrier
    } finally {
        $script:suppressComposerEvents = $previousSuppress
    }
}

function Sync-ComposerModelAndEffortCombos($StateInfo, $AvailModels, [string]$CurModel, [string]$WebModel, [string]$CurEffort, [string]$WebEffort, [bool]$IsNarrow, [switch]$FromBackgroundPoll) {
    if (-not $StateInfo -or -not $StateInfo.ModelCombo -or -not $StateInfo.EffortCombo) { return }
    # Programmatic repopulation/selection must not invoke the user's SelectionChanged handlers.
    $previousSuppress = [bool]$script:suppressComposerEvents
    $script:suppressComposerEvents = $true
    try {
    if (-not ($StateInfo.PSObject.Properties['CollapsedProviders'] -and $StateInfo.CollapsedProviders -is [hashtable])) {
        Set-SessionPropSafe $StateInfo 'CollapsedProviders' @{}
    }
    $activeProvider = Resolve-UiPlatformCode $(if ($StateInfo.PSObject.Properties['Provider'] -and $StateInfo.Provider) { [string]$StateInfo.Provider } else { 'chatgpt' })
    Set-SessionPropSafe $StateInfo 'Provider' $activeProvider

    $modelsArr = @(if ($AvailModels) { $AvailModels })
    $providerCatalogs = if ($StateInfo.PSObject.Properties['AvailableModelsByProvider']) { $StateInfo.AvailableModelsByProvider } else { $null }
    $connectedProviders = $null
    if ($StateInfo.PSObject.Properties['ConnectedProviders'] -and $null -ne $StateInfo.ConnectedProviders) { $connectedProviders = @($StateInfo.ConnectedProviders) }
    $connectedSig = if ($null -eq $connectedProviders) { 'unknown' } else { 'known:' + (@($connectedProviders) -join ',') }
    $catalogsSig = if ($providerCatalogs) { $providerCatalogs | ConvertTo-Json -Depth 12 -Compress } else { '' }
    $modelSlugsSig = (@($modelsArr | ForEach-Object {
        $s = if ($_.PSObject.Properties['slug']) { [string]$_.slug } else { '' }
        $t = if ($_.PSObject.Properties['title']) { [string]$_.title } else { $s }
        $ef = if ($_.PSObject.Properties['effort_items'] -and $_.effort_items) {
            (@($_.effort_items | ForEach-Object { "$($_.id):$($_.label)" }) -join ',')
        } elseif ($_.PSObject.Properties['efforts'] -and $_.efforts) {
            (@($_.efforts) -join ',')
        } else { '' }
        $cfgFlag = if ($_.PSObject.Properties['configurable_effort']) { [string]([bool]$_.configurable_effort) } else { '' }
        $defEf = if ($_.PSObject.Properties['default_effort']) { [string]$_.default_effort } else { '' }
        "$s|$t|$ef|$cfgFlag|$defEf"
    }) -join ';')
    $profStateRef = if ($StateInfo.PSObject.Properties['ProfilesState'] -and $StateInfo.ProfilesState) {
        $StateInfo.ProfilesState
    } elseif ($script:profilesState) {
        $script:profilesState
    } else { $null }
    $enabledPlats = @(if ($profStateRef -and $profStateRef.PSObject.Properties['EnabledPlatforms'] -and $profStateRef.EnabledPlatforms) {
        $profStateRef.EnabledPlatforms | Where-Object { $_ } | ForEach-Object { Resolve-UiPlatformCode ([string]$_) }
    } else { @('chatgpt') })
    if ($enabledPlats.Count -eq 0) { $enabledPlats = @('chatgpt') }
    $hasLiveDisplay = ($null -ne $script:display -and $script:display.PSObject.Properties['Running'])
    $tunOnlineNow = if ($StateInfo.PSObject.Properties['TunnelOnline'] -and $null -ne $StateInfo.TunnelOnline) {
        [bool]$StateInfo.TunnelOnline
    } elseif ($hasLiveDisplay) {
        [bool]$script:display.Running
    } else {
        $true
    }
    $pubTunOnlineNow = if ($StateInfo.PSObject.Properties['PublicTunnelOnline'] -and $null -ne $StateInfo.PublicTunnelOnline) {
        [bool]$StateInfo.PublicTunnelOnline
    } elseif ($script:context -and (Get-Command Get-PublicMcpTunnelState -ErrorAction SilentlyContinue)) {
        [bool](Get-PublicMcpTunnelState $script:context).Running
    } else {
        $null
    }
    $resolvePlatGroupSummary = {
        param([string]$PlatCode)
        $normCode = Resolve-UiPlatformCode $PlatCode
        $pTitle = switch ($normCode) {
            'chatgpt'  { 'ChatGPT' }
            'claude'   { 'Claude' }
            'gemini'   { 'Gemini' }
            'deepseek' { 'DeepSeek' }
            'opencode' { 'OpenCode' }
            default    { $normCode }
        }
        $actP = $null
        if ($profStateRef -and $profStateRef.PSObject.Properties['Profiles'] -and $profStateRef.Profiles) {
            $actP = $profStateRef.Profiles | Where-Object {
                $pl = if ($_.PSObject.Properties['Platform'] -and $_.Platform) { Resolve-UiPlatformCode ([string]$_.Platform) } else { 'chatgpt' }
                $pl -eq $normCode -and ($_.PSObject.Properties['IsActive'] -and [bool]$_.IsActive)
            } | Select-Object -First 1
            if (-not $actP) {
                $actP = $profStateRef.Profiles | Where-Object {
                    $pl = if ($_.PSObject.Properties['Platform'] -and $_.Platform) { Resolve-UiPlatformCode ([string]$_.Platform) } else { 'chatgpt' }
                    $pl -eq $normCode
                } | Select-Object -First 1
            }
        }
        $pName = if ($actP -and $actP.PSObject.Properties['Name'] -and $actP.Name) { [string]$actP.Name } else { '默认' }
        $pEn = if ($actP -and $actP.PSObject.Properties['Enabled']) { [bool]$actP.Enabled } else { $true }
        $pHk = if ($actP -and $actP.PSObject.Properties['HasKey']) { [bool]$actP.HasKey } else { $false }
        $pKind = if ($actP -and $actP.PSObject.Properties['Kind'] -and $actP.Kind) { [string]$actP.Kind } elseif ($normCode -eq 'chatgpt') { 'tunnel' } else { 'public_tunnel' }
        $pTid = if ($actP -and $actP.PSObject.Properties['TunnelId']) { [string]$actP.TunnelId } else { '' }
        $isReady = if ($normCode -eq 'chatgpt' -or $pKind -eq 'tunnel') {
            $pEn -and $pHk -and [bool]$pTid -and $tunOnlineNow
        } elseif ($null -ne $pubTunOnlineNow) {
            $pEn -and [bool]$pubTunOnlineNow
        } else {
            $pEn -and ($pHk -or $pKind -eq 'public_tunnel')
        }
        $dotIcon = if ($isReady) { '🟢' } else { '⚪' }
        return [pscustomobject]@{
            Code = $normCode
            Title = $pTitle
            Name = $pName
            Ready = $isReady
            Dot = $dotIcon
            Sig = "${normCode}:${pName}:${isReady}"
        }
    }
    $platsSig = (@($enabledPlats | ForEach-Object { (& $resolvePlatGroupSummary $_).Sig }) -join '|')
    $collapsedSig = (@($enabledPlats | ForEach-Object { "${_}:$([bool]$StateInfo.CollapsedProviders[$_])" }) -join ',')
    $isColdStartNoWebModel = ($modelsArr.Count -eq 0) -and [string]::IsNullOrWhiteSpace($WebModel) -and ([string]::IsNullOrWhiteSpace($CurModel) -or $CurModel -eq 'inherit') -and [string]::IsNullOrWhiteSpace($WebEffort)
    $catalogSig = "$connectedSig||$catalogsSig||$modelSlugsSig||webM=$WebModel||webE=$WebEffort||curM=$CurModel||prov=$activeProvider||plats=$platsSig||fold=$collapsedSig||cold=$isColdStartNoWebModel"

    $modelCombo = $StateInfo.ModelCombo
    $effortCombo = $StateInfo.EffortCombo
    $webModelDisplay = if ($WebModel) { $WebModel } else { '跟随网页' }
    if ($StateInfo.LastCatalogSig -eq $catalogSig -and $modelCombo.Items.Count -gt 0 -and $effortCombo.Items.Count -gt 0 -and -not $modelCombo.IsDropDownOpen -and -not $effortCombo.IsDropDownOpen) {
        if ([string]$modelCombo.Items[0].Tag -eq 'inherit') {
            $modelCombo.Items[0].Content = $(if ($IsNarrow) { '🤖 默认' } else { "🤖 默认 ($webModelDisplay)" })
        } elseif ($modelCombo.Items.Count -gt 1 -and [string]$modelCombo.Items[1].Tag -eq 'inherit' -and [string]$modelCombo.Items[1].ToolTip -eq 'chatgpt') {
            $modelCombo.Items[1].Content = $(if ($IsNarrow) { '🤖 默认' } else { "🤖 默认 ($webModelDisplay)" })
        }
        if ($activeProvider -in @('gemini', 'claude')) {
            $effortCombo.IsEnabled = $false
            $effortCombo.Items[0].Content = '🧠 跟随网页设置'
        } else {
            $effortCombo.IsEnabled = $true
            $curEffItem0 = [string]$effortCombo.Items[0].Content
            if ($curEffItem0 -match '固定') {
                $effortCombo.Items[0].Content = $(if ($IsNarrow) { '🧠 固定' } else { '🧠 默认 (当前模型固定)' })
            } elseif ($StateInfo.PSObject.Properties['LastWebEffortDisplay'] -and $StateInfo.LastWebEffortDisplay) {
                $effortCombo.Items[0].Content = $(if ($IsNarrow) { '🧠 默认' } else { "🧠 默认 ($($StateInfo.LastWebEffortDisplay))" })
            }
        }
    } else {

    # Resolve active model entry and optional sibling -thinking entry up front; Scheme A renders pure official raw English effort IDs
    $activeModelKey = if ($CurModel -and $CurModel -ne 'inherit') { $CurModel } else { $WebModel }
    $parenSlugMatch = if ($activeModelKey -match '\(([^()]+)\)\s*$') { $Matches[1].Trim() } else { '' }
    $matchedModelEntry = $modelsArr | Where-Object {
        ($_.PSObject.Properties['slug'] -and ([string]$_.slug -eq $activeModelKey -or ($parenSlugMatch -and [string]$_.slug -eq $parenSlugMatch))) -or
        ($_.PSObject.Properties['title'] -and [string]$_.title -eq $activeModelKey)
    } | Select-Object -First 1
    $activeSlug = if ($matchedModelEntry -and $matchedModelEntry.PSObject.Properties['slug'] -and $matchedModelEntry.slug) {
        ([string]$matchedModelEntry.slug).Trim().ToLowerInvariant()
    } elseif ($parenSlugMatch) {
        $parenSlugMatch.ToLowerInvariant()
    } else {
        ([string]$activeModelKey).Trim().ToLowerInvariant()
    }
    $siblingThinkingEntry = $null
    if ($activeSlug -match '^(gpt-\d+(?:-\d+)?)(?:-instant)?$') {
        $thinkingSlugCandidate = "$($Matches[1])-thinking"
        $siblingThinkingEntry = $modelsArr | Where-Object {
            $_.PSObject.Properties['slug'] -and ([string]$_.slug).Trim().ToLowerInvariant() -eq $thinkingSlugCandidate
        } | Select-Object -First 1
    }
    $matchedHasEfforts = ($null -ne $matchedModelEntry) -and (
        ($matchedModelEntry.PSObject.Properties['effort_items'] -and @($matchedModelEntry.effort_items).Count -gt 0) -or
        ($matchedModelEntry.PSObject.Properties['efforts'] -and @($matchedModelEntry.efforts).Count -gt 0)
    )
    $siblingHasEfforts = ($null -ne $siblingThinkingEntry) -and (
        ($siblingThinkingEntry.PSObject.Properties['effort_items'] -and @($siblingThinkingEntry.effort_items).Count -gt 0) -or
        ($siblingThinkingEntry.PSObject.Properties['efforts'] -and @($siblingThinkingEntry.efforts).Count -gt 0)
    )
    $effortSourceEntry = if ($matchedHasEfforts) {
        $matchedModelEntry
    } elseif ($siblingHasEfforts) {
        $siblingThinkingEntry
    } else {
        $matchedModelEntry
    }

    $effortItemsResolved = New-Object 'System.Collections.Generic.List[object]'
    if ($effortSourceEntry -and $effortSourceEntry.PSObject.Properties['effort_items'] -and @($effortSourceEntry.effort_items).Count -gt 0) {
        foreach ($ei in @($effortSourceEntry.effort_items)) {
            if (-not $ei) { continue }
            $eId = if ($ei.PSObject.Properties['id'] -and $ei.id) { ([string]$ei.id).Trim().ToLowerInvariant() } else { '' }
            $origLbl = if ($ei.PSObject.Properties['label'] -and $ei.label) { ([string]$ei.label).Trim() } else { '' }
            $eFull = if ($ei.PSObject.Properties['full_label'] -and $ei.full_label) { ([string]$ei.full_label).Trim() } else { $origLbl }
            if ($eId) {
                [void]$effortItemsResolved.Add([pscustomobject]@{ Id = $eId; OrigLabel = $origLbl; FullLabel = $eFull })
            }
        }
    } elseif ($effortSourceEntry -and $effortSourceEntry.PSObject.Properties['efforts'] -and @($effortSourceEntry.efforts).Count -gt 0) {
        foreach ($re in @($effortSourceEntry.efforts)) {
            $k = ([string]$re).Trim().ToLowerInvariant()
            if ($k) {
                [void]$effortItemsResolved.Add([pscustomobject]@{ Id = $k; OrigLabel = ([string]$re).Trim(); FullLabel = ([string]$re).Trim() })
            }
        }
    }

    $declaredEffortIds = @($effortItemsResolved | ForEach-Object { [string]$_.Id } | Where-Object { $_ })
    $resolveRawEffortId = {
        param([string]$RawVal, [string[]]$AllowedPool = @())
        $cl = if ($RawVal) {
            (($RawVal -replace '^(?:思考强度|推理强度|Reasoning)[:：\s]*', '') -replace '[\s⌄▾▼∨⌃▴▲]+$', '').Trim()
        } else { '' }
        if (-not $cl) { return '' }
        $lw = $cl.ToLowerInvariant()
        if ($lw -eq 'inherit') { return 'inherit' }
        if ($lw -in @('none', 'instant', '未开启思考', '无', '即时')) { return 'none' }

        $exactIdHit = $effortItemsResolved | Where-Object { $_.Id -eq $lw } | Select-Object -First 1
        if ($exactIdHit) { return [string]$exactIdHit.Id }

        $exactLblHit = $effortItemsResolved | Where-Object {
            ($_.OrigLabel -and $_.OrigLabel.ToLowerInvariant() -eq $lw) -or
            ($_.FullLabel -and $_.FullLabel.ToLowerInvariant() -eq $lw)
        } | Select-Object -First 1
        if ($exactLblHit) { return [string]$exactLblHit.Id }

        $pool = if ($AllowedPool -and $AllowedPool.Count -gt 0) { $AllowedPool } else { $declaredEffortIds }
        $prefs = switch ($lw) {
            { $_ -in @('低', '轻度', '极简', '快速思考', 'min', 'minimal', 'light', 'low') } { @('min', 'light', 'low', 'minimal'); break }
            { $_ -in @('中', '标准', '思考中', 'standard', 'medium') } { @('standard', 'medium'); break }
            { $_ -in @('高', '深度', '进阶思考', 'extended', 'high', 'deep') } { @('extended', 'high'); break }
            { $_ -in @('极高', 'xhigh') } { @('xhigh', 'max', 'ultra'); break }
            { $_ -in @('最高', '深度思考', 'max', 'heavy') } { @('max', 'xhigh', 'ultra'); break }
            { $_ -in @('深入', '超强', 'ultra') } { @('max', 'ultra', 'xhigh'); break }
            default { @() }
        }
        if ($prefs.Count -gt 0) {
            foreach ($cand in $prefs) {
                if ($pool -contains $cand) { return $cand }
            }
            if ($lw -in @('min', 'minimal', 'light', 'low', 'standard', 'medium', 'extended', 'high', 'max', 'xhigh', 'ultra') -and $pool.Count -eq 0) {
                return $lw
            }
            return $(if ($prefs[0] -eq 'xhigh') { 'max' } else { $prefs[0] })
        }
        if ($cl -match '^[a-zA-Z0-9_-]+$') { return $lw }
        return $cl
    }

    $rawWebEffortCandidate = if ($WebEffort) {
        $WebEffort
    } elseif ($matchedModelEntry -and $matchedModelEntry.PSObject.Properties['default_effort'] -and $matchedModelEntry.default_effort) {
        [string]$matchedModelEntry.default_effort
    } else { '' }
    $resolvedWebId = & $resolveRawEffortId $rawWebEffortCandidate @()
    $webEffortDisplay = if ($isColdStartNoWebModel) {
        '跟随网页'
    } elseif ($resolvedWebId -and $resolvedWebId -ne 'inherit') {
        $resolvedWebId
    } elseif ($WebModel -match '(?i)(^gpt-6$|^gpt-5-6$|-instant$|GPT-6 Instant|GPT-5\.6 Instant)') {
        'none'
    } else {
        'standard'
    }

    $StateInfo | Add-Member -NotePropertyName 'LastWebEffortDisplay' -NotePropertyValue $webEffortDisplay -Force
    if ($StateInfo.LastCatalogSig -ne $catalogSig -and -not $modelCombo.IsDropDownOpen -and -not $effortCombo.IsDropDownOpen) {
        $StateInfo.LastCatalogSig = $catalogSig
        $StateInfo.AvailableModels = $modelsArr

        $buildPlatGroupHeader = {
            param([string]$PlatCode)
            $normCode = Resolve-UiPlatformCode $PlatCode
            $summary = & $resolvePlatGroupSummary $normCode
            $isCollapsed = [bool]$StateInfo.CollapsedProviders[$normCode]
            $arrowIcon = if ($isCollapsed) { '▸' } else { '▾' }
            $hdrItem = New-Object Windows.Controls.ComboBoxItem
            $hdrItem.Content = "$arrowIcon $($summary.Dot) $($summary.Title) · $($summary.Name)"
            $hdrItem.Tag = "__group_$normCode"
            $hdrItem.FontWeight = 'SemiBold'
            $hdrItem.IsEnabled = $true
            $hdrItem.Focusable = $false
            $hdrItem.Add_PreviewMouseLeftButtonDown({
                param($s, $e)
                $e.Handled = $true
                $pCode = ([string]$s.Tag) -replace '^__group_', ''
                Toggle-ComposerModelGroupFold $StateInfo $pCode
            })
            return $hdrItem
        }

        $modelCombo.ToolTip = "选择本任务使用的平台与模型（默认继承原网页当前模型：$webModelDisplay）"
        $modelCombo.Items.Clear()
        $allowWebDomModels = ($StateInfo.PSObject.Properties['AllowWebDomModelList'] -and [bool]$StateInfo.AllowWebDomModelList)

        if ($enabledPlats.Count -le 1) {
            $singleProv = Resolve-UiPlatformCode $enabledPlats[0]
            $defaultModelItem = New-Object Windows.Controls.ComboBoxItem
            $defaultModelItem.Content = $(if ($IsNarrow) { '🤖 默认' } else { "🤖 默认 ($webModelDisplay)" })
            $defaultModelItem.Tag = 'inherit'
            $defaultModelItem.ToolTip = $singleProv
            [void]$modelCombo.Items.Add($defaultModelItem)
            $pModels = @(if ($singleProv -in @('gemini', 'claude') -and -not $allowWebDomModels) {
            } elseif ($null -ne $connectedProviders -and $connectedProviders -notcontains $singleProv) {
            } elseif ($providerCatalogs -and $providerCatalogs.PSObject.Properties[$singleProv]) {
                $providerCatalogs.$singleProv
            } elseif ($singleProv -eq 'chatgpt') {
                $modelsArr
            })
            foreach ($m in $pModels) {
                $slug = [string]$m.slug
                if (-not $slug) { continue }
                $item = New-Object Windows.Controls.ComboBoxItem
                $item.Content = "🤖 $($m.title) ($slug)"
                $item.Tag = $slug
                $item.ToolTip = $singleProv
                [void]$modelCombo.Items.Add($item)
            }
        } else {
            for ($pi = 0; $pi -lt $enabledPlats.Count; $pi++) {
                $provider = Resolve-UiPlatformCode $enabledPlats[$pi]
                $isGroupCollapsed = [bool]$StateInfo.CollapsedProviders[$provider]
                $childVis = if ($isGroupCollapsed) { 'Collapsed' } else { 'Visible' }
                [void]$modelCombo.Items.Add((& $buildPlatGroupHeader $provider))

                $pDefItem = New-Object Windows.Controls.ComboBoxItem
                $pDefItem.Content = if ($provider -eq 'chatgpt') {
                    if ($IsNarrow) { '🤖 默认' } else { "🤖 默认 ($webModelDisplay)" }
                } else {
                    if ($IsNarrow) { '🤖 默认' } else { '🤖 默认 (跟随网页)' }
                }
                $pDefItem.Tag = 'inherit'
                $pDefItem.ToolTip = $provider
                $pDefItem.Visibility = $childVis
                [void]$modelCombo.Items.Add($pDefItem)

                $pModels = @(if ($provider -in @('gemini', 'claude') -and -not $allowWebDomModels) {
                    # Option A: Gemini & Claude strictly expose only '🤖 默认 (跟随网页)' without fragile DOM-simulated model lists
                } elseif ($null -ne $connectedProviders -and $connectedProviders -notcontains $provider) {
                } elseif ($providerCatalogs -and $providerCatalogs.PSObject.Properties[$provider]) {
                    $providerCatalogs.$provider
                } elseif ($provider -eq 'chatgpt') {
                    $modelsArr
                })
                foreach ($m in $pModels) {
                    $slug = [string]$m.slug
                    if (-not $slug) { continue }
                    $item = New-Object Windows.Controls.ComboBoxItem
                    $item.Content = "🤖 $($m.title) ($slug)"
                    $item.Tag = $slug
                    $item.ToolTip = $provider
                    $item.Visibility = $childVis
                    [void]$modelCombo.Items.Add($item)
                }
            }
        }

        if ($activeProvider -in @('gemini', 'claude')) {
            $effortCombo.IsEnabled = $false
            $effortCombo.ToolTip = '当前平台推理与思考强度直接在网页端控制（跟随网页设置）'
            $effortCombo.Items.Clear()
            $webSettingItem = New-Object Windows.Controls.ComboBoxItem
            $webSettingItem.Content = '🧠 跟随网页设置'
            $webSettingItem.Tag = 'inherit'
            [void]$effortCombo.Items.Add($webSettingItem)
            $CurEffort = 'inherit'
        } else {
            $effortCombo.IsEnabled = $true
            $effortLabels = New-Object 'System.Collections.Generic.List[string]'
            foreach ($ri in $effortItemsResolved) {
                if ($ri.Id -and -not $effortLabels.Contains([string]$ri.Id)) {
                    [void]$effortLabels.Add([string]$ri.Id)
                }
            }
            $hasExplicitNonConfig = ($null -ne $matchedModelEntry -and $matchedModelEntry.PSObject.Properties['configurable_effort'] -and (-not [bool]$matchedModelEntry.configurable_effort))
            $hasThinkingSiblingSupport = ($null -ne $siblingThinkingEntry) -and (
                $siblingHasEfforts -or (-not ($siblingThinkingEntry.PSObject.Properties['configurable_effort'] -and (-not [bool]$siblingThinkingEntry.configurable_effort)))
            )
            $isExplicitFastOrFixed = ($activeSlug -match '(-fast$|^research$|4o-mini|gpt-4-5)') -or
                                     ($null -ne $matchedModelEntry -and $matchedModelEntry.PSObject.Properties['fixed_effort'] -and [bool]$matchedModelEntry.fixed_effort) -or
                                     ($hasExplicitNonConfig -and -not $hasThinkingSiblingSupport)
            $isFixedEffortModel = ($effortLabels.Count -eq 0 -and $isExplicitFastOrFixed)
            if ($effortLabels.Count -eq 0 -and -not $isFixedEffortModel -and -not $isColdStartNoWebModel) {
                if ($activeSlug -match '-pro$') {
                    foreach ($stdId in @('standard', 'max')) { [void]$effortLabels.Add($stdId) }
                } elseif ($activeSlug -match '-instant$') {
                    foreach ($stdId in @('none', 'min', 'standard', 'extended', 'max')) { [void]$effortLabels.Add($stdId) }
                } else {
                    foreach ($stdId in @('min', 'standard', 'extended', 'max')) { [void]$effortLabels.Add($stdId) }
                }
            } elseif (-not $isFixedEffortModel -and $activeSlug -match '-instant$' -and -not $effortLabels.Contains('none')) {
                $effortLabels.Insert(0, 'none')
            }

            $effortCombo.ToolTip = if ($isFixedEffortModel) {
                '当前所选模型使用固定思考强度，无需额外切换档位'
            } else {
                "选择本任务的推理思考强度（默认继承原网页当前强度：$webEffortDisplay）"
            }
            $effortCombo.Items.Clear()
            $defaultEffortItem = New-Object Windows.Controls.ComboBoxItem
            $defaultEffortItem.Content = if ($isFixedEffortModel) {
                if ($IsNarrow) { '🧠 固定' } else { '🧠 默认 (当前模型固定)' }
            } else {
                if ($IsNarrow) { '🧠 默认' } else { "🧠 默认 ($webEffortDisplay)" }
            }
            $defaultEffortItem.Tag = 'inherit'
            [void]$effortCombo.Items.Add($defaultEffortItem)

            if (-not $isFixedEffortModel) {
                foreach ($el in $effortLabels) {
                    $ebItem = New-Object Windows.Controls.ComboBoxItem
                    $ebItem.Content = "🧠 $el"
                    $ebItem.Tag = $el
                    [void]$effortCombo.Items.Add($ebItem)
                }
            }

            # Never carry an unsupported effort across model switches; migrate any legacy Chinese effort into its raw official English ID.
            $curEffTrim = ([string]$CurEffort).Trim()
            $normalizedEffort = if ($curEffTrim) {
                & $resolveRawEffortId $curEffTrim @($effortLabels)
            } else { '' }
            $effectiveEffort = if ($normalizedEffort -and $normalizedEffort -ne 'inherit' -and -not $isFixedEffortModel -and $effortLabels.Contains($normalizedEffort)) {
                $normalizedEffort
            } else { 'inherit' }
            if ($effectiveEffort -ne $CurEffort) {
                $CurEffort = $effectiveEffort
                if ((-not $FromBackgroundPoll) -and $StateInfo.PSObject.Properties['TaskKey'] -and $StateInfo.TaskKey -and $script:context) {
                    [void](Set-TaskComposerConfig -Context $script:context -SessionKey $StateInfo.TaskKey -ReasoningEffort $effectiveEffort)
                    if ($StateInfo.Session) { Set-SessionPropSafe $StateInfo.Session 'ReasoningEffort' $effectiveEffort }
                }
            }
        }
    }
    }

    if (-not $modelCombo.IsDropDownOpen) {
        $targetMIdx = -1
        for ($i = 0; $i -lt $modelCombo.Items.Count; $i++) {
            $it = $modelCombo.Items[$i]
            if (-not $it -or [string]$it.Tag -like '__group_*') { continue }
            $itProv = Resolve-UiPlatformCode ([string]$it.ToolTip)
            if ($itProv -eq $activeProvider -and ([string]$it.Tag -eq $CurModel -or [string]$it.Content -eq "🤖 $CurModel")) {
                $targetMIdx = $i
                break
            }
        }
        if ($targetMIdx -lt 0) {
            for ($i = 0; $i -lt $modelCombo.Items.Count; $i++) {
                $it = $modelCombo.Items[$i]
                if (-not $it -or [string]$it.Tag -like '__group_*') { continue }
                if ((Resolve-UiPlatformCode ([string]$it.ToolTip)) -eq $activeProvider -and [string]$it.Tag -eq 'inherit') {
                    $targetMIdx = $i
                    break
                }
            }
        }
        if ($targetMIdx -lt 0) {
            for ($i = 0; $i -lt $modelCombo.Items.Count; $i++) {
                $it = $modelCombo.Items[$i]
                if ($it -and [string]$it.Tag -notlike '__group_*') {
                    $targetMIdx = $i
                    break
                }
            }
        }
        if ($targetMIdx -ge 0 -and $modelCombo.SelectedIndex -ne $targetMIdx) {
            $modelCombo.SelectedIndex = $targetMIdx
        }
    }
    if (-not $effortCombo.IsDropDownOpen) {
        $targetEIdx = 0
        for ($i = 0; $i -lt $effortCombo.Items.Count; $i++) {
            $it = $effortCombo.Items[$i]
            if ($it -and [string]$it.Tag -eq $CurEffort) {
                $targetEIdx = $i
                break
            }
        }
        if ($effortCombo.SelectedIndex -ne $targetEIdx) {
            $effortCombo.SelectedIndex = $targetEIdx
        }
    }
    } finally {
        $script:suppressComposerEvents = $previousSuppress
    }
}

function Resolve-ComposerCatalogState($SessionObj, $RawState) {
    if ($SessionObj -and $SessionObj.PSObject.Properties['AvailableModelsByProvider'] -and $null -ne $SessionObj.AvailableModelsByProvider) {
        return [pscustomobject]@{ available_models_by_provider = $SessionObj.AvailableModelsByProvider; connected_providers = @($SessionObj.ConnectedProviders) }
    }
    # Legacy session snapshots expose only AvailableModels; absence of online metadata is unknown, not disconnected.
    if ($SessionObj -and -not $RawState) {
        return [pscustomobject]@{ available_models_by_provider = $null; connected_providers = $null }
    }
    $connected = New-Object 'System.Collections.Generic.List[string]'
    if ($RawState -and $RawState.PSObject.Properties['tabs'] -and $RawState.tabs) {
        foreach ($entry in $RawState.tabs.PSObject.Properties) {
            $tab = $entry.Value
            if (-not $tab -or -not $tab.PSObject.Properties['last_seen_at']) { continue }
            try { $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$tab.last_seen_at)).TotalSeconds } catch { continue }
            if ($age -gt 15 -or $age -lt -5) { continue }
            $provider = Get-WebRoomProvider $tab
            if (-not $connected.Contains($provider)) { $connected.Add($provider) }
        }
    }
    return [pscustomobject]@{ available_models_by_provider = $(if ($RawState -and $RawState.PSObject.Properties['available_models_by_provider']) { $RawState.available_models_by_provider } else { $null }); connected_providers = @($connected) }
}

function Build-PlanBComposerPod($SessionObj = $null, [bool]$IsNarrow = $false, [bool]$IsZeroTask = $false, [int]$PaneId = 0, [switch]$InPlaceUpdate) {
    $taskKey = if ($IsZeroTask -or -not $SessionObj) { '__new_task__' } else { [string]$SessionObj.SessionKey }
    $draftObj = Get-TaskDraftState $taskKey

    # Cleanup 3: When $SessionObj is present, trust $SessionObj properties directly without redundant disk reads on UI thread
    $wbState = $null
    $curBinding = $null
    $autoCfg = $null
    if ($IsZeroTask -or -not $SessionObj) {
        $autoCfg = Get-AutoResendConfig $script:context
        $wbState = Get-WebBridgeState $script:context
        if ($wbState.session_bindings -and $wbState.session_bindings.PSObject.Properties[$taskKey]) {
            $curBinding = $wbState.session_bindings.$taskKey
        }
    }

    $catalogState = Resolve-ComposerCatalogState $SessionObj $wbState

    $rawMode = if ($IsZeroTask) { 'new_window' }
               elseif ($SessionObj -and $SessionObj.PSObject.Properties['TargetMode'] -and $SessionObj.TargetMode) { [string]$SessionObj.TargetMode }
               elseif ($curBinding -and $curBinding.PSObject.Properties['target_mode'] -and $curBinding.target_mode) { [string]$curBinding.target_mode }
               else { 'follow_window' }
    $curTargetMode = if ($rawMode -eq 'new_window') { 'new_window' } else { 'follow_window' }

    $curModel = if ($SessionObj -and $SessionObj.PSObject.Properties['TargetModel'] -and $SessionObj.TargetModel) { [string]$SessionObj.TargetModel }
                elseif ($curBinding -and $curBinding.PSObject.Properties['target_model'] -and $curBinding.target_model) { [string]$curBinding.target_model }
                else { 'inherit' }
    $webModel = if ($SessionObj -and $SessionObj.PSObject.Properties['WebCurrentModel'] -and $SessionObj.WebCurrentModel) { [string]$SessionObj.WebCurrentModel } else { '' }

    $curEffort = if ($SessionObj -and $SessionObj.PSObject.Properties['ReasoningEffort'] -and $SessionObj.ReasoningEffort) { [string]$SessionObj.ReasoningEffort }
                 elseif ($curBinding -and $curBinding.PSObject.Properties['reasoning_effort'] -and $curBinding.reasoning_effort) { [string]$curBinding.reasoning_effort }
                 else { 'inherit' }
    $webEffort = if ($SessionObj -and $SessionObj.PSObject.Properties['WebCurrentEffort'] -and $SessionObj.WebCurrentEffort) { [string]$SessionObj.WebCurrentEffort } else { '' }

    $availModels = @(if ($SessionObj -and $SessionObj.PSObject.Properties['AvailableModels'] -and $SessionObj.AvailableModels) {
        $SessionObj.AvailableModels
    } elseif ($script:display -and $script:display.PSObject.Properties['AvailableModels'] -and $script:display.AvailableModels) {
        $script:display.AvailableModels
    })

    $availProfsForDefault = @(Get-AvailableBrowserProfiles -Context $script:context)
    $defaultProfObj = $availProfsForDefault | Where-Object { $_.IsDefault } | Select-Object -First 1
    $defaultProfId = if ($defaultProfObj -and $defaultProfObj.Id) { [string]$defaultProfObj.Id } else { Resolve-RelayBrowserProfile '' $script:context }
    $curBrowserProf = if ($SessionObj -and $SessionObj.PSObject.Properties['BrowserProfile'] -and $SessionObj.BrowserProfile) { [string]$SessionObj.BrowserProfile }
                      elseif ($curBinding -and $curBinding.PSObject.Properties['user_locked_browser'] -and $curBinding.user_locked_browser -and $curBinding.PSObject.Properties['browser_profile'] -and $curBinding.browser_profile) { [string]$curBinding.browser_profile }
                      elseif (-not $IsZeroTask -and $curBinding -and $curBinding.PSObject.Properties['browser_profile'] -and $curBinding.browser_profile) { [string]$curBinding.browser_profile }
                      else { $defaultProfId }
    $curBrowserProf = Resolve-RelayBrowserProfile $curBrowserProf $script:context
    if ((-not $SessionObj) -and $wbState) {
        if ($curBrowserProf -and $wbState.PSObject.Properties['available_models_by_profile'] -and $wbState.available_models_by_profile -and $wbState.available_models_by_profile.PSObject.Properties[$curBrowserProf]) {
            $profSpecificModels = @($wbState.available_models_by_profile.$curBrowserProf)
            if ($profSpecificModels.Count -gt 0) { $availModels = $profSpecificModels }
        }
        if (-not $webModel -and $wbState.PSObject.Properties['tabs'] -and $wbState.tabs) {
            foreach ($tp in $wbState.tabs.PSObject.Properties) {
                $tv = $tp.Value
                if ($tv -and $tv.PSObject.Properties['browser_profile'] -and [string]$tv.browser_profile -eq $curBrowserProf -and $tv.PSObject.Properties['current_model'] -and $tv.current_model) {
                    $webModel = [string]$tv.current_model
                    if (-not $webEffort -and $tv.PSObject.Properties['current_effort'] -and $tv.current_effort) { $webEffort = [string]$tv.current_effort }
                    break
                }
            }
        }
    }

    $effAutoResend = if ($SessionObj -and $SessionObj.PSObject.Properties['AutoResendEnabled'] -and $null -ne $SessionObj.AutoResendEnabled) { [bool]$SessionObj.AutoResendEnabled }
                     elseif ($SessionObj -and $SessionObj.PSObject.Properties['AutoWakeupEnabled'] -and $null -ne $SessionObj.AutoWakeupEnabled) { [bool]$SessionObj.AutoWakeupEnabled }
                     elseif ($curBinding -and $curBinding.PSObject.Properties['auto_resend_enabled'] -and $null -ne $curBinding.auto_resend_enabled) { [bool]$curBinding.auto_resend_enabled }
                     elseif ($autoCfg) { [bool]$autoCfg.Enabled }
                     else { $false }
    $curStallMins = if ($SessionObj -and $SessionObj.PSObject.Properties['StallMinutes'] -and [double]$SessionObj.StallMinutes -gt 0) { [double]$SessionObj.StallMinutes }
                    elseif ($curBinding -and $curBinding.PSObject.Properties['stall_minutes'] -and [double]$curBinding.stall_minutes -gt 0) { [double]$curBinding.stall_minutes }
                    elseif ($autoCfg) { [double]$autoCfg.StallMinutes }
                    else { 3 }
    $curStallSecs = if ($SessionObj -and $SessionObj.PSObject.Properties['StallSeconds'] -and [int]$SessionObj.StallSeconds -gt 0 -and [int]$SessionObj.StallSeconds -lt 60) { [int]$SessionObj.StallSeconds }
                    elseif ($SessionObj -and $SessionObj.PSObject.Properties['StallMinutes'] -and [double]$SessionObj.StallMinutes -gt 0) { [int][Math]::Round([double]$SessionObj.StallMinutes * 60) }
                    elseif ($curBinding -and $curBinding.PSObject.Properties['stall_seconds'] -and [int]$curBinding.stall_seconds -gt 0) { [int]$curBinding.stall_seconds }
                    elseif ($autoCfg -and $autoCfg.PSObject.Properties['StallSeconds'] -and [int]$autoCfg.StallSeconds -gt 0) { [int]$autoCfg.StallSeconds }
                    else { [int][Math]::Round($curStallMins * 60) }
    $curMaxRetries = if ($SessionObj -and $SessionObj.PSObject.Properties['MaxRetries'] -and [int]$SessionObj.MaxRetries -gt 0) { [int]$SessionObj.MaxRetries }
                     elseif ($curBinding -and $curBinding.PSObject.Properties['max_retries'] -and [int]$curBinding.max_retries -gt 0) { [int]$curBinding.max_retries }
                     elseif ($autoCfg -and $autoCfg.PSObject.Properties['MaxRetries'] -and [int]$autoCfg.MaxRetries -gt 0) { [int]$autoCfg.MaxRetries }
                     else { 1 }
    $curStallKey = if ($curStallSecs -le 45) { '30s' } elseif ($curStallSecs -ge 240) { '5' } else { '3' }
    $curRetryKey = if ($curMaxRetries -ge 3) { '3' } elseif ($curMaxRetries -eq 2) { '2' } else { '1' }

    $seededCarrierByProv = @{}
    foreach ($carrierMapSrc in @(
        $(if ($SessionObj -and $SessionObj.PSObject.Properties['CarrierByProvider']) { $SessionObj.CarrierByProvider }),
        $(if ($SessionObj -and $SessionObj.PSObject.Properties['carrier_by_provider']) { $SessionObj.carrier_by_provider }),
        $(if ($curBinding -and $curBinding.PSObject.Properties['carrier_by_provider']) { $curBinding.carrier_by_provider })
    )) {
        if (-not $carrierMapSrc) { continue }
        if ($carrierMapSrc -is [System.Collections.IDictionary]) {
            foreach ($ck in $carrierMapSrc.Keys) {
                if ($ck -and $carrierMapSrc[$ck]) { $seededCarrierByProv[(Resolve-UiPlatformCode ([string]$ck))] = [string]$carrierMapSrc[$ck] }
            }
        } else {
            foreach ($cp in $carrierMapSrc.PSObject.Properties) {
                if ($cp.Name -and $cp.Value) { $seededCarrierByProv[(Resolve-UiPlatformCode ([string]$cp.Name))] = [string]$cp.Value }
            }
        }
    }
    $resolvedInitialProv = Resolve-UiPlatformCode $(if ($SessionObj -and $SessionObj.PSObject.Properties['Provider'] -and $SessionObj.Provider) { [string]$SessionObj.Provider } elseif ($curBinding) { Get-WebRoomProvider $curBinding } else { 'chatgpt' })
    if ($curBrowserProf -and -not $seededCarrierByProv.ContainsKey($resolvedInitialProv)) {
        if (-not ($resolvedInitialProv -in @('gemini', 'claude') -and $curBrowserProf -like 'Desktop:*')) {
            $seededCarrierByProv[$resolvedInitialProv] = $curBrowserProf
        }
    }

    $podCacheKey = "$PaneId|$taskKey|$IsZeroTask"
    if ($script:composerPodCache -and $script:composerPodCache.ContainsKey($podCacheKey)) {
        $cachedBorder = $script:composerPodCache[$podCacheKey]
        if ($cachedBorder) {
            if ((-not $InPlaceUpdate) -and $cachedBorder.Parent -is [Windows.Controls.Panel]) {
                [void]$cachedBorder.Parent.Children.Remove($cachedBorder)
            }
            $script:suppressComposerEvents = $true
            try {
                if ($cachedBorder.Tag) {
                    $st = $cachedBorder.Tag
                    $lockActive = Test-ComposerOptimisticLockActive $st
                    $st.Session = $SessionObj
                    $st.DraftObj = $draftObj
                    $st.ConnectedProviders = $catalogState.connected_providers
                    $st.AvailableModelsByProvider = $catalogState.available_models_by_provider
                    $st.WebModel = $webModel
                    $st.WebEffort = $webEffort
                    if ($st.IsNarrow -ne $IsNarrow) {
                        $st.IsNarrow = $IsNarrow
                        if ($st.BtnFollowSeg) { $st.BtnFollowSeg.Content = if ($IsNarrow) { '原窗' } else { '跟随原窗口' } }
                        if ($st.BtnNewWinSeg) { $st.BtnNewWinSeg.Content = if ($IsNarrow) { '新窗交接' } else { '新建网页交接' } }
                        if ($st.ModelCombo) { $st.ModelCombo.MaxWidth = if ($IsNarrow) { 125 } else { 185 } }
                        if ($st.EffortCombo) { $st.EffortCombo.MaxWidth = if ($IsNarrow) { 96 } else { 130 } }
                        if ($st.ProfCombo) { $st.ProfCombo.MaxWidth = if ($IsNarrow) { 142 } else { 165 } }
                        if ($st.AutoResendChk) { $st.AutoResendChk.Content = if ($IsNarrow) { '重发' } else { '自动重发' } }
                        if ($st.RuleCombo) {
                            $st.RuleCombo.MaxWidth = if ($IsNarrow) { 82 } else { 118 }
                            if ($st.RuleCombo.Items.Count -ge 3) {
                                $st.RuleCombo.Items[0].Content = if ($IsNarrow) { '30秒(测)' } else { '停顿 30 秒 (测试)' }
                                $st.RuleCombo.Items[1].Content = if ($IsNarrow) { '停顿 3m' } else { '停顿 3 分钟' }
                                $st.RuleCombo.Items[2].Content = if ($IsNarrow) { '停顿 5m' } else { '停顿 5 分钟' }
                            }
                        }
                        if ($st.RetryCombo) {
                            $st.RetryCombo.MaxWidth = if ($IsNarrow) { 58 } else { 78 }
                            if ($st.RetryCombo.Items.Count -ge 3) {
                                $st.RetryCombo.Items[0].Content = if ($IsNarrow) { '1次' } else { '重试 1 次' }
                                $st.RetryCombo.Items[1].Content = if ($IsNarrow) { '2次' } else { '重试 2 次' }
                                $st.RetryCombo.Items[2].Content = if ($IsNarrow) { '3次' } else { '重试 3 次' }
                            }
                        }
                    }
                    if ($st.InputBox -and -not $st.InputBox.IsKeyboardFocused -and $st.InputBox.Text -ne [string]$draftObj.DraftText) {
                        $st.InputBox.Text = [string]$draftObj.DraftText
                    }
                    if (-not $lockActive) {
                        $st.TargetMode = $curTargetMode
                        $st.Provider = $resolvedInitialProv
                        if ($seededCarrierByProv.Count -gt 0) {
                            if (-not ($st.PSObject.Properties['CarrierByProvider'] -and $st.CarrierByProvider -is [hashtable])) {
                                Set-SessionPropSafe $st 'CarrierByProvider' @{}
                            }
                            foreach ($sk in $seededCarrierByProv.Keys) {
                                $st.CarrierByProvider[$sk] = $seededCarrierByProv[$sk]
                            }
                        }
                        Sync-ComposerModelAndEffortCombos -StateInfo $st -AvailModels $availModels -CurModel $curModel -WebModel $webModel -CurEffort $curEffort -WebEffort $webEffort -IsNarrow $IsNarrow -FromBackgroundPoll
                        [void](Sync-ComposerCarrierCombo -StateInfo $st -AvailCarriers $availProfsForDefault -PreferredCarrier $curBrowserProf)
                        if ($st.AutoResendChk) {
                            $st.AutoResendChk.IsChecked = $effAutoResend
                        }
                        if ($st.RuleCombo -and -not $st.RuleCombo.IsDropDownOpen) {
                            $sk = $curStallKey
                            for ($i = 0; $i -lt $st.RuleCombo.Items.Count; $i++) {
                                if ($st.RuleCombo.Items[$i].Tag -eq $sk) { $st.RuleCombo.SelectedIndex = $i; break }
                            }
                        }
                        if ($st.RetryCombo -and -not $st.RetryCombo.IsDropDownOpen) {
                            $rk = $curRetryKey
                            for ($i = 0; $i -lt $st.RetryCombo.Items.Count; $i++) {
                                if ($st.RetryCombo.Items[$i].Tag -eq $rk) { $st.RetryCombo.SelectedIndex = $i; break }
                            }
                        }
                    } else {
                        $lockedM = if ($st.ModelCombo -and $st.ModelCombo.SelectedItem -and $st.ModelCombo.SelectedItem.Tag) { [string]$st.ModelCombo.SelectedItem.Tag } else { $curModel }
                        $lockedE = if ($st.EffortCombo -and $st.EffortCombo.SelectedItem -and $st.EffortCombo.SelectedItem.Tag) { [string]$st.EffortCombo.SelectedItem.Tag } else { $curEffort }
                        Sync-ComposerModelAndEffortCombos -StateInfo $st -AvailModels $availModels -CurModel $lockedM -WebModel $webModel -CurEffort $lockedE -WebEffort $webEffort -IsNarrow $IsNarrow -FromBackgroundPoll
                    }
                    Update-ComposerPodState $st
                }
            } finally {
                $script:suppressComposerEvents = $false
            }
            return $cachedBorder
        }
    }

    $composeBorder = New-Object Windows.Controls.Border
    if ($IsZeroTask) {
        $composeBorder.Background = ConvertTo-Brush '#FFFFFF'
        $composeBorder.BorderThickness = [Windows.Thickness]::new(0)
        $composeBorder.Padding = [Windows.Thickness]::new(22, 0, 22, 24)
        $composeBorder.VerticalAlignment = 'Top'
    } else {
        $composeBorder.Background = ConvertTo-Brush '#FAFAFA'
        $composeBorder.BorderBrush = ConvertTo-Brush '#F1F1F4'
        $composeBorder.BorderThickness = [Windows.Thickness]::new(0, 1, 0, 0)
        $composeBorder.Padding = [Windows.Thickness]::new(14, 10, 14, 12)
    }

    $composerPod = New-Object Windows.Controls.Border
    $composerPod.Background = ConvertTo-Brush '#FFFFFF'
    $composerPod.BorderBrush = ConvertTo-Brush '#D4D4D8'
    $composerPod.BorderThickness = [Windows.Thickness]::new(1)
    $composerPod.CornerRadius = [Windows.CornerRadius]::new(12)
    $composerPod.Padding = if ($IsZeroTask) { [Windows.Thickness]::new(14, 12, 12, 10) } else { [Windows.Thickness]::new(12, 8, 10, 8) }

    $podStack = New-Object Windows.Controls.StackPanel

    # Upper Area: Borderless Input Box + Dynamic Placeholder
    $inputHost = New-Object Windows.Controls.Grid
    $inputHost.Margin = if ($IsZeroTask) { [Windows.Thickness]::new(0, 0, 0, 10) } else { [Windows.Thickness]::new(0, 0, 0, 8) }
    if ($IsZeroTask) { $inputHost.MinHeight = 72 }

    $inputBox = New-Object Windows.Controls.TextBox
    $inputBox.FontSize = if ($IsZeroTask) { 13.5 } else { 13 }
    $inputBox.Padding = if ($IsZeroTask) { [Windows.Thickness]::new(2, 2, 6, 4) } else { [Windows.Thickness]::new(2, 4, 6, 4) }
    $inputBox.Foreground = ConvertTo-Brush '#18181B'
    $inputBox.CaretBrush = ConvertTo-Brush '#18181B'
    $inputBox.Background = ConvertTo-Brush 'Transparent'
    $inputBox.BorderThickness = [Windows.Thickness]::new(0)
    $inputBox.VerticalContentAlignment = if ($IsZeroTask) { 'Top' } else { 'Center' }
    if ($IsZeroTask) {
        $inputBox.MinHeight = 68
        $inputBox.MaxHeight = 160
        $inputBox.TextWrapping = 'Wrap'
    }
    $inputBox.Text = [string]$draftObj.DraftText

    $placeholder = New-Object Windows.Controls.TextBlock
    $placeholder.FontSize = if ($IsZeroTask) { 13 } else { 12.5 }
    $placeholder.Foreground = ConvertTo-Brush '#A1A1AA'
    $placeholder.Margin = if ($IsZeroTask) { [Windows.Thickness]::new(4, 3, 8, 0) } else { [Windows.Thickness]::new(4, 0, 8, 0) }
    $placeholder.VerticalAlignment = if ($IsZeroTask) { 'Top' } else { 'Center' }
    $placeholder.IsHitTestVisible = $false
    $placeholder.TextTrimming = 'CharacterEllipsis'
    $placeholder.TextWrapping = 'NoWrap'

    [void]$inputHost.Children.Add($inputBox)
    [void]$inputHost.Children.Add($placeholder)
    [void]$podStack.Children.Add($inputHost)

    # Lower Area: Single-Line 6-Control Bar (Left Horizontal StackPanel + Right Primary Send Button, NoWrap)
    $bottomBarGrid = New-Object Windows.Controls.Grid
    $bbc0 = New-Object Windows.Controls.ColumnDefinition; $bbc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $bbc1 = New-Object Windows.Controls.ColumnDefinition; $bbc1.Width = [Windows.GridLength]::Auto
    [void]$bottomBarGrid.ColumnDefinitions.Add($bbc0); [void]$bottomBarGrid.ColumnDefinitions.Add($bbc1)

    $pillsRow = New-Object Windows.Controls.WrapPanel
    $pillsRow.Orientation = 'Horizontal'
    $pillsRow.VerticalAlignment = 'Center'

    # Pill 1: Mode Segmented Toggle [跟随原窗口 | 新建网页交接]
    $segGroup = New-Object Windows.Controls.Border
    $segGroup.Background = ConvertTo-Brush '#F4F4F5'
    $segGroup.BorderBrush = ConvertTo-Brush '#E4E4E7'
    $segGroup.BorderThickness = [Windows.Thickness]::new(1)
    $segGroup.CornerRadius = [Windows.CornerRadius]::new(7)
    $segGroup.Padding = [Windows.Thickness]::new(2, 2, 2, 2)
    $segGroup.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
    $segGroup.VerticalAlignment = 'Center'

    $segStack = New-Object Windows.Controls.StackPanel
    $segStack.Orientation = 'Horizontal'

    $btnFollowSeg = New-Object Windows.Controls.Button
    $btnFollowSeg.Content = if ($IsNarrow) { '原窗' } else { '跟随原窗口' }
    $btnFollowSeg.Padding = [Windows.Thickness]::new(6, 2, 6, 2)
    $btnFollowSeg.MinHeight = 22
    $btnFollowSeg.FontSize = 11
    $btnFollowSeg.ToolTip = '发往当前任务绑定的原 ChatGPT 网页窗口；留空发送“请继续”，输入文字则原样发送'

    $btnNewWinSeg = New-Object Windows.Controls.Button
    $btnNewWinSeg.Content = if ($IsNarrow) { '新窗交接' } else { '新建网页交接' }
    $btnNewWinSeg.Padding = [Windows.Thickness]::new(6, 2, 6, 2)
    $btnNewWinSeg.MinHeight = 22
    $btnNewWinSeg.FontSize = 11
    $btnNewWinSeg.ToolTip = '在选定浏览器中开启新 ChatGPT 窗口，并自动注入本任务的完整进度交接单'

    [void]$segStack.Children.Add($btnFollowSeg)
    [void]$segStack.Children.Add($btnNewWinSeg)
    $segGroup.Child = $segStack
    $segGroup.Visibility = if ($IsZeroTask) { 'Collapsed' } else { 'Visible' }
    [void]$pillsRow.Children.Add($segGroup)

    # Pill 2: Model Capsule [🤖 模型 ⌄] (Dynamically populated from /backend-api/models)
    $modelCombo = New-Object Windows.Controls.ComboBox
    $modelCombo.Margin = [Windows.Thickness]::new(0, 2, 5, 2)
    $modelCombo.MaxWidth = if ($IsNarrow) { 125 } else { 185 }
    [void]$pillsRow.Children.Add($modelCombo)

    # Pill 3: Reasoning Effort Capsule [🧠 强度 ⌄] (Dynamically linked to selected model's efforts)
    $effortCombo = New-Object Windows.Controls.ComboBox
    $effortCombo.Margin = [Windows.Thickness]::new(0, 2, 5, 2)
    $effortCombo.MaxWidth = if ($IsNarrow) { 96 } else { 130 }
    [void]$pillsRow.Children.Add($effortCombo)

    # Pill 4: Browser Profile Capsule [🌐 浏览器 ⌄] (Per-task locked, never overwritten by background poll)
    $profCombo = New-Object Windows.Controls.ComboBox
    $profCombo.Margin = [Windows.Thickness]::new(0, 2, 6, 2)
    $profCombo.MaxWidth = if ($IsNarrow) { 142 } else { 165 }
    $profCombo.ToolTip = '按任务独立绑定目标浏览器（切换浏览器后，下次发送将自动携带进度账本在新浏览器中交接续跑）'
    $availProfs = $availProfsForDefault
    [void]$pillsRow.Children.Add($profCombo)

    # Pill 5: Auto-Resend CheckBox + Decoupled [停顿时间 ⌄] + [重试次数 ⌄] Capsules
    $autoResendChk = New-Object Windows.Controls.CheckBox
    $autoResendChk.Content = if ($IsNarrow) { '重发' } else { '自动重发' }
    $autoResendChk.IsChecked = $effAutoResend
    $autoResendChk.FontSize = 11
    $autoResendChk.FontWeight = 'SemiBold'
    $autoResendChk.Foreground = ConvertTo-Brush '#3F3F46'
    $autoResendChk.VerticalAlignment = 'Center'
    $autoResendChk.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
    $autoResendChk.ToolTip = '按任务独立开启或关闭停顿自动重发守护'

    $ruleCombo = New-Object Windows.Controls.ComboBox
    $ruleCombo.MaxWidth = if ($IsNarrow) { 82 } else { 118 }
    $ruleCombo.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
    $ruleCombo.ToolTip = '选择停顿多久后自动触发重发（默认停顿 3 分钟）'
    $stallPresets = @(
        @{ Key = '30s'; Secs = 30;  Mins = 0.5; Label = $(if ($IsNarrow) { '30秒(测)' } else { '停顿 30 秒 (测试)' }) },
        @{ Key = '3';   Secs = 180; Mins = 3;   Label = $(if ($IsNarrow) { '停顿 3m' } else { '停顿 3 分钟' }) },
        @{ Key = '5';   Secs = 300; Mins = 5;   Label = $(if ($IsNarrow) { '停顿 5m' } else { '停顿 5 分钟' }) }
    )
    $ruleSelIdx = 1
    for ($si = 0; $si -lt $stallPresets.Count; $si++) {
        $sp = $stallPresets[$si]
        $sItem = New-Object Windows.Controls.ComboBoxItem
        $sItem.Content = $sp.Label
        $sItem.Tag = $sp.Key
        [void]$ruleCombo.Items.Add($sItem)
        if ($sp.Key -eq $curStallKey) { $ruleSelIdx = $si }
    }
    $ruleCombo.SelectedIndex = $ruleSelIdx

    $retryCombo = New-Object Windows.Controls.ComboBox
    $retryCombo.MaxWidth = if ($IsNarrow) { 58 } else { 78 }
    $retryCombo.ToolTip = '选择原窗口连续唤醒重试几次无果后自动切换新窗口交接（默认重试 1 次）'
    $retryPresets = @(
        @{ Key = '1'; Retries = 1; Label = $(if ($IsNarrow) { '1次' } else { '重试 1 次' }) },
        @{ Key = '2'; Retries = 2; Label = $(if ($IsNarrow) { '2次' } else { '重试 2 次' }) },
        @{ Key = '3'; Retries = 3; Label = $(if ($IsNarrow) { '3次' } else { '重试 3 次' }) }
    )
    $retrySelIdx = 0
    for ($rti = 0; $rti -lt $retryPresets.Count; $rti++) {
        $rtp = $retryPresets[$rti]
        $rtItem = New-Object Windows.Controls.ComboBoxItem
        $rtItem.Content = $rtp.Label
        $rtItem.Tag = $rtp.Key
        [void]$retryCombo.Items.Add($rtItem)
        if ($rtp.Key -eq $curRetryKey) { $retrySelIdx = $rti }
    }
    $retryCombo.SelectedIndex = $retrySelIdx

    $autoResendGroup = New-Object Windows.Controls.StackPanel
    $autoResendGroup.Orientation = 'Horizontal'
    $autoResendGroup.VerticalAlignment = 'Center'
    $autoResendGroup.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
    [void]$autoResendGroup.Children.Add($autoResendChk)
    [void]$autoResendGroup.Children.Add($ruleCombo)
    [void]$autoResendGroup.Children.Add($retryCombo)
    [void]$pillsRow.Children.Add($autoResendGroup)
    [Windows.Controls.Grid]::SetColumn($pillsRow, 0)
    [void]$bottomBarGrid.Children.Add($pillsRow)

    # Pill 6: Primary Send Button (4-State Matrix)
    $sendBtn = New-Object Windows.Controls.Button
    $sendBtn.Padding = [Windows.Thickness]::new(13, 5, 13, 5)
    $sendBtn.MinHeight = 29
    $sendBtn.Height = 30
    $sendBtn.VerticalAlignment = 'Bottom'
    $sendBtn.Margin = [Windows.Thickness]::new(8, 0, 0, 2)
    $sendBtn.Foreground = ConvertTo-Brush '#FEFEFF'

    $sendLbl = New-Object Windows.Controls.TextBlock
    $sendLbl.FontSize = 11.5
    $sendLbl.FontWeight = 'Bold'
    $sendLbl.Foreground = ConvertTo-Brush '#FEFEFF'
    $sendBtn.Content = $sendLbl

    $composerStateInfo = [pscustomobject]@{
        TaskKey = $taskKey
        DraftObj = $draftObj
        InputBox = $inputBox
        Placeholder = $placeholder
        Session = $SessionObj
        SendButton = $sendBtn
        SendLabel = $sendLbl
        SegGroup = $segGroup
        BtnFollowSeg = $btnFollowSeg
        BtnNewWinSeg = $btnNewWinSeg
        ZeroFooterHost = $null
        ModelCombo = $modelCombo
        EffortCombo = $effortCombo
        ProfCombo = $profCombo
        AutoResendChk = $autoResendChk
        RuleCombo = $ruleCombo
        RetryCombo = $retryCombo
        TargetMode = $curTargetMode
        IsZeroTask = $IsZeroTask
        IsNarrow = $IsNarrow
        PodBorder = $composerPod
        LastCatalogSig = ''
        Provider = $resolvedInitialProv
        ConnectedProviders = $catalogState.connected_providers
        AvailableModelsByProvider = $catalogState.available_models_by_provider
        AvailableModels = $availModels
        AvailableCarriers = $availProfs
        CarrierByProvider = $seededCarrierByProv
        BrowserProfile = $curBrowserProf
        CollapsedProviders = @{}
        MutationEpoch = [DateTime]::MinValue
        WebModel = $webModel
        WebEffort = $webEffort
        PaneId = $PaneId
    }

    Sync-ComposerModelAndEffortCombos -StateInfo $composerStateInfo -AvailModels $availModels -CurModel $curModel -WebModel $webModel -CurEffort $curEffort -WebEffort $webEffort -IsNarrow $IsNarrow
    [void](Sync-ComposerCarrierCombo -StateInfo $composerStateInfo -AvailCarriers $availProfs -PreferredCarrier $curBrowserProf)

    $modelCombo.Tag = $composerStateInfo
    $modelCombo.Add_SelectionChanged({
        param($sender, $e)
        if ($script:initializing -or $script:suppressComposerEvents) { return }
        $info = $sender.Tag
        $sel = $sender.SelectedItem
        if (-not $info -or -not $info.TaskKey -or -not $sel -or -not $sel.Tag) { return }
        $newModelVal = [string]$sel.Tag
        if ($newModelVal -like '__group_*') { return }
        $selectedProvider = Resolve-UiPlatformCode ([string]$sel.ToolTip)
        $info.Provider = $selectedProvider
        if ($info.AvailableModelsByProvider -and $info.AvailableModelsByProvider.PSObject.Properties[$selectedProvider]) {
            $info.AvailableModels = @($info.AvailableModelsByProvider.$selectedProvider)
        }
        $curEffVal = if ($selectedProvider -in @('gemini', 'claude')) {
            'inherit'
        } elseif ($newModelVal -match '-instant$') {
            'none'
        } elseif ($info.EffortCombo -and $info.EffortCombo.SelectedItem -and $info.EffortCombo.SelectedItem.Tag) {
            [string]$info.EffortCombo.SelectedItem.Tag
        } else { 'inherit' }
        $resolvedCarrier = ''
        $script:suppressComposerEvents = $true
        try {
            Sync-ComposerModelAndEffortCombos -StateInfo $info -AvailModels $info.AvailableModels -CurModel $newModelVal -WebModel $info.WebModel -CurEffort $curEffVal -WebEffort $info.WebEffort -IsNarrow $info.IsNarrow
            $resolvedCarrier = Sync-ComposerCarrierCombo -StateInfo $info -AvailCarriers $info.AvailableCarriers -PreferredCarrier ([string]$info.BrowserProfile)
        } finally {
            $script:suppressComposerEvents = $false
        }
        $effEffortAfterSync = if ($info.EffortCombo -and $info.EffortCombo.SelectedItem -and $info.EffortCombo.SelectedItem.Tag) {
            [string]$info.EffortCombo.SelectedItem.Tag
        } else { $curEffVal }
        $persistParams = @{
            Context = $script:context
            SessionKey = $info.TaskKey
            TargetModel = $newModelVal
            Provider = $selectedProvider
            ReasoningEffort = $effEffortAfterSync
        }
        if ($resolvedCarrier) { $persistParams['BrowserProfile'] = $resolvedCarrier }
        if ($info.CarrierByProvider -is [hashtable] -and $info.CarrierByProvider.Count -gt 0) {
            $persistParams['CarrierByProvider'] = $info.CarrierByProvider
        }
        [void](Invoke-ComposerPersistence -StateInfo $info -Params $persistParams)
        if ($info.Session) {
            Set-SessionPropSafe $info.Session 'Provider' $selectedProvider
            Set-SessionPropSafe $info.Session 'TargetModel' $newModelVal
            Set-SessionPropSafe $info.Session 'ReasoningEffort' $effEffortAfterSync
            if ($resolvedCarrier) { Set-SessionPropSafe $info.Session 'BrowserProfile' $resolvedCarrier }
        }
        Show-QuickToast "✓ 本任务模型已设为：$($sel.Content)"
    })

    $effortCombo.Tag = $composerStateInfo
    $effortCombo.Add_SelectionChanged({
        param($sender, $e)
        if ($script:initializing -or $script:suppressComposerEvents) { return }
        $info = $sender.Tag
        $sel = $sender.SelectedItem
        if ($info -and $info.TaskKey -and $sel -and $sel.Tag) {
            $newEffortVal = [string]$sel.Tag
            $curMVal = if ($info.ModelCombo -and $info.ModelCombo.SelectedItem -and $info.ModelCombo.SelectedItem.Tag) { [string]$info.ModelCombo.SelectedItem.Tag } else { 'inherit' }
            $effBaseModel = if ($curMVal -and $curMVal -ne 'inherit') { $curMVal } else { [string]$info.WebModel }
            $linkedModelVal = ''
            $thinkingIdSet = @('min', 'minimal', 'light', 'low', 'standard', 'medium', 'extended', 'high', 'max', 'xhigh', 'ultra', '低', '中', '高', '轻度', '标准', '深度', '极高', '最高', '深入', '超强', '极简')
            if ($newEffortVal -in @('none', 'instant', '即时', '未开启思考')) { $newEffortVal = 'none' }
            if ($newEffortVal -in $thinkingIdSet -and $effBaseModel -match '(?i)^(gpt-6|gpt-6-instant|GPT-6|GPT-6 Instant)$') {
                $linkedModelVal = 'gpt-6-thinking'
            } elseif ($newEffortVal -in $thinkingIdSet -and $effBaseModel -match '(?i)^(gpt-5-6|gpt-5-6-instant|GPT-5\.6|GPT-5\.6 Instant)$') {
                $linkedModelVal = 'gpt-5-6-thinking'
            } elseif ($newEffortVal -eq 'none' -and $effBaseModel -match '(?i)^(gpt-6|gpt-6-thinking|GPT-6|GPT-6 Thinking)$') {
                $linkedModelVal = 'gpt-6-instant'
            } elseif ($newEffortVal -eq 'none' -and $effBaseModel -match '(?i)^(gpt-5-6|gpt-5-6-thinking|GPT-5\.6|GPT-5\.6 Thinking)$') {
                $linkedModelVal = 'gpt-5-6-instant'
            }
            if ($linkedModelVal) {
                [void](Invoke-ComposerPersistence -StateInfo $info -Params @{
                    Context = $script:context
                    SessionKey = $info.TaskKey
                    TargetModel = $linkedModelVal
                    ReasoningEffort = $newEffortVal
                })
                if ($info.Session) {
                    Set-SessionPropSafe $info.Session 'TargetModel' $linkedModelVal
                    Set-SessionPropSafe $info.Session 'ReasoningEffort' $newEffortVal
                }
                $script:suppressComposerEvents = $true
                try {
                    Sync-ComposerModelAndEffortCombos -StateInfo $info -AvailModels $info.AvailableModels -CurModel $linkedModelVal -WebModel $info.WebModel -CurEffort $newEffortVal -WebEffort $info.WebEffort -IsNarrow $info.IsNarrow
                } finally {
                    $script:suppressComposerEvents = $false
                }
            } else {
                [void](Invoke-ComposerPersistence -StateInfo $info -Params @{
                    Context = $script:context
                    SessionKey = $info.TaskKey
                    ReasoningEffort = $newEffortVal
                })
                if ($info.Session) { Set-SessionPropSafe $info.Session 'ReasoningEffort' $newEffortVal }
            }
            Show-QuickToast "✓ 本任务推理强度已设为：$($sel.Content)"
        }
    })

    $profCombo.Tag = $composerStateInfo
    $profCombo.Add_SelectionChanged({
        param($sender, $e)
        if ($script:initializing -or $script:suppressComposerEvents) { return }
        $info = $sender.Tag
        $selItem = $sender.SelectedItem
        if ($info -and $info.TaskKey -and $selItem -and $selItem.Tag) {
            $newProfVal = [string]$selItem.Tag
            $curProv = Resolve-UiPlatformCode $(if ($info.PSObject.Properties['Provider'] -and $info.Provider) { [string]$info.Provider } else { 'chatgpt' })
            if (-not ($info.PSObject.Properties['CarrierByProvider'] -and $info.CarrierByProvider -is [hashtable])) {
                Set-SessionPropSafe $info 'CarrierByProvider' @{}
            }
            $info.CarrierByProvider[$curProv] = $newProfVal
            $info.BrowserProfile = $newProfVal
            [void](Invoke-ComposerPersistence -StateInfo $info -Params @{
                Context = $script:context
                SessionKey = $info.TaskKey
                Provider = $curProv
                BrowserProfile = $newProfVal
                CarrierByProvider = $info.CarrierByProvider
            })
            if ($info.Session) { Set-SessionPropSafe $info.Session 'BrowserProfile' $newProfVal }
            Show-QuickToast "✓ 本任务浏览器已独立锁定为：$($selItem.Content)（下次发送自动无缝交接）"
        }
    })

    $saveRuleHandler = {
        param($sender, $e)
        if ($script:initializing -or $script:suppressComposerEvents) { return }
        $info = $sender.Tag
        if (-not $info) { return }
        $en = [bool]$info.AutoResendChk.IsChecked
        $stallTag = if ($info.RuleCombo -and $info.RuleCombo.SelectedItem -and $info.RuleCombo.SelectedItem.Tag) { [string]$info.RuleCombo.SelectedItem.Tag } else { '3' }
        $retryTag = if ($info.RetryCombo -and $info.RetryCombo.SelectedItem -and $info.RetryCombo.SelectedItem.Tag) { [string]$info.RetryCombo.SelectedItem.Tag } else { '1' }
        $rVal = [Math]::Max(1, [Math]::Min(3, [int]$retryTag))
        if ($stallTag -match '^(\d+)s$') {
            $sVal = [int]$Matches[1]
            $mVal = [Math]::Round($sVal / 60.0, 2)
            [void](Invoke-ComposerPersistence -StateInfo $info -Params @{
                Context = $script:context
                SessionKey = $info.TaskKey
                AutoResendEnabled = $en
                StallSeconds = $sVal
                MaxRetries = $rVal
            })
            $stallToastLabel = "$sVal 秒 (测试)"
        } else {
            $mVal = [int]$stallTag
            $sVal = $mVal * 60
            [void](Invoke-ComposerPersistence -StateInfo $info -Params @{
                Context = $script:context
                SessionKey = $info.TaskKey
                AutoResendEnabled = $en
                StallSeconds = $sVal
                StallMinutes = $mVal
                MaxRetries = $rVal
            })
            $stallToastLabel = "$mVal 分钟"
        }
        if ($info.Session) {
            Set-SessionPropSafe $info.Session 'AutoResendEnabled' $en
            Set-SessionPropSafe $info.Session 'AutoWakeupEnabled' $en
            Set-SessionPropSafe $info.Session 'StallMinutes' $mVal
            Set-SessionPropSafe $info.Session 'StallSeconds' $sVal
            Set-SessionPropSafe $info.Session 'MaxRetries' $rVal
        }
        try {
            if ($script:controls -and $script:controls.PanesHostGrid -and $script:controls.PanesHostGrid.Children.Count -gt 0) {
                foreach ($child in @($script:controls.PanesHostGrid.Children)) {
                    if ($child -and $child.Tag -and $child.Tag.PSObject.Properties['StreamHost'] -and $child.Tag.StreamHost -and $child.Tag.StreamHost.Tag) {
                        $sr = $child.Tag.StreamHost.Tag
                        if ($info.Session -and ($child.Tag.PaneId -eq $info.PaneId -or $child.Tag.MatchedSessionKey -eq $info.TaskKey)) {
                            Update-PaneStatusPillVisual -StatusPill $sr.StatusPill -SDot $sr.StatusDot -SLabel $sr.StatusLabel -SessionObj $info.Session
                        }
                    }
                }
            }
        } catch { }
        Show-QuickToast $(if ($en) { "✓ 本任务自动重发已设为：停顿 $stallToastLabel · 重试 $rVal 次" } else { '✓ 已关闭本任务自动重发守护' })
    }
    $autoResendChk.Tag = $composerStateInfo
    $ruleCombo.Tag = $composerStateInfo
    $retryCombo.Tag = $composerStateInfo
    $autoResendChk.Add_Checked($saveRuleHandler)
    $autoResendChk.Add_Unchecked($saveRuleHandler)
    $ruleCombo.Add_SelectionChanged($saveRuleHandler)
    $retryCombo.Add_SelectionChanged($saveRuleHandler)

    $btnFollowSeg.Tag = $composerStateInfo
    $btnFollowSeg.Add_Click({
        param($sender, $e)
        if ($script:initializing -or $script:suppressComposerEvents) { return }
        $info = $sender.Tag
        if (-not $info) { return }
        $info.TargetMode = 'follow_window'
        [void](Invoke-ComposerPersistence -StateInfo $info -Params @{
            Context = $script:context
            SessionKey = $info.TaskKey
            TargetMode = 'follow_window'
        })
        if ($info.Session) { Set-SessionPropSafe $info.Session 'TargetMode' 'follow_window' }
        Update-ComposerPodState $info
        Show-QuickToast '✓ 本任务已设为「跟随原窗口」'
    })

    $btnNewWinSeg.Tag = $composerStateInfo
    $btnNewWinSeg.Add_Click({
        param($sender, $e)
        if ($script:initializing -or $script:suppressComposerEvents) { return }
        $info = $sender.Tag
        if (-not $info) { return }
        $info.TargetMode = 'new_window'
        [void](Invoke-ComposerPersistence -StateInfo $info -Params @{
            Context = $script:context
            SessionKey = $info.TaskKey
            TargetMode = 'new_window'
        })
        if ($info.Session) { Set-SessionPropSafe $info.Session 'TargetMode' 'new_window' }
        Update-ComposerPodState $info
        Show-QuickToast '✓ 本任务已设为「新建网页交接」（自动携带进度账本）'
    })

    $inputBox.Tag = $composerStateInfo
    $inputBox.Add_GotFocus({
        param($sender, $e)
        $info = $sender.Tag
        if ($info -and $info.PodBorder) {
            $info.PodBorder.BorderBrush = ConvertTo-Brush '#2563EB'
        }
    })
    $inputBox.Add_LostFocus({
        param($sender, $e)
        $info = $sender.Tag
        if ($info -and $info.PodBorder) {
            $info.PodBorder.BorderBrush = ConvertTo-Brush '#D4D4D8'
        }
    })
    $inputBox.Add_TextChanged({
        param($sender, $e)
        $info = $sender.Tag
        if (-not $info) { return }
        if ($info.DraftObj) {
            $info.DraftObj.DraftText = $sender.Text
        }
        Update-ComposerPodState $info
    })
    $inputBox.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq [Windows.Input.Key]::Return) {
            if (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) -eq [Windows.Input.ModifierKeys]::Shift) {
                $caret = $sender.CaretIndex
                $sender.Text = $sender.Text.Insert($caret, "`r`n")
                $sender.CaretIndex = $caret + 2
                $e.Handled = $true
                return
            }
            $e.Handled = $true
            $info = $sender.Tag
            if ($info) {
                $txt = $sender.Text.Trim()
                $selProf   = if ($info.ProfCombo -and $info.ProfCombo.SelectedItem -and $info.ProfCombo.SelectedItem.Tag) { [string]$info.ProfCombo.SelectedItem.Tag } else { '' }
                $selModel  = if ($info.ModelCombo -and $info.ModelCombo.SelectedItem -and $info.ModelCombo.SelectedItem.Tag) { [string]$info.ModelCombo.SelectedItem.Tag } else { '' }
                $selEffort = if ($info.EffortCombo -and $info.EffortCombo.SelectedItem -and $info.EffortCombo.SelectedItem.Tag) { [string]$info.EffortCombo.SelectedItem.Tag } else { '' }
                $selProv   = Resolve-UiPlatformCode $(if ($info.PSObject.Properties['Provider'] -and $info.Provider) { [string]$info.Provider } else { 'chatgpt' })
                $dispatchMode = if ($info.TargetMode -eq 'new_window' -or $info.IsZeroTask) { 'new_window_handover' } else { 'follow_window' }
                $sentOk = Invoke-SendWebBridgeMessage $info.Session $dispatchMode $txt ([int]$info.PaneId) $selProf $selModel $selEffort $selProv
                if ($sentOk -ne $false) {
                    $sender.Text = ''
                    if ($info.DraftObj) { $info.DraftObj.DraftText = '' }
                }
            }
        }
    })

    $sendBtn.Tag = $composerStateInfo
    $sendBtn.Add_Click({
        param($sender, $e)
        $info = $sender.Tag
        if ($info) {
            $txt = if ($info.InputBox) { $info.InputBox.Text.Trim() } else { '' }
            $selProf   = if ($info.ProfCombo -and $info.ProfCombo.SelectedItem -and $info.ProfCombo.SelectedItem.Tag) { [string]$info.ProfCombo.SelectedItem.Tag } else { '' }
            $selModel  = if ($info.ModelCombo -and $info.ModelCombo.SelectedItem -and $info.ModelCombo.SelectedItem.Tag) { [string]$info.ModelCombo.SelectedItem.Tag } else { '' }
            $selEffort = if ($info.EffortCombo -and $info.EffortCombo.SelectedItem -and $info.EffortCombo.SelectedItem.Tag) { [string]$info.EffortCombo.SelectedItem.Tag } else { '' }
            $selProv   = Resolve-UiPlatformCode $(if ($info.PSObject.Properties['Provider'] -and $info.Provider) { [string]$info.Provider } else { 'chatgpt' })
            $dispatchMode = if ($info.TargetMode -eq 'new_window' -or $info.IsZeroTask) { 'new_window_handover' } else { 'follow_window' }
            $sentOk = Invoke-SendWebBridgeMessage $info.Session $dispatchMode $txt ([int]$info.PaneId) $selProf $selModel $selEffort $selProv
            if ($sentOk -ne $false) {
                if ($info.InputBox) { $info.InputBox.Text = '' }
                if ($info.DraftObj) { $info.DraftObj.DraftText = '' }
            }
        }
    })

    [Windows.Controls.Grid]::SetColumn($sendBtn, 1)
    [void]$bottomBarGrid.Children.Add($sendBtn)
    [void]$podStack.Children.Add($bottomBarGrid)

    Update-ComposerPodState $composerStateInfo

    $composerPod.Child = $podStack
    $composeBorder.Name = 'ComposerPodHost'
    $composeBorder.Tag = $composerStateInfo
    if ($IsZeroTask) {
        $zeroRootStack = New-Object Windows.Controls.StackPanel
        $zeroRootStack.MaxWidth = 760
        $zeroRootStack.HorizontalAlignment = 'Stretch'
        [void]$zeroRootStack.Children.Add($composerPod)
        $zeroFooterHost = New-Object Windows.Controls.StackPanel
        $zeroFooterHost.Margin = [Windows.Thickness]::new(0, 20, 0, 0)
        $zeroFooterHost.Visibility = 'Collapsed'
        [void]$zeroRootStack.Children.Add($zeroFooterHost)
        $composerStateInfo.ZeroFooterHost = $zeroFooterHost
        $composeBorder.Child = $zeroRootStack
    } else {
        $composeBorder.Child = $composerPod
    }
    if (-not $script:composerPodCache) { $script:composerPodCache = @{} }
    $script:composerPodCache[$podCacheKey] = $composeBorder
    return $composeBorder
}
function Render-PanesWorkspace {
    $script:deferredPaneRebuildWhileTyping = $false
    $hostGrid = $script:controls.PanesHostGrid

    Normalize-PaneWeights
    $panes = @($script:layout.Panes)
    $allSessions = @(Get-AllAvailableSessions)
    $activeSessions = @(if ($script:display -and $script:display.Sessions) { $script:display.Sessions })

    # Auto-assign first pane to first active session if first pane has no session and only 1 pane is open
    $hasValidFirst = $panes[0].session_key -and ($allSessions | Where-Object { $_.SessionKey -eq $panes[0].session_key })
    if ($panes.Count -eq 1 -and (-not $hasValidFirst) -and $activeSessions.Count -gt 0 -and -not $script:launchpadPaneIds.ContainsKey([int]$panes[0].id) -and -not $script:pickerPaneIds.ContainsKey([int]$panes[0].id)) {
        $panes[0].session_key = $activeSessions[0].SessionKey
    }

    $availWorkspaceW = [Math]::Max(480.0, [double]$script:window.Width - $(if ($script:layout.RailCollapsed) { 16.0 } else { [double]$script:layout.RailWidth + 16.0 }))

    $resolvedPanes = New-Object 'System.Collections.Generic.List[object]'
    $allSessionMode = ($panes.Count -gt 0)
    foreach ($pItem in $panes) {
        $estW = $availWorkspaceW * ([Math]::Max(15.0, [double]$pItem.width_weight) / 100.0)
        $isNar = ($estW -lt 680.0) -or ($panes.Count -ge 2)
        $mSess = if ($pItem.session_key) {
            $allSessions | Where-Object { $_.SessionKey -eq $pItem.session_key -or $_.WfrId -eq $pItem.session_key } | Select-Object -First 1
        } else { $null }
        $pMode = if ($mSess) {
            'session'
        } elseif ($script:launchpadPaneIds.ContainsKey([int]$pItem.id) -or ($activeSessions.Count -eq 0 -and (-not $script:pickerPaneIds.ContainsKey([int]$pItem.id)))) {
            'launchpad'
        } else {
            'picker'
        }
        if ($pMode -ne 'session') { $allSessionMode = $false }
        $mKey = if ($mSess) { [string]$mSess.SessionKey } else { '' }
        $rCkptsArr = @(if ($mSess -and $mSess.PSObject.Properties['ReadableCheckpoints'] -and $mSess.ReadableCheckpoints) { $mSess.ReadableCheckpoints })
        $ckptTopSig = if ($rCkptsArr.Count -gt 0) { "$($rCkptsArr.Count):$($rCkptsArr[0].TimeText):$($rCkptsArr[0].Summary)" } else { '0' }
        [void]$resolvedPanes.Add([pscustomobject]@{
            Pane = $pItem
            MatchedSession = $mSess
            MatchedKey = $mKey
            Mode = $pMode
            IsNarrow = $isNar
            TopoSig = "$($pItem.id):${pMode}:${mKey}:${isNar}:$($panes.Count):${ckptTopSig}"
        })
    }
    $workspaceTopologySig = (@($resolvedPanes | ForEach-Object { $_.TopoSig }) -join '||')
    $expectedChildCount = if ($panes.Count -gt 0) { ($panes.Count * 2) - 1 } else { 0 }

    if ($allSessionMode -and $script:lastWorkspaceTopologySig -eq $workspaceTopologySig -and $hostGrid.Children.Count -eq $expectedChildCount -and $hostGrid.ColumnDefinitions.Count -eq $expectedChildCount) {
        $script:sessionQueueBannerBorders = @{}
        for ($idx = 0; $idx -lt $resolvedPanes.Count; $idx++) {
            $rp = $resolvedPanes[$idx]
            $pane = $rp.Pane
            $matchedSession = $rp.MatchedSession
            $isNarrowPane = $rp.IsNarrow
            $paneColIdx = $idx * 2
            $hostGrid.ColumnDefinitions[$paneColIdx].Width = [Windows.GridLength]::new([Math]::Max(15.0, [double]$pane.width_weight), [Windows.GridUnitType]::Star)
            $paneBorder = $hostGrid.Children[$paneColIdx]
            if (-not $paneBorder -or -not $paneBorder.Tag) { continue }
            $pTag = $paneBorder.Tag
            if ($pTag.PSObject.Properties['HeaderDot'] -and $pTag.HeaderDot) {
                $pTag.HeaderDot.Fill = ConvertTo-Brush $matchedSession.DotColor
            }
            if ($pTag.PSObject.Properties['HeaderTitle'] -and $pTag.HeaderTitle) {
                $pTag.HeaderTitle.Text = $(if ($matchedSession.ShortTitle) { $matchedSession.ShortTitle } else { $matchedSession.Title })
            }
            if ($pTag.PSObject.Properties['HeaderSubText'] -and $pTag.HeaderSubText) {
                $topCommits = @(if ($matchedSession.PSObject.Properties['RecentCommits'] -and $matchedSession.RecentCommits) { $matchedSession.RecentCommits })
                $pTag.HeaderSubText.Text = if ($topCommits.Count -gt 0) {
                    if ($isNarrowPane) { "· Git $($topCommits[0].Sha)" } else { "· 最近 Git 提交 $($topCommits[0].Sha)" }
                } elseif ($matchedSession.ShortId) {
                    "· $($matchedSession.ShortId)"
                } else { '' }
            }
            if ($pTag.PSObject.Properties['SummaryButton'] -and $pTag.SummaryButton) {
                $stepsArr = @(if ($matchedSession.PSObject.Properties['Steps'] -and $matchedSession.Steps) { $matchedSession.Steps })
                $doneCnt = @($stepsArr | Where-Object { $_.Status -in @('completed', 'quarantined') }).Count
                $pTag.SummaryButton.Content = if ($stepsArr.Count -gt 0) { "步骤 $doneCnt/$($stepsArr.Count) ▾" } else { '步骤摘要 ▾' }
                $showSum = [bool]$pane.show_summary
                $pTag.SummaryButton.Background = ConvertTo-Brush $(if ($showSum) { '#EFF6FF' } else { '#FFFFFF' })
                $pTag.SummaryButton.BorderBrush = ConvertTo-Brush $(if ($showSum) { '#BFDBFE' } else { '#E4E4E7' })
                $pTag.SummaryButton.Foreground = ConvertTo-Brush $(if ($showSum) { '#2563EB' } else { '#3F3F46' })
            }
            if ($pTag.PSObject.Properties['SummaryCard'] -and $pTag.SummaryCard) {
                Update-CodexSummaryCardContent $pTag.SummaryCard $pane $matchedSession
                $pTag.SummaryCard.Visibility = if ($pane.show_summary) { 'Visible' } else { 'Collapsed' }
            }
            if ($pTag.PSObject.Properties['StreamHost'] -and $pTag.StreamHost -and $pTag.StreamHost.Tag) {
                $sr = $pTag.StreamHost.Tag
                if ($sr.TitleBlock) { $sr.TitleBlock.Text = $matchedSession.Title }
                if ($sr.OpenWebButton) { $sr.OpenWebButton.Tag = $matchedSession }
                if ($sr.StepFillBar -and $sr.StepPillText) {
                    $progPctVal = if ($null -ne $matchedSession.ProgressPercent) { [Math]::Max(0, [Math]::Min(100, [int]$matchedSession.ProgressPercent)) } else { 100 }
                    $sr.StepFillBar.Width = [Math]::Max(4.0, [Math]::Round(($progPctVal / 100.0) * 44.0, 1))
                    $stepsCount = @(if ($matchedSession.PSObject.Properties['Steps'] -and $matchedSession.Steps) { $matchedSession.Steps }).Count
                    $sr.StepPillText.Text = if ($stepsCount -gt 0) {
                        "已完成 $($matchedSession.StepCountText -replace '\s*步已完成',' 步') ($progPctVal%)"
                    } else {
                        "$($matchedSession.StepCountText)"
                    }
                }
                Update-PaneStatusPillVisual -StatusPill $sr.StatusPill -SDot $sr.StatusDot -SLabel $sr.StatusLabel -SessionObj $matchedSession
                if ($sr.DiagTextBlock) {
                    $sr.DiagTextBlock.Text = $(if ($matchedSession.HumanDiagnosis) { $matchedSession.HumanDiagnosis } else { $matchedSession.LatestSummary })
                }
                if ($sr.QueueBanner) {
                    Update-QueueBannerBorder -BannerBorder $sr.QueueBanner -SessionObj $matchedSession
                    $sessKeyForBanner = if ($matchedSession.PSObject.Properties['SessionKey'] -and $matchedSession.SessionKey) { [string]$matchedSession.SessionKey } else { '' }
                    if ($sessKeyForBanner) {
                        if ($script:sessionQueueBannerBorders.ContainsKey($sessKeyForBanner) -and $script:sessionQueueBannerBorders[$sessKeyForBanner]) {
                            $prevArr = [object[]]$script:sessionQueueBannerBorders[$sessKeyForBanner]
                            $nextArr = New-Object 'object[]' ($prevArr.Length + 1)
                            [Array]::Copy($prevArr, $nextArr, $prevArr.Length)
                            $nextArr[$prevArr.Length] = $sr.QueueBanner
                            $script:sessionQueueBannerBorders[$sessKeyForBanner] = $nextArr
                        } else {
                            $singleArr = New-Object 'object[]' 1
                            $singleArr[0] = $sr.QueueBanner
                            $script:sessionQueueBannerBorders[$sessKeyForBanner] = $singleArr
                        }
                    }
                }
            }
            [void](Build-PlanBComposerPod -SessionObj $matchedSession -IsNarrow $isNarrowPane -IsZeroTask $false -PaneId ([int]$pane.id) -InPlaceUpdate)
        }
        return
    }

    $script:lastWorkspaceTopologySig = $workspaceTopologySig
    $script:sessionQueueBannerBorders = @{}
    $hostGrid.Children.Clear()
    $hostGrid.ColumnDefinitions.Clear()

    for ($idx = 0; $idx -lt $panes.Count; $idx++) {
        $pane = $panes[$idx]
        $estPaneW = $availWorkspaceW * ([Math]::Max(15.0, [double]$pane.width_weight) / 100.0)
        $isNarrowPane = ($estPaneW -lt 680.0) -or ($panes.Count -ge 2)

        $paneColIdx = $hostGrid.ColumnDefinitions.Count
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = [Windows.GridLength]::new([Math]::Max(15.0, [double]$pane.width_weight), [Windows.GridUnitType]::Star)
        $colDef.MinWidth = 110
        [void]$hostGrid.ColumnDefinitions.Add($colDef)

        $matchedSession = $null
        if ($pane.session_key) {
            $matchedSession = $allSessions | Where-Object { $_.SessionKey -eq $pane.session_key -or $_.WfrId -eq $pane.session_key } | Select-Object -First 1
        }

        $paneBorder = New-Object Windows.Controls.Border
        $paneBorder.Background = ConvertTo-Brush '#FFFFFF'
        $paneBorder.ClipToBounds = $true
        $paneGrid = New-Object Windows.Controls.Grid
        $pr0 = New-Object Windows.Controls.RowDefinition; $pr0.Height = [Windows.GridLength]::new(42)
        $pr1 = New-Object Windows.Controls.RowDefinition; $pr1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        [void]$paneGrid.RowDefinitions.Add($pr0); [void]$paneGrid.RowDefinitions.Add($pr1)

        # Per-Pane Task Header inside the Elevated White Card (Window Controls live in the Gray AppTitleBarBorder above)
        $headerBorder = New-Object Windows.Controls.Border
        $headerBorder.Background = ConvertTo-Brush '#FFFFFF'
        $headerBorder.BorderBrush = ConvertTo-Brush '#F1F1F4'
        $headerBorder.BorderThickness = [Windows.Thickness]::new(0, 0, 0, 1)
        $headerBorder.Padding = [Windows.Thickness]::new($(if ($isNarrowPane) { 14 } else { 18 }), 0, $(if ($isNarrowPane) { 10 } else { 14 }), 0)

        $hGrid = New-Object Windows.Controls.Grid
        $hcLeft = New-Object Windows.Controls.ColumnDefinition; $hcLeft.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $hcRight = New-Object Windows.Controls.ColumnDefinition; $hcRight.Width = [Windows.GridLength]::Auto
        [void]$hGrid.ColumnDefinitions.Add($hcLeft); [void]$hGrid.ColumnDefinitions.Add($hcRight)

        $leftBar = New-Object Windows.Controls.Grid
        $lbc0 = New-Object Windows.Controls.ColumnDefinition; $lbc0.Width = [Windows.GridLength]::Auto
        $lbc1 = New-Object Windows.Controls.ColumnDefinition; $lbc1.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        [void]$leftBar.ColumnDefinitions.Add($lbc0); [void]$leftBar.ColumnDefinitions.Add($lbc1)
        $leftBar.VerticalAlignment = 'Center'
        $leftBar.Margin = [Windows.Thickness]::new(0, 0, 8, 0)

        $sDot = $null
        $sTxt = $null
        $topSubTxt = $null
        $sumBtn = $null
        $codexCard = $null
        if ($matchedSession) {
            $selBtn = New-Object Windows.Controls.Button
            $selBtn.Background = ConvertTo-Brush 'Transparent'
            $selBtn.BorderBrush = ConvertTo-Brush 'Transparent'
            $selBtn.Padding = [Windows.Thickness]::new(6, 4, 6, 4)
            $selBtn.MinHeight = 28
            $selBtn.Tag = [int]$pane.id
            $selBtn.ToolTip = '点击切换此分栏显示的任务栏目'
            $selBtn.Add_Click({
                param($sender, $e)
                Switch-PaneToPicker ([int]$sender.Tag)
            })
            $selStack = New-Object Windows.Controls.StackPanel
            $selStack.Orientation = 'Horizontal'
            $sDot = New-Object Windows.Shapes.Ellipse
            $sDot.Width = 7; $sDot.Height = 7
            $sDot.Fill = ConvertTo-Brush $matchedSession.DotColor
            $sDot.VerticalAlignment = 'Center'
            $sDot.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
            [void]$selStack.Children.Add($sDot)
            $sTxt = New-Object Windows.Controls.TextBlock
            $sTxt.Text = $(if ($matchedSession.ShortTitle) { $matchedSession.ShortTitle } else { $matchedSession.Title })
            $sTxt.FontSize = 13
            $sTxt.FontWeight = 'SemiBold'
            $sTxt.Foreground = ConvertTo-Brush '#18181B'
            $sTxt.MaxWidth = $(if ($isNarrowPane) { 185 } else { 360 })
            $sTxt.TextTrimming = 'CharacterEllipsis'
            $sTxt.TextWrapping = 'NoWrap'
            [void]$selStack.Children.Add($sTxt)
            $sCaret = New-Object Windows.Controls.TextBlock
            $sCaret.Text = ' 切换 ▾'
            $sCaret.FontSize = 11
            $sCaret.FontWeight = 'SemiBold'
            $sCaret.Foreground = ConvertTo-Brush '#2563EB'
            $sCaret.VerticalAlignment = 'Center'
            $sCaret.Margin = [Windows.Thickness]::new(3, 0, 0, 0)
            [void]$selStack.Children.Add($sCaret)
            $selBtn.Content = $selStack
            [Windows.Controls.Grid]::SetColumn($selBtn, 0)
            [void]$leftBar.Children.Add($selBtn)

            # Quiet Git Commit / Session Tail in Top Header Bar (Auto-ellipsized so it never collides with right buttons)
            $topCommits = @(if ($matchedSession.PSObject.Properties['RecentCommits'] -and $matchedSession.RecentCommits) { $matchedSession.RecentCommits })
            $topSubTxt = New-Object Windows.Controls.TextBlock
            $topSubTxt.Text = if ($topCommits.Count -gt 0) {
                if ($isNarrowPane) { "· Git $($topCommits[0].Sha)" } else { "· 最近 Git 提交 $($topCommits[0].Sha)" }
            } elseif ($matchedSession.ShortId) {
                "· $($matchedSession.ShortId)"
            } else { '' }
            $topSubTxt.FontSize = 11.5
            $topSubTxt.Foreground = ConvertTo-Brush '#71717A'
            $topSubTxt.VerticalAlignment = 'Center'
            $topSubTxt.Margin = [Windows.Thickness]::new(4, 0, 4, 0)
            $topSubTxt.TextTrimming = 'CharacterEllipsis'
            $topSubTxt.TextWrapping = 'NoWrap'
            [Windows.Controls.Grid]::SetColumn($topSubTxt, 1)
            [void]$leftBar.Children.Add($topSubTxt)
        } else {
            $isNewTaskMode = $script:launchpadPaneIds.ContainsKey([int]$pane.id) -or ($activeSessions.Count -eq 0 -and (-not $script:pickerPaneIds.ContainsKey([int]$pane.id)))
            if ($isNewTaskMode) {
                $selNewBtn = New-Object Windows.Controls.Button
                $selNewBtn.Background = ConvertTo-Brush 'Transparent'
                $selNewBtn.BorderBrush = ConvertTo-Brush 'Transparent'
                $selNewBtn.Padding = [Windows.Thickness]::new(6, 4, 6, 4)
                $selNewBtn.MinHeight = 28
                $selNewBtn.Tag = [int]$pane.id
                $selNewBtn.ToolTip = '点击切换此分栏显示的任务栏目'
                $selNewBtn.Add_Click({
                    param($sender, $e)
                    Switch-PaneToPicker ([int]$sender.Tag)
                })
                $selNewStack = New-Object Windows.Controls.StackPanel
                $selNewStack.Orientation = 'Horizontal'
                $newLbl = New-Object Windows.Controls.TextBlock
                $newLbl.Text = '新建任务'
                $newLbl.FontSize = 13
                $newLbl.FontWeight = 'SemiBold'
                $newLbl.Foreground = ConvertTo-Brush '#18181B'
                [void]$selNewStack.Children.Add($newLbl)
                $newCaret = New-Object Windows.Controls.TextBlock
                $newCaret.Text = ' 切换 ▾'
                $newCaret.FontSize = 11
                $newCaret.FontWeight = 'SemiBold'
                $newCaret.Foreground = ConvertTo-Brush '#2563EB'
                $newCaret.VerticalAlignment = 'Center'
                $newCaret.Margin = [Windows.Thickness]::new(3, 0, 0, 0)
                [void]$selNewStack.Children.Add($newCaret)
                $selNewBtn.Content = $selNewStack
                [Windows.Controls.Grid]::SetColumn($selNewBtn, 0)
                [void]$leftBar.Children.Add($selNewBtn)
            } else {
                $newLbl = New-Object Windows.Controls.TextBlock
                $newLbl.Text = '选择任务'
                $newLbl.FontSize = 13
                $newLbl.FontWeight = 'SemiBold'
                $newLbl.Foreground = ConvertTo-Brush '#18181B'
                $newLbl.VerticalAlignment = 'Center'
                [Windows.Controls.Grid]::SetColumn($newLbl, 0)
                [void]$leftBar.Children.Add($newLbl)
            }
        }
        [Windows.Controls.Grid]::SetColumn($leftBar, 0)
        [void]$hGrid.Children.Add($leftBar)

        # Right side of Task Pane Header: [步骤 5/7 ▾] + [◫ 分栏] + [× 关闭此分栏]
        $rightBar = New-Object Windows.Controls.StackPanel
        $rightBar.Orientation = 'Horizontal'
        $rightBar.VerticalAlignment = 'Center'

        if ($matchedSession) {
            $stepsArr = @(if ($matchedSession.PSObject.Properties['Steps'] -and $matchedSession.Steps) { $matchedSession.Steps })
            $doneCnt = @($stepsArr | Where-Object { $_.Status -in @('completed', 'quarantined') }).Count
            $sumLabelStr = if ($stepsArr.Count -gt 0) { "步骤 $doneCnt/$($stepsArr.Count) ▾" } else { '步骤摘要 ▾' }

            $sumBtn = New-Object Windows.Controls.Button
            $sumBtn.Content = $sumLabelStr
            $sumBtn.Padding = [Windows.Thickness]::new(9, 3, 9, 3)
            $sumBtn.MinHeight = 25
            $sumBtn.FontSize = 11.5
            $sumBtn.FontWeight = 'SemiBold'
            $sumBtn.Background = ConvertTo-Brush $(if ($pane.show_summary) { '#EFF6FF' } else { '#FFFFFF' })
            $sumBtn.BorderBrush = ConvertTo-Brush $(if ($pane.show_summary) { '#BFDBFE' } else { '#E4E4E7' })
            $sumBtn.Foreground = ConvertTo-Brush $(if ($pane.show_summary) { '#2563EB' } else { '#3F3F46' })
            $sumBtn.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
            $sumBtn.ToolTip = '显示/隐藏步骤与进展摘要（Codex 悬浮卡片）'
            $sumBtn.Tag = [int]$pane.id
            $sumBtn.Add_Click({
                param($sender, $e)
                Toggle-PaneSummary ([int]$sender.Tag)
            })
            [void]$rightBar.Children.Add($sumBtn)
        }

        $splitBtn = New-Object Windows.Controls.Button
        $splitBtn.Padding = [Windows.Thickness]::new(9, 3, 9, 3)
        $splitBtn.MinHeight = 25
        $splitBtn.Background = ConvertTo-Brush '#FFFFFF'
        $splitBtn.BorderBrush = ConvertTo-Brush '#E4E4E7'
        $splitBtn.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
        $splitBtn.ToolTip = '在窗口内部向右横拆出新分栏（最多 4 栏）'
        $splitBtn.Tag = [int]$pane.id
        $splitStack = New-Object Windows.Controls.StackPanel
        $splitStack.Orientation = 'Horizontal'
        $splitIcon = New-VectorIcon -Kind 'split' -Size 12.5 -ColorHex '#52525B'
        $splitIcon.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
        [void]$splitStack.Children.Add($splitIcon)
        $splitTxt = New-Object Windows.Controls.TextBlock
        $splitTxt.Text = '分栏'
        $splitTxt.FontSize = 11.5
        $splitTxt.FontWeight = 'SemiBold'
        $splitTxt.Foreground = ConvertTo-Brush '#3F3F46'
        [void]$splitStack.Children.Add($splitTxt)
        $splitBtn.Content = $splitStack
        $splitBtn.Add_Click({
            param($sender, $e)
            Split-PaneAfter ([int]$sender.Tag)
        })
        [void]$rightBar.Children.Add($splitBtn)

        if ($panes.Count -gt 1) {
            $closePaneBtn = New-QuietIconButton -Kind 'close' -TooltipText '关闭当前分栏（不改变窗口外框比例）' -BoxSize 26 -IconSize 13.5
            $closePaneBtn.Tag = [int]$pane.id
            $closePaneBtn.Add_Click({
                param($sender, $e)
                Close-PaneById ([int]$sender.Tag)
            })
            [void]$rightBar.Children.Add($closePaneBtn)
        }

        [Windows.Controls.Grid]::SetColumn($rightBar, 1)
        [void]$hGrid.Children.Add($rightBar)
        $headerBorder.Child = $hGrid
        [Windows.Controls.Grid]::SetRow($headerBorder, 0)
        [void]$paneGrid.Children.Add($headerBorder)

        # Pane Body (Stream Content or Antigravity Task Picker)
        $bodyElem = if ($matchedSession) {
            Build-PaneStreamContent $pane $matchedSession $isNarrowPane
        } else {
            Build-PaneTaskPicker $pane
        }
        [Windows.Controls.Grid]::SetRow($bodyElem, 1)
        [void]$paneGrid.Children.Add($bodyElem)

        # Codex Floating Step Summary Card (Overlay in RowSpan 2, pre-mounted for in-place Visibility toggle)
        if ($matchedSession) {
            $codexCard = Build-CodexSummaryCard $pane $matchedSession
            $codexCard.Visibility = if ($pane.show_summary) { 'Visible' } else { 'Collapsed' }
            [Windows.Controls.Grid]::SetRow($codexCard, 0)
            [Windows.Controls.Grid]::SetRowSpan($codexCard, 2)
            [void]$paneGrid.Children.Add($codexCard)
        }

        $paneBorder.Tag = [pscustomobject]@{
            PaneIndex = $idx
            PaneId = [int]$pane.id
            ColumnIndex = $paneColIdx
            MatchedSessionKey = $(if ($matchedSession) { [string]$matchedSession.SessionKey } else { '' })
            HeaderDot = $sDot
            HeaderTitle = $sTxt
            HeaderSubText = $topSubTxt
            SummaryButton = $sumBtn
            SummaryCard = $codexCard
            StreamHost = $bodyElem
        }
        $paneBorder.Child = $paneGrid
        [Windows.Controls.Grid]::SetColumn($paneBorder, $paneColIdx)
        [void]$hostGrid.Children.Add($paneBorder)

        # Add Draggable Vertical Resizer between adjacent panes
        if ($idx -lt ($panes.Count - 1)) {
            $resColIdx = $hostGrid.ColumnDefinitions.Count
            $resCol = New-Object Windows.Controls.ColumnDefinition
            $resCol.Width = [Windows.GridLength]::new(7)
            [void]$hostGrid.ColumnDefinitions.Add($resCol)

            $resizerBar = New-Object Windows.Controls.Border
            $resizerBar.Background = ConvertTo-Brush 'Transparent'
            $resizerBar.Cursor = [Windows.Input.Cursors]::SizeWE
            $resizerBar.ToolTip = '左右拖动调节相邻两栏宽度（推到最小舒适宽度后继续往外拉过半可直接顺滑收起该栏）'
            $resGrid = New-Object Windows.Controls.Grid
            $rLine = New-Object Windows.Controls.Border
            $rLine.Width = 1
            $rLine.Background = ConvertTo-Brush '#E4E4E7'
            $rLine.HorizontalAlignment = 'Center'
            [void]$resGrid.Children.Add($rLine)
            $rGrip = New-Object Windows.Controls.Border
            $rGrip.Background = ConvertTo-Brush '#FFFFFF'
            $rGrip.BorderBrush = ConvertTo-Brush '#E4E4E7'
            $rGrip.BorderThickness = [Windows.Thickness]::new(1)
            $rGrip.CornerRadius = [Windows.CornerRadius]::new(3)
            $rGrip.Padding = [Windows.Thickness]::new(1, 2, 1, 2)
            $rGrip.HorizontalAlignment = 'Center'
            $rGrip.VerticalAlignment = 'Center'
            $rGripTxt = New-Object Windows.Controls.TextBlock
            $rGripTxt.Text = '⋮'
            $rGripTxt.FontSize = 10
            $rGripTxt.Foreground = ConvertTo-Brush '#A1A1AA'
            $rGrip.Child = $rGripTxt
            [void]$resGrid.Children.Add($rGrip)
            $resizerBar.Child = $resGrid
            $resizerBar.Tag = $idx

            $resizerBar.Add_MouseLeftButtonDown({
                param($sender, $e)
                if ($script:paneAnimTimer -and $script:paneAnimTimer.IsEnabled) {
                    $script:paneAnimTimer.Stop()
                }
                $rIdx = [int]$sender.Tag
                $pt = $e.GetPosition($script:controls.PanesHostGrid)
                $totalW = [Math]::Max(360.0, [double]$script:controls.PanesHostGrid.ActualWidth)
                $panesArr = @($script:layout.Panes)
                if ($rIdx -ge 0 -and ($rIdx + 1) -lt $panesArr.Count) {
                    $sumW = 0.0
                    foreach ($pItem in $panesArr) { $sumW += [double]$pItem.width_weight }
                    $script:paneDragCtx = [pscustomobject]@{
                        ResizerIdx = $rIdx
                        StartX = $pt.X
                        ContainerWidth = $totalW
                        TotalWeight = $sumW
                        StartLeftW = [double]$panesArr[$rIdx].width_weight
                        StartRightW = [double]$panesArr[$rIdx + 1].width_weight
                    }
                    [void]$sender.CaptureMouse()
                    $e.Handled = $true
                }
            })
            $resizerBar.Add_MouseMove({
                param($sender, $e)
                if (-not $script:paneDragCtx) { return }
                $ctx = $script:paneDragCtx
                $pt = $e.GetPosition($script:controls.PanesHostGrid)
                $dx = $pt.X - $ctx.StartX
                $deltaWeight = ($dx / [Math]::Max(360.0, $ctx.ContainerWidth)) * $ctx.TotalWeight
                $pairWeight = $ctx.StartLeftW + $ctx.StartRightW
                $pairPx = ($pairWeight / [Math]::Max(1.0, $ctx.TotalWeight)) * $ctx.ContainerWidth
                $minComfortPx = [Math]::Min($script:PANE_MIN_COMFORT_PX, $pairPx * 0.36)
                $minComfortW = ($minComfortPx / [Math]::Max(360.0, $ctx.ContainerWidth)) * $ctx.TotalWeight
                $snapClosePx = [Math]::Min($script:PANE_SNAP_HIDE_PX, $minComfortPx * 0.44)

                $rawLeftW = $ctx.StartLeftW + $deltaWeight
                $rawRightW = $ctx.StartRightW - $deltaWeight
                $rawLeftPx = ($rawLeftW / [Math]::Max(1.0, $ctx.TotalWeight)) * $ctx.ContainerWidth
                $rawRightPx = ($rawRightW / [Math]::Max(1.0, $ctx.TotalWeight)) * $ctx.ContainerWidth

                $panesArr = @($script:layout.Panes)
                # Push past midpoint of clamped pane -> smoothly slide-close that pane without ever squishing below minComfortPx
                if ($panesArr.Count -gt 1 -and $rawRightPx -lt $snapClosePx) {
                    $closeId = [int]$panesArr[$ctx.ResizerIdx + 1].id
                    $script:paneDragCtx = $null
                    $sender.ReleaseMouseCapture()
                    Close-PaneById $closeId
                    return
                }
                if ($panesArr.Count -gt 1 -and $rawLeftPx -lt $snapClosePx) {
                    $closeId = [int]$panesArr[$ctx.ResizerIdx].id
                    $script:paneDragCtx = $null
                    $sender.ReleaseMouseCapture()
                    Close-PaneById $closeId
                    return
                }

                # Clamp strictly to [minComfortW, pairWeight - minComfortW] so content never squishes
                $newLeft = [Math]::Max($minComfortW, [Math]::Min(($pairWeight - $minComfortW), $rawLeftW))
                $newRight = [Math]::Max($minComfortW, ($pairWeight - $newLeft))

                $panesArr[$ctx.ResizerIdx].width_weight = $newLeft
                $panesArr[$ctx.ResizerIdx + 1].width_weight = $newRight

                $leftColDefIdx = $ctx.ResizerIdx * 2
                $rightColDefIdx = ($ctx.ResizerIdx + 1) * 2
                if ($leftColDefIdx -lt $script:controls.PanesHostGrid.ColumnDefinitions.Count) {
                    $script:controls.PanesHostGrid.ColumnDefinitions[$leftColDefIdx].Width = [Windows.GridLength]::new($newLeft, [Windows.GridUnitType]::Star)
                }
                if ($rightColDefIdx -lt $script:controls.PanesHostGrid.ColumnDefinitions.Count) {
                    $script:controls.PanesHostGrid.ColumnDefinitions[$rightColDefIdx].Width = [Windows.GridLength]::new($newRight, [Windows.GridUnitType]::Star)
                }
            })
            $resizerBar.Add_MouseLeftButtonUp({
                param($sender, $e)
                if (-not $script:paneDragCtx) { return }
                $script:paneDragCtx = $null
                $sender.ReleaseMouseCapture()
                Normalize-PaneWeights
                Sync-LayoutMemory
            })

            [Windows.Controls.Grid]::SetColumn($resizerBar, $resColIdx)
            [void]$hostGrid.Children.Add($resizerBar)
        }
    }
}
function Update-SessionDetailModal {
    if (-not $script:detailSessionKey) { return }
    $sessions = @(Get-AllAvailableSessions)
    $target = $sessions | Where-Object { $_.SessionKey -eq $script:detailSessionKey } | Select-Object -First 1
    if (-not $target -and @($sessions).Count -gt 0) { $target = $sessions[0] }
    if (-not $target) {
        Close-SessionDetail
        return
    }
    $script:controls.DetailModalTitle.Text = $target.Title
    # Spec v4.7 §3.2: fold multi-line goals into one flattened line (MaxHeight=36 + ellipsis), full text in ToolTip
    $goalFull = if ($target.Goal) { "任务目标：$($target.Goal)" } else { [string]$target.MetaText }
    $script:controls.DetailModalGoal.Text = (([string]$goalFull) -replace '\s*[\r\n]+\s*', ' ').Trim()
    $script:controls.DetailModalGoal.ToolTip = if ($goalFull) { [string]$goalFull } else { $null }
    # Spec v4.7 §3.4: VitalSubstate badge (locally derived) overrides the hub badge; missing substate keeps legacy badge
    $detailVital = Get-VitalSubstateVisual $target
    if ($detailVital) {
        $script:controls.DetailModalBadgeBorder.Background = ConvertTo-Brush $detailVital.Bg
        $script:controls.DetailModalBadgeBorder.BorderBrush = ConvertTo-Brush $detailVital.Border
        $script:controls.DetailModalBadgeText.Text = "● $($detailVital.Badge)"
        $script:controls.DetailModalBadgeText.Foreground = ConvertTo-Brush $detailVital.Fg
    } else {
        $script:controls.DetailModalBadgeBorder.Background = ConvertTo-Brush $target.StatusBg
        $script:controls.DetailModalBadgeBorder.BorderBrush = ConvertTo-Brush $target.StatusBorder
        $script:controls.DetailModalBadgeText.Text = $target.StatusBadge
        $script:controls.DetailModalBadgeText.Foreground = ConvertTo-Brush $target.StatusFg
    }
    $script:controls.DetailDiagnosisText.Text = if ($target.HumanDiagnosis) { $target.HumanDiagnosis } else { $target.ActionText }
    $script:controls.DetailProgressBar.Value = if ($null -ne $target.ProgressPercent) { [double]$target.ProgressPercent } else { 100 }
    $script:controls.DetailProgressText.Text = if ($target.ProgressText) { $target.ProgressText } else { $target.MetaText }
    $script:controls.DetailLatestSummaryText.Text = if ($target.LatestSummary) { $target.LatestSummary } else { $target.ActionText }
    $script:controls.DetailModalMetaText.Text = $target.MetaText

    $steps = @(if ($target.PSObject.Properties.Name -contains 'Steps' -and $target.Steps) { $target.Steps })
    $commits = @(if ($target.PSObject.Properties.Name -contains 'RecentCommits' -and $target.RecentCommits) { $target.RecentCommits })
    $ckpts = @(if ($target.PSObject.Properties.Name -contains 'Checkpoints' -and $target.Checkpoints) { $target.Checkpoints })
    $firstSha = if (@($commits).Count -gt 0) { $commits[0].Sha } else { '' }
    # Spec v4.7 §3.3: full dynamic fingerprint (step status + newest checkpoint) so 12-capped checkpoints never freeze the modal
    $vSubSig = if ($target.PSObject.Properties['VitalSubstate']) { [string]$target.VitalSubstate } else { '' }
    $stepsSig = (@($steps) | ForEach-Object { "$($_.Id):$($_.Status):$($_.UpdatedText)" }) -join ','
    $lastCkpt = if (@($ckpts).Count -gt 0) { "$($ckpts[0].TimeText)|$($ckpts[0].Summary)" } else { '' }
    $panelSig = "$($target.SessionKey)|$($target.VitalState)|$vSubSig|$($target.CommandCount)|$($target.ProgressText)|$stepsSig|$firstSha|$(@($ckpts).Count)|$lastCkpt"
    if ($script:lastDetailPanelSig -eq $panelSig -and $script:controls.DetailStepsPanel.Children.Count -gt 0) {
        return
    }
    $script:lastDetailPanelSig = $panelSig

    $script:controls.DetailStepsPanel.Children.Clear()
    if (@($steps).Count -eq 0) {
        $emptyStep = New-Object Windows.Controls.TextBlock
        $emptyStep.Text = '当前对话未创建分步契约（tsk_*.json），直接通过 MCP 转发工具指令。'
        $emptyStep.Foreground = ConvertTo-Brush '#71717A'
        $emptyStep.FontSize = 12
        $emptyStep.Margin = [Windows.Thickness]::new(12, 8, 12, 8)
        [void]$script:controls.DetailStepsPanel.Children.Add($emptyStep)
    } else {
        for ($i = 0; $i -lt @($steps).Count; $i++) {
            $st = $steps[$i]
            $rowBg = if ($st.Status -eq 'in_progress') { '#EFF6FF' } else { '#FFFFFF' }
            $b = New-Object Windows.Controls.Border
            $b.Background = ConvertTo-Brush $rowBg
            $b.BorderBrush = ConvertTo-Brush '#E4E4E7'
            $b.BorderThickness = [Windows.Thickness]::new(0, 0, 0, $(if ($i -lt (@($steps).Count - 1)) { 1 } else { 0 }))
            $b.Padding = [Windows.Thickness]::new(10, 4, 10, 4)

            $g = New-Object Windows.Controls.Grid
            $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::Auto
            $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::Auto
            [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)

            $pill = New-Object Windows.Controls.Border
            $pill.Background = ConvertTo-Brush $st.BadgeBg
            $pill.CornerRadius = [Windows.CornerRadius]::new(4)
            $pill.Padding = [Windows.Thickness]::new(6, 2, 6, 2)
            $pill.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
            $pill.VerticalAlignment = 'Center'
            $pillTxt = New-Object Windows.Controls.TextBlock
            $pillTxt.Text = $st.StatusLabel
            $pillTxt.Foreground = ConvertTo-Brush $st.BadgeFg
            $pillTxt.FontSize = 11.5
            $pillTxt.FontWeight = 'SemiBold'
            $pill.Child = $pillTxt
            [Windows.Controls.Grid]::SetColumn($pill, 0)
            [void]$g.Children.Add($pill)

            $stTitle = New-Object Windows.Controls.TextBlock
            $stTitle.Text = "步骤 $($st.Id)：$($st.Title)"
            $stTitle.FontSize = 12.5
            $stTitle.FontWeight = $(if ($st.Status -eq 'in_progress') { 'SemiBold' } else { 'Normal' })
            $stTitle.Foreground = ConvertTo-Brush $(if ($st.Status -eq 'pending') { '#71717A' } else { '#18181B' })
            $stTitle.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($stTitle, 1)
            [void]$g.Children.Add($stTitle)

            if ($st.UpdatedText) {
                $stTime = New-Object Windows.Controls.TextBlock
                $stTime.Text = $st.UpdatedText
                $stTime.FontSize = 11.5
                $stTime.Foreground = ConvertTo-Brush '#71717A'
                $stTime.FontFamily = New-Object Windows.Media.FontFamily('Consolas, Cascadia Mono, Source Han Serif SC VF, Noto Serif SC')
                $stTime.VerticalAlignment = 'Center'
                [Windows.Controls.Grid]::SetColumn($stTime, 2)
                [void]$g.Children.Add($stTime)
            }
            $b.Child = $g
            [void]$script:controls.DetailStepsPanel.Children.Add($b)
        }
    }

    $script:controls.DetailCommitsPanel.Children.Clear()
    if (@($commits).Count -eq 0) {
        $noCommit = New-Object Windows.Controls.TextBlock
        $noCommit.Text = '暂无关联代码库提交记录'
        $noCommit.Foreground = ConvertTo-Brush '#71717A'
        $noCommit.FontSize = 11.5
        [void]$script:controls.DetailCommitsPanel.Children.Add($noCommit)
    } else {
        foreach ($cm in $commits) {
            $cmBlock = New-Object Windows.Controls.TextBlock
            $cmBlock.Text = "● $($cm.TimeText) ($($cm.AgoText)) · [$($cm.Sha)] $($cm.Message)"
            $cmBlock.FontSize = 11.5
            $cmBlock.Foreground = ConvertTo-Brush '#18181B'
            $cmBlock.FontFamily = New-Object Windows.Media.FontFamily('Consolas, Cascadia Mono, Source Han Serif SC VF, Noto Serif SC')
            $cmBlock.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
            [void]$script:controls.DetailCommitsPanel.Children.Add($cmBlock)
        }
    }

    $script:controls.DetailCheckpointsPanel.Children.Clear()
    if (@($ckpts).Count -eq 0) {
        $noCkpt = New-Object Windows.Controls.TextBlock
        $noCkpt.Text = '暂无历史检查点记录'
        $noCkpt.Foreground = ConvertTo-Brush '#71717A'
        $noCkpt.FontSize = 12
        $noCkpt.Margin = [Windows.Thickness]::new(12, 8, 12, 8)
        [void]$script:controls.DetailCheckpointsPanel.Children.Add($noCkpt)
    } else {
        for ($i = 0; $i -lt @($ckpts).Count; $i++) {
            $ck = $ckpts[$i]
            $cb = New-Object Windows.Controls.Border
            $cb.BorderBrush = ConvertTo-Brush '#E4E4E7'
            $cb.BorderThickness = [Windows.Thickness]::new(0, 0, 0, $(if ($i -lt (@($ckpts).Count - 1)) { 1 } else { 0 }))
            $cb.Padding = [Windows.Thickness]::new(12, 7, 12, 7)
            $cTxt = New-Object Windows.Controls.TextBlock
            $cTxt.Text = "[$($ck.TimeText)] $($ck.Summary)"
            $cTxt.FontSize = 11.5
            $cTxt.Foreground = ConvertTo-Brush '#3F3F46'
            $cb.Child = $cTxt
            [void]$script:controls.DetailCheckpointsPanel.Children.Add($cb)
        }
    }
}

function Open-SessionDetail([string]$SessionKey) {
    if (-not $SessionKey) { return }
    $script:detailSessionKey = $SessionKey
    $script:lastDetailPanelSig = ''
    Update-SessionDetailModal
    $script:controls.DetailModalScroll.ScrollToTop()
    $script:controls.SessionDetailOverlay.Visibility = 'Visible'
    if ($script:controls.SessionDetailOverlay.Child) {
        Start-SmoothEnterAnimation $script:controls.SessionDetailOverlay.Child -FromY 8 -DurationMs 170
    }
}

function Close-SessionDetail {
    $script:detailSessionKey = ''
    $script:lastDetailPanelSig = ''
    $script:controls.SessionDetailOverlay.Visibility = 'Collapsed'
}

function Update-SessionCards {
    $sessions = @(if ($script:display -and $script:display.PSObject.Properties.Name -contains 'Sessions' -and $script:display.Sessions) { $script:display.Sessions })
    $archivedSessions = @(if ($script:display -and $script:display.PSObject.Properties.Name -contains 'ArchivedSessions' -and $script:display.ArchivedSessions) { $script:display.ArchivedSessions })
    $count = @($sessions).Count
    $archCount = @($archivedSessions).Count

    $script:controls.TabLiveButton.Content = if ($count -gt 0) { "实时网页主对话 ($count)" } else { '实时网页主对话' }
    $script:controls.ActiveQueueHeaderText.Text = "进行中任务 ($count)"
    if ($script:controls.ArchiveDrawerBtnText) {
        $script:controls.ArchiveDrawerBtnText.Text = "📦 归档管理 ($archCount)"
    }

    $hiddenCount = if ($script:display -and $script:display.PSObject.Properties.Name -contains 'HiddenIdleCount') { [int]$script:display.HiddenIdleCount } else { 0 }
    $subCount = if ($script:display -and $script:display.PSObject.Properties.Name -contains 'SubagentCallCount') { [int]$script:display.SubagentCallCount } else { 0 }
    if ($hiddenCount -gt 0) {
        $script:controls.FilterSummaryText.Text = "已合并 $subCount 次子代理 · 已自动清理 $hiddenCount 个超 15m 旧对话"
    } elseif ($subCount -gt 0) {
        $script:controls.FilterSummaryText.Text = "仅显示网页主对话 · 已合并 $subCount 次子代理调用"
    } else {
        $script:controls.FilterSummaryText.Text = '仅显示网页主对话 · 停工 >15m 自动清理'
    }

    $availModelsCount = @(if ($script:display -and $script:display.PSObject.Properties['AvailableModels'] -and $script:display.AvailableModels) { $script:display.AvailableModels }).Count
    $activeParts = @(foreach ($s in $sessions) {
        $sentArr = @(if ($s.PSObject.Properties['SentWebMessages'] -and $s.SentWebMessages) { $s.SentWebMessages })
        $sentCnt = $sentArr.Count
        $latestStSig = if ($sentCnt -gt 0 -and $sentArr[0].PSObject.Properties['Status']) { [string]$sentArr[0].Status } else { '' }
        $pendCntSig = if ($s.PSObject.Properties['PendingQueueCount']) { [int]$s.PendingQueueCount } else { 0 }
        $vStateSig = if ($s.PSObject.Properties['VitalState']) { [string]$s.VitalState } else { '' }
        $vHintSig  = if ($s.PSObject.Properties['VitalHintText']) { [string]$s.VitalHintText } else { '' }
        $vSubSig   = if ($s.PSObject.Properties['VitalSubstate']) { [string]$s.VitalSubstate } else { '' }
        if ($vSubSig -eq 'WAITING_CONFIRM' -and $s.PSObject.Properties['SilenceCountdownSec'] -and "$($s.SilenceCountdownSec)" -match '^\d+(\.\d+)?$') {
            $vSubSig += "~$([int][Math]::Floor([double]$s.SilenceCountdownSec / 10))"
        }
        $vHintSig = "$vHintSig/$vSubSig"
        $tModeSig = if ($s.PSObject.Properties['TargetMode']) { $s.TargetMode } else { '' }
        $bProfSig = if ($s.PSObject.Properties['BrowserProfile']) { $s.BrowserProfile } else { '' }
        $tModSig  = if ($s.PSObject.Properties['TargetModel']) { $s.TargetModel } else { '' }
        $effSig   = if ($s.PSObject.Properties['ReasoningEffort']) { $s.ReasoningEffort } else { '' }
        $webModSig = if ($s.PSObject.Properties['WebCurrentModel']) { $s.WebCurrentModel } else { '' }
        $webEffSig = if ($s.PSObject.Properties['WebCurrentEffort']) { $s.WebCurrentEffort } else { '' }
        $arEnSig  = if ($s.PSObject.Properties['AutoResendEnabled']) { $s.AutoResendEnabled } else { '' }
        $stMinSig = if ($s.PSObject.Properties['StallMinutes']) { $s.StallMinutes } else { '' }
        $stSecSig = if ($s.PSObject.Properties['StallSeconds']) { $s.StallSeconds } else { '' }
        $maxRtySig = if ($s.PSObject.Properties['MaxRetries']) { $s.MaxRetries } else { '' }
        "$($s.SessionKey):$($s.Title):$($s.StatusBadge):$($s.ProgressPercent):$($s.IsStalled):$($s.LatestSummary):$($s.RetryCount):${sentCnt}:${latestStSig}:${pendCntSig}:${vStateSig}:${vHintSig}:${tModeSig}:${bProfSig}:${tModSig}:${effSig}:${webModSig}:${webEffSig}:${arEnSig}:${stMinSig}:${stSecSig}:${maxRtySig}"
    })
    $archParts = @(foreach ($ar in $archivedSessions) { "$($ar.SessionKey):$($ar.Title):$($ar.ArchiveReason)" })
    $paneParts = @(foreach ($p in @($script:layout.Panes)) { "$($p.id):$($p.session_key):$($p.show_summary):$([Math]::Round([double]$p.width_weight,1)):lp=$($script:launchpadPaneIds.ContainsKey([int]$p.id)):pk=$($script:pickerPaneIds.ContainsKey([int]$p.id))" })
    $focusedElem = [Windows.Input.Keyboard]::FocusedElement
    $isTypingInComposer = ($focusedElem -is [Windows.Controls.TextBox]) -and (-not $focusedElem.Name)
    $cardsSig = ($activeParts -join ';') + '||' + ($archParts -join ';') + '||' + ($paneParts -join ';') + "||$($script:layout.RailCollapsed)|$($script:layout.ShowArchived)|m=$availModelsCount"
    if ($cardsSig -eq $script:lastCardsSig -and ($count -eq 0 -or $script:controls.SessionListPanel.Children.Count -eq $count) -and (-not $script:deferredPaneRebuildWhileTyping -or $isTypingInComposer)) {
        if ($script:detailSessionKey) { Update-SessionDetailModal }
        return
    }
    $prevPaneSig = $script:lastPaneSig
    $curPaneSig = ($paneParts -join ';') + "|$($script:layout.RailCollapsed)"
    $script:lastCardsSig = $cardsSig
    $script:lastPaneSig = $curPaneSig

    # Populate Left Rail Active Tasks (Prototype-aligned 2-row card with hover-revealed action icons)
    $script:controls.SessionListPanel.Children.Clear()
    if ($count -eq 0) {
        $script:controls.EmptySessionBox.Visibility = 'Visible'
        if ($script:controls.GoConfigButton) {
            $script:controls.GoConfigButton.Visibility = if ($script:display -and $script:display.IsFault) { 'Visible' } else { 'Collapsed' }
        }
    } else {
        $script:controls.EmptySessionBox.Visibility = 'Collapsed'
        $firstPaneKey = if (@($script:layout.Panes).Count -gt 0) { [string]$script:layout.Panes[0].session_key } else { '' }
        foreach ($s in $sessions) {
            $isStalled = ($s.PSObject.Properties.Name -contains 'IsStalled') -and [bool]$s.IsStalled
            $isOpenedInAnyPane = @($script:layout.Panes | Where-Object { $_.session_key -eq $s.SessionKey }).Count -gt 0
            $isActiveFirst = ($firstPaneKey -eq $s.SessionKey) -or (-not $firstPaneKey -and $s -eq $sessions[0])

            $rowBorder = New-Object Windows.Controls.Border
            $rowBorder.Background = ConvertTo-Brush $(if ($isActiveFirst) { '#FFFFFF' } else { 'Transparent' })
            $rowBorder.BorderBrush = ConvertTo-Brush $(if ($isActiveFirst) { '#E4E4E7' } else { 'Transparent' })
            $rowBorder.BorderThickness = [Windows.Thickness]::new(1)
            $rowBorder.CornerRadius = [Windows.CornerRadius]::new(8)
            $rowBorder.Padding = [Windows.Thickness]::new(10, 8, 10, 8)
            $rowBorder.Margin = [Windows.Thickness]::new(0, 0, 0, 5)
            $rowBorder.Cursor = [Windows.Input.Cursors]::Hand
            if ($isActiveFirst) {
                $cardShadow = New-Object Windows.Media.Effects.DropShadowEffect
                $cardShadow.BlurRadius = 6; $cardShadow.ShadowDepth = 1; $cardShadow.Opacity = 0.04; $cardShadow.Color = [Windows.Media.Color]::FromRgb(24, 24, 27)
                $rowBorder.Effect = $cardShadow
            }

            $stack = New-Object Windows.Controls.StackPanel
            $topGrid = New-Object Windows.Controls.Grid
            $tc0 = New-Object Windows.Controls.ColumnDefinition; $tc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $tc1 = New-Object Windows.Controls.ColumnDefinition; $tc1.Width = [Windows.GridLength]::Auto
            [void]$topGrid.ColumnDefinitions.Add($tc0); [void]$topGrid.ColumnDefinitions.Add($tc1)

            $leftStack = New-Object Windows.Controls.StackPanel
            $leftStack.Orientation = 'Horizontal'
            $leftStack.VerticalAlignment = 'Center'
            $dot = New-Object Windows.Shapes.Ellipse
            $dot.Width = 7; $dot.Height = 7
            $dot.Fill = ConvertTo-Brush $s.DotColor
            $dot.VerticalAlignment = 'Center'
            $dot.Margin = [Windows.Thickness]::new(0, 0, 7, 0)
            [void]$leftStack.Children.Add($dot)

            $tBlock = New-Object Windows.Controls.TextBlock
            $tBlock.Text = $(if ($s.PSObject.Properties.Name -contains 'ShortTitle' -and $s.ShortTitle) { $s.ShortTitle } else { $s.Title })
            $tBlock.FontSize = 12.5
            $tBlock.FontWeight = 'SemiBold'
            $tBlock.Foreground = ConvertTo-Brush '#18181B'
            $tBlock.TextTrimming = 'CharacterEllipsis'
            $tBlock.TextWrapping = 'NoWrap'
            [void]$leftStack.Children.Add($tBlock)
            [Windows.Controls.Grid]::SetColumn($leftStack, 0)
            [void]$topGrid.Children.Add($leftStack)

            # Hover-revealed quick action icons (Collapsed by default so title gets full width!)
            $actRow = New-Object Windows.Controls.StackPanel
            $actRow.Orientation = 'Horizontal'
            $actRow.VerticalAlignment = 'Center'
            $actRow.Margin = [Windows.Thickness]::new(4, 0, 0, 0)
            $actRow.Visibility = 'Collapsed'

            $webMiniBtn = New-QuietIconButton -Kind 'externalLink' -ToolTip '一键跳转到对应的 ChatGPT 网页标签页' -BoxSize 21 -IconSize 12.5 -Tag $s.SessionKey
            $webMiniBtn.Margin = [Windows.Thickness]::new(0, 0, 1, 0)
            $webMiniBtn.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                if ($sender.Tag) { Invoke-OpenSessionWebPage ([string]$sender.Tag) }
            })
            [void]$actRow.Children.Add($webMiniBtn)

            $archMiniBtn = New-QuietIconButton -Kind 'archive' -ToolTip '归档此任务' -BoxSize 21 -IconSize 12.5 -Tag $s.SessionKey
            $archMiniBtn.Add_Click({
                param($sender, $e)
                $e.Handled = $true
                if ($sender.Tag) { Invoke-ArchiveSession ([string]$sender.Tag) }
            })
            [void]$actRow.Children.Add($archMiniBtn)

            [Windows.Controls.Grid]::SetColumn($actRow, 1)
            [void]$topGrid.Children.Add($actRow)
            [void]$stack.Children.Add($topGrid)

            # Row 2: Left = Step Count (已完成 5 / 7 步), Right = Concise Status (执行中 / 停顿中) matching prototype-variants.html
            $subGrid = New-Object Windows.Controls.Grid
            $sc0 = New-Object Windows.Controls.ColumnDefinition; $sc0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $sc1 = New-Object Windows.Controls.ColumnDefinition; $sc1.Width = [Windows.GridLength]::Auto
            [void]$subGrid.ColumnDefinitions.Add($sc0); [void]$subGrid.ColumnDefinitions.Add($sc1)
            $subGrid.Margin = [Windows.Thickness]::new(14, 3, 0, 0)

            $subBlock = New-Object Windows.Controls.TextBlock
            $stepsCnt = @(if ($s.PSObject.Properties['Steps'] -and $s.Steps) { $s.Steps }).Count
            $subBlock.Text = if ($stepsCnt -gt 0 -and $s.StepCountText) {
                "已完成 $($s.StepCountText -replace '\s*步已完成',' 步')"
            } elseif ($s.PSObject.Properties.Name -contains 'RailSubtitle' -and $s.RailSubtitle) {
                $s.RailSubtitle
            } else {
                $s.ActionText
            }
            $subBlock.FontSize = 11
            $subBlock.Foreground = ConvertTo-Brush '#71717A'
            $subBlock.TextTrimming = 'CharacterEllipsis'
            $subBlock.TextWrapping = 'NoWrap'
            [Windows.Controls.Grid]::SetColumn($subBlock, 0)
            [void]$subGrid.Children.Add($subBlock)

            $statusRightTxt = New-Object Windows.Controls.TextBlock
            $cardVital = Get-VitalSubstateVisual $s
            $statusRightTxt.FontSize = 11
            if ($cardVital) {
                # Spec v4.7 §3.4: fine-grained StatusBadge derived locally from VitalSubstate
                $statusRightTxt.Text = $cardVital.Badge
                $statusRightTxt.FontWeight = 'SemiBold'
                $statusRightTxt.Foreground = ConvertTo-Brush $cardVital.Fg
                $statusRightTxt.ToolTip = $cardVital.PillText
            } else {
                $statusRightTxt.Text = $(if ($isStalled) { '停顿中' } else { '执行中' })
                $statusRightTxt.FontWeight = $(if ($isStalled) { 'SemiBold' } else { 'Normal' })
                $statusRightTxt.Foreground = ConvertTo-Brush $(if ($isStalled) { '#B45309' } else { '#15803D' })
            }
            $statusRightTxt.Margin = [Windows.Thickness]::new(6, 0, 0, 0)
            [Windows.Controls.Grid]::SetColumn($statusRightTxt, 1)
            [void]$subGrid.Children.Add($statusRightTxt)
            [void]$stack.Children.Add($subGrid)

            # Row 3: Per-task independent config summary tag [跟随原窗 | Thinking | 默认宿主]
            $modeShort = if ($s.PSObject.Properties['TargetMode'] -and $s.TargetMode -eq 'new_window') { '新窗交接' } else { '跟随原窗' }
            $modelRaw = if ($s.PSObject.Properties['TargetModel'] -and $s.TargetModel -and $s.TargetModel -ne 'inherit') { [string]$s.TargetModel }
                        elseif ($s.PSObject.Properties['WebCurrentModel'] -and $s.WebCurrentModel) { [string]$s.WebCurrentModel }
                        else { '跟随网页' }
            $modelShort = ($modelRaw -replace '^GPT-[0-9.]+\s*','' -replace '^gpt-[0-9.]+\s*','' -replace '^GPT-','')
            if (-not $modelShort) { $modelShort = $modelRaw }
            $availProfsForRow = @(Get-AvailableBrowserProfiles)
            $profRaw = if ($s.PSObject.Properties['BrowserProfile'] -and $s.BrowserProfile) { [string]$s.BrowserProfile } else { Resolve-RelayBrowserProfile '' $script:context }
            $matchedRowProf = $availProfsForRow | Where-Object { $_.Id -eq $profRaw } | Select-Object -First 1
            $profShort = if ($matchedRowProf -and $matchedRowProf.Label) {
                if ($profRaw -eq 'Desktop:ChatGPT') { '桌面客户端' }
                else { ([string]$matchedRowProf.Label -replace '^(💻|🌐)\s*', '' -replace '^Chrome\s*·\s*', '' -replace '\s*·\s*', '·').Trim() }
            } else {
                ($profRaw -replace '^[^:]+:','')
            }
            $cfgTagTxt = New-Object Windows.Controls.TextBlock
            $cfgTagTxt.Text = "[$modeShort | $modelShort | $profShort]"
            $cfgTagTxt.FontSize = 10.5
            $cfgTagTxt.Foreground = ConvertTo-Brush '#2563EB'
            $cfgTagTxt.Margin = [Windows.Thickness]::new(14, 2, 0, 0)
            $cfgTagTxt.TextTrimming = 'CharacterEllipsis'
            $cfgTagTxt.TextWrapping = 'NoWrap'
            [void]$stack.Children.Add($cfgTagTxt)

            $rowBorder.Tag = [pscustomobject]@{
                SessionKey = $s.SessionKey
                ActRow = $actRow
                IsActive = $isActiveFirst
            }
            $rowBorder.Add_MouseEnter({
                param($sender, $e)
                $info = $sender.Tag
                if ($info -and $info.ActRow) {
                    $info.ActRow.Visibility = 'Visible'
                }
                if ($info -and -not $info.IsActive) {
                    $sender.Background = ConvertTo-Brush '#F4F4F5'
                }
            })
            $rowBorder.Add_MouseLeave({
                param($sender, $e)
                $info = $sender.Tag
                if ($info -and $info.ActRow) {
                    $info.ActRow.Visibility = 'Collapsed'
                }
                if ($info -and -not $info.IsActive) {
                    $sender.Background = ConvertTo-Brush 'Transparent'
                }
            })
            $rowBorder.Add_MouseLeftButtonUp({
                param($sender, $e)
                $info = $sender.Tag
                if ($info -and $info.SessionKey) { Open-TaskFromRail ([string]$info.SessionKey) }
            })

            $rowBorder.Child = $stack
            [void]$script:controls.SessionListPanel.Children.Add($rowBorder)
        }
    }

    if (-not ($isTypingInComposer -and $prevPaneSig -eq $curPaneSig -and $script:controls.PanesHostGrid.Children.Count -gt 0)) {
        Render-PanesWorkspace
    } else {
        $script:deferredPaneRebuildWhileTyping = $true
        foreach ($sLive in $sessions) {
            if ($sLive -and $sLive.SessionKey) {
                Update-SessionQueueUI -SessionKey ([string]$sLive.SessionKey) -FallbackSession $sLive
            }
        }
    }
    if ($script:detailSessionKey) { Update-SessionDetailModal }
}

function Show-Feedback([string]$Text, [bool]$Failure = $false) {
    $script:controls.FeedbackText.Text = $Text
    $fgHex = if ($Failure) { '#8A241C' } else { '#234975' }
    $bgHex = if ($Failure) { '#FDEDE9' } else { '#EFF4FC' }
    $script:controls.FeedbackText.Foreground = ConvertTo-Brush $fgHex
    $script:controls.FeedbackBox.Background = ConvertTo-Brush $bgHex
    if ($script:controls.FeedbackReconnectButton) {
        $script:controls.FeedbackReconnectButton.Visibility = if ($Text -match '已断开') { 'Visible' } else { 'Collapsed' }
    }
    $script:controls.FeedbackBox.Visibility = 'Visible'
}

function Refresh-SecretHints {
    $script:controls.KeyHint.Text = if (Test-SavedOpenAIKey $script:context) { '密钥已保存。留空可继续使用；粘贴新密钥可替换。' } else { '粘贴密钥本身。保存后加密存放，输入框不会保留明文。' }
}

function Save-Form {
    $curPlat = if ($script:activeCapsulePlatform) { $script:activeCapsulePlatform.Trim().ToLowerInvariant() } else { 'chatgpt' }
    if ($curPlat -eq 'openai') { $curPlat = 'chatgpt' }
    $enteredKey = $script:controls.KeyInput.Text
    $enteredName = if ($script:controls.ProfileNameInput -and $script:controls.ProfileNameInput.Text.Trim()) {
        $script:controls.ProfileNameInput.Text.Trim()
    } else { '' }
    if ($curPlat -ne 'chatgpt') {
        $script:lastTestedApiKeyProfileId = ''
        $script:lastTestedApiKeyProfileSig = ''
        $platProfs = @(if ($script:profilesState -and $script:profilesState.Profiles) {
            $script:profilesState.Profiles | Where-Object { ([string]$_.Platform).ToLowerInvariant() -eq $curPlat }
        })
        $activeProf = $platProfs | Where-Object { $_.IsActive } | Select-Object -First 1
        $targetProfId = if ($script:viewingProfileId) { $script:viewingProfileId } elseif ($activeProf) { $activeProf.Id } else { 'new' }
        $existingTarget = $platProfs | Where-Object { $_.Id -eq $targetProfId } | Select-Object -First 1
        $preserveEnabled = if ($existingTarget) { [bool]$existingTarget.Enabled } else { $false }
        $isEditingActive = (-not $activeProf) -or ($targetProfId -eq $activeProf.Id) -or ($platProfs.Count -le 1 -and $targetProfId -ne 'new')
        if ($script:controls.TunnelInput.Text.Trim()) { [void](ConvertTo-PublicMcpUrl $script:controls.TunnelInput.Text) }
        $savedState = Save-ConnectionProfile -Context $script:context -Settings $script:settings -ProfileId $targetProfId -Name $enteredName -TunnelId '' -ApiKey $enteredKey -Platform $curPlat -Kind 'public_tunnel' -BaseUrl $script:controls.TunnelInput.Text -Enabled $preserveEnabled -SetActive:$isEditingActive
        if ($savedState -and $savedState.PSObject.Properties['LastSavedProfileId'] -and $savedState.LastSavedProfileId) {
            $script:viewingProfileId = $savedState.LastSavedProfileId
        }
    } else {
        $coreCfg = Get-CoreEngineConfig $script:context
        $candidate = [pscustomobject]@{
            schema_version = 1; tunnel_id = $script:controls.TunnelInput.Text; api_base_url = $script:controls.BaseInput.Text
            runtime_root = $script:controls.RootInput.Text; tunnel_client = $script:controls.ClientInput.Text
            health_port = 8789; credential_revision = $script:settings.credential_revision
            readonly_shield = [bool]$script:controls.ShieldCheck.IsChecked; shield_port = $script:settings.shield_port
            core_port = $coreCfg.CorePort
            acp_max_concurrent_prompts = $coreCfg.AcpMaxConcurrentPrompts
            acp_default_profile = $coreCfg.AcpDefaultProfile
            browser_enabled = $coreCfg.BrowserEnabled
            startup_mode = $coreCfg.StartupMode
        }
        $activeProf = if ($script:profilesState -and $script:profilesState.Profiles) {
            $script:profilesState.Profiles | Where-Object { (-not $_.Platform -or $_.Platform -in @('chatgpt', 'openai')) -and $_.IsActive } | Select-Object -First 1
        } else { $null }
        $targetProfId = if ($script:viewingProfileId) { $script:viewingProfileId } else {
            if ($activeProf) { $activeProf.Id } else { 'prof_primary' }
        }
        $isEditingActive = (-not $activeProf) -or ($targetProfId -eq $activeProf.Id) -or (@($script:profilesState.Profiles | Where-Object { -not $_.Platform -or $_.Platform -in @('chatgpt', 'openai') }).Count -le 1 -and $targetProfId -ne 'new')
        if ($isEditingActive -and $script:controls.TunnelInput.Text.Trim()) {
            Save-ConnectionSettings -Context $script:context -Settings $candidate -ApiKey $enteredKey
            $script:settings = Read-ConnectionSettings $script:context
        } elseif ($script:controls.TunnelInput.Text.Trim()) {
            [void](ConvertTo-TunnelId $script:controls.TunnelInput.Text)
        }
        $savedState = Save-ConnectionProfile -Context $script:context -Settings $script:settings -ProfileId $targetProfId -Name $enteredName -TunnelId $script:controls.TunnelInput.Text -ApiKey $enteredKey -Platform 'chatgpt' -Kind 'tunnel' -SetActive:$isEditingActive
        if ($savedState -and $savedState.PSObject.Properties['LastSavedProfileId'] -and $savedState.LastSavedProfileId) {
            $script:viewingProfileId = $savedState.LastSavedProfileId
        } elseif ($savedState -and $savedState.ActiveProfileId) {
            $script:viewingProfileId = $savedState.ActiveProfileId
        }
        if ($script:controls.TunnelInput.Text.Trim()) {
            $script:controls.TunnelInput.Text = [string](ConvertTo-TunnelId $script:controls.TunnelInput.Text)
        }
    }
    $script:dirty = $false
    $script:popoverEditMode = $false
    $script:popoverExpandedProfileId = ''
    $script:activeTab = 'Live'
    if ($script:controls.FormScroll) { $script:controls.FormScroll.Visibility = 'Collapsed' }
    if ($script:controls.PopoverDetailCardBorder) { $script:controls.PopoverDetailCardBorder.Visibility = 'Collapsed' }
    Refresh-SecretHints
    Refresh-ProfilePopoverState
}

function Update-PulseBanner {
    if (-not $script:display) { return }
    if ($script:controls.TopHeartbeatText) {
        $nth = if ($script:display.PSObject.Properties['NonTaskHeartbeat']) { $script:display.NonTaskHeartbeat } else { $null }
        $nthCount = if ($nth -and $nth.PSObject.Properties['count'] -and [int]$nth.count -gt 0) { [int]$nth.count } else { 0 }
        if ($script:display.IsFault) {
            $script:controls.TopHeartbeatPillBorder.Visibility = 'Visible'
            $script:controls.TopHeartbeatText.Text = '隧道告警: 请检查连接'
            $script:controls.TopHeartbeatText.Foreground = ConvertTo-Brush '#B91C1C'
            $script:controls.TopHeartbeatDot.Fill = ConvertTo-Brush '#EF4444'
            $script:controls.TopHeartbeatPillBorder.Background = ConvertTo-Brush '#FEF2F2'
            $script:controls.TopHeartbeatPillBorder.BorderBrush = ConvertTo-Brush '#FECACA'
        } else {
            $script:controls.TopHeartbeatPillBorder.Visibility = 'Collapsed'
        }
    }
    $script:controls.SessionStatus.Text = $script:display.Session
    $script:controls.SessionStatus.Foreground = ConvertTo-Brush $script:display.SessionColor
    $isFault = ($script:display.PSObject.Properties.Name -contains 'IsFault') -and [bool]$script:display.IsFault
    if ($isFault) {
        $script:controls.PulseBannerBorder.Visibility = 'Visible'
        $script:controls.PulseBannerBorder.Background = ConvertTo-Brush '#FEF2F2'
        $script:controls.PulseBannerBorder.BorderBrush = ConvertTo-Brush '#FECACA'
        $script:controls.PulsePrefixLabel.Text = '⚠ 通道故障告警：'
        $script:controls.PulsePrefixLabel.Foreground = ConvertTo-Brush '#991B1B'
        $script:controls.PulsePrefixLabel.FontWeight = 'Bold'
    } else {
        $script:controls.PulseBannerBorder.Visibility = 'Collapsed'
        $script:controls.PulseBannerBorder.Background = ConvertTo-Brush '#EEF2F6'
        $script:controls.PulseBannerBorder.BorderBrush = ConvertTo-Brush '#E2E8F0'
        $script:controls.PulsePrefixLabel.Text = '通道总览：'
        $script:controls.PulsePrefixLabel.Foreground = ConvertTo-Brush '#475569'
        $script:controls.PulsePrefixLabel.FontWeight = 'Normal'
    }
}

function Invoke-QueueFastPollTick {
    if ($script:pollInFlight -or $script:busy -or $script:context.Isolated) { return }
    if (-not (Test-ShouldRunUiRefreshTimer -IsVisible ([bool]$script:window.IsVisible) -WindowState $script:window.WindowState -IsActive ([bool]$script:window.IsActive) -Busy ([bool]$script:busy))) {
        if ($script:queueFastTimer -and $script:queueFastTimer.IsEnabled) { $script:queueFastTimer.Stop() }
        return
    }
    $script:pollInFlight = $true
    try {
        $digest = Invoke-StudioHubQueueDigest -Context $script:context -SinceRev $script:lastQueueRev
        if ($digest -and $digest.ok) {
            $isNotMod = ($digest.PSObject.Properties['not_modified'] -and $digest.not_modified)
            if ($digest.PSObject.Properties['queue_rev'] -and $digest.queue_rev) {
                $script:lastQueueRev = [string]$digest.queue_rev
            }
            if ((-not $isNotMod) -and $digest.PSObject.Properties['queues'] -and $digest.queues) {
                foreach ($qp in $digest.queues.PSObject.Properties) {
                    if ($qp.Name -and $qp.Value) {
                        Apply-SessionQueueSlice -SessionKey ([string]$qp.Name) -QueueSlice $qp.Value
                    }
                }
            }
        }
    } catch { } finally {
        $script:pollInFlight = $false
    }
    Sync-QueueFastPollingState
}

function Refresh-FormState {
    param([switch]$ForceInfraProbe)
    $script:lastRefreshUtc = [DateTime]::UtcNow
    $script:display = Get-ConnectionDisplayState -Context $script:context -Settings $script:settings -ForceInfraProbe:$ForceInfraProbe
    $script:controls.CoreStatus.Text = $script:display.Core
    $script:controls.TunnelStatus.Text = $script:display.Tunnel
    Update-PulseBanner
    $dotHex = if ($script:display.IsFault) { '#EF4444' } elseif ($script:display.Running) { '#22C55E' } elseif ($script:display.Core -eq '已准备好') { '#F59E0B' } else { '#71717A' }
    $script:controls.TopStatusDot.Fill = ConvertTo-Brush $dotHex
    $script:controls.EndpointText.Text = '本地内核地址  ' + $script:display.Endpoint
    $script:controls.DetailText.Text = $script:display.Detail
    $script:controls.StatusButton.IsEnabled = [bool]$script:display.UiUrl
    $script:controls.DisconnectButton.IsEnabled = $script:display.Running
    if ($script:display.Running -and $script:controls.FeedbackBox.Visibility -eq 'Visible' -and $script:controls.FeedbackText.Text -match '已断开') {
        $script:controls.FeedbackBox.Visibility = 'Collapsed'
    }
    $coreReady = $script:display.Core -eq '已准备好'
    $legacy = $script:display.Tunnel -eq '旧脚本连接仍在运行'
    $script:controls.ConnectButton.Content = if ($legacy) { '断开旧隧道' } else { '保存并连接' }
    $script:controls.OfficialButton.Visibility = 'Collapsed'
    $script:controls.DisconnectButton.Visibility = if ($coreReady -and $legacy) { 'Collapsed' } else { 'Visible' }
    if ($coreReady -and $legacy) { $script:controls.DetailText.Text = '旧连接通向 8787。准备切换时，点击右上角“断开旧隧道”，再按新配置连接。' }
    if ($script:popoverOpen -or $script:globalSettingsOpen) {
        if ($script:controls.ConnIconStatusDot -and $script:display) {
            $capDotColor = if ($script:display.IsFault) { '#EF4444' } elseif ($script:display.Running) { '#16A34A' } elseif ($script:display.Core -eq '已准备好') { '#F59E0B' } else { '#A1A1AA' }
            $script:controls.ConnIconStatusDot.Fill = ConvertTo-Brush $capDotColor
        }
    } else {
        Refresh-ProfilePopoverState
    }
    Update-SessionCards
    Sync-QueueFastPollingState
}

function Open-OfficialPanel {
    [void](Restart-LocalCoreEngine $script:context $script:settings)
    Refresh-FormState
    Show-Feedback '已在后台自动启动或重启本地 RelayStudio 内核。'
}

function Invoke-FormAction([scriptblock]$Action) {
    if ($script:busy) { return }
    $script:busy = $true
    $script:controls.ConnectButton.IsEnabled = $false; $script:controls.SaveButton.IsEnabled = $false
    try { & $Action }
    catch {
        Select-WindowTab 'Config'
        if ($_.Exception.Message -match '访问令牌') { $script:controls.Advanced.IsExpanded = $true }
        Show-Feedback $_.Exception.Message $true
    } finally {
        $script:busy = $false
        $script:controls.ConnectButton.IsEnabled = $true; $script:controls.SaveButton.IsEnabled = $true
    }
}

$script:controls.TunnelInput.Text = $script:settings.tunnel_id
$script:controls.BaseInput.Text = $script:settings.api_base_url
$script:controls.RootInput.Text = $script:settings.runtime_root
$script:controls.ClientInput.Text = $script:settings.tunnel_client
$script:controls.ShieldCheck.IsChecked = [bool]$script:settings.readonly_shield
Refresh-SecretHints
Apply-LeftRailGeometry
if ($script:controls.AppTitleBarBorder) {
    Attach-WindowTitleDrag $script:controls.AppTitleBarBorder
}
if ($script:controls.LeftRailHeaderBorder) {
    Attach-WindowTitleDrag $script:controls.LeftRailHeaderBorder
}
if ($script:controls.AppMinButton) {
    $script:controls.AppMinButton.Add_Click({
        $script:window.WindowState = [Windows.WindowState]::Minimized
    })
}
if ($script:controls.AppMaxButton) {
    $script:controls.AppMaxButton.Add_Click({
        $script:window.WindowState = if ($script:window.WindowState -eq [Windows.WindowState]::Maximized) {
            [Windows.WindowState]::Normal
        } else {
            [Windows.WindowState]::Maximized
        }
    })
}
if ($script:controls.AppCloseButton) {
    $script:controls.AppCloseButton.Add_MouseEnter({
        param($s, $e)
        $s.Background = ConvertTo-Brush '#FEE2E2'
        if ($script:controls.AppCloseIconPath) { $script:controls.AppCloseIconPath.Stroke = ConvertTo-Brush '#DC2626' }
    })
    $script:controls.AppCloseButton.Add_MouseLeave({
        param($s, $e)
        $s.Background = ConvertTo-Brush 'Transparent'
        if ($script:controls.AppCloseIconPath) { $script:controls.AppCloseIconPath.Stroke = ConvertTo-Brush '#52525B' }
    })
    $script:controls.AppCloseButton.Add_Click({
        $script:window.Close()
    })
}

foreach ($name in @('TunnelInput','KeyInput','BaseInput','RootInput','ClientInput')) {
    $script:controls[$name].Add_TextChanged({ if (-not $script:initializing) { $script:dirty = $true } })
}
$script:controls.ShieldCheck.Add_Checked({ if (-not $script:initializing) { $script:dirty = $true } })
$script:controls.ShieldCheck.Add_Unchecked({ if (-not $script:initializing) { $script:dirty = $true } })
$script:controls.TunnelInput.Add_LostFocus({
    try { $script:controls.TunnelInput.Text = ConvertTo-TunnelId $script:controls.TunnelInput.Text } catch { }
})

# Left Rail Collapse & Drag-to-Auto-Hide (< 145px) Events
$script:controls.ToggleRailButton.Add_Click({ Toggle-LeftRail })
$script:controls.ResetLayoutButton.Add_Click({ Reset-DefaultWindowLayout })
if ($script:controls.TopHeartbeatPillBorder) {
    $script:controls.TopHeartbeatPillBorder.Add_MouseLeftButtonUp({ Toggle-KeyPopover })
}
$script:controls.UndoDeleteButton.Add_Click({ Invoke-UndoDeleteSession })
if ($script:controls.DismissUndoDeleteButton) {
    $script:controls.DismissUndoDeleteButton.Add_Click({ Dismiss-UndoDeleteBanner })
}
if ($script:controls.OpenArchiveDrawerButton) {
    $script:controls.OpenArchiveDrawerButton.Add_Click({ Open-ArchiveDrawer })
}
if ($script:controls.CloseArchiveDrawerButton) {
    $script:controls.CloseArchiveDrawerButton.Add_Click({ Close-ArchiveDrawer })
}
if ($script:controls.CloseSentHistoryButton) {
    $script:controls.CloseSentHistoryButton.Add_Click({ Close-SentHistoryModal })
}
if ($script:controls.ClearAllArchivedButton) {
    $script:controls.ClearAllArchivedButton.Add_Click({ Invoke-ClearAllArchivedSessions })
}
if ($script:controls.ToggleArchivedButton) {
    $script:controls.ToggleArchivedButton.Add_Click({
        $script:layout.ShowArchived = -not [bool]$script:layout.ShowArchived
        Sync-LayoutMemory
        Update-SessionCards
    })
}

$script:controls.RailResizerBar.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($script:railAnimTimer -and $script:railAnimTimer.IsEnabled) {
        $script:railAnimTimer.Stop()
    }
    $pt = $e.GetPosition($script:controls.P3BodyGrid)
    $script:railDragCtx = [pscustomobject]@{
        StartX = $pt.X
        WasCollapsed = [bool]$script:layout.RailCollapsed
        StartWidth = $(if ($script:layout.RailCollapsed) { 0.0 } else { [double]$script:layout.RailWidth })
    }
    [void]$sender.CaptureMouse()
    $e.Handled = $true
})
$script:controls.RailResizerBar.Add_MouseMove({
    param($sender, $e)
    if (-not $script:railDragCtx) { return }
    $ctx = $script:railDragCtx
    $pt = $e.GetPosition($script:controls.P3BodyGrid)
    $dx = $pt.X - $ctx.StartX
    $rawW = $ctx.StartWidth + $dx
    if ($ctx.WasCollapsed) {
        if ($rawW -gt 75.0) {
            $ctx.WasCollapsed = $false
            $script:layout.RailCollapsed = $false
            $script:controls.LeftTaskRail.Visibility = 'Visible'
            $script:controls.LeftTaskRail.Opacity = 1.0
            $script:controls.SnapHideRailBadge.Visibility = 'Collapsed'
            $clampedW = [Math]::Min($script:RAIL_MAX_WIDTH_PX, [Math]::Max($script:RAIL_MIN_WIDTH_PX, $rawW))
            $script:layout.RailWidth = [int][Math]::Round($clampedW)
            $script:controls.LeftRailColumn.Width = [Windows.GridLength]::new($clampedW)
        }
        return
    }
    if (-not $script:layout.RailCollapsed) {
        # Codex/ChatGPT Web style: hard stop at RAIL_MIN_WIDTH_PX (200px) so content never squishes;
        # if dragged past RAIL_SNAP_HIDE_PX (< 95px), immediately slide-close smoothly without any ghosting or black pill.
        if ($rawW -lt $script:RAIL_SNAP_HIDE_PX) {
            $script:railDragCtx = $null
            $sender.ReleaseMouseCapture()
            $script:layout.RailCollapsed = $true
            if ([double]$script:layout.RailWidth -lt $script:RAIL_MIN_WIDTH_PX) { $script:layout.RailWidth = 260 }
            Sync-LayoutMemory
            Start-LeftRailDrawerAnimation -FromW $script:RAIL_MIN_WIDTH_PX -ToW 0.0 -DurationMs 175
            return
        }
        $clampedW = [Math]::Min($script:RAIL_MAX_WIDTH_PX, [Math]::Max($script:RAIL_MIN_WIDTH_PX, $rawW))
        $script:layout.RailWidth = [int][Math]::Round($clampedW)
        $script:controls.LeftRailColumn.Width = [Windows.GridLength]::new($clampedW)
        $script:controls.LeftTaskRail.Opacity = 1.0
        $script:controls.SnapHideRailBadge.Visibility = 'Collapsed'
        Update-MemoryFootprintLabel
    }
})
$script:controls.RailResizerBar.Add_MouseLeftButtonUp({
    param($sender, $e)
    if (-not $script:railDragCtx) { return }
    $script:railDragCtx = $null
    $sender.ReleaseMouseCapture()
    Apply-LeftRailGeometry
    Sync-LayoutMemory
})

# Popover & Profile Card Events
if ($script:controls.ProfileNameInput) {
    $script:controls.ProfileNameInput.Add_TextChanged({ if (-not $script:initializing) { $script:dirty = $true } })
}
$script:controls.ConnIconBadgeButton.Add_Click({
    Select-CapsulePlatform 'chatgpt' $script:controls.ConnIconBadgeButton
})
if ($script:controls.AddPlatformCellButton) {
    $script:controls.AddPlatformCellButton.Add_Click({ Toggle-AddPlatformPopover })
}
if ($script:controls.RemoveCapsulePlatformButton) {
    $script:controls.RemoveCapsulePlatformButton.Add_Click({ Invoke-RemoveCurrentCapsulePlatform })
}
if ($script:controls.GlobalSettingsButton) {
    $script:controls.GlobalSettingsButton.Add_Click({ Toggle-GlobalSettingsPopover })
}
if ($script:controls.CloseGlobalSettingsButton) {
    $script:controls.CloseGlobalSettingsButton.Add_Click({
        Close-AllTopPopovers
    })
}
if ($script:controls.DismissKeyPopoverButton) {
    $script:controls.DismissKeyPopoverButton.Add_Click({
        Close-AllTopPopovers
    })
}
$script:controls.ClosePopoverButton.Add_Click({
    Close-AllTopPopovers
})
foreach ($outsideSurface in @($script:controls.WorkspaceOuterBorder, $script:controls.LeftTaskRail)) {
    if ($outsideSurface) {
        $outsideSurface.Add_PreviewMouseLeftButtonDown({
            if ($script:popoverOpen -or $script:globalSettingsOpen) {
                Close-AllTopPopovers
            }
        })
    }
}
$script:controls.TogglePopoverEditButton.Add_Click({
    if ($script:activeTab -eq 'Config') { Select-WindowTab 'Live' } else { Select-WindowTab 'Config' }
})
if ($script:controls.EditCurrentProfileLink) {
    $script:controls.EditCurrentProfileLink.Add_Click({ Enter-ProfileEditMode $script:viewingProfileId })
}
if ($script:controls.ConfirmDetailButton) {
    $script:controls.ConfirmDetailButton.Add_Click({
        $script:popoverExpandedProfileId = ''
        $script:popoverEditMode = $false
        Refresh-ProfilePopoverState
    })
}
if ($script:controls.CancelEditProfileButton) {
    $script:controls.CancelEditProfileButton.Add_Click({
        $script:dirty = $false
        $script:popoverEditMode = $false
        $script:popoverExpandedProfileId = ''
        $script:activeTab = 'Live'
        if ($script:viewingProfileId -eq 'new') {
            $activeProf = if ($script:profilesState -and $script:profilesState.Profiles) {
                $script:profilesState.Profiles | Where-Object { $_.IsActive } | Select-Object -First 1
            } else { $null }
            $script:viewingProfileId = if ($activeProf) { $activeProf.Id } else { 'prof_primary' }
        }
        Refresh-ProfilePopoverState
    })
}
if ($script:controls.AddProfileButton) {
    $script:controls.AddProfileButton.Add_Click({ Start-NewProfileForm })
}
if ($script:controls.DeleteProfileButton) {
    $script:controls.DeleteProfileButton.Add_Click({ Invoke-DeleteCurrentProfile })
}
$script:controls.ProfilePrimaryButton.Add_Click({ Select-ProfileCard 'prof_primary' })
$script:controls.ProfileBusinessButton.Add_Click({ Select-ProfileCard 'prof_business' })
if ($script:controls.QuickConnectButton) {
    $script:controls.QuickConnectButton.Add_Click({ Invoke-FormAction { Invoke-PopoverQuickConnect } })
}
if ($script:controls.FeedbackReconnectButton) {
    $script:controls.FeedbackReconnectButton.Add_Click({ Invoke-FormAction { Invoke-PopoverQuickConnect } })
}
if ($script:controls.DismissFeedbackButton) {
    $script:controls.DismissFeedbackButton.Add_Click({ $script:controls.FeedbackBox.Visibility = 'Collapsed' })
}
$script:controls.ToggleKeyMaskButton.Add_Click({
    $script:keyMasked = -not $script:keyMasked
    Refresh-ProfilePopoverState
})
$script:controls.CopyApiKeyButton.Add_Click({
    $viewProf = $script:profilesState.Profiles | Where-Object { $_.Id -eq $script:viewingProfileId } | Select-Object -First 1
    $plain = if ($viewProf -and $viewProf.PlainKey) { $viewProf.PlainKey } else { Get-SavedOpenAIKeyPlaintext $script:context }
    if ($plain) {
        try { [Windows.Clipboard]::SetText($plain) } catch { }
        Show-QuickToast '已复制完整 API Key 到剪贴板'
    } else {
        Show-QuickToast '当前配置尚未保存 API Key'
    }
})
$script:controls.CopyTunnelIdButton.Add_Click({
    $viewProf = $script:profilesState.Profiles | Where-Object { $_.Id -eq $script:viewingProfileId } | Select-Object -First 1
    $tid = if ($viewProf -and $viewProf.TunnelId) { $viewProf.TunnelId } else { $script:settings.tunnel_id }
    if ($tid) {
        try { [Windows.Clipboard]::SetText($tid) } catch { }
        Show-QuickToast '已复制隧道编号到剪贴板'
    }
})
if ($script:controls.AcpLimit0Button) {
    $script:controls.AcpLimit0Button.Add_Click({ Set-AcpConcurrencyLimit -Context $script:context -Limit 0 | Out-Null; Refresh-ProfilePopoverState; Show-QuickToast '已关闭 CLI 智能体并发（上限设为 0）' })
}
$script:controls.AcpLimit2Button.Add_Click({ Set-AcpConcurrencyLimit -Context $script:context -Limit 2 | Out-Null; Refresh-ProfilePopoverState; Show-QuickToast '已将 CLI 智能体并发上限设为 2 个' })
$script:controls.AcpLimit4Button.Add_Click({ Set-AcpConcurrencyLimit -Context $script:context -Limit 4 | Out-Null; Refresh-ProfilePopoverState; Show-QuickToast '已将 CLI 智能体并发上限设为 4 个' })
$script:controls.AcpLimit6Button.Add_Click({ Set-AcpConcurrencyLimit -Context $script:context -Limit 6 | Out-Null; Refresh-ProfilePopoverState; Show-QuickToast '已将 CLI 智能体并发上限设为 6 个' })

foreach ($archBtnSpec in @(
    @{ Btn = $script:controls.AutoArchiveImmediateButton; Mode = 'immediate'; Label = '立即' },
    @{ Btn = $script:controls.AutoArchive1dButton;        Mode = '1d';        Label = '1 天' },
    @{ Btn = $script:controls.AutoArchive3dButton;        Mode = '3d';        Label = '3 天 (默认)' },
    @{ Btn = $script:controls.AutoArchive7dButton;        Mode = '7d';        Label = '7 天' },
    @{ Btn = $script:controls.AutoArchiveOffButton;       Mode = 'off';       Label = '关闭' }
)) {
    if ($archBtnSpec.Btn) {
        $archBtnSpec.Btn.Tag = [pscustomobject]@{ Mode = $archBtnSpec.Mode; Label = $archBtnSpec.Label }
        $archBtnSpec.Btn.Add_Click({
            param($s, $e)
            if (-not $s.Tag) { return }
            $cfg = Get-CoreEngineConfig $script:context
            $script:settings = (Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile ([string]$cfg.AcpDefaultProfile) -BrowserEnabled ([bool]$cfg.BrowserEnabled) -StartupMode ([string]$cfg.StartupMode) -AutoArchiveCompletedMode ([string]$s.Tag.Mode) -ApplyStartup:$false).Settings
            Refresh-ProfilePopoverState
            Show-QuickToast "已将完工任务自动归档设为「$($s.Tag.Label)」"
        })
    }
}

if ($script:controls.DefaultCarrierCombo) {
    $script:controls.DefaultCarrierCombo.Add_SelectionChanged({
        param($s, $e)
        if ($script:suppressDefaultCarrierComboEvent) { return }
        $selItem = $s.SelectedItem
        if (-not $selItem -or -not $selItem.Tag) { return }
        $chosenProf = [string]$selItem.Tag
        $cfg = Get-CoreEngineConfig $script:context
        $script:settings = (Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile ([string]$cfg.AcpDefaultProfile) -BrowserEnabled ([bool]$cfg.BrowserEnabled) -StartupMode ([string]$cfg.StartupMode) -DefaultBrowserProfile $chosenProf -ApplyStartup:$false).Settings
        Refresh-ProfilePopoverState
        Show-QuickToast "已将新建任务默认载体设为「$([string]$selItem.Content)」"
    })
}

if ($script:controls.RestartCoreButton) {
    $script:controls.RestartCoreButton.Add_Click({
        $ok = Restart-LocalCoreEngine $script:context $script:settings
        Refresh-FormState
        Refresh-ProfilePopoverState
        if ($ok -and $ok.Restarted) {
            Show-QuickToast '✓ 本地 RelayStudio 内核已重启并就绪'
        } else {
            Show-QuickToast '本地内核正在后台启动，请稍候刷新查看'
        }
    })
}
if ($script:controls.AcpProfileCodexButton) {
    $script:controls.AcpProfileCodexButton.Add_Click({
        Select-DefaultCliAgent 'codex' 'Codex'
    })
}
if ($script:controls.AcpProfileClaudeButton) {
    $script:controls.AcpProfileClaudeButton.Add_Click({
        Select-DefaultCliAgent 'claude' 'Claude'
    })
}
if ($script:controls.AddCustomCliAgentButton) {
    $script:controls.AddCustomCliAgentButton.Add_Click({
        Invoke-AddCustomCliAgentDialog
    })
}
if ($script:controls.RescanCliAgentsButton) {
    $script:controls.RescanCliAgentsButton.Add_Click({
        Invoke-RescanCliAgents
    })
}
if ($script:controls.BrowserCdpToggleButton) {
    $script:controls.BrowserCdpToggleButton.Add_Click({
        $cfg = Get-CoreEngineConfig $script:context
        $nextBrowser = -not [bool]$cfg.BrowserEnabled
        $script:settings = (Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile ([string]$cfg.AcpDefaultProfile) -BrowserEnabled $nextBrowser -StartupMode ([string]$cfg.StartupMode) -ApplyStartup:(-not $script:context.Isolated)).Settings
        if (-not $script:context.Isolated) { [void](Restart-LocalCoreEngine $script:context $script:settings) }
        Refresh-FormState
        Refresh-ProfilePopoverState
        Show-QuickToast ($(if ($nextBrowser) { '已开启浏览器自动化 (CDP)' } else { '已关闭浏览器自动化 (CDP)' }))
    })
}
if ($script:controls.StartupPopupButton) {
    $script:controls.StartupPopupButton.Add_Click({
        $cfg = Get-CoreEngineConfig $script:context
        $script:settings = (Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile ([string]$cfg.AcpDefaultProfile) -BrowserEnabled ([bool]$cfg.BrowserEnabled) -StartupMode 'popup' -ApplyStartup:(-not $script:context.Isolated)).Settings
        Refresh-ProfilePopoverState
        Show-QuickToast '已设为「开机弹窗」：登录 Windows 时自动打开工作台'
    })
}
if ($script:controls.StartupTrayButton) {
    $script:controls.StartupTrayButton.Add_Click({
        $cfg = Get-CoreEngineConfig $script:context
        $script:settings = (Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile ([string]$cfg.AcpDefaultProfile) -BrowserEnabled ([bool]$cfg.BrowserEnabled) -StartupMode 'tray' -ApplyStartup:(-not $script:context.Isolated)).Settings
        Refresh-ProfilePopoverState
        Show-QuickToast '已设为「静默托盘」：开机驻留右下角托盘并自动连好隧道'
    })
}
if ($script:controls.StartupOffButton) {
    $script:controls.StartupOffButton.Add_Click({
        $cfg = Get-CoreEngineConfig $script:context
        $script:settings = (Set-CoreEngineConfig -Context $script:context -AcpDefaultProfile ([string]$cfg.AcpDefaultProfile) -BrowserEnabled ([bool]$cfg.BrowserEnabled) -StartupMode 'off' -ApplyStartup:(-not $script:context.Isolated)).Settings
        Refresh-ProfilePopoverState
        Show-QuickToast '已关闭开机自启'
    })
}
if ($script:controls.ThemeToggleButton) {
    $script:controls.ThemeToggleButton.Add_Click({
        Invoke-QuickThemeToggle -Action 'invert'
    })
    $script:controls.ThemeToggleButton.Add_MouseRightButtonUp({
        param($sender, $e)
        $e.Handled = $true
        Invoke-QuickThemeToggle -Action 'system'
    })
}
if ($script:controls.ThemeSystemButton) {
    $script:controls.ThemeSystemButton.Add_Click({
        Invoke-QuickThemeToggle -Action 'system'
    })
}
if ($script:controls.ThemeLightButton) {
    $script:controls.ThemeLightButton.Add_Click({
        Invoke-QuickThemeToggle -Action 'light'
    })
}
if ($script:controls.ThemeDarkButton) {
    $script:controls.ThemeDarkButton.Add_Click({
        Invoke-QuickThemeToggle -Action 'dark'
    })
}
$script:window.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq [Windows.Input.Key]::D -and
        (([Windows.Input.Keyboard]::Modifiers -band ([Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift)) -eq ([Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift))) {
        $e.Handled = $true
        Invoke-QuickThemeToggle -Action 'invert'
    }
})

# Legacy & Compatibility Tab/Detail/Save Events
$script:controls.TabLiveButton.Add_Click({ Close-SessionDetail; Select-WindowTab 'Live' })
$script:controls.TabConfigButton.Add_Click({ Close-SessionDetail; Select-WindowTab 'Config' })
$script:controls.GoConfigButton.Add_Click({ Close-SessionDetail; Select-WindowTab 'Config' })
if ($script:controls.NewTaskRailButton) {
    $script:controls.NewTaskRailButton.Add_Click({ Enter-NewTaskLaunchpad })
}
$script:controls.CloseDetailButton.Add_Click({ Close-SessionDetail })
$script:controls.RefreshDetailButton.Add_Click({ Refresh-FormState })
$script:controls.SaveRenameButton.Add_Click({
    if ($script:renamingSessionKey) {
        Set-SessionAlias -Context $script:context -SessionKey $script:renamingSessionKey -Title $script:controls.RenameInput.Text
        Close-SessionRename
        Refresh-FormState
        Show-Feedback '已保存对话名称，与您的 ChatGPT 网页左栏保持对齐。'
    }
})
$script:controls.ResetRenameButton.Add_Click({
    if ($script:renamingSessionKey) {
        Set-SessionAlias -Context $script:context -SessionKey $script:renamingSessionKey -Title ''
        Close-SessionRename
        Refresh-FormState
        Show-Feedback '已恢复为自动识别的任务标题。'
    }
})
$script:controls.CancelRenameButton.Add_Click({ Close-SessionRename })
$script:controls.SaveButton.Add_Click({ Invoke-FormAction { Save-Form; Show-Feedback '配置已保存，密钥已加密。保存配置不会建立连接。' } })
$script:controls.ConnectButton.Add_Click({ Invoke-FormAction {
    if ($script:display.Tunnel -eq '旧脚本连接仍在运行') { Show-Feedback (Stop-ConnectionTunnel $script:context $script:settings); Refresh-FormState; Refresh-ProfilePopoverState; return }
    Save-Form
    Show-Feedback (Start-ConnectionTunnel $script:context $script:settings)
    Refresh-FormState
    Refresh-ProfilePopoverState
} })
$script:controls.DisconnectButton.Add_Click({
    Invoke-FormAction {
        $curPlat = if ($script:activeCapsulePlatform) { $script:activeCapsulePlatform.Trim().ToLowerInvariant() } else { 'chatgpt' }
        if ($curPlat -eq 'openai') { $curPlat = 'chatgpt' }
        if ($curPlat -ne 'chatgpt') {
            Stop-PublicMcpTunnel $script:context
            Refresh-ProfilePopoverState
            Show-QuickToast '已断开 Gemini 与 Claude 共享的公网隧道'
            return
        }
        Show-Feedback (Stop-ConnectionTunnel $script:context $script:settings)
        Refresh-FormState
        Refresh-ProfilePopoverState
    }
})
$script:controls.OfficialButton.Add_Click({ Invoke-FormAction { Open-OfficialPanel } })
$script:controls.PlatformButton.Add_Click({
    $pm = Get-CapsulePlatformMeta $script:activeCapsulePlatform
    Start-Process $pm.PlatUrl
})
$script:controls.ApiKeysButton.Add_Click({
    $pm = Get-CapsulePlatformMeta $script:activeCapsulePlatform
    Start-Process $pm.ApiKeysUrl
})
$script:controls.StatusButton.Add_Click({ if ($script:display.UiUrl) { Start-Process $script:display.UiUrl } })
$script:controls.BridgeExtButton.Add_Click({
    $extDir = Join-Path $PSScriptRoot 'browser-bridge'
    if (Test-Path -LiteralPath $extDir) {
        Start-Process explorer.exe -ArgumentList ('"' + $extDir + '"')
        try { [Windows.Clipboard]::SetText($extDir) } catch { }
        Show-QuickToast '已打开 browser-bridge 文件夹并复制路径，请在浏览器扩展页点击「加载已解压的扩展程序」'
    }
})
$script:controls.FolderButton.Add_Click({ [IO.Directory]::CreateDirectory($script:context.DataRoot) | Out-Null; Start-Process explorer.exe -ArgumentList ('"' + $script:context.DataRoot + '"') })
$script:controls.Advanced.Add_Expanded({
    Select-WindowTab 'Config'
})

$script:window.Add_SizeChanged({
    param($sender, $e)
    if ($script:initializing) { return }
    Request-DeferredLayoutSync
    if ($script:suppressSizeChangedRebuild) { return }
    if ($NoShow) {
        Render-PanesWorkspace
        return
    }
    if (-not $script:resizeDebounceTimer) {
        $script:resizeDebounceTimer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
        $script:resizeDebounceTimer.Interval = [TimeSpan]::FromMilliseconds(95)
        $script:resizeDebounceTimer.Add_Tick({
            $script:resizeDebounceTimer.Stop()
            Render-PanesWorkspace
        })
    }
    $script:resizeDebounceTimer.Stop()
    $script:resizeDebounceTimer.Start()
})

$script:allowRealExit = $false
$script:trayHintShown = $false

function Initialize-TrayContextMenu {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue
    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $itemOpen = $trayMenu.Items.Add('打开 RelayStudio 工作台')
    $itemOpen.Font = New-Object System.Drawing.Font($trayMenu.Font, [System.Drawing.FontStyle]::Bold)
    $itemOpen.Add_Click({ Restore-MainWindowFromTray })

    $itemReconnect = $trayMenu.Items.Add('一键重连本地内核与隧道')
    $itemReconnect.Add_Click({
        try {
            [void](Start-ConnectionTunnel $script:context $script:settings)
            Refresh-FormState
        } catch { }
    })

    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $script:trayItemThemeToggle = $trayMenu.Items.Add('🌙 切换深色 / 浅色模式 (Ctrl+Shift+D)')
    $script:trayItemThemeToggle.Add_Click({
        try { Invoke-QuickThemeToggle -Action 'invert' } catch { }
    })
    $script:trayItemThemeSystem = $trayMenu.Items.Add('🖥 外观主题：跟随系统')
    $script:trayItemThemeSystem.Add_Click({
        try { Invoke-QuickThemeToggle -Action 'system' } catch { }
    })

    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $itemExit = $trayMenu.Items.Add('彻底退出 RelayStudio（关闭后台服务）')
    $itemExit.Add_Click({
        $script:allowRealExit = $true
        try { [void](Stop-ConnectionTunnel $script:context $script:settings) } catch { }
        try {
            Get-Process -Name 'relaystudio-core' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        } catch { }
        if ($script:notifyIcon) {
            $script:notifyIcon.Visible = $false
        }
        try { $script:window.Close() } catch { }
        try { [System.Windows.Threading.Dispatcher]::ExitAllFrames() } catch { }
    })
    $script:trayMenu = $trayMenu
    Apply-WindowTheme
    return $trayMenu
}

function Restore-MainWindowFromTray {
    try {
        $script:window.ShowInTaskbar = $true
        if (-not $script:window.IsVisible) {
            $script:window.Show()
        }
        if ($script:window.WindowState -eq [Windows.WindowState]::Minimized) {
            $script:window.WindowState = [Windows.WindowState]::Normal
        }
        $interop = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
        if ($interop.Handle -ne [IntPtr]::Zero) {
            [void][Win32.NativeWin]::ShowWindow($interop.Handle, 9)
            [void][Win32.NativeWin]::SetForegroundWindow($interop.Handle)
        }
        [void]$script:window.Activate()
        Sync-ForegroundPollingState -RefreshImmediate $true
    } catch { }
}

$script:window.Add_Closing({
    param($sender, $eventArgs)
    Sync-LayoutMemory
    if ($NoShow -or $script:allowRealExit) {
        return
    }
    if (Test-HasUnsavedFormEdits) {
        $answer = [Windows.MessageBox]::Show('尚有未保存的输入。最小化到托盘前是否放弃这些未保存输入？', 'RelayStudio', 'OKCancel', 'Question')
        if ($answer -eq 'Cancel') {
            $eventArgs.Cancel = $true
            return
        }
        Select-WindowTab 'Live'
    }
    # Close-to-Tray: keep RelayStudio running in the system tray
    $eventArgs.Cancel = $true
    $script:window.ShowInTaskbar = $false
    $script:window.Hide()
    if ($timer -and $timer.IsEnabled) { $timer.Stop() }
    if ($script:notifyIcon -and -not $script:trayHintShown) {
        $script:trayHintShown = $true
        try {
            $script:notifyIcon.ShowBalloonTip(2000, 'RelayStudio 仍在后台运行', '双击右下角 R 托盘图标可随时唤出工作台；右键托盘图标可彻底退出。', [System.Windows.Forms.ToolTipIcon]::None)
        } catch { }
    }
})

Apply-WindowTheme
Select-WindowTab 'Live'
Refresh-FormState
$script:initializing = $false
$script:dirty = $false

$icoCandidates = @(
    (Join-Path $PSScriptRoot 'RelayStudio.ico'),
    (Join-Path ([string]$script:settings.runtime_root) 'RelayStudio.ico')
)
foreach ($icoPath in $icoCandidates) {
    if ($icoPath -and (Test-Path -LiteralPath $icoPath)) {
        try {
            $script:window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($icoPath, [UriKind]::Absolute))
            break
        } catch { }
    }
}

function Export-WindowRender([string]$Path) {
    [IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($Path)) -Parent)) | Out-Null
    $visual = $script:window.Content
    $visual.Background = ConvertTo-Brush '#F4F4F6'
    foreach ($el in @($script:controls.FormScroll, $script:controls.ProfilesListPanel, $script:controls.ProfilesListScroll, $script:controls.KeyPopoverBorder.Child, $script:controls.KeyPopoverBorder, $visual)) {
        if ($null -ne $el -and $el -is [Windows.UIElement]) {
            $el.InvalidateMeasure()
            $el.InvalidateArrange()
        }
    }
    $visual.Measure([Windows.Size]::new($script:window.Width, $script:window.Height))
    $visual.Arrange([Windows.Rect]::new(0, 0, $script:window.Width, $script:window.Height))
    $visual.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$script:window.Width, [int]$script:window.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $background = New-Object Windows.Media.DrawingVisual
    $drawing = $background.RenderOpen()
    $drawing.DrawRectangle((ConvertTo-Brush '#F4F4F6'), $null, [Windows.Rect]::new(0, 0, $script:window.Width, $script:window.Height))
    $drawing.Close()
    $bitmap.Render($background)
    $bitmap.Render($visual)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}
if ($RenderPath) { Export-WindowRender $RenderPath }
if ($RenderAdvancedPath) { Select-WindowTab 'Config'; $script:controls.Advanced.IsExpanded = $true; Export-WindowRender $RenderAdvancedPath; $script:controls.Advanced.IsExpanded = $false; Select-WindowTab 'Live' }
if ($RenderDetailPath) {
    $sessions = @(if ($script:display -and $script:display.Sessions) { $script:display.Sessions })
    if (@($sessions).Count -gt 0) { Open-SessionDetail $sessions[0].SessionKey }
    Export-WindowRender $RenderDetailPath
    Close-SessionDetail
}
if ($RenderArchivePath) {
    Open-ArchiveDrawer
    Export-WindowRender $RenderArchivePath
    Close-ArchiveDrawer
}
if ($NoShow) { return }

$created = $true
if ($script:earlyMutex -and $script:earlyRestoreEvent) {
    $mutex = $script:earlyMutex
    $restoreEvent = $script:earlyRestoreEvent
} else {
    $created = $false
    $mutex = New-Object Threading.Mutex($true, 'Local\RelayStudio.OpenAI.ConnectionManager', [ref]$created)
    $restoreEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\RelayStudio.OpenAI.RestoreEvent')
}
if (-not $created) {
    try { [void]$restoreEvent.Set() } catch { }
    Add-Type -Namespace Win32 -Name SingleInstanceRestore -MemberDefinition @'
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@ -ErrorAction SilentlyContinue
    try {
        $existingHwnd = [Win32.SingleInstanceRestore]::FindWindow($null, 'RelayStudio · 智能体接力与多栏工作台')
        if ($existingHwnd -ne [IntPtr]::Zero) {
            if ([Win32.SingleInstanceRestore]::IsIconic($existingHwnd)) {
                [void][Win32.SingleInstanceRestore]::ShowWindow($existingHwnd, 9)
            }
            [void][Win32.SingleInstanceRestore]::SetForegroundWindow($existingHwnd)
        }
    } catch {}
    $restoreEvent.Dispose()
    $mutex.Dispose()
    return
}

# Build System Tray Icon (NotifyIcon)
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
$script:notifyIcon = $null
try {
    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:notifyIcon.Text = 'RelayStudio · 智能体接力与多栏工作台'
    $trayIcoLoaded = $false
    foreach ($icoPath in $icoCandidates) {
        if ($icoPath -and (Test-Path -LiteralPath $icoPath)) {
            try {
                $script:notifyIcon.Icon = New-Object System.Drawing.Icon($icoPath)
                $trayIcoLoaded = $true
                break
            } catch { }
        }
    }
    if (-not $trayIcoLoaded) {
        $bmp = New-Object System.Drawing.Bitmap(32, 32)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 24, 24, 27))
        $g.FillEllipse($bgBrush, 1, 1, 30, 30)
        $font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString('R', $font, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new(0, 1, 32, 32), $sf)
        $g.Dispose()
        $script:notifyIcon.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
    $trayMenu = Initialize-TrayContextMenu
    $script:notifyIcon.ContextMenuStrip = $trayMenu
    $script:notifyIcon.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Restore-MainWindowFromTray
        }
    })
    $script:notifyIcon.Visible = $true
} catch { }

# Ensure Local Core & Tunnel Auto-Start on Launch asynchronously in a background Runspace (zero UI freeze)
$script:bootPs = $null
$script:bootAsyncHandle = $null
if (-not $script:context.Isolated) {
    $modPath = Join-Path $PSScriptRoot 'ConnectionManager.psm1'
    $bootDataRoot = [string]$script:context.DataRoot
    try {
        $script:bootPs = [powershell]::Create()
        [void]$script:bootPs.AddScript({
            param($ModulePath, $DataRoot)
            try {
                Import-Module $ModulePath -Force
                $ctx = New-ConnectionContext -DataRoot $DataRoot
                $cfg = Read-ConnectionSettings $ctx
                [void](Start-OfficialCoreIfNeeded $ctx $cfg)
                if ($cfg.tunnel_id -and (Test-SavedOpenAIKey $ctx)) {
                    $disp = Get-ConnectionDisplayState $ctx $cfg -ForceInfraProbe
                    if (-not $disp.Running) {
                        [void](Start-ConnectionTunnel $ctx $cfg)
                    }
                }
            } catch { }
        }).AddArgument($modPath).AddArgument($bootDataRoot)
        $script:bootAsyncHandle = $script:bootPs.BeginInvoke()
    } catch {
        $script:bootPs = $null
        $script:bootAsyncHandle = $null
    }
    $bootTimer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
    $bootTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $bootTimer.Add_Tick({
        if (-not $script:bootAsyncHandle) {
            $bootTimer.Stop()
            return
        }
        if ($script:bootAsyncHandle.IsCompleted) {
            $bootTimer.Stop()
            try { [void]$script:bootPs.EndInvoke($script:bootAsyncHandle) } catch { }
            try { $script:bootPs.Dispose() } catch { }
            $script:bootPs = $null
            $script:bootAsyncHandle = $null
            try { Refresh-FormState -ForceInfraProbe } catch { }
        }
    })
    $bootTimer.Start()
}

$script:queueFastTimer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
$script:queueFastTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$script:queueFastTimer.Add_Tick({
    Invoke-QueueFastPollTick
})

$script:tickCounter = 0
$timer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    if ($script:pollInFlight) { return }
    if (-not (Test-ShouldRunUiRefreshTimer -IsVisible ([bool]$script:window.IsVisible) -WindowState $script:window.WindowState -IsActive ([bool]$script:window.IsActive) -Busy ([bool]$script:busy))) {
        return
    }
    $script:pollInFlight = $true
    try {
        $script:tickCounter++
        if (($script:tickCounter % 15) -eq 1) {
            [void](Repair-RelayProcessPriority $script:context $script:settings)
        }
        Refresh-FormState
    } catch {
        $script:controls.DetailText.Text = '状态暂时无法读取。配置和连接保持原状。'
    } finally {
        $script:pollInFlight = $false
    }
})

$ipcTimer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
$ipcTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$ipcTimer.Add_Tick({
    try {
        if ($restoreEvent.WaitOne(0)) {
            Restore-MainWindowFromTray
        }
        if ([string]$script:layout.ThemeMode -eq 'system') {
            $sysPref = Get-SystemThemePreference
            if ($sysPref -ne $script:effectiveTheme) {
                Apply-WindowTheme -ThemeMode 'system'
            }
        }
    } catch { }
})
$ipcTimer.Start()

function Sync-ForegroundPollingState([bool]$RefreshImmediate = $false) {
    if (-not (Test-ShouldRunUiRefreshTimer -IsVisible ([bool]$script:window.IsVisible) -WindowState $script:window.WindowState -IsActive ([bool]$script:window.IsActive) -Busy $false)) {
        if ($timer.IsEnabled) { $timer.Stop() }
        if ($script:queueFastTimer -and $script:queueFastTimer.IsEnabled) { $script:queueFastTimer.Stop() }
        return
    }
    if ($RefreshImmediate -and -not $script:busy -and -not $script:initializing -and -not $script:pollInFlight) {
        $elapsedSec = if ($script:lastRefreshUtc) { ([DateTime]::UtcNow - $script:lastRefreshUtc).TotalSeconds } else { 999 }
        if ($elapsedSec -ge 2.0) {
            $script:pollInFlight = $true
            try { Refresh-FormState } catch {} finally { $script:pollInFlight = $false }
        }
    }
    if (-not $timer.IsEnabled) { $timer.Start() }
    Sync-QueueFastPollingState
}

$script:window.Add_StateChanged({
    Sync-ForegroundPollingState -RefreshImmediate ($script:window.WindowState -ne [Windows.WindowState]::Minimized)
})
$script:window.Add_Activated({
    Sync-ForegroundPollingState -RefreshImmediate $true
})
$script:window.Add_Deactivated({
    Sync-ForegroundPollingState -RefreshImmediate $false
})
Add-Type -Namespace Win32 -Name NativeWin -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("shell32.dll", SetLastError = true)] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -ErrorAction SilentlyContinue
try { [void][Win32.NativeWin]::SetCurrentProcessExplicitAppUserModelID('com.relaystudio.desktop') } catch { }

$script:window.Add_SourceInitialized({
    try {
        $consoleHwnd = [Win32.NativeWin]::GetConsoleWindow()
        if ($consoleHwnd -ne [IntPtr]::Zero) { [void][Win32.NativeWin]::ShowWindow($consoleHwnd, 0) }
        $interop = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
        if ($interop.Handle -ne [IntPtr]::Zero) {
            foreach ($icoPath in $icoCandidates) {
                if ($icoPath -and (Test-Path -LiteralPath $icoPath)) {
                    try {
                        $bigIco = New-Object System.Drawing.Icon($icoPath, 48, 48)
                        $smIco  = New-Object System.Drawing.Icon($icoPath, 16, 16)
                        [void][Win32.NativeWin]::SendMessage($interop.Handle, 0x0080, [IntPtr]1, $bigIco.Handle)
                        [void][Win32.NativeWin]::SendMessage($interop.Handle, 0x0080, [IntPtr]0, $smIco.Handle)
                    } catch { }
                    break
                }
            }
        }
        if ($StartMinimized) {
            $script:window.ShowInTaskbar = $false
            $script:window.WindowState = [Windows.WindowState]::Minimized
            $script:window.Hide()
            return
        }
        if ($interop.Handle -ne [IntPtr]::Zero) {
            [void][Win32.NativeWin]::ShowWindow($interop.Handle, 5)
            [void][Win32.NativeWin]::SetForegroundWindow($interop.Handle)
        }
        [void]$script:window.Activate()
    } catch { }
})
$script:window.Add_Loaded({
    if ($StartMinimized) {
        try {
            $script:window.ShowInTaskbar = $false
            $script:window.Hide()
        } catch { }
        return
    }
    try {
        $interop = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
        if ($interop.Handle -ne [IntPtr]::Zero) {
            [void][Win32.NativeWin]::ShowWindow($interop.Handle, 5)
            [void][Win32.NativeWin]::SetForegroundWindow($interop.Handle)
        }
        [void]$script:window.Activate()
    } catch { }
})
$script:window.Add_ContentRendered({
    if ($StartMinimized) { return }
    try {
        $interop = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
        if ($interop.Handle -ne [IntPtr]::Zero) {
            [void][Win32.NativeWin]::ShowWindow($interop.Handle, 5)
            [void][Win32.NativeWin]::SetForegroundWindow($interop.Handle)
        }
    } catch { }
    $script:window.Opacity = 1.0
})
if (-not $StartMinimized) { $timer.Start() }
$script:window.Add_Closed({
    try { [System.Windows.Threading.Dispatcher]::ExitAllFrames() } catch { }
})
try {
    if (-not $StartMinimized) {
        [void]$script:window.Show()
    }
    [System.Windows.Threading.Dispatcher]::Run()
}
finally {
    if ($script:bootPs) { try { $script:bootPs.Dispose() } catch { }; $script:bootPs = $null }
    $timer.Stop()
    if ($script:queueFastTimer) { $script:queueFastTimer.Stop() }
    $ipcTimer.Stop()
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
    $restoreEvent.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
