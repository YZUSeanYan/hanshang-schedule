# Capture the DevTools window WITHOUT stealing focus.
#
# Why PrintWindow instead of a screen grab: CopyFromScreen captures whatever is
# physically on top, so we would have to call SetForegroundWindow first -- which
# yanks the window away from the user mid-task. PrintWindow renders the target
# window into a bitmap directly, so it can stay in the background.
# Flag 2 = PW_RENDERFULLCONTENT, required for GPU-composited (Chromium) windows.
#
# ASCII-only: PowerShell 5.1 reads .ps1 using the ANSI code page.
param(
  [string]$Out = "$env:TEMP\devtools-window.png",
  [int]$CropRightPercent = 0    # >0: crop to the rightmost N% (the simulator pane)
)

Add-Type -AssemblyName System.Drawing

# 输出目录可能不存在（清理过截图目录后），Save 不会自动建目录且失败得很安静
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  Write-Output ("created output dir: {0}" -f $outDir)
}

$sig = @'
using System;
using System.Runtime.InteropServices;
public class WinCap {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -TypeDefinition $sig

$target = $null
foreach ($p in Get-Process) {
  try {
    if ($p.MainWindowHandle -ne 0 -and $p.Path -like '*Program Files (x86)\Tencent*') { $target = $p; break }
  } catch { }
}
if (-not $target) { Write-Output "DevTools window not found"; exit 1 }

# A minimized window renders as a solid black bitmap under PrintWindow.
# SW_SHOWNOACTIVATE (4) restores it WITHOUT pulling focus away from the user.
if ([WinCap]::IsIconic($target.MainWindowHandle)) {
  Write-Output "window was minimized -> restoring without activation"
  [void][WinCap]::ShowWindow($target.MainWindowHandle, 4)
  Start-Sleep -Milliseconds 1500
}

$rect = New-Object WinCap+RECT
[void][WinCap]::GetWindowRect($target.MainWindowHandle, [ref]$rect)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
Write-Output ("window: {0}x{1} title='{2}'" -f $w, $h, $target.MainWindowTitle)

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $gfx.GetHdc()
$ok = [WinCap]::PrintWindow($target.MainWindowHandle, $hdc, 2)
$gfx.ReleaseHdc($hdc)
$gfx.Dispose()
Write-Output ("PrintWindow ok: {0}" -f $ok)

if ($CropRightPercent -gt 0) {
  $cw = [int]($w * $CropRightPercent / 100.0)
  $cropRect = New-Object System.Drawing.Rectangle($w - $cw, 0, $cw, $h)
  $cropped = $bmp.Clone($cropRect, $bmp.PixelFormat)
  $cropped.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $cropped.Dispose()
  Write-Output ("saved cropped: {0} ({1}x{2})" -f $Out, $cw, $h)
} else {
  $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Output ("saved: {0}" -f $Out)
}
$bmp.Dispose()
