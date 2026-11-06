# Resize the DevTools window so its simulator pane becomes visible, without
# activating it (SWP_NOACTIVATE). ASCII-only.
param(
  [int]$Width = 1900,
  [int]$Height = 1100
)

$sig = @'
using System;
using System.Runtime.InteropServices;
public class WinMove {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
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

$r = New-Object WinMove+RECT
[void][WinMove]::GetWindowRect($target.MainWindowHandle, [ref]$r)
Write-Output ("before: {0},{1} {2}x{3}" -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))

# SWP_NOZORDER(0x4) | SWP_NOACTIVATE(0x10) -> resize/move without focus change
$flags = 4 -bor 16
[void][WinMove]::SetWindowPos($target.MainWindowHandle, [IntPtr]::Zero, $r.Left, $r.Top, $Width, $Height, $flags)
Start-Sleep -Milliseconds 2000

$r2 = New-Object WinMove+RECT
[void][WinMove]::GetWindowRect($target.MainWindowHandle, [ref]$r2)
Write-Output ("after : {0},{1} {2}x{3}" -f $r2.Left, $r2.Top, ($r2.Right - $r2.Left), ($r2.Bottom - $r2.Top))
