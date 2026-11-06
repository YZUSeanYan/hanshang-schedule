# Bring the DevTools window to the foreground and capture the screen, so we can
# visually verify the mini program simulator (automator.screenshot only captures
# the page webview, which stays unpainted in this environment).
#
# WARNING: this steals window focus and grabs the whole desktop. Only run it when
# the machine is idle -- it will interrupt whatever the user is doing.
#
# ASCII-only: PowerShell 5.1 reads .ps1 using the ANSI code page.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$sig = @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -TypeDefinition $sig

# Find the DevTools process: it is the one whose exe lives under Tencent devtools.
# We cannot match the Chinese process name from an ANSI-read script, so match by path.
$target = $null
foreach ($p in Get-Process) {
  try {
    if ($p.MainWindowHandle -ne 0 -and $p.Path -like '*Tencent*') { $target = $p; break }
  } catch { }
}

if (-not $target) {
  Write-Output "DevTools window not found"
  exit 1
}

Write-Output ("target PID={0} title={1}" -f $target.Id, $target.MainWindowTitle)
[void][Win32]::ShowWindow($target.MainWindowHandle, 3)   # 3 = maximize
[void][Win32]::SetForegroundWindow($target.MainWindowHandle)
Start-Sleep -Milliseconds 1500

$rect = New-Object Win32+RECT
[void][Win32]::GetWindowRect($target.MainWindowHandle, [ref]$rect)
Write-Output ("window rect: {0},{1} - {2},{3}" -f $rect.Left, $rect.Top, $rect.Right, $rect.Bottom)

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$out = Join-Path $env:TEMP 'devtools-screen.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$gfx.Dispose(); $bmp.Dispose()
Write-Output ("saved: {0}" -f $out)
