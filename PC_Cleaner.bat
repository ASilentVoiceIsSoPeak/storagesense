<# : batch
@echo off
set "PATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\WindowsPowerShell\v1.0;%PATH%"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PS%" (echo PowerShell not found on this PC. & pause & exit /b)
set "PCC_SELF=%~f0"
set "PCC_ARG="
set "PCC_ELEV="
for %%A in (%*) do (
  if /i "%%~A"=="/auto" set "PCC_ARG=/auto"
  if /i "%%~A"=="/elevated" set "PCC_ELEV=1"
)
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1 && goto :pcc_admin
if defined PCC_ELEV (
  echo.
  echo  Could not get admin rights.
  echo  Right-click PC_Cleaner.bat and choose "Run as administrator".
  echo.
  pause
  exit /b
)
set "PCC_RA=/elevated"
if defined PCC_ARG set "PCC_RA=/auto /elevated"
"%PS%" -nop -c "Start-Process -FilePath $env:PCC_SELF -ArgumentList $env:PCC_RA -Verb RunAs"
exit /b
:pcc_admin
title PC Cleaner - Full Scan
"%PS%" -nop -ep bypass -c "iex ([IO.File]::ReadAllText($env:PCC_SELF))"
if /i not "%PCC_ARG%"=="/auto" pause
exit /b
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}
try { $Host.UI.RawUI.WindowTitle = 'PC Cleaner' } catch {}
$script:All  = $false
$script:Quit = $false

# ---------------- helpers ----------------
function Fmt([long]$b){
  if($b -lt 0){'tweak'} elseif($b -eq 0){'?'} elseif($b -ge 1GB){'{0:N2} GB' -f ($b/1GB)} elseif($b -ge 1MB){'{0:N0} MB' -f ($b/1MB)} else {'{0:N0} KB' -f ($b/1KB)}
}

function Header($t){
  Write-Host ''
  Write-Host ('=' * 60) -ForegroundColor DarkCyan
  Write-Host "  $t" -ForegroundColor Cyan
  Write-Host ('=' * 60) -ForegroundColor DarkCyan
}

function Ask($label, $detail, [long]$bytes, $verb = 'Delete', [switch]$Risky){
  if($script:Quit){ return $false }
  Write-Host ''
  Write-Host ('[{0,9}] ' -f (Fmt $bytes)) -NoNewline -ForegroundColor Yellow
  Write-Host $label -ForegroundColor White
  if($detail){ Write-Host "            $detail" -ForegroundColor DarkGray }
  if($script:Auto){
    if($Risky){ Write-Host '            skipped (overnight)' -ForegroundColor DarkGray; return $false }
    Write-Host '            auto (overnight)' -ForegroundColor DarkGreen; return $true
  }
  if($script:Max -and -not $Risky){ Write-Host '            auto (MAX)' -ForegroundColor DarkGreen; return $true }
  if($script:All){ return $true }
  while($true){
    Write-Host "            $verb? [Y]es [N]o [A]ll in section [Q]uit: " -NoNewline -ForegroundColor Cyan
    $k = ([string]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').Character).ToUpper()
    Write-Host $k
    switch($k){
      'Y' { return $true }
      'N' { return $false }
      'A' { $script:All = $true; return $true }
      'Q' { $script:Quit = $true; return $false }
    }
  }
}

function Done { Write-Host '            done.' -ForegroundColor Green }

function Get-DirSize($p){
  $sum = [long]0
  $st = New-Object System.Collections.Stack
  $st.Push($p)
  while($st.Count){
    $d = $st.Pop()
    try {
      $di = [IO.DirectoryInfo]$d
      foreach($f in $di.GetFiles()){ $sum += $f.Length }
      foreach($s in $di.GetDirectories()){
        if(-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)){ $st.Push($s.FullName) }
      }
    } catch {}
  }
  $sum
}

# deletes a folder tree; .NET removes junctions/symlinks without following them
function Remove-Tree($p){
  try { [IO.Directory]::Delete($p, $true) } catch {
    try {
      $di = [IO.DirectoryInfo]$p
      foreach($f in $di.GetFiles('*', 'AllDirectories')){ try { $f.Attributes = 'Normal' } catch {} }
      [IO.Directory]::Delete($p, $true)
    } catch {}
  }
}

# deletes contents, keeps folder; never follows junctions
function Clear-Dir($p){
  try {
    $di = [IO.DirectoryInfo]$p
    foreach($f in $di.GetFiles()){ try { $f.Attributes = 'Normal'; $f.Delete() } catch {} }
    foreach($s in $di.GetDirectories()){ Remove-Tree $s.FullName }
  } catch {}
}

function Get-Free {
  $h = @{}
  Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $h[$_.DeviceID] = [long]$_.FreeSpace }
  $h
}

function New-Set([string[]]$items){
  $s = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach($i in $items){ [void]$s.Add($i) }
  ,$s
}

Add-Type -AssemblyName Microsoft.VisualBasic
function Recycle($p){
  try {
    if(Test-Path -LiteralPath $p -PathType Container){ [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin') }
    else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin') }
  } catch {}
}

function Norm($s){ ([string]$s).ToLower() -replace '[^a-z0-9]','' }

function Get-DirStats($p){
  $sum = [long]0; $newest = [datetime]::MinValue
  $st = New-Object System.Collections.Stack
  $st.Push($p)
  while($st.Count){
    $d = $st.Pop()
    try {
      $di = [IO.DirectoryInfo]$d
      foreach($f in $di.GetFiles()){ $sum += $f.Length; if($f.LastWriteTime -gt $newest){ $newest = $f.LastWriteTime } }
      foreach($s in $di.GetDirectories()){
        if(-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)){ $st.Push($s.FullName) }
      }
    } catch {}
  }
  [pscustomobject]@{ Size = $sum; Newest = $newest }
}

function Get-Hash($p, [int]$limit){
  $fs = $null
  try {
    $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
    $sha = [Security.Cryptography.SHA256]::Create()
    if($limit -gt 0){
      $buf = New-Object byte[] $limit
      $n = $fs.Read($buf, 0, $limit)
      $h = $sha.ComputeHash($buf, 0, $n)
    } else { $h = $sha.ComputeHash($fs) }
    [BitConverter]::ToString($h)
  } catch { $null } finally { if($fs){ $fs.Dispose() } }
}

function Get-DownloadsPath {
  $d = $null
  try { $d = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch {}
  if(-not $d){ $d = "$env:USERPROFILE\Downloads" }
  $d
}

$freeBefore = Get-Free
$drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID })
$sd = $env:SystemDrive
$wr = $env:SystemRoot
$la = $env:LOCALAPPDATA

Clear-Host
Write-Host ''
Write-Host '  PC CLEANER - FULL SCAN' -ForegroundColor Cyan
Write-Host "  Drives: $($drives -join ', ')" -ForegroundColor DarkGray
Write-Host '  Close browsers, Discord and games first for best results.' -ForegroundColor DarkGray
Write-Host '  [A] only applies to the current section.' -ForegroundColor DarkGray
$script:Auto = ($env:PCC_ARG -eq '/auto')
$taskName = 'PC Cleaner Overnight'
$pccDir = "$env:ProgramData\PCCleaner"

if($script:Auto){
  New-Item $pccDir -ItemType Directory -Force | Out-Null
  Start-Transcript -LiteralPath "$pccDir\last_run.log" -Force | Out-Null
  Write-Host "  OVERNIGHT RUN $(Get-Date -Format 'yyyy-MM-dd HH:mm') - safe items only" -ForegroundColor Cyan
  $script:Max = $true
} else {
  $existing = Get-ScheduledTask -TaskName $taskName
  Write-Host ''
  Write-Host '  [1] Ask about everything' -ForegroundColor White
  Write-Host '  [2] MAX - auto-clean all junk, only ask about risky items' -ForegroundColor White
  Write-Host '  [3] Set up OVERNIGHT auto-clean (daily, wakes PC, safe items only)' -ForegroundColor White
  if($existing){ Write-Host '  [4] Remove overnight auto-clean' -ForegroundColor White }
  Write-Host '  Mode: ' -NoNewline -ForegroundColor Cyan
  do { $m = [string]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').Character } until($m -in '1','2','3' -or ($existing -and $m -eq '4'))
  Write-Host $m
  $script:Max = ($m -eq '2')

  if($m -eq '3'){
    New-Item $pccDir -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $env:PCC_SELF "$pccDir\PC_Cleaner.bat" -Force
    Write-Host '  Run time (HH:mm, Enter = 03:00): ' -NoNewline -ForegroundColor Cyan
    $t = Read-Host
    if($t -notmatch '^\d{1,2}:\d{2}$'){ $t = '03:00' }
    $act = New-ScheduledTaskAction -Execute "$pccDir\PC_Cleaner.bat" -Argument '/auto'
    $trg = New-ScheduledTaskTrigger -Daily -At $t
    $set = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    $prn = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Settings $set -Principal $prn -Force | Out-Null
    if(Get-ScheduledTask -TaskName $taskName){
      Write-Host ''
      Write-Host "  Overnight auto-clean set for $t daily." -ForegroundColor Green
      Write-Host '  - Runs only while you are signed in (sleep is fine, it wakes the PC).' -ForegroundColor DarkGray
      Write-Host '  - Cleans safe junk only; skips Windows.old, Downloads, restore points, apps, startup, Explorer.' -ForegroundColor DarkGray
      Write-Host "  - Log: $pccDir\last_run.log" -ForegroundColor DarkGray
    } else { Write-Host '  Could not create the scheduled task.' -ForegroundColor Red }
    exit
  }
  if($m -eq '4'){
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Remove-Item -LiteralPath $pccDir -Recurse -Force
    Write-Host '  Overnight auto-clean removed.' -ForegroundColor Green
    exit
  }
}

# ---------------- 1. Recycle Bin ----------------
Header 'RECYCLE BIN (all drives)'
$script:All = $false
$rb = [long]0
try { (New-Object -ComObject Shell.Application).NameSpace(10).Items() | ForEach-Object { $rb += [long]$_.Size } } catch {}
if($rb -gt 0){
  if(Ask 'Recycle Bin' 'every drive' $rb -Risky:$script:Auto){ Clear-RecycleBin -Force; Done }
} else { Write-Host '  empty.' -ForegroundColor DarkGray }

# ---------------- 2. System junk ----------------
Header 'SYSTEM JUNK'
$script:All = $false
$known = @(
  @('User Temp',                 "$la\Temp"),
  @('Windows Temp',              "$wr\Temp"),
  @('Windows Update downloads',  "$wr\SoftwareDistribution\Download"),
  @('Delivery Optimization',     "$wr\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"),
  @('Windows setup leftovers',   "$sd\`$WINDOWS.~BT"),
  @('Windows setup leftovers',   "$sd\`$Windows.~WS"),
  @('Windows ESD leftovers',     "$sd\ESD"),
  @('CBS logs',                  "$wr\Logs\CBS"),
  @('Kernel reports',            "$wr\LiveKernelReports"),
  @('Minidumps',                 "$wr\Minidump"),
  @('Crash dumps',               "$la\CrashDumps"),
  @('Error reports (archive)',   "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"),
  @('Error reports (queue)',     "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"),
  @('Internet cache',            "$la\Microsoft\Windows\INetCache"),
  @('DirectX shader cache',      "$la\D3DSCache"),
  @('NVIDIA DXCache',            "$la\NVIDIA\DXCache"),
  @('NVIDIA GLCache',            "$la\NVIDIA\GLCache"),
  @('NVIDIA NV_Cache',           "$env:ProgramData\NVIDIA Corporation\NV_Cache"),
  @('AMD DxCache',               "$la\AMD\DxCache"),
  @('AMD DxcCache',              "$la\AMD\DxcCache"),
  @('Roblox logs',               "$la\Roblox\logs"),
  @('Windows Update logs',       "$wr\Logs\WindowsUpdate"),
  @('Windows Update datastore logs', "$wr\SoftwareDistribution\DataStore\Logs"),
  @('Update orchestrator logs',  "$env:ProgramData\USOShared\Logs"),
  @('Error reports (temp)',      "$env:ProgramData\Microsoft\Windows\WER\Temp"),
  @('Error reports (user)',      "$la\Microsoft\Windows\WER"),
  @('npm cache',                 "$la\npm-cache"),
  @('NuGet cache',               "$la\NuGet\v3-cache"),
  @('NuGet plugins cache',       "$la\NuGet\plugins-cache"),
  @('Steam logs',                "${env:ProgramFiles(x86)}\Steam\logs"),
  @('Steam crash dumps',         "${env:ProgramFiles(x86)}\Steam\dumps"),
  @('Steam http cache',          "${env:ProgramFiles(x86)}\Steam\appcache\httpcache"),
  @('Windows Installer patch cache', "$wr\Installer\`$PatchCache`$"),
  @('NVIDIA installer downloads', "$env:ProgramData\NVIDIA Corporation\Downloader"),
  @('NVIDIA driver extract',     "$sd\NVIDIA"),
  @('AMD driver extract',        "$sd\AMD"),
  @('Intel driver extract',      "$sd\Intel"),
  @('Windows Defender scan cache', "$env:ProgramData\Microsoft\Windows Defender\Scans\History\Results\Resource"),
  @('Windows logs (misc)',       "$wr\Logs\DISM"),
  @('Windows Panther logs',      "$wr\Panther"),
  @('Downloaded program files',  "$wr\Downloaded Program Files"),
  @('Windows logs (all)',        "$wr\Logs"),
  @('System log files',          "$wr\System32\LogFiles"),
  @('Telemetry logs',            "$env:ProgramData\Microsoft\Diagnosis\ETLLogs"),
  @('Windows caches',            "$la\Microsoft\Windows\Caches"),
  @('PerfLogs',                  "$sd\PerfLogs"),
  @('Windows 10 upgrade leftovers', "$sd\Windows10Upgrade"),
  @('Windows update leftovers',  "$sd\`$GetCurrent"),
  @('Windows reset leftovers',   "$sd\`$SysReset"),
  @('Microsoft Store cache',     "$la\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalCache"),
  @('OneDrive logs',             "$la\Microsoft\OneDrive\logs"),
  @('Spotify streaming cache',   "$la\Spotify\Data"),
  @('Roblox old installers',     "$la\Roblox\Downloads"),
  @('Bloxstrap logs',            "$la\Bloxstrap\Logs"),
  @('Epic Games logs',           "$la\EpicGamesLauncher\Saved\Logs"),
  @('Riot Client logs',          "$la\Riot Games\Riot Client\Logs"),
  @('EA app logs',               "$la\Electronic Arts\EA Desktop\Logs"),
  @('Ubisoft Connect logs',      "${env:ProgramFiles(x86)}\Ubisoft\Ubisoft Game Launcher\logs"),
  @('NVIDIA per-user cache',     "$la\NVIDIA Corporation\NV_Cache"),
  @('VS Code cached data',       "$env:APPDATA\Code\CachedData"),
  @('VS Code extension installers', "$env:APPDATA\Code\CachedExtensionVSIXs"),
  @('Go build cache',            "$la\go-build"),
  @('Gradle cache',              "$env:USERPROFILE\.gradle\caches"),
  @('Scoop download cache',      "$env:USERPROFILE\scoop\cache"),
  @('pip cache',                 "$la\pip\cache"),
  @('Yarn cache',                "$la\Yarn\Cache"),
  @('pnpm cache',                "$la\pnpm-cache"),
  @('Bun cache',                 "$env:USERPROFILE\.bun\install\cache"),
  @('Cargo download cache',      "$env:USERPROFILE\.cargo\registry\cache"),
  @('Composer cache',            "$la\Composer"),
  @('winget logs',               "$la\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir"),
  @('Chocolatey logs',           "$env:ProgramData\chocolatey\logs"),
  @('Chocolatey backup leftovers', "$env:ProgramData\chocolatey\lib-bkp")
)
$done = New-Set @()
foreach($k in $known){
  $p = $k[1]
  [void]$done.Add($p)
  if(-not (Test-Path -LiteralPath $p)){ continue }
  $b = Get-DirSize $p
  if($b -lt 100KB){ continue }
  if(Ask $k[0] $p $b){
    if($p -like '*SoftwareDistribution*'){ Stop-Service wuauserv,bits -Force }
    Clear-Dir $p
    if($p -like '*SoftwareDistribution*'){ Start-Service wuauserv,bits }
    Done
  }
}

# Windows.old
$wo = "$sd\Windows.old"
if(Test-Path -LiteralPath $wo){
  $b = Get-DirSize $wo
  if(Ask 'Windows.old (previous Windows install - no rollback after)' $wo $b -Risky){
    $yn = switch((Get-UICulture).TwoLetterISOLanguageName){ 'de'{'J'} 'nl'{'J'} 'fr'{'O'} 'es'{'S'} 'it'{'S'} 'pt'{'S'} default{'Y'} }
    takeown /f $wo /r /d $yn *> $null
    icacls $wo /grant '*S-1-5-32-544:F' /t /c /q *> $null
    Remove-Tree $wo
    Done
  }
}

# ---------------- 3. Full drive scan ----------------
if(-not $script:Quit){
  Header 'SCANNING ALL DRIVES (can take a few minutes)'

  $skipNames = New-Set @('System Volume Information','$Recycle.Bin','Recovery','Windows.old','$WINDOWS.~BT','$Windows.~WS','node_modules','.git','WinSxS')
  $junkDirNames = New-Set @('Cache','Code Cache','GPUCache','ShaderCache','GrShaderCache','DawnCache','DawnGraphiteCache','DawnWebGPUCache',
                            'cache2','htmlcache','INetCache','CrashDumps','D3DSCache','DXCache','GLCache','NV_Cache','DxCache','DxcCache','Temp',
                            'Crashpad','CrashReports','Crash Reports','Media Cache','Media Cache Files',
                            'TempState','CacheStorage','ScriptCache','component_crx_cache','GraphiteDawnCache',
                            'crashes','minidumps','Dumps','D3DCache','shadercache_temp',
                            'CachedData','CachedExtensionVSIXs','DeferredBrowserMetrics','optimization_guide_model_store',
                            'GrShaderCache','VideoDecodeStats','__pycache__')
  $junkExt   = New-Set @('.tmp','.temp','.dmp','.chk','._mp','.gid')
  $logExt    = New-Set @('.log','.etl')
  $junkNames = New-Set @('thumbs.db','ehthumbs.db')
  $cut = (Get-Date).AddDays(-7)
  $wrFull = $wr.TrimEnd('\')

  $junkDirs = New-Object System.Collections.ArrayList
  $fileGroups = @{}
  $n = 0

  foreach($drv in $drives){
    $st = New-Object System.Collections.Stack
    $st.Push([IO.DirectoryInfo]"$drv\")
    while($st.Count){
      $di = $st.Pop(); $n++
      if($n % 2000 -eq 0){ Write-Host ("`r  {0}  {1:N0} folders scanned   " -f $drv, $n) -NoNewline -ForegroundColor DarkGray }

      try { $files = $di.GetFiles() } catch { $files = @() }
      foreach($f in $files){
        $e = $f.Extension
        if($junkExt.Contains($e) -or $junkNames.Contains($f.Name) -or ($logExt.Contains($e) -and $f.LastWriteTime -lt $cut)){
          $key = $di.FullName
          if(-not $fileGroups.ContainsKey($key)){ $fileGroups[$key] = New-Object System.Collections.ArrayList }
          [void]$fileGroups[$key].Add($f)
        }
      }

      try { $subs = $di.GetDirectories() } catch { $subs = @() }
      foreach($s in $subs){
        if($s.Attributes -band [IO.FileAttributes]::ReparsePoint){ continue }
        if($skipNames.Contains($s.Name)){ continue }
        if($s.FullName -ieq $wrFull){ continue }
        if($done.Contains($s.FullName)){ continue }
        if($junkDirNames.Contains($s.Name) -or $s.Name -like 'webcache*'){ [void]$junkDirs.Add($s.FullName); continue }
        $st.Push($s)
      }
    }
  }
  Write-Host ''

  # build candidate list
  $items = New-Object System.Collections.ArrayList
  foreach($d in $junkDirs){
    $b = Get-DirSize $d
    if($b -gt 0){ [void]$items.Add([pscustomobject]@{ Type='dir'; Path=$d; Bytes=$b; Files=$null; Label="Cache/temp folder" }) }
  }
  foreach($key in $fileGroups.Keys){
    $fl = $fileGroups[$key]
    $b = [long]0; foreach($f in $fl){ $b += $f.Length }
    if($b -gt 0){ [void]$items.Add([pscustomobject]@{ Type='files'; Path=$key; Bytes=$b; Files=$fl; Label="$($fl.Count) junk files (tmp/dmp/old logs)" }) }
  }

  $big   = @($items | Where-Object { $_.Bytes -ge 1MB } | Sort-Object Bytes -Descending)
  $small = @($items | Where-Object { $_.Bytes -lt 1MB })
  $total = [long]0; foreach($i in $items){ $total += $i.Bytes }

  Header ("SCAN RESULTS: {0} spots, {1} total  ({2} folders scanned)" -f $items.Count, (Fmt $total), $n)
  $script:All = $false
  foreach($i in $big){
    if($script:Quit){ break }
    if(Ask $i.Label $i.Path $i.Bytes){
      if($i.Type -eq 'dir'){ Clear-Dir $i.Path } else { foreach($f in $i.Files){ try { $f.Attributes='Normal'; $f.Delete() } catch {} } }
      Done
    }
  }
  if($small.Count -gt 0){
    $sb = [long]0; foreach($i in $small){ $sb += $i.Bytes }
    if(Ask "Small junk ($($small.Count) spots under 1 MB each)" '' $sb){
      foreach($i in $small){
        if($i.Type -eq 'dir'){ Clear-Dir $i.Path } else { foreach($f in $i.Files){ try { $f.Attributes='Normal'; $f.Delete() } catch {} } }
      }
      Done
    }
  }
}

# ---------------- 4. Old downloads ----------------
if(-not $script:Quit){
  $dl = $null
  try { $dl = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch {}
  if(-not $dl){ $dl = "$env:USERPROFILE\Downloads" }
  $old = @(Get-ChildItem -LiteralPath $dl -File -Force | Where-Object {
           $_.Extension -match '^\.(exe|msi|zip|rar|7z|iso)$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-30) -and $_.Length -ge 1MB
         } | Sort-Object Length -Descending)
  if($old.Count -gt 0){
    Header "OLD INSTALLERS / ARCHIVES IN DOWNLOADS (30+ days)"
    $script:All = $false
    foreach($f in $old){
      if(Ask $f.Name $f.LastWriteTime.ToString('yyyy-MM-dd') $f.Length -Risky){ Remove-Item -LiteralPath $f.FullName -Force; Done }
    }
  }
}

# ---------------- 5. Windows extras ----------------
if(-not $script:Quit){
  Header 'WINDOWS EXTRAS'
  $script:All = $false
  $hf = Get-Item -LiteralPath "$sd\hiberfil.sys" -Force
  if($hf){
    if(Ask 'Hibernation file (turns off hibernate + Fast Startup)' "$sd\hiberfil.sys" $hf.Length -Risky){ powercfg /h off; Done }
  }
  if(Ask 'Component store cleanup (DISM, takes a few minutes)' 'removes superseded update files' 0){
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup
    Done
    if(Ask 'Also /ResetBase (frees more, but installed updates can no longer be uninstalled)' '' 0 'Run' -Risky){
      Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
      Done
    }
  }
  ipconfig /flushdns > $null
  netsh interface ip delete arpcache > $null
}

# ---------------- 6. Deep clean ----------------
if(-not $script:Quit){
  Header 'DEEP CLEAN'
  $script:All = $false

  if(Ask 'Windows Disk Cleanup - all categories (old drivers, update leftovers, logs...)' 'silent cleanmgr run, Downloads excluded' 0 'Run'){
    $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    Get-ChildItem $vc | Where-Object { $_.PSChildName -ne 'DownloadsFolder' } | ForEach-Object {
      Set-ItemProperty -LiteralPath $_.PSPath -Name StateFlags0777 -Value 2 -Type DWord
    }
    Write-Host '            running Disk Cleanup (can take several minutes)...' -ForegroundColor DarkGray
    Start-Process cleanmgr.exe '/sagerun:777' -WindowStyle Hidden -Wait
    Done
  }

  $sc = @(Get-CimInstance Win32_ShadowCopy | Sort-Object InstallDate)
  if($sc.Count -gt 1){
    $used = [long]0; Get-CimInstance Win32_ShadowStorage | ForEach-Object { $used += [long]$_.UsedSpace }
    if(Ask "Old restore points ($($sc.Count - 1) of $($sc.Count), newest kept)" 'size shown = all restore points' $used -Risky){
      $sc | Select-Object -First ($sc.Count - 1) | Remove-CimInstance
      Done
    }
  }

  if(Ask 'Disable Reserved Storage (~7 GB Windows holds back for updates)' '' -1 'Apply' -Risky){
    Dism.exe /Online /Set-ReservedStorageState /State:Disabled /Quiet
    Done
  }

  # full memory dump
  $md = Get-Item -LiteralPath "$wr\MEMORY.DMP" -Force
  if($md -and (Ask 'Full memory crash dump' $md.FullName $md.Length)){ Remove-Item -LiteralPath $md.FullName -Force; Done }

  # search index
  $sx = "$env:ProgramData\Microsoft\Search\Data\Applications\Windows"
  if(Test-Path -LiteralPath $sx){
    if(Ask 'Rebuild Windows Search index (rebuilds in background)' $sx (Get-DirSize $sx) 'Rebuild' -Risky:$script:Auto){
      Stop-Service WSearch -Force
      Get-ChildItem -LiteralPath $sx -Force -File | Where-Object { $_.Name -match '^Windows.*\.(edb|db|db-wal|db-shm|jfm)$|\.log$|\.jrs$|\.chk$' } | Remove-Item -Force
      Clear-Dir "$sx\GatherLogs"
      Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' SetupCompletedSuccessfully 0 -Type DWord
      Start-Service WSearch
      Done
    }
  }

  # font cache
  $fc = "$wr\ServiceProfiles\LocalService\AppData\Local\FontCache"
  $fb = (Get-DirSize $fc) + [long](Get-Item -LiteralPath "$wr\System32\FNTCACHE.DAT" -Force).Length
  if($fb -gt 0 -and (Ask 'Rebuild font cache' $fc $fb 'Rebuild' -Risky:$script:Auto)){
    Stop-Service FontCache,FontCache3.0.0.0 -Force
    Clear-Dir $fc
    Remove-Item -LiteralPath "$wr\System32\FNTCACHE.DAT" -Force
    Start-Service FontCache
    Done
  }

  # event logs
  $el = "$wr\System32\winevt\Logs"
  if(Ask 'Clear all Windows event logs (loses troubleshooting history)' $el (Get-DirSize $el) 'Clear' -Risky){
    wevtutil el | ForEach-Object { wevtutil cl "$_" 2>$null }
    Done
  }

  # compact OS
  if(Ask 'Compact OS (compress Windows files, frees 2-4 GB, tiny CPU cost)' '' -1 'Apply' -Risky){
    compact.exe /CompactOS:always
    Done
  }
}

# ---------------- 6b. Bloatware ----------------
if(-not $script:Quit){
  $bloat = @(
    'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.BingSearch','Microsoft.GetHelp','Microsoft.Getstarted',
    'Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftOfficeHub','Microsoft.People','Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos','Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.ZuneVideo','Clipchamp.Clipchamp',
    'MicrosoftTeams','MSTeams','Microsoft.549981C3F5F10','Microsoft.SkypeApp','Microsoft.MixedReality.Portal',
    'Microsoft.Microsoft3DViewer','Microsoft.MicrosoftStickyNotes','Microsoft.Copilot','Microsoft.Windows.DevHome',
    'MicrosoftCorporationII.QuickAssist','Microsoft.OutlookForWindows','king.com.*','*Disney*','*CandyCrush*','*TikTok*','*Facebook*','*Instagram*'
  )
  $apps = @()
  foreach($b in $bloat){ $apps += @(Get-AppxPackage -AllUsers -Name $b) }
  $apps = @($apps | Sort-Object Name -Unique)
  if($apps.Count -gt 0){
    Header "PREINSTALLED BLOATWARE ($($apps.Count) found)"
    $script:All = $false
    foreach($a in $apps){
      if(Ask $a.Name $a.InstallLocation -1 'Uninstall' -Risky){
        Get-AppxPackage -AllUsers -Name $a.Name | Remove-AppxPackage -AllUsers
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $a.Name | Remove-AppxProvisionedPackage -Online | Out-Null
        Done
      }
    }
  }
}

# ---------------- 6c. Startup apps ----------------
if(-not $script:Quit){
  $sa = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
  $ents = New-Object System.Collections.ArrayList
  foreach($src in @(
      @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU','Run'),
      @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM','Run'),
      @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKLM','Run32'))){
    $props = Get-ItemProperty -LiteralPath $src[0]
    if(-not $props){ continue }
    foreach($p in $props.PSObject.Properties){
      if($p.Name -in 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider'){ continue }
      [void]$ents.Add([pscustomobject]@{ Name=$p.Name; Cmd=[string]$p.Value; Hive=$src[1]; Sub=$src[2] })
    }
  }
  foreach($sf in @(@([Environment]::GetFolderPath('Startup'),'HKCU'), @([Environment]::GetFolderPath('CommonStartup'),'HKLM'))){
    Get-ChildItem -LiteralPath $sf[0] -File -Force | Where-Object Name -ne 'desktop.ini' | ForEach-Object {
      [void]$ents.Add([pscustomobject]@{ Name=$_.Name; Cmd=$_.FullName; Hive=$sf[1]; Sub='StartupFolder' })
    }
  }
  $ents = @($ents | Where-Object {
    $v = (Get-ItemProperty -LiteralPath "$($_.Hive):\$sa\$($_.Sub)").($_.Name)
    -not ($v -and ($v[0] -band 1))
  })
  if($ents.Count -gt 0){
    Header "STARTUP APPS ($($ents.Count) enabled) - re-enable anytime in Task Manager"
    $script:All = $false
    foreach($e in $ents){
      if(Ask $e.Name $e.Cmd -1 'Disable' -Risky){
        $k = "$($e.Hive):\$sa\$($e.Sub)"
        if(-not (Test-Path $k)){ New-Item $k -Force | Out-Null }
        New-ItemProperty -LiteralPath $k -Name $e.Name -PropertyType Binary -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Force | Out-Null
        Done
      }
    }
  }
}

# ---------------- 7. Explorer refresh ----------------
# ---------------- 6d. Leftovers from uninstalled apps ----------------
if(-not $script:Quit -and -not $script:Auto){
  Header 'LEFTOVERS FROM UNINSTALLED APPS (moved to Recycle Bin, recoverable)'
  Write-Host '  Checking installed apps...' -ForegroundColor DarkGray
  $script:All = $false
  $kn = New-Set @()
  $addPath = { param($v)
    if([string]$v -match '([A-Za-z]:\\[^"*?<>|]+)'){
      foreach($seg in ($Matches[1] -split '\\')){ $n = Norm $seg; if($n.Length -ge 3){ [void]$kn.Add($n) } }
    }
  }
  $txt = New-Object System.Text.StringBuilder
  foreach($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'){
    foreach($u in @(Get-ItemProperty $k)){
      foreach($v in $u.DisplayName, $u.Publisher, $u.PSChildName){ [void]$txt.Append('|').Append((Norm $v)) }
      foreach($v in $u.InstallLocation, $u.DisplayIcon, $u.UninstallString){ & $addPath $v }
    }
  }
  foreach($a in @(Get-AppxPackage -AllUsers)){ [void]$txt.Append('|').Append((Norm $a.Name)); & $addPath $a.InstallLocation }
  foreach($m in @(Get-ChildItem "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests" -Filter '*.item' -File)){
    try { $j = Get-Content -LiteralPath $m.FullName -Raw | ConvertFrom-Json
          [void]$txt.Append('|').Append((Norm $j.DisplayName)).Append('|').Append((Norm $j.AppName)); & $addPath $j.InstallLocation } catch {}
  }
  foreach($p in @(Get-Process)){ & $addPath $p.Path }
  foreach($s in @(Get-CimInstance Win32_Service)){ & $addPath $s.PathName }
  foreach($s in @(Get-ScheduledTask)){ foreach($ac in $s.Actions){ & $addPath ([Environment]::ExpandEnvironmentVariables([string]$ac.Execute)) } }
  foreach($r in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'){
    $pr = Get-ItemProperty -LiteralPath $r
    if($pr){ foreach($x in $pr.PSObject.Properties){ & $addPath ([string]$x.Value) } }
  }
  $blob = $txt.ToString()

  $skipLeft = New-Set @('Common Files','Package Cache','Packages','Temp','ModifiableWindowsApps','Internet Explorer','Reference Assemblies',
    'MSBuild','dotnet','PowerShell','Uninstall Information','PackageManagement','ssh','USOShared','USOPrivate','SoftwareDistribution','Comms',
    'ConnectedDevicesPlatform','Publishers','D3DSCache','CrashDumps','Programs','PlaceholderTileLogoFolder','Realtek','Application Data',
    'Desktop','Documents','History','Start Menu','Templates','Favorites','PCCleaner','Claude','AnthropicClaude','IsolatedStorage','VirtualStore',
    'Adobe','Google','Mozilla','Apple','Apple Computer','Downloaded Installations','SquirrelTemp','Diagnosis','Spooler','Steam','npm','fontconfig',
    'CEF','ElevatedDiagnostics','Peernet','PeerDistRepub','Battle.net','Epic','Package Store','Sun','Java','Oracle','Docker','DockerDesktop')
  $cutL = (Get-Date).AddDays(-60)
  $leftRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $la, "$env:USERPROFILE\AppData\LocalLow") |
               Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
  $left = New-Object System.Collections.ArrayList
  foreach($r in $leftRoots){
    try { $ds = ([IO.DirectoryInfo]$r).GetDirectories() } catch { $ds = @() }
    foreach($d in $ds){
      if($d.Attributes -band [IO.FileAttributes]::ReparsePoint){ continue }
      $nm = $d.Name
      if($skipLeft.Contains($nm) -or $nm -match '^(Microsoft|Windows|NVIDIA|Intel|AMD|regid|\.|\{)'){ continue }
      $n = Norm $nm
      if($n.Length -lt 3 -or $kn.Contains($n) -or $blob.Contains($n)){ continue }
      $stt = Get-DirStats $d.FullName
      if($stt.Size -lt 100KB -or $stt.Newest -gt $cutL){ continue }
      [void]$left.Add([pscustomobject]@{ Path = $d.FullName; Name = $nm; Bytes = $stt.Size; Newest = $stt.Newest })
    }
  }
  if($left.Count){
    foreach($l in ($left | Sort-Object Bytes -Descending)){
      if(Ask "Leftover: $($l.Name)" "$($l.Path)   (last changed $($l.Newest.ToString('yyyy-MM-dd')))" $l.Bytes 'Recycle' -Risky){ Recycle $l.Path; Done }
    }
  } else { Write-Host '  none found.' -ForegroundColor DarkGray }
}

# ---------------- 6e. Broken shortcuts ----------------
if(-not $script:Quit){
  $wsh = New-Object -ComObject WScript.Shell
  $lnkRoots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'),
                [Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('CommonStartMenu'),
                "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch") | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
  $broken = @(foreach($r in $lnkRoots){
    Get-ChildItem -LiteralPath $r -Filter '*.lnk' -File -Recurse -Force | Where-Object {
      $t = $wsh.CreateShortcut($_.FullName).TargetPath
      $t -and $t -match '^[A-Za-z]:\\' -and ($drives -contains $t.Substring(0,2).ToUpper()) -and -not (Test-Path -LiteralPath $t)
    }
  })
  if($broken.Count){
    Header "BROKEN SHORTCUTS ($($broken.Count))"
    $script:All = $false
    $broken | Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor DarkGray }
    if($broken.Count -gt 20){ Write-Host "  ...and $($broken.Count - 20) more" -ForegroundColor DarkGray }
    $bb = [long]0; $broken | ForEach-Object { $bb += $_.Length }
    if(Ask "$($broken.Count) shortcuts pointing to files that no longer exist" '' $bb){
      $broken | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
      Done
    }
  }
}

# ---------------- 6f. Steam leftovers ----------------
if(-not $script:Quit){
  $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath
  if(-not $steam){ $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam').InstallPath }
  if($steam){
    $steam = ($steam -replace '/','\').TrimEnd('\')
    $libs = @($steam)
    $vdf = "$steam\steamapps\libraryfolders.vdf"
    if(Test-Path -LiteralPath $vdf){
      $libs += [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"') | ForEach-Object { ($_.Groups[1].Value -replace '\\\\','\').TrimEnd('\') }
    }
    $libs = @($libs | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath "$_\steamapps" })
    $steamRunning = [bool](Get-Process steam)
    Header "STEAM LEFTOVERS ($($libs.Count) librar$(if($libs.Count -eq 1){'y'}else{'ies'}))"
    $script:All = $false
    if($steamRunning){ Write-Host '  Steam is running - download/temp folders skipped. Close Steam for a full clean.' -ForegroundColor DarkGray }

    if(-not $steamRunning){
      $dc = "$steam\depotcache"
      $b = Get-DirSize $dc
      if($b -gt 1MB -and (Ask 'Steam depot cache' $dc $b)){ Clear-Dir $dc; Done }
    }

    foreach($lib in $libs){
      $sa = "$lib\steamapps"
      $ids = New-Set @(); $dirs = New-Set @()
      foreach($m in @(Get-ChildItem -LiteralPath $sa -Filter 'appmanifest_*.acf' -File)){
        if($m.BaseName -match '_(\d+)$'){ [void]$ids.Add($Matches[1]) }
        if([IO.File]::ReadAllText($m.FullName) -match '"installdir"\s+"([^"]+)"'){ [void]$dirs.Add($Matches[1]) }
      }

      if(-not $steamRunning){
        foreach($sub in 'downloading','temp'){
          $p = "$sa\$sub"; $b = Get-DirSize $p
          if($b -gt 0 -and (Ask "Steam unfinished $sub" $p $b)){ Clear-Dir $p; Done }
        }
      }

      if($ids.Count -eq 0){ continue }

      foreach($sub in 'shadercache','workshop\content'){
        $orph = @(Get-ChildItem -LiteralPath "$sa\$sub" -Directory | Where-Object { $_.Name -match '^\d+$' -and -not $ids.Contains($_.Name) })
        if($orph.Count){
          $b = [long]0; foreach($o in $orph){ $b += Get-DirSize $o.FullName }
          if($b -gt 0 -and (Ask "Steam $sub for $($orph.Count) uninstalled game(s)" "$sa\$sub" $b)){
            foreach($o in $orph){ Remove-Tree $o.FullName }
            Done
          }
        }
      }

      foreach($g in @(Get-ChildItem -LiteralPath "$sa\common" -Directory)){
        if($dirs.Contains($g.Name)){ continue }
        $b = Get-DirSize $g.FullName
        if($b -gt 0 -and (Ask "Orphaned game folder: $($g.Name) (no Steam install found, PERMANENT delete)" $g.FullName $b 'Delete' -Risky)){
          Remove-Tree $g.FullName
          Done
        }
      }
    }
  }
}

# ---------------- 6g. Old driver versions ----------------
if(-not $script:Quit -and -not $script:Auto){
  Header 'OLD DRIVER VERSIONS'
  Write-Host '  Reading driver store...' -ForegroundColor DarkGray
  $script:All = $false
  $inUse = New-Set @(Get-CimInstance Win32_PnPSignedDriver | ForEach-Object { $_.InfName } | Where-Object { $_ })
  $drvAll = @(Get-WindowsDriver -Online)
  $oldDrv = @(foreach($g in ($drvAll | Group-Object { (Split-Path $_.OriginalFileName -Leaf).ToLower() + '|' + $_.ProviderName })){
    if($g.Count -lt 2){ continue }
    $g.Group | Sort-Object @{ e = { try { [version]$_.Version } catch { [version]'0.0' } } }, Date -Descending |
      Select-Object -Skip 1 | Where-Object { -not $inUse.Contains($_.Driver) }
  })
  if($oldDrv.Count){
    foreach($d in ($oldDrv | Sort-Object ProviderName, ClassName)){
      $b = Get-DirSize (Split-Path $d.OriginalFileName)
      $dt = try { (Get-Date $d.Date).ToString('yyyy-MM-dd') } catch { '?' }
      if(Ask "$($d.ProviderName) $($d.ClassName) driver v$($d.Version) ($dt)" "$($d.Driver) - newer version is kept" $b){
        pnputil /delete-driver $d.Driver *> $null
        if($LASTEXITCODE -eq 0){ Done } else { Write-Host '            in use, kept.' -ForegroundColor DarkGray }
      }
    }
  } else { Write-Host '  none found.' -ForegroundColor DarkGray }
}

# ---------------- 6h. WSL / Docker virtual disks ----------------
if(-not $script:Quit -and -not $script:Auto){
  $vhds = @()
  foreach($pk in @(Get-ChildItem -LiteralPath "$la\Packages" -Directory)){ $vhds += @(Get-ChildItem -LiteralPath "$($pk.FullName)\LocalState" -Filter '*.vhdx' -File) }
  $vhds += @(Get-ChildItem -LiteralPath "$la\Docker\wsl" -Filter '*.vhdx' -File -Recurse)
  foreach($lx in @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss')){
    $bp = $lx.GetValue('BasePath')
    if($bp){ $vhds += @(Get-ChildItem -LiteralPath ($bp -replace '^\\\\\?\\','') -Filter '*.vhdx' -File) }
  }
  $vhds = @($vhds | Where-Object { $_ } | Sort-Object FullName -Unique)
  if($vhds.Count){
    Header 'WSL / DOCKER VIRTUAL DISKS'
    $script:All = $false
    $tot = [long]0
    foreach($v in $vhds){ $tot += $v.Length; Write-Host "  $($v.FullName)" -ForegroundColor DarkGray }
    if(Ask "Compact $($vhds.Count) virtual disk(s) - shuts down WSL and Docker" 'gives back space deleted inside Linux/containers' $tot 'Compact' -Risky){
      $distros = @((wsl.exe -l -q) -replace "`0",'' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      foreach($d in $distros){ wsl.exe -d $d -u root -- fstrim -a *> $null }
      Get-Process 'Docker Desktop','com.docker.backend','com.docker.build' | Stop-Process -Force
      wsl.exe --shutdown
      Start-Sleep 5
      $dp = "$env:TEMP\pcc_diskpart.txt"
      foreach($v in $vhds){
        $before = (Get-Item -LiteralPath $v.FullName).Length
        "select vdisk file=`"$($v.FullName)`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk" | Set-Content -LiteralPath $dp -Encoding ASCII
        diskpart /s $dp *> $null
        $after = (Get-Item -LiteralPath $v.FullName).Length
        Write-Host ("            {0}: {1} -> {2}" -f $v.Name, (Fmt $before), (Fmt $after)) -ForegroundColor Green
      }
      Remove-Item -LiteralPath $dp -Force
    }
  }
}

# ---------------- 6i. Duplicate files ----------------
if(-not $script:Quit -and -not $script:Auto){
  Header 'DUPLICATE FILES (all drives - photos, videos, music, docs, archives over 1 MB)'
  $dupExt = New-Set @('.jpg','.jpeg','.png','.gif','.webp','.bmp','.tif','.tiff','.heic','.raw','.cr2','.nef','.arw','.dng','.psd',
                      '.mp4','.mkv','.mov','.avi','.wmv','.webm','.m4v','.mp3','.wav','.flac','.m4a','.aac','.ogg',
                      '.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.zip','.rar','.7z','.iso')
  $instExt = New-Set @('.exe','.msi')
  $dupSkip = New-Set @('Windows','Program Files','Program Files (x86)','ProgramData','AppData','$Recycle.Bin','System Volume Information',
                       'Recovery','WindowsApps','XboxGames','steamapps','SteamLibrary','Epic Games','Riot Games','Battle.net','EA Games',
                       'Origin Games','Ubisoft','Ubisoft Game Launcher','GOG Games','GOG Galaxy','node_modules','.git','Windows.old',
                       '$WINDOWS.~BT','$Windows.~WS','$GetCurrent','$SysReset','PCCleaner')
  $dlPath = Get-DownloadsPath
  $deskPath = [Environment]::GetFolderPath('Desktop')
  $cloudMask = 0x441000   # Offline | RecallOnOpen | RecallOnDataAccess (OneDrive cloud-only files)
  $bySize = @{}
  $nd = 0
  foreach($drv in $drives){
    $st = New-Object System.Collections.Stack
    $st.Push([IO.DirectoryInfo]"$drv\")
    while($st.Count){
      $di = $st.Pop(); $nd++
      if($nd % 2000 -eq 0){ Write-Host ("`r  {0}  {1:N0} folders scanned   " -f $drv, $nd) -NoNewline -ForegroundColor DarkGray }
      try { $fs = $di.GetFiles() } catch { $fs = @() }
      foreach($f in $fs){
        if($f.Length -lt 1MB){ continue }
        if([int]$f.Attributes -band $cloudMask){ continue }
        $e = $f.Extension
        if(-not $dupExt.Contains($e)){
          if(-not ($instExt.Contains($e) -and ($f.FullName.StartsWith("$dlPath\", 'OrdinalIgnoreCase') -or $f.FullName.StartsWith("$deskPath\", 'OrdinalIgnoreCase')))){ continue }
        }
        $sz = $f.Length
        if(-not $bySize.ContainsKey($sz)){ $bySize[$sz] = New-Object System.Collections.ArrayList }
        [void]$bySize[$sz].Add($f)
      }
      try { $subs = $di.GetDirectories() } catch { $subs = @() }
      foreach($s in $subs){
        if($s.Attributes -band [IO.FileAttributes]::ReparsePoint){ continue }
        if($dupSkip.Contains($s.Name)){ continue }
        $st.Push($s)
      }
    }
  }
  Write-Host ''

  $cands = New-Object System.Collections.ArrayList
  foreach($v in $bySize.Values){ if($v.Count -gt 1){ [void]$cands.Add($v) } }
  $groups = New-Object System.Collections.ArrayList
  $ci = 0
  foreach($c in $cands){
    $ci++
    if($ci % 200 -eq 0){ Write-Host ("`r  comparing {0} / {1}   " -f $ci, $cands.Count) -NoNewline -ForegroundColor DarkGray }
    foreach($p1 in @($c | Group-Object { Get-Hash $_.FullName 65536 } | Where-Object { $_.Count -gt 1 -and $_.Name })){
      foreach($p2 in @($p1.Group | Group-Object { Get-Hash $_.FullName 0 } | Where-Object { $_.Count -gt 1 -and $_.Name })){
        $gf = @($p2.Group)
        [void]$groups.Add([pscustomobject]@{ Files = $gf; Wasted = [long]$gf[0].Length * ($gf.Count - 1) })
      }
    }
  }
  Write-Host ''

  if($groups.Count){
    $wasted = [long]0; foreach($g in $groups){ $wasted += $g.Wasted }
    Write-Host ("  {0} sets of duplicates, {1} wasted. Copies go to the Recycle Bin." -f $groups.Count, (Fmt $wasted)) -ForegroundColor Cyan
    $script:All = $false
    foreach($grp in @($groups | Sort-Object Wasted -Descending)){
      $g = $grp.Files
      if($script:Quit){ break }
      $keep = $g | Sort-Object @{ e = { if($_.FullName.StartsWith("$dlPath\", 'OrdinalIgnoreCase')){ 1 } else { 0 } } }, CreationTime, @{ e = { $_.FullName.Length } } |
              Select-Object -First 1
      $extra = @($g | Where-Object { $_.FullName -ne $keep.FullName })
      Write-Host ''
      Write-Host "  KEEP  $($keep.FullName)" -ForegroundColor Green
      foreach($x in $extra){ Write-Host "  copy  $($x.FullName)" -ForegroundColor DarkYellow }
      if(Ask "$($extra.Count) duplicate(s) of $($keep.Name)" '' ($keep.Length * $extra.Count) 'Recycle copies' -Risky){
        foreach($x in $extra){ Recycle $x.FullName }
        Done
      }
    }
  } else { Write-Host '  none found.' -ForegroundColor DarkGray }
}

if(-not $script:Quit -and -not $script:Auto){
  $roots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
             [Environment]::GetFolderPath('MyVideos'), "$env:USERPROFILE\Downloads") | Select-Object -Unique | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  $cut90 = (Get-Date).AddDays(-90)
  $bigs = @(foreach($r in $roots){
              Get-ChildItem -LiteralPath $r -File -Recurse -Force | Where-Object { $_.Length -ge 1GB -and $_.LastWriteTime -lt $cut90 -and $_.LastAccessTime -lt $cut90 }
            }) | Sort-Object FullName -Unique | Sort-Object Length -Descending | Select-Object -First 30
  if($bigs){
    Header 'LARGE FILES UNTOUCHED FOR 90+ DAYS (moved to Recycle Bin, recoverable)'
    $script:All = $false
    Add-Type -AssemblyName Microsoft.VisualBasic
    foreach($f in $bigs){
      if(Ask $f.Name $f.DirectoryName $f.Length 'Recycle' -Risky){
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
        Done
      }
    }
  }
}

# ---------------- 6j. Empty folders ----------------
if(-not $script:Quit -and -not $script:Auto){
  $script:empties = New-Object System.Collections.ArrayList
  function Find-Empty([IO.DirectoryInfo]$d){
    $isEmpty = $true
    try { if($d.GetFiles().Count){ $isEmpty = $false } } catch { return $false }
    try { $subs = $d.GetDirectories() } catch { return $false }
    foreach($s in $subs){
      if(($s.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $s.Name -eq '.git'){ $isEmpty = $false; continue }
      if(Find-Empty $s){ [void]$script:empties.Add($s.FullName) } else { $isEmpty = $false }
    }
    $isEmpty
  }
  $eRoots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Get-DownloadsPath),
              [Environment]::GetFolderPath('MyPictures'), [Environment]::GetFolderPath('MyVideos'), [Environment]::GetFolderPath('MyMusic')) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
  foreach($r in $eRoots){ [void](Find-Empty ([IO.DirectoryInfo]$r)) }
  if($script:empties.Count){
    Header "EMPTY FOLDERS ($($script:empties.Count) in Desktop/Documents/Downloads/Pictures/Videos/Music)"
    $script:All = $false
    $script:empties | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if($script:empties.Count -gt 15){ Write-Host "  ...and $($script:empties.Count - 15) more" -ForegroundColor DarkGray }
    if(Ask "$($script:empties.Count) empty folders" '' 0){
      foreach($e in $script:empties){ try { [IO.Directory]::Delete($e) } catch {} }
      Done
    }
  }
}

if(-not $script:Quit -and -not $script:Auto){
  Header 'EXPLORER REFRESH'
  $script:All = $false
  $exp  = "$la\Microsoft\Windows\Explorer"
  $rec  = "$env:APPDATA\Microsoft\Windows\Recent"
  $expK = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
  $bags = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell'
  $doRecent = $false; $doThumb = $false; $doBags = $false; $restart = $false

  if(Ask 'Clear Quick Access + recent files history (also unpins Quick Access)' $rec (Get-DirSize $rec) -Risky){ $doRecent = $true }

  $tb = [long]0
  Get-ChildItem -LiteralPath $exp -Filter '*cache_*.db' -Force | ForEach-Object { $tb += $_.Length }
  $ic = Get-Item -LiteralPath "$la\IconCache.db" -Force; if($ic){ $tb += $ic.Length }
  if(Ask 'Rebuild thumbnail + icon cache' $exp $tb 'Rebuild'){ $doThumb = $true }

  if(Ask 'Reset all folder views to "General items" (stops slow folder-type detection)' '' -1 'Apply' -Risky){ $doBags = $true }

  if(Ask 'Stop tracking recent/frequent files in Quick Access' '' -1 'Apply' -Risky){
    Set-ItemProperty $expK ShowRecent 0 -Type DWord
    Set-ItemProperty $expK ShowFrequent 0 -Type DWord
    $restart = $true; Done
  }

  if(Ask 'Open Explorer to "This PC" instead of Home' '' -1 'Apply' -Risky){
    Set-ItemProperty "$expK\Advanced" LaunchTo 1 -Type DWord
    $restart = $true; Done
  }

  if([Environment]::OSVersion.Version.Build -ge 22000){
    if(Ask 'Classic right-click menu (no "Show more options")' '' -1 'Apply' -Risky){
      $cm = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
      New-Item $cm -Force | Out-Null
      Set-Item $cm -Value ''
      $restart = $true; Done
    }
  }

  # third-party right-click extensions
  $blockKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
  $blocked  = Get-ItemProperty -LiteralPath $blockKey
  $seen = New-Set @()
  $exts = New-Object System.Collections.ArrayList
  foreach($r in '*','Directory','Directory\Background','Folder','AllFilesystemObjects','Drive'){
    foreach($h in (Get-ChildItem -LiteralPath "Registry::HKEY_CLASSES_ROOT\$r\shellex\ContextMenuHandlers")){
      $clsid = $h.GetValue('')
      if($clsid -notmatch '^\{[0-9A-Fa-f-]{36}\}$'){ $clsid = $h.PSChildName }
      if($clsid -notmatch '^\{[0-9A-Fa-f-]{36}\}$'){ continue }
      if(-not $seen.Add($clsid)){ continue }
      if($blocked -and $blocked.PSObject.Properties[$clsid]){ continue }
      $dll = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\InprocServer32").'(default)'
      if(-not $dll){ continue }
      $dll = [Environment]::ExpandEnvironmentVariables($dll).Trim('"')
      if($dll -like "$wr\*"){ continue }
      $name = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid").'(default)'
      if(-not $name){ $name = $h.PSChildName }
      [void]$exts.Add([pscustomobject]@{ Name = $name; Clsid = $clsid; Dll = $dll })
    }
  }
  if($exts.Count -gt 0){
    Write-Host ''
    Write-Host "  Third-party right-click extensions found: $($exts.Count)" -ForegroundColor Cyan
    $script:All = $false
    $log = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PC_Cleaner_blocked_extensions.txt'
    foreach($x in $exts){
      if(Ask $x.Name $x.Dll -1 'Block' -Risky){
        if(-not (Test-Path $blockKey)){ New-Item $blockKey -Force | Out-Null }
        New-ItemProperty -LiteralPath $blockKey -Name $x.Clsid -Value $x.Name -PropertyType String -Force | Out-Null
        Add-Content $log ("{0}  {1}`r`n   undo: reg delete `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`" /v {1} /f" -f $x.Name, $x.Clsid)
        $restart = $true; Done
      }
    }
    if(Test-Path $log){ Write-Host "  Undo list saved: $log" -ForegroundColor DarkGray }
  }

  # apply (needs Explorer closed)
  if($doRecent -or $doThumb -or $doBags -or $restart){
    Write-Host ''
    Write-Host '  Restarting Explorer...' -ForegroundColor DarkGray
    for($t = 0; $t -lt 3; $t++){
      taskkill /f /im explorer.exe *> $null
      Start-Sleep -Milliseconds 400
      if($doRecent){
        foreach($f in ([IO.DirectoryInfo]$rec).GetFiles()){ try { $f.Delete() } catch {} }
        Clear-Dir "$rec\AutomaticDestinations"
        Clear-Dir "$rec\CustomDestinations"
      }
      if($doThumb){
        Get-ChildItem -LiteralPath $exp -Filter '*cache_*.db' -Force | Remove-Item -Force
        Remove-Item -LiteralPath "$la\IconCache.db" -Force
      }
      if($doBags){
        Remove-Item "$bags\Bags" -Recurse -Force
        Remove-Item "$bags\BagMRU" -Recurse -Force
        New-Item "$bags\Bags\AllFolders\Shell" -Force | Out-Null
        Set-ItemProperty "$bags\Bags\AllFolders\Shell" FolderType 'NotSpecified'
      }
      if(-not $doThumb -or -not (Get-ChildItem -LiteralPath $exp -Filter 'thumbcache_*.db' -Force | Where-Object Length -gt 1MB)){ break }
    }
    for($w = 0; $w -lt 10 -and -not (Get-Process explorer); $w++){ Start-Sleep 1 }
    if(-not (Get-Process explorer)){ Start-Process explorer.exe }
    Done
  }
}

# ---------------- summary ----------------
$freeAfter = Get-Free
Header 'DONE'
$sum = [long]0
foreach($d in $freeAfter.Keys){
  $diff = $freeAfter[$d] - $freeBefore[$d]
  if($diff -gt 0){ $sum += $diff; Write-Host ("  {0}  +{1}" -f $d, (Fmt $diff)) -ForegroundColor Green }
}
Write-Host ("  Total freed: {0}" -f (Fmt $sum)) -ForegroundColor Cyan
Write-Host '  Locked/in-use files were skipped. Reboot recommended.' -ForegroundColor DarkGray
Write-Host ''
if($script:Auto){ Stop-Transcript | Out-Null }
