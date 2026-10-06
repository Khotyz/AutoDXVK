$ErrorActionPreference = 'Stop'

$script:Repository = 'https://github.com/Khotyz/AutoDXVK'
$script:RawBase = 'https://raw.githubusercontent.com/Khotyz/AutoDXVK/main'
$script:LanguageCodes = @('en', 'pt-br', 'es')
$script:OnlineRun = [string]::IsNullOrEmpty($PSScriptRoot) -and [string]::IsNullOrEmpty($PSCommandPath)

function Test-Administrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HostExecutable {
    $candidate = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $candidate)) { $candidate = Join-Path $PSHOME 'pwsh.exe' }
    return $candidate
}

function Start-NewHost {
    param([string]$ScriptPath, [bool]$Elevate)
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $ScriptPath))
    $parameters = @{ FilePath = (Get-HostExecutable); ArgumentList = $arguments; WindowStyle = 'Hidden' }
    if ($Elevate) { $parameters['Verb'] = 'RunAs' }
    Start-Process @parameters
}

if ($script:OnlineRun) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'AutoDXVK'
    [void](New-Item -ItemType Directory -Path $tempRoot -Force)
    $langFolder = Join-Path $tempRoot 'lang'
    [void](New-Item -ItemType Directory -Path $langFolder -Force)
    $targetScript = Join-Path $tempRoot 'AutoDXVK.ps1'
    $ProgressPreference = 'SilentlyContinue'
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    try {
        Invoke-WebRequest -Uri ($script:RawBase + '/AutoDXVK.ps1') -OutFile $targetScript -UseBasicParsing
        foreach ($code in $script:LanguageCodes) {
            Invoke-WebRequest -Uri ($script:RawBase + '/lang/' + $code + '.json') -OutFile (Join-Path $langFolder ($code + '.json')) -UseBasicParsing
        }
    }
    catch {
        Write-Host ('Failed to download AutoDXVK: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    Start-NewHost -ScriptPath $targetScript -Elevate (-not (Test-Administrator))
    exit
}

$needsElevation = -not (Test-Administrator)
$needsSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA
if (($needsElevation -or $needsSta) -and $PSCommandPath) {
    Start-NewHost -ScriptPath $PSCommandPath -Elevate $needsElevation
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$script:AppRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:AppRoot)) {
    try { $script:AppRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
    catch { $script:AppRoot = (Get-Location).Path }
}
$script:LanguageRoot = Join-Path $script:AppRoot 'lang'

$script:ReleasesUrl = 'https://api.github.com/repos/doitsujin/dxvk/releases?per_page=15'
$script:ReleaseLimit = 5
$script:UserAgent = 'AutoDXVK/1.0'
$script:AppUserModelId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$script:BackupFolderName = 'DXVK_Backup'
$script:DownloadSubfolderName = 'Auto DXVK'

$script:DirectXRules = @(
    [pscustomobject]@{ Version = 'D3D12'; Libraries = @('d3d12.dll') },
    [pscustomobject]@{ Version = 'D3D11'; Libraries = @('d3d11.dll', 'dxgi.dll') },
    [pscustomobject]@{ Version = 'D3D10.1'; Libraries = @('d3d10_1.dll') },
    [pscustomobject]@{ Version = 'D3D10'; Libraries = @('d3d10.dll', 'd3d10core.dll') },
    [pscustomobject]@{ Version = 'D3D9'; Libraries = @('d3d9.dll') },
    [pscustomobject]@{ Version = 'D3D8'; Libraries = @('d3d8.dll') }
)

$script:DllMap = @{
    'D3D8'    = @('d3d8.dll')
    'D3D9'    = @('d3d9.dll')
    'D3D10'   = @('d3d10.dll', 'd3d10_1.dll', 'd3d10core.dll', 'dxgi.dll')
    'D3D10.1' = @('d3d10.dll', 'd3d10_1.dll', 'd3d10core.dll', 'dxgi.dll')
    'D3D11'   = @('d3d11.dll', 'dxgi.dll')
    'D3D12'   = @('d3d12.dll', 'dxgi.dll')
}

$script:ArchFolderByArchitecture = @{
    'x64' = 'x64'
    'x86' = 'x32'
}

function ConvertTo-FlagEmoji {
    param([string]$Region)
    $builder = New-Object System.Text.StringBuilder
    foreach ($letter in $Region.ToUpperInvariant().ToCharArray()) {
        [void]$builder.Append([char]::ConvertFromUtf32(0x1F1E6 + ([int]$letter - [int][char]'A')))
    }
    return $builder.ToString()
}

$script:LanguageOptions = @(
    [pscustomobject]@{ Code = 'en'; Label = ((ConvertTo-FlagEmoji 'US') + ' English') },
    [pscustomobject]@{ Code = 'pt-br'; Label = ((ConvertTo-FlagEmoji 'BR') + ' Portugu' + [char]0x00EA + 's (BR)') },
    [pscustomobject]@{ Code = 'es'; Label = ((ConvertTo-FlagEmoji 'ES') + ' Espa' + [char]0x00F1 + 'ol') }
)

$script:LanguageCache = @{}
$script:Strings = @{}
$script:FallbackStrings = @{}
$script:ActiveJobs = New-Object System.Collections.ArrayList
$script:NativeReady = $false

function Import-LanguageStrings {
    param([string]$Code)
    if ($script:LanguageCache.ContainsKey($Code)) { return $script:LanguageCache[$Code] }
    $table = @{}
    $path = Join-Path $script:LanguageRoot ($Code + '.json')
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $parsed = $raw | ConvertFrom-Json
            foreach ($property in $parsed.PSObject.Properties) { $table[$property.Name] = [string]$property.Value }
        }
        catch { $table = @{} }
    }
    $script:LanguageCache[$Code] = $table
    return $table
}

function Get-Text {
    param([Parameter(Mandatory = $true)][string]$Key)
    if ($script:Strings.ContainsKey($Key)) { return $script:Strings[$Key] }
    if ($script:FallbackStrings.ContainsKey($Key)) { return $script:FallbackStrings[$Key] }
    return $Key
}

function Get-SystemLanguageCode {
    switch ((Get-Culture).TwoLetterISOLanguageName) {
        'pt' { return 'pt-br' }
        'es' { return 'es' }
        default { return 'en' }
    }
}

function Get-WindowsBuildNumber {
    $version = [System.Environment]::OSVersion.Version
    if ($version.Major -ge 10) { return $version.Build }
    try {
        $value = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber' -ErrorAction Stop
        return [int]$value
    }
    catch { return $version.Build }
}

function Get-SystemUsesLightTheme {
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ([int]$value -eq 1)
    }
    catch { return $true }
}

function Get-AccentColorHex {
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -ErrorAction Stop
        $bytes = [System.BitConverter]::GetBytes([int]$value)
        return ('#{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2])
    }
    catch { return '#0078D4' }
}

function Get-PreferredFontFamily {
    try {
        $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
        if ($installed -contains 'Segoe UI Variable Text') { return 'Segoe UI Variable Text, Segoe UI' }
    }
    catch { $null = $null }
    return 'Segoe UI'
}

function Get-DownloadsFolder {
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace('shell:Downloads')
        if ($folder -and $folder.Self -and $folder.Self.Path) { return [string]$folder.Self.Path }
    }
    catch { $null = $null }
    return (Join-Path ([System.Environment]::GetFolderPath('UserProfile')) 'Downloads')
}

function Get-ThemePalette {
    param([bool]$Light, [string]$Accent, [string]$Font)
    if ($Light) {
        return @{
            WINDOWBG = '#F3F3F3'; FG = '#1A1A1A'; SUBFG = '#5F5F5F'; PANEL = '#99FFFFFF'; INPUT = '#CCFFFFFF'
            LINE = '#26000000'; POPUP = '#FFFFFFFF'; HOVER = '#14000000'; OVERLAY = '#000000'; ACCENT = $Accent; FONT = $Font
        }
    }
    return @{
        WINDOWBG = '#202020'; FG = '#FFFFFF'; SUBFG = '#B8B8B8'; PANEL = '#12FFFFFF'; INPUT = '#1AFFFFFF'
        LINE = '#33FFFFFF'; POPUP = '#2C2C2C'; HOVER = '#1FFFFFFF'; OVERLAY = '#FFFFFF'; ACCENT = $Accent; FONT = $Font
    }
}

function Get-ExecutableArchitecture {
    param([string]$Path)
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    }
    catch { return $null }
    try {
        if ($stream.Length -lt 64) { return $null }
        $reader = New-Object System.IO.BinaryReader($stream)
        [void]$stream.Seek(0, [System.IO.SeekOrigin]::Begin)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return $null }
        [void]$stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin)
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or ($peOffset + 26) -gt $stream.Length) { return $null }
        [void]$stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin)
        if ($reader.ReadUInt32() -ne 0x00004550) { return $null }
        [void]$stream.Seek($peOffset + 24, [System.IO.SeekOrigin]::Begin)
        $magic = $reader.ReadUInt16()
        if ($magic -eq 0x10B) { return 'x86' }
        if ($magic -eq 0x20B) { return 'x64' }
        return $null
    }
    finally { $stream.Dispose() }
}

function Find-ImportedLibraries {
    param([string]$Path, [string[]]$Names)
    $found = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $chunkSize = 32MB
    $overlap = 64
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    }
    catch { return , $found }
    try {
        $buffer = New-Object byte[] ($chunkSize + $overlap)
        $carry = 0
        while ($true) {
            $read = $stream.Read($buffer, $carry, $chunkSize)
            if ($read -le 0) { break }
            $total = $carry + $read
            $views = @(
                [System.Text.Encoding]::ASCII.GetString($buffer, 0, $total),
                [System.Text.Encoding]::Unicode.GetString($buffer, 0, $total)
            )
            if ($total -gt 1) { $views += [System.Text.Encoding]::Unicode.GetString($buffer, 1, $total - 1) }
            foreach ($name in $Names) {
                if ($found.Contains($name)) { continue }
                foreach ($view in $views) {
                    if ($view.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        [void]$found.Add($name)
                        break
                    }
                }
            }
            $carry = [Math]::Min($overlap, $total)
            [System.Array]::Copy($buffer, $total - $carry, $buffer, 0, $carry)
        }
    }
    finally { $stream.Dispose() }
    return , $found
}

function Resolve-DirectXVersion {
    param($Libraries, $Rules)
    $priority = @('d3d11.dll', 'd3d12.dll', 'd3d10_1.dll', 'd3d10.dll', 'd3d10core.dll', 'd3d9.dll', 'd3d8.dll')
    foreach ($library in $priority) {
        if (-not $Libraries.Contains($library)) { continue }
        foreach ($rule in $Rules) {
            if ($rule.Libraries -contains $library) { return $rule.Version }
        }
    }
    if ($Libraries.Contains('dxgi.dll')) { return 'D3D11' }
    return $null
}

function Find-RenderingCandidates {
    param([string]$ExePath)
    $folder = Split-Path -Parent $ExePath
    $results = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($ExePath) { [void]$seen.Add($ExePath) }

    $unityPlayer = Join-Path $folder 'UnityPlayer.dll'
    if (Test-Path -LiteralPath $unityPlayer -PathType Leaf) {
        if ($seen.Add($unityPlayer)) { [void]$results.Add($unityPlayer) }
    }

    $siblingExes = @(Get-ChildItem -LiteralPath $folder -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    foreach ($pattern in @('*-Win64-Shipping.exe', '*-Win32-Shipping.exe', '*-Shipping.exe')) {
        foreach ($file in ($siblingExes | Where-Object { $_.Name -like $pattern })) {
            if ($seen.Add($file.FullName)) { [void]$results.Add($file.FullName) }
        }
    }

    $extra = 0
    foreach ($file in $siblingExes) {
        if ($extra -ge 3) { break }
        if ($seen.Add($file.FullName)) {
            [void]$results.Add($file.FullName)
            $extra++
        }
    }

    $parent = Split-Path -Parent $folder
    $binFolders = @(
        (Join-Path $folder 'Binaries\Win64'),
        (Join-Path $folder 'Binaries\Win32'),
        (Join-Path $parent 'Binaries\Win64'),
        (Join-Path $parent 'Binaries\Win32')
    )
    $binExtra = 0
    foreach ($binFolder in $binFolders) {
        if ($binExtra -ge 5) { break }
        if (-not (Test-Path -LiteralPath $binFolder -PathType Container)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $binFolder -Filter '*.exe' -File -ErrorAction SilentlyContinue)) {
            if ($binExtra -ge 5) { break }
            if ($seen.Add($file.FullName)) {
                [void]$results.Add($file.FullName)
                $binExtra++
            }
        }
    }

    return $results.ToArray()
}

function Initialize-NativeMethods {
    if ($script:NativeReady) { return $true }
    try {
        if (-not ('AutoDxvk.Native' -as [type])) {
            Add-Type -Namespace AutoDxvk -Name Native -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
[DllImport("dwmapi.dll")]
public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);
[StructLayout(LayoutKind.Sequential)]
public struct MARGINS { public int Left; public int Right; public int Top; public int Bottom; }
'@
        }
        $script:NativeReady = $true
    }
    catch { $script:NativeReady = $false }
    return $script:NativeReady
}

function Set-DwmAttribute {
    param([IntPtr]$Handle, [int]$Attribute, [int]$Value)
    try {
        $buffer = [int]$Value
        return [int][AutoDxvk.Native]::DwmSetWindowAttribute($Handle, $Attribute, [ref]$buffer, 4)
    }
    catch { return -1 }
}

function Enable-WindowEffects {
    try {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window).Handle
        if ($handle -eq [IntPtr]::Zero) { return }
        if (-not (Initialize-NativeMethods)) { return }
        $darkValue = if ($script:UseLightTheme) { 0 } else { 1 }
        if ((Set-DwmAttribute -Handle $handle -Attribute 20 -Value $darkValue) -ne 0) {
            [void](Set-DwmAttribute -Handle $handle -Attribute 19 -Value $darkValue)
        }
        if (-not $script:IsWindows11) { return }
        [void](Set-DwmAttribute -Handle $handle -Attribute 33 -Value 2)
        $backdropResult = Set-DwmAttribute -Handle $handle -Attribute 38 -Value 2
        if ($backdropResult -ne 0 -and $script:WindowsBuild -lt 22621) {
            $backdropResult = Set-DwmAttribute -Handle $handle -Attribute 1029 -Value 1
        }
        if ($backdropResult -ne 0) { return }
        $margins = New-Object 'AutoDxvk.Native+MARGINS'
        $margins.Left = -1
        $margins.Right = -1
        $margins.Top = -1
        $margins.Bottom = -1
        if ([AutoDxvk.Native]::DwmExtendFrameIntoClientArea($handle, [ref]$margins) -ne 0) { return }
        $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
        if ($source -and $source.CompositionTarget) {
            $source.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
        }
        $script:Window.Background = [System.Windows.Media.Brushes]::Transparent
    }
    catch { $null = $null }
}

function Get-WindowIconSource {
    try {
        $icon = [System.Drawing.SystemIcons]::Application
        $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icon.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $source.Freeze()
        return $source
    }
    catch { return $null }
}

$script:MainWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Auto DXVK" Width="700" Height="520" MinWidth="620" MinHeight="460"
        WindowStartupLocation="CenterScreen"
        Background="@@WINDOWBG@@" Foreground="@@FG@@" FontFamily="@@FONT@@" FontSize="14"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="FgBrush" Color="@@FG@@"/>
    <SolidColorBrush x:Key="SubFgBrush" Color="@@SUBFG@@"/>
    <SolidColorBrush x:Key="PanelBrush" Color="@@PANEL@@"/>
    <SolidColorBrush x:Key="InputBrush" Color="@@INPUT@@"/>
    <SolidColorBrush x:Key="LineBrush" Color="@@LINE@@"/>
    <SolidColorBrush x:Key="PopupBrush" Color="@@POPUP@@"/>
    <SolidColorBrush x:Key="HoverBrush" Color="@@HOVER@@"/>
    <SolidColorBrush x:Key="AccentBrush" Color="@@ACCENT@@"/>

    <ControlTemplate x:Key="ButtonTemplate" TargetType="Button">
      <Grid>
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"/>
        <Border x:Name="Overlay" Background="@@OVERLAY@@" CornerRadius="6" Opacity="0" IsHitTestVisible="False"/>
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Trigger.EnterActions>
            <BeginStoryboard>
              <Storyboard>
                <DoubleAnimation Storyboard.TargetName="Overlay" Storyboard.TargetProperty="Opacity" To="0.1" Duration="0:0:0.12"/>
              </Storyboard>
            </BeginStoryboard>
          </Trigger.EnterActions>
          <Trigger.ExitActions>
            <BeginStoryboard>
              <Storyboard>
                <DoubleAnimation Storyboard.TargetName="Overlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.12"/>
              </Storyboard>
            </BeginStoryboard>
          </Trigger.ExitActions>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter TargetName="Overlay" Property="Opacity" Value="0.18"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.45"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource InputBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{StaticResource FgBrush}"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template" Value="{StaticResource ButtonTemplate}"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="42"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource InputBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{StaticResource FgBrush}"/>
      <Setter Property="CaretBrush" Value="{StaticResource FgBrush}"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <ControlTemplate x:Key="ComboToggleTemplate" TargetType="ToggleButton">
      <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" Data="M 0 0 L 4 4 L 8 0" Stroke="{StaticResource SubFgBrush}" StrokeThickness="1.6" StrokeLineJoin="Round"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Foreground" Value="{StaticResource FgBrush}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Template="{StaticResource ComboToggleTemplate}" Background="{StaticResource InputBrush}" BorderBrush="{StaticResource LineBrush}" Focusable="False" ClickMode="Press" IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter Margin="12,0,32,0" VerticalAlignment="Center" HorizontalAlignment="Left" IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}" Margin="0,4,0,0" Padding="0,4" Background="{StaticResource PopupBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="8">
                  <ScrollViewer>
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource FgBrush}"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Margin="4,1" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <Grid Margin="28,20,28,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock x:Name="TitleText" Text="Auto DXVK" FontSize="32" FontWeight="SemiBold"/>
          <TextBlock x:Name="SubtitleText" Margin="0,2,0,0" FontSize="14" Foreground="{StaticResource SubFgBrush}" TextWrapping="Wrap"/>
        </StackPanel>
        <ComboBox x:Name="LanguageCombo" Grid.Column="1" Width="180" VerticalAlignment="Top" HorizontalAlignment="Right"/>
      </Grid>

      <StackPanel Grid.Row="1" Margin="0,22,0,0">
        <TextBlock x:Name="VersionLabel" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ComboBox x:Name="VersionCombo" Grid.Column="0"/>
          <Button x:Name="RefreshButton" Grid.Column="1" Margin="8,0,0,0"/>
        </Grid>
      </StackPanel>

      <StackPanel Grid.Row="2" Margin="0,16,0,0">
        <TextBlock x:Name="ExeLabel" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="ExePathBox" Grid.Column="0" IsReadOnly="True"/>
          <Button x:Name="BrowseButton" Grid.Column="1" Margin="8,0,0,0"/>
        </Grid>
      </StackPanel>

      <Border x:Name="AnalysisPanel" Grid.Row="3" Margin="0,16,0,0" Padding="16,12" Visibility="Collapsed" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="8">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="170"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="ArchLabel" Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Foreground="{StaticResource SubFgBrush}"/>
          <TextBox x:Name="ArchBox" Grid.Row="0" Grid.Column="1" Height="32" IsReadOnly="True"/>
          <TextBlock x:Name="DxLabel" Grid.Row="1" Grid.Column="0" Margin="0,8,0,0" VerticalAlignment="Center" Foreground="{StaticResource SubFgBrush}"/>
          <TextBox x:Name="DxBox" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0" Height="32" IsReadOnly="True"/>
          <TextBlock x:Name="DllLabel" Grid.Row="2" Grid.Column="0" Margin="0,8,0,0" VerticalAlignment="Center" Foreground="{StaticResource SubFgBrush}"/>
          <TextBox x:Name="DllBox" Grid.Row="2" Grid.Column="1" Margin="0,8,0,0" Height="32" IsReadOnly="True"/>
        </Grid>
      </Border>

      <StackPanel Grid.Row="4" Margin="0,20,0,0">
        <ProgressBar x:Name="ProgressIndicator" Height="4" IsIndeterminate="True" Visibility="Hidden" BorderThickness="0" Foreground="{StaticResource AccentBrush}" Background="{StaticResource LineBrush}"/>
        <TextBlock x:Name="StatusText" Margin="0,8,0,0" FontSize="13" Foreground="{StaticResource SubFgBrush}" TextWrapping="Wrap"/>
      </StackPanel>

      <Button x:Name="InstallButton" Grid.Row="5" Margin="0,14,0,0" Style="{StaticResource PrimaryButton}" IsEnabled="False"/>

      <TextBlock x:Name="FooterText" Grid.Row="6" Margin="0,14,0,0" FontSize="12" Foreground="{StaticResource SubFgBrush}" TextTrimming="CharacterEllipsis"/>
    </Grid>
  </ScrollViewer>
</Window>
'@

$script:ReleasesWork = {
    param($Url, $UserAgent, $Limit)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = 'application/vnd.github+json' }
    $response = Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 30
    $collected = New-Object System.Collections.ArrayList
    foreach ($release in @($response)) {
        if ($release.draft) { continue }
        $assets = @($release.assets) | Where-Object { $_.name -like '*.tar.gz' }
        $asset = $assets | Where-Object { $_.name -notlike 'dxvk-native*' } | Select-Object -First 1
        if (-not $asset) { $asset = $assets | Select-Object -First 1 }
        if (-not $asset) { continue }
        $published = $release.published_at
        if ($published -isnot [datetime]) {
            $published = [datetime]::Parse([string]$published, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        [void]$collected.Add([pscustomobject]@{
                Tag        = [string]$release.tag_name
                Published  = $published.ToLocalTime()
                Prerelease = [bool]$release.prerelease
                AssetName  = [string]$asset.name
                AssetUrl   = [string]$asset.browser_download_url
            })
        if ($collected.Count -ge $Limit) { break }
    }
    if ($collected.Count -eq 0) { throw 'No DXVK releases with a .tar.gz asset were found.' }
    $collected.ToArray()
}

$script:AnalysisWork = {
    param($ExePath, $Rules)
    $ErrorActionPreference = 'Stop'
    $names = @($Rules | ForEach-Object { $_.Libraries })
    $architecture = Get-ExecutableArchitecture -Path $ExePath
    $directX = $null
    if ($architecture) {
        $libraries = Find-ImportedLibraries -Path $ExePath -Names $names
        $directX = Resolve-DirectXVersion -Libraries $libraries -Rules $Rules
    }
    if (-not $directX) {
        $candidates = Find-RenderingCandidates -ExePath $ExePath
        foreach ($candidate in $candidates) {
            $candidateArch = Get-ExecutableArchitecture -Path $candidate
            if (-not $candidateArch) { continue }
            $candidateLibraries = Find-ImportedLibraries -Path $candidate -Names $names
            $candidateDirectX = Resolve-DirectXVersion -Libraries $candidateLibraries -Rules $Rules
            if ($candidateDirectX) {
                $directX = $candidateDirectX
                if (-not $architecture) { $architecture = $candidateArch }
                break
            }
        }
    }
    [pscustomobject]@{ Architecture = $architecture; DirectX = $directX }
}

$script:DownloadWork = {
    param($AssetUrl, $AssetName, $TargetFolder, $ArchFolder, $UserAgent, $Sync)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $stage = 'download'
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        [void](New-Item -ItemType Directory -Path $TargetFolder -Force)
        $archivePath = Join-Path $TargetFolder $AssetName
        $Sync.Status = 'status_downloading'
        $client = New-Object System.Net.WebClient
        try {
            $client.Headers.Add('User-Agent', $UserAgent)
            $client.Proxy = [System.Net.WebRequest]::DefaultWebProxy
            if ($client.Proxy) { $client.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
            $client.DownloadFile($AssetUrl, $archivePath)
        }
        finally { $client.Dispose() }

        $stage = 'extract'
        $Sync.Status = 'status_extracting'
        $tarPath = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tarPath)) { $tarPath = 'tar.exe' }
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $tarOutput = & $tarPath -xzf $archivePath -C $TargetFolder 2>&1
        $tarExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        if ($tarExitCode -ne 0) { throw (($tarOutput | Out-String).Trim()) }

        $stage = 'package'
        $packageName = $AssetName -replace '\.tar\.gz$', ''
        $packageDirectory = Join-Path $TargetFolder $packageName
        if (-not (Test-Path -LiteralPath (Join-Path $packageDirectory $ArchFolder))) {
            $candidate = Get-ChildItem -LiteralPath $TargetFolder -Directory -Filter 'dxvk-*' |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $ArchFolder) } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($candidate) { $packageDirectory = $candidate.FullName }
        }
        $archDirectory = Join-Path $packageDirectory $ArchFolder
        if (-not (Test-Path -LiteralPath $archDirectory -PathType Container)) {
            throw ('Folder not found: ' + $archDirectory)
        }
        [pscustomobject]@{ Success = $true; Stage = 'done'; Message = ''; ArchDirectory = $archDirectory; ArchivePath = $archivePath }
    }
    catch {
        [pscustomobject]@{ Success = $false; Stage = $stage; Message = $_.Exception.Message; ArchDirectory = ''; ArchivePath = '' }
    }
}

function Get-InnermostMessage {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    return $exception.Message
}

function Invoke-Async {
    param(
        [scriptblock]$Work,
        [object[]]$Arguments = @(),
        [string[]]$Functions = @(),
        [scriptblock]$OnComplete,
        $Sync = $null
    )
    $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($functionName in $Functions) {
        $definition = (Get-Item -Path ('function:' + $functionName)).ScriptBlock.ToString()
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $functionName, $definition
        $initialState.Commands.Add($entry)
    }
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
    $runspace.Open()
    $shell = [System.Management.Automation.PowerShell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($Work.ToString())
    foreach ($argument in $Arguments) { [void]$shell.AddArgument($argument) }
    $handle = $shell.BeginInvoke()

    $job = [pscustomobject]@{ Shell = $shell; Runspace = $runspace; Handle = $handle; OnComplete = $OnComplete; Sync = $Sync }
    [void]$script:ActiveJobs.Add($job)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Tag = $job
    $timer.Add_Tick({
            param($sender, $eventArgs)
            $current = $sender.Tag
            if ($null -ne $current.Sync -and $current.Sync.Status -and $current.Sync.Status -ne $script:State.StatusKey) {
                Set-StatusKey $current.Sync.Status
            }
            if (-not $current.Handle.IsCompleted) { return }
            $sender.Stop()
            $output = $null
            $failure = $null
            try { $output = $current.Shell.EndInvoke($current.Handle) }
            catch { $failure = Get-InnermostMessage $_ }
            try { $current.Shell.Dispose() } catch { $null = $null }
            try { $current.Runspace.Dispose() } catch { $null = $null }
            $script:ActiveJobs.Remove($current)
            try { & $current.OnComplete $output $failure }
            catch {
                Set-Busy $false
                Set-StatusKey 'status_failed'
                [void](Show-Message -BodyKey 'msg_error_unexpected' -Detail (Get-InnermostMessage $_))
            }
        })
    $timer.Start()
}

function Show-Message {
    param(
        [string]$BodyKey,
        [string]$Detail = '',
        [string]$Kind = 'Error',
        [string]$Buttons = 'OK',
        [string[]]$FormatArguments = @()
    )
    $body = Get-Text $BodyKey
    if ($FormatArguments.Count -gt 0) { $body = $body -f $FormatArguments }
    if ($Detail) { $body = $body + "`r`n`r`n" + $Detail }
    $titleKey = 'msg_success_title'
    $image = 'Information'
    switch ($Kind) {
        'Error' { $titleKey = 'msg_error_title'; $image = 'Error' }
        'Warning' { $titleKey = 'msg_warning_title'; $image = 'Warning' }
        'Question' { $titleKey = 'msg_confirm_title'; $image = 'Question' }
    }
    return [System.Windows.MessageBox]::Show($script:Window, $body, (Get-Text $titleKey), $Buttons, $image)
}

function Set-StatusKey {
    param([string]$Key)
    $script:State.StatusKey = $Key
    $script:Ui.StatusText.Text = Get-Text $Key
}

function Update-FooterText {
    $script:Ui.FooterText.Text = '{0}: {1}' -f (Get-Text 'label_downloads_path'), $script:State.DownloadFolder
    $script:Ui.FooterText.ToolTip = $script:State.DownloadFolder
}

function Update-InstallButtonState {
    $selected = $script:Ui.VersionCombo.SelectedIndex
    $ready = (-not $script:State.Busy) -and ($selected -ge 0) -and (@($script:State.Releases).Count -gt 0) -and `
        [bool]$script:State.ExePath -and [bool]$script:State.Arch -and [bool]$script:State.DirectX
    $script:Ui.InstallButton.IsEnabled = [bool]$ready
}

function Set-Busy {
    param([bool]$Busy)
    $script:State.Busy = $Busy
    $script:Ui.ProgressIndicator.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    $script:Ui.BrowseButton.IsEnabled = -not $Busy
    $script:Ui.RefreshButton.IsEnabled = -not $Busy
    $script:Ui.VersionCombo.IsEnabled = -not $Busy
    Update-InstallButtonState
}

function Update-AnalysisDisplay {
    $state = $script:State
    if (-not $state.ExePath) {
        $script:Ui.AnalysisPanel.Visibility = 'Collapsed'
        $script:Ui.ExePathBox.Text = ''
        return
    }
    $script:Ui.AnalysisPanel.Visibility = 'Visible'
    $script:Ui.ExePathBox.Text = $state.ExePath
    $archText = Get-Text 'arch_unknown'
    if ($state.Arch -eq 'x86') { $archText = Get-Text 'arch_32' }
    if ($state.Arch -eq 'x64') { $archText = Get-Text 'arch_64' }
    $script:Ui.ArchBox.Text = $archText
    $script:Ui.DxBox.Text = if ($state.DirectX) { [string]$state.DirectX } else { Get-Text 'dx_unknown' }
    $script:Ui.DllBox.Text = if (@($state.Dlls).Count -gt 0) { (@($state.Dlls) -join ', ') } else { '-' }
}

function Update-ReleaseList {
    $combo = $script:Ui.VersionCombo
    $previousIndex = $combo.SelectedIndex
    $combo.Items.Clear()
    foreach ($release in @($script:State.Releases)) {
        $dateText = $release.Published.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $label = '{0}  -  {1}' -f $release.Tag, $dateText
        if ($release.Prerelease) { $label = $label + '  ' + (Get-Text 'release_prerelease') }
        [void]$combo.Items.Add($label)
    }
    if ($combo.Items.Count -gt 0) {
        if ($previousIndex -lt 0 -or $previousIndex -ge $combo.Items.Count) { $previousIndex = 0 }
        $combo.SelectedIndex = $previousIndex
    }
    Update-InstallButtonState
}

function Set-UiLanguage {
    param([string]$Code)
    $script:State.LanguageCode = $Code
    $script:Strings = Import-LanguageStrings -Code $Code
    $ui = $script:Ui
    $script:Window.Title = Get-Text 'app_title'
    $ui.TitleText.Text = Get-Text 'app_title'
    $ui.SubtitleText.Text = Get-Text 'app_subtitle'
    $ui.LanguageCombo.ToolTip = Get-Text 'label_language'
    $ui.VersionLabel.Text = Get-Text 'label_dxvk_version'
    $ui.RefreshButton.Content = Get-Text 'button_refresh'
    $ui.ExeLabel.Text = Get-Text 'label_game_exe'
    $ui.BrowseButton.Content = Get-Text 'button_browse'
    $ui.ArchLabel.Text = Get-Text 'label_arch'
    $ui.DxLabel.Text = Get-Text 'label_dx_version'
    $ui.DllLabel.Text = Get-Text 'label_dlls_to_install'
    $ui.InstallButton.Content = Get-Text 'button_install'
    Update-ReleaseList
    Update-AnalysisDisplay
    Update-FooterText
    Set-StatusKey $script:State.StatusKey
}

function Reset-Analysis {
    $script:State.ExePath = ''
    $script:State.Arch = $null
    $script:State.DirectX = $null
    $script:State.Dlls = @()
    Update-AnalysisDisplay
    Update-InstallButtonState
}

function Start-ReleaseLoad {
    Set-Busy $true
    Set-StatusKey 'status_fetching'
    Invoke-Async -Work $script:ReleasesWork -Arguments @($script:ReleasesUrl, $script:UserAgent, $script:ReleaseLimit) -OnComplete {
        param($output, $failure)
        Set-Busy $false
        if ($failure) {
            Set-StatusKey 'status_failed'
            [void](Show-Message -BodyKey 'msg_error_network' -Detail $failure)
            return
        }
        $script:State.Releases = @($output | Where-Object { $_ })
        Update-ReleaseList
        Set-StatusKey 'status_ready'
    }
}

function Start-ExecutableAnalysis {
    param([string]$Path)
    $isExecutable = (Test-Path -LiteralPath $Path -PathType Leaf) -and ([System.IO.Path]::GetExtension($Path) -eq '.exe')
    if (-not $isExecutable) {
        Reset-Analysis
        [void](Show-Message -BodyKey 'msg_error_no_exe' -Kind 'Warning')
        return
    }
    $script:State.PendingExePath = $Path
    Set-Busy $true
    Set-StatusKey 'status_analyzing'
    Invoke-Async -Work $script:AnalysisWork -Functions @('Get-ExecutableArchitecture', 'Find-ImportedLibraries', 'Resolve-DirectXVersion', 'Find-RenderingCandidates') -Arguments @($Path, $script:DirectXRules) -OnComplete {
        param($output, $failure)
        Set-Busy $false
        if ($failure) {
            Reset-Analysis
            Set-StatusKey 'status_failed'
            [void](Show-Message -BodyKey 'msg_error_analysis' -Detail $failure)
            return
        }
        $result = $output | Select-Object -First 1
        if (-not $result -or -not $result.Architecture) {
            Reset-Analysis
            Set-StatusKey 'status_failed'
            [void](Show-Message -BodyKey 'msg_error_arch')
            return
        }
        $script:State.ExePath = $script:State.PendingExePath
        $script:State.Arch = [string]$result.Architecture
        $script:State.DirectX = $result.DirectX
        $script:State.Dlls = if ($result.DirectX) { @($script:DllMap[[string]$result.DirectX]) } else { @() }
        Update-AnalysisDisplay
        Update-InstallButtonState
        Set-StatusKey 'status_ready'
        if (-not $result.DirectX) {
            [void](Show-Message -BodyKey 'msg_error_dx' -Kind 'Warning')
        }
        elseif ($result.DirectX -eq 'D3D12') {
            [void](Show-Message -BodyKey 'msg_warn_d3d12' -Kind 'Warning')
        }
    }
}

function Get-InstallPlan {
    param([string]$DirectX, [string]$ArchDirectory)
    $wanted = @($script:DllMap[$DirectX])
    $required = @($wanted | Where-Object { $_ -ne 'dxgi.dll' })
    $available = @($wanted | Where-Object { Test-Path -LiteralPath (Join-Path $ArchDirectory $_) -PathType Leaf })
    if ($DirectX -eq 'D3D10' -or $DirectX -eq 'D3D10.1') {
        $hasCore = $available -contains 'd3d10core.dll'
        $hasLegacy = $available -contains 'd3d10.dll'
        $runtimeAvailable = Test-Path -LiteralPath (Join-Path $ArchDirectory 'd3d11.dll') -PathType Leaf
        if ($hasCore -and -not $hasLegacy -and $runtimeAvailable) { $available = @($available) + 'd3d11.dll' }
    }
    $requiredAvailable = @($required | Where-Object { $available -contains $_ })
    return [pscustomobject]@{ Required = $required; Available = @($available); RequiredAvailable = $requiredAvailable }
}

function Show-SuccessNotification {
    param([string]$Title, [string]$Message, [string[]]$Lines)
    $shown = $false
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $titleText = [System.Security.SecurityElement]::Escape($Title)
        $messageText = [System.Security.SecurityElement]::Escape($Message)
        $detailText = [System.Security.SecurityElement]::Escape(($Lines -join "`n"))
        $toastXml = '<toast><visual><binding template="ToastGeneric"><text>' + $titleText + '</text><text>' + $messageText + '</text><text>' + $detailText + '</text></binding></visual></toast>'
        $document = New-Object Windows.Data.Xml.Dom.XmlDocument
        $document.LoadXml($toastXml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification -ArgumentList $document
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:AppUserModelId).Show($toast)
        $shown = $true
    }
    catch { $shown = $false }
    if (-not $shown) {
        $body = $Message + "`r`n`r`n" + ($Lines -join "`r`n")
        [void][System.Windows.MessageBox]::Show($script:Window, $body, $Title, 'OK', 'Information')
    }
}

function Complete-Installation {
    param($Result)
    $release = $script:State.PendingRelease
    $gameDirectory = Split-Path -Parent $script:State.ExePath
    $plan = Get-InstallPlan -DirectX $script:State.DirectX -ArchDirectory $Result.ArchDirectory

    if ($plan.RequiredAvailable.Count -eq 0) {
        Set-Busy $false
        Set-StatusKey 'status_failed'
        if ($script:State.DirectX -eq 'D3D12') {
            [void](Show-Message -BodyKey 'msg_error_d3d12' -Kind 'Warning')
        }
        else {
            [void](Show-Message -BodyKey 'msg_error_missing_dlls' -Kind 'Warning' -FormatArguments @(($plan.Required -join ', ')))
        }
        return
    }

    $existing = @($plan.Available | Where-Object { Test-Path -LiteralPath (Join-Path $gameDirectory $_) -PathType Leaf })
    if ($existing.Count -gt 0) {
        $answer = Show-Message -BodyKey 'msg_confirm_overwrite' -Detail ($existing -join ', ') -Kind 'Question' -Buttons 'YesNo'
        if ($answer -ne 'Yes') {
            Set-Busy $false
            Set-StatusKey 'status_cancelled'
            return
        }
    }

    Set-StatusKey 'status_copying'
    try {
        if ($existing.Count -gt 0) {
            $backupDirectory = Join-Path $gameDirectory $script:BackupFolderName
            [void](New-Item -ItemType Directory -Path $backupDirectory -Force)
            foreach ($name in $existing) {
                $backupTarget = Join-Path $backupDirectory $name
                if (-not (Test-Path -LiteralPath $backupTarget)) {
                    Copy-Item -LiteralPath (Join-Path $gameDirectory $name) -Destination $backupTarget -Force
                }
            }
        }
        foreach ($name in $plan.Available) {
            Copy-Item -LiteralPath (Join-Path $Result.ArchDirectory $name) -Destination (Join-Path $gameDirectory $name) -Force
        }
        $configPath = Join-Path $gameDirectory 'dxvk.conf'
        if (-not (Test-Path -LiteralPath $configPath)) { [void](New-Item -ItemType File -Path $configPath -Force) }
    }
    catch {
        Set-Busy $false
        Set-StatusKey 'status_failed'
        [void](Show-Message -BodyKey 'msg_error_copy' -Detail (Get-InnermostMessage $_))
        return
    }

    Set-Busy $false
    Set-StatusKey 'status_done'
    $lines = @(
        ((Get-Text 'msg_success_version') -f $release.Tag),
        ((Get-Text 'msg_success_dlls') -f ($plan.Available -join ', ')),
        ((Get-Text 'msg_success_game_folder') -f $gameDirectory),
        ((Get-Text 'msg_success_files_folder') -f $script:State.DownloadFolder)
    )
    $script:Ui.StatusText.ToolTip = ($lines -join "`r`n")
    Show-SuccessNotification -Title (Get-Text 'msg_success_title') -Message (Get-Text 'msg_success_body') -Lines $lines
}

function Start-Installation {
    $index = $script:Ui.VersionCombo.SelectedIndex
    $releases = @($script:State.Releases)
    if ($index -lt 0 -or $index -ge $releases.Count) {
        [void](Show-Message -BodyKey 'msg_error_no_version' -Kind 'Warning')
        return
    }
    $exePath = $script:State.ExePath
    if (-not $exePath -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        [void](Show-Message -BodyKey 'msg_error_no_exe' -Kind 'Warning')
        return
    }
    $release = $releases[$index]
    $script:State.PendingRelease = $release
    $archFolder = $script:ArchFolderByArchitecture[[string]$script:State.Arch]
    if (-not $archFolder) { $archFolder = 'x32' }
    $sync = [hashtable]::Synchronized(@{ Status = 'status_downloading' })
    $script:Ui.StatusText.ToolTip = $null
    Set-Busy $true
    Set-StatusKey 'status_downloading'
    Invoke-Async -Work $script:DownloadWork -Sync $sync -Arguments @($release.AssetUrl, $release.AssetName, $script:State.DownloadFolder, $archFolder, $script:UserAgent, $sync) -OnComplete {
        param($output, $failure)
        $result = $output | Select-Object -First 1
        if ($failure -or -not $result -or -not $result.Success) {
            Set-Busy $false
            Set-StatusKey 'status_failed'
            $messageKey = 'msg_error_download'
            if ($result) {
                if ($result.Stage -eq 'extract') { $messageKey = 'msg_error_extract' }
                if ($result.Stage -eq 'package') { $messageKey = 'msg_error_package' }
            }
            $detail = ''
            if ($failure) { $detail = $failure } elseif ($result) { $detail = [string]$result.Message }
            [void](Show-Message -BodyKey $messageKey -Detail $detail)
            return
        }
        Complete-Installation -Result $result
    }
}

try {
    $script:FallbackStrings = Import-LanguageStrings -Code 'en'
    if ($script:FallbackStrings.Count -eq 0) {
        [void][System.Windows.MessageBox]::Show(('Language files not found in: ' + $script:LanguageRoot), 'Auto DXVK', 'OK', 'Error')
        exit 1
    }

    $script:WindowsBuild = Get-WindowsBuildNumber
    $script:IsWindows11 = ($script:WindowsBuild -ge 22000)
    $script:UseLightTheme = Get-SystemUsesLightTheme

    $script:State = @{
        Releases        = @()
        ExePath         = ''
        PendingExePath  = ''
        PendingRelease  = $null
        Arch            = $null
        DirectX         = $null
        Dlls            = @()
        Busy            = $false
        Started         = $false
        Initializing    = $true
        StatusKey       = 'status_ready'
        LanguageCode    = 'en'
        DownloadFolder  = (Join-Path (Get-DownloadsFolder) $script:DownloadSubfolderName)
    }

    $palette = Get-ThemePalette -Light $script:UseLightTheme -Accent (Get-AccentColorHex) -Font (Get-PreferredFontFamily)
    $xamlText = $script:MainWindowXaml
    foreach ($key in $palette.Keys) { $xamlText = $xamlText.Replace('@@' + $key + '@@', [string]$palette[$key]) }
    $xamlReader = New-Object System.Xml.XmlNodeReader -ArgumentList ([xml]$xamlText)
    $script:Window = [System.Windows.Markup.XamlReader]::Load($xamlReader)

    $icon = Get-WindowIconSource
    if ($icon) { $script:Window.Icon = $icon }

    $script:Ui = @{}
    $controlNames = @(
        'TitleText', 'SubtitleText', 'LanguageCombo', 'VersionLabel', 'VersionCombo', 'RefreshButton',
        'ExeLabel', 'ExePathBox', 'BrowseButton', 'AnalysisPanel', 'ArchLabel', 'ArchBox', 'DxLabel', 'DxBox',
        'DllLabel', 'DllBox', 'ProgressIndicator', 'StatusText', 'InstallButton', 'FooterText'
    )
    foreach ($controlName in $controlNames) { $script:Ui[$controlName] = $script:Window.FindName($controlName) }

    foreach ($option in $script:LanguageOptions) { [void]$script:Ui.LanguageCombo.Items.Add($option.Label) }
    $initialCode = Get-SystemLanguageCode
    $initialIndex = 0
    for ($position = 0; $position -lt $script:LanguageOptions.Count; $position++) {
        if ($script:LanguageOptions[$position].Code -eq $initialCode) { $initialIndex = $position }
    }
    $script:Ui.LanguageCombo.SelectedIndex = $initialIndex

    $script:Window.Add_SourceInitialized({ Enable-WindowEffects })

    $script:Window.Add_ContentRendered({
            if (-not $script:State.Started) {
                $script:State.Started = $true
                Start-ReleaseLoad
            }
        })

    $script:Window.Add_Closed({
            foreach ($job in @($script:ActiveJobs)) {
                try { [void]$job.Shell.BeginStop($null, $null) } catch { $null = $null }
            }
        })

    $script:Ui.LanguageCombo.Add_SelectionChanged({
            $selectedIndex = $script:Ui.LanguageCombo.SelectedIndex
            if ($selectedIndex -ge 0 -and -not $script:State.Initializing) {
                Set-UiLanguage -Code $script:LanguageOptions[$selectedIndex].Code
            }
        })

    $script:Ui.VersionCombo.Add_SelectionChanged({ Update-InstallButtonState })

    $script:Ui.RefreshButton.Add_Click({ Start-ReleaseLoad })

    $script:Ui.BrowseButton.Add_Click({
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Filter = Get-Text 'dialog_filter_exe'
            $dialog.Title = Get-Text 'dialog_title_exe'
            $dialog.CheckFileExists = $true
            if ($script:State.ExePath) { $dialog.InitialDirectory = Split-Path -Parent $script:State.ExePath }
            if ($dialog.ShowDialog($script:Window) -eq $true) { Start-ExecutableAnalysis -Path $dialog.FileName }
        })

    $script:Ui.InstallButton.Add_Click({ Start-Installation })

    Set-UiLanguage -Code $script:LanguageOptions[$initialIndex].Code
    $script:State.Initializing = $false
    Update-InstallButtonState

    [void]$script:Window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show((Get-InnermostMessage $_), 'Auto DXVK', 'OK', 'Error')
    exit 1
}