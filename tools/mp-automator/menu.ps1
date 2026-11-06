# Inspect (and optionally invoke) the DevTools native menu via UI Automation.
#
# Why: the simulator pane is toggled off, and every other route (CLI, config files,
# window resize) failed. The menu bar is a native Windows menu, so UIA can read it
# and invoke an item precisely -- unlike blind keyboard navigation, which risks
# hitting something destructive like an upload command.
#
# Chinese literals are deliberately avoided: PowerShell 5.1 reads .ps1 as ANSI, so
# menu names are passed in as arguments from Node (which handles Unicode properly).
#
# Usage:
#   powershell -File menu.ps1 -List
#   powershell -File menu.ps1 -Menu <topMenuName> -Item <itemName> [-ListItems]
param(
  [switch]$List,
  [string]$Menu,
  [string]$Item,
  [switch]$ListItems
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

# locate the DevTools window: match by exe path under Tencent
$target = $null
foreach ($p in Get-Process) {
  try {
    if ($p.MainWindowHandle -ne 0 -and $p.Path -like '*Program Files (x86)\Tencent*') { $target = $p; break }
  } catch { }
}
if (-not $target) { Write-Output "DevTools window not found"; exit 1 }
Write-Output ("window pid={0}" -f $target.Id)

$cond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $target.Id)
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if (-not $win) { Write-Output "UIA could not find the window element"; exit 1 }

$menuBarCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
  [System.Windows.Automation.ControlType]::MenuBar)
$menuBar = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $menuBarCond)
if (-not $menuBar) { Write-Output "no MenuBar found (menu may not be exposed to UIA)"; exit 1 }
Write-Output "MenuBar found"

$topItems = $menuBar.FindAll([System.Windows.Automation.TreeScope]::Children,
  [System.Windows.Automation.Condition]::TrueCondition)
Write-Output ("top-level menus: {0}" -f $topItems.Count)
for ($i = 0; $i -lt $topItems.Count; $i++) {
  $t = $topItems.Item($i).Current.Name
  Write-Output ("  [{0}] {1}" -f $i, $t)
}

if (-not $Menu) { exit 0 }

# find the requested top menu
$targetMenu = $null
for ($i = 0; $i -lt $topItems.Count; $i++) {
  if ($topItems.Item($i).Current.Name -eq $Menu) { $targetMenu = $topItems.Item($i); break }
}
if (-not $targetMenu) { Write-Output ("menu not found: {0}" -f $Menu); exit 1 }
Write-Output ("found menu: {0}" -f $Menu)

# expand it
try {
  $expand = $targetMenu.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
  $expand.Expand()
  Start-Sleep -Milliseconds 900
} catch {
  Write-Output ("expand failed: {0}" -f $_.Exception.Message)
}

$subItems = $targetMenu.FindAll([System.Windows.Automation.TreeScope]::Descendants,
  [System.Windows.Automation.Condition]::TrueCondition)
Write-Output ("sub items: {0}" -f $subItems.Count)
for ($i = 0; $i -lt $subItems.Count; $i++) {
  $el = $subItems.Item($i)
  $n = $el.Current.Name
  $ct = $el.Current.ControlType.ProgrammaticName
  if ($n) { Write-Output ("  [{0}] {1}  ({2})" -f $i, $n, $ct) }
}

if ($ListItems) { exit 0 }
if (-not $Item) { exit 0 }

for ($i = 0; $i -lt $subItems.Count; $i++) {
  $el = $subItems.Item($i)
  if ($el.Current.Name -eq $Item) {
    Write-Output ("invoking: {0}" -f $Item)
    try {
      $inv = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $inv.Invoke()
      Write-Output "invoked"
    } catch {
      Write-Output ("invoke failed: {0}" -f $_.Exception.Message)
    }
    break
  }
}
