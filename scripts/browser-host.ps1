[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)]
  [ValidateSet('Ensure', 'Status', 'Adopt', 'Stop')]
  [string]$Action,

  [Parameter(Mandatory)]
  [string]$HostRoot,

  [string]$ProfilePath,
  [string]$ChromeExecutable,
  [string]$SourceInstancePath,
  [string]$StartUrl = 'https://chatgpt.com/'
)

$ErrorActionPreference = 'Stop'
$hostRootPath = [System.IO.Path]::GetFullPath($HostRoot)
$manifestPath = Join-Path $hostRootPath 'host.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Resolve-PathValue([string]$Value) {
  return [System.IO.Path]::GetFullPath($Value).TrimEnd('\')
}

function Get-HostManifest {
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
  try {
    return Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  } catch {
    throw "Browser Host manifest is invalid: $manifestPath"
  }
}

function Get-ProcessRecord([int]$ProcessId) {
  if ($ProcessId -le 0) { return $null }
  return Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
}

function Get-UserDataDirFromCommandLine([string]$CommandLine) {
  if (-not $CommandLine) { return $null }
  $match = [regex]::Match($CommandLine, '(?i)(?:^|\s)--user-data-dir=(?:"([^"]+)"|(\S+))')
  if (-not $match.Success) { return $null }
  $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
  try { return Resolve-PathValue $value } catch { return $null }
}

function Get-CDPPortFromCommandLine([string]$CommandLine) {
  if (-not $CommandLine) { return $null }
  $match = [regex]::Match($CommandLine, '(?i)(?:^|\s)--remote-debugging-port=(\d+)(?:\s|$)')
  if (-not $match.Success) { return $null }
  return [int]$match.Groups[1].Value
}

function Get-DefaultUserDataDir([string]$ProcessName) {
  if ($ProcessName -match '(?i)^chrome\.exe$') {
    return Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
  }
  if ($ProcessName -match '(?i)^msedge\.exe$') {
    return Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
  }
  return $null
}

function Test-ExistingChromeUserDataDir([string]$Profile) {
  if (-not (Test-Path -LiteralPath $Profile -PathType Container)) { return $false }
  if (-not (Test-Path -LiteralPath (Join-Path $Profile 'Local State') -PathType Leaf)) { return $false }
  $profileDirs = @(Get-ChildItem -LiteralPath $Profile -Directory -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^(Default|Profile \d+)$' -and
    (Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences') -PathType Leaf)
  })
  return $profileDirs.Count -gt 0
}

function Get-ProfileOwners([string]$Profile) {
  $expected = Resolve-PathValue $Profile
  return Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
    Where-Object {
      if ($_.Name -notmatch '(?i)^(chrome|msedge)\.exe$' -or $_.CommandLine -match '(?i)(?:^|\s)--type=') { return $false }
      $commandLineProfile = Get-UserDataDirFromCommandLine $_.CommandLine
      if ($commandLineProfile) {
        return $commandLineProfile.Equals($expected, [StringComparison]::OrdinalIgnoreCase)
      }
      $defaultProfile = Get-DefaultUserDataDir $_.Name
      return $defaultProfile -and (Resolve-PathValue $defaultProfile).Equals($expected, [StringComparison]::OrdinalIgnoreCase)
    }
}

function Test-CdpEndpoint([int]$Port) {
  if ($Port -lt 1 -or $Port -gt 65535) { return $false }
  try {
    $result = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2
    return [bool]$result.webSocketDebuggerUrl
  } catch {
    return $false
  }
}

function Test-HostProcess($State, [string]$ExpectedProfile) {
  if (
    -not $State -or
    [int]$State.schema_version -ne 1 -or
    -not $State.host_id -or
    -not $State.started_at -or
    (Resolve-PathValue ([string]$State.profile)) -ine (Resolve-PathValue $ExpectedProfile) -or
    [string]$State.endpoint -ine "http://127.0.0.1:$([int]$State.port)"
  ) {
    return $false
  }
  return Test-CDPProcess -ProcessId ([int]$State.pid) -Profile $ExpectedProfile -Port ([int]$State.port)
}

function Test-CDPProcess([int]$ProcessId, [string]$Profile, [int]$Port) {
  if ($ProcessId -le 0 -or $Port -lt 1 -or $Port -gt 65535) { return $false }
  $processRecord = Get-ProcessRecord $ProcessId
  if (-not $processRecord) { return $false }
  $observedProfile = Get-UserDataDirFromCommandLine $processRecord.CommandLine
  if (-not $observedProfile) { $observedProfile = Get-DefaultUserDataDir $processRecord.Name }
  if ($observedProfile -ine (Resolve-PathValue $Profile)) {
    return $false
  }
  if ((Get-CDPPortFromCommandLine $processRecord.CommandLine) -ne $Port) { return $false }
  $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
  if (-not ($listeners | Where-Object {
    [int]$_.OwningProcess -eq $ProcessId -and
    [string]$_.LocalAddress -eq '127.0.0.1'
  })) { return $false }
  return (Test-CdpEndpoint $Port)
}

function Write-HostManifest($State) {
  $null = New-Item -ItemType Directory -Path $hostRootPath -Force
  $temporaryPath = "$manifestPath.$PID.tmp"
  $json = $State | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $utf8NoBom)
  try {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
      $backupPath = "$manifestPath.$PID.bak"
      [System.IO.File]::Replace($temporaryPath, $manifestPath, $backupPath)
      if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
      }
    } else {
      [System.IO.File]::Move($temporaryPath, $manifestPath)
    }
  } finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function New-HostManifest([int]$ProcessId, [string]$Profile, [int]$Port, $Previous) {
  $sameSession = $Previous -and [int]$Previous.pid -eq $ProcessId -and [int]$Previous.port -eq $Port
  $startedAt = if ($sameSession -and $Previous.started_at) {
    [string]$Previous.started_at
  } else {
    [DateTime]::UtcNow.ToString('o')
  }
  $hostId = if ($Previous -and $Previous.host_id) {
    [string]$Previous.host_id
  } else {
    "browser-host-$([Guid]::NewGuid().ToString('N'))"
  }
  return [ordered]@{
    schema_version = 1
    host_id = $hostId
    pid = $ProcessId
    profile = (Resolve-PathValue $Profile)
    port = $Port
    endpoint = "http://127.0.0.1:$Port"
    started_at = $startedAt
  }
}

function New-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    $listener.Stop()
  }
}

function Get-ExistingProfileHost([string]$Profile) {
  $owners = @(Get-ProfileOwners $Profile)
  if ($owners.Count -gt 1) {
    throw "Multiple Chrome processes claim the Browser Host Profile; refusing to guess: $Profile"
  }
  if ($owners.Count -eq 0) { return $null }
  $owner = $owners[0]
  $port = Get-CDPPortFromCommandLine $owner.CommandLine
  if (-not $port -or -not (Test-CDPProcess -ProcessId ([int]$owner.ProcessId) -Profile $Profile -Port $port)) {
    throw "Chrome already owns this Profile without a verifiable CDP endpoint. Do not start another browser or create another Profile. Close Chrome normally, then run Ensure again with this same existing Profile: $Profile"
  }
  return New-HostManifest -ProcessId ([int]$owner.ProcessId) -Profile $Profile -Port $port -Previous (Get-HostManifest)
}

function Get-HostMutexName([string]$Root) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Resolve-PathValue $Root).ToLowerInvariant())
    $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    return "Local\chatgpt-web-agent-channel-$hash"
  } finally {
    $sha.Dispose()
  }
}

if ($Action -eq 'Status') {
  $state = Get-HostManifest
  if (-not $state) { throw "Browser Host is not initialized: $manifestPath" }
  if (-not (Test-HostProcess $state ([string]$state.profile))) {
    throw "Browser Host state is stale or its PID/Profile/CDP port no longer match. Run Ensure after confirming the Profile is not open elsewhere."
  }
  $state | ConvertTo-Json -Depth 8 -Compress
  exit 0
}

$null = New-Item -ItemType Directory -Path $hostRootPath -Force
$mutex = [System.Threading.Mutex]::new($false, (Get-HostMutexName $hostRootPath))
$mutexHeld = $false
try {
  try {
    $mutexHeld = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
  } catch [System.Threading.AbandonedMutexException] {
    $mutexHeld = $true
  }
  if (-not $mutexHeld) { throw "Timed out waiting for Browser Host lifecycle lock: $hostRootPath" }

  $previous = Get-HostManifest
  if ($Action -eq 'Stop') {
    if (-not $previous) { throw "Browser Host is not initialized: $manifestPath" }
    if (-not (Test-HostProcess $previous ([string]$previous.profile))) {
      throw "Refusing to stop Chrome because its PID, Profile, or CDP port does not match the Browser Host manifest."
    }
    $processId = [int]$previous.pid
    if ($PSCmdlet.ShouldProcess("Chrome PID $processId using $($previous.profile)", 'Stop Browser Host')) {
      Stop-Process -Id $processId -Force
      $deadline = [DateTime]::UtcNow.AddSeconds(10)
      while ((Get-ProcessRecord $processId) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
      }
      if (Get-ProcessRecord $processId) { throw "Timed out stopping Browser Host PID $processId" }
      Remove-Item -LiteralPath $manifestPath -Force
      [ordered]@{ stopped = $true; pid = $processId; host_id = $previous.host_id } | ConvertTo-Json -Compress
    }
    exit 0
  }

  if ($Action -eq 'Adopt') {
    if (-not $SourceInstancePath) { throw 'Adopt requires -SourceInstancePath.' }
    $sourcePath = (Resolve-Path -LiteralPath $SourceInstancePath).Path
    $sourceInstance = Get-Content -Raw -LiteralPath $sourcePath | ConvertFrom-Json
    $sourceProfile = Resolve-PathValue ([string]$sourceInstance.browser_profile)
    $sourceStatePath = [string]$sourceInstance.browser_state_file
    if (-not $sourceStatePath -or -not (Test-Path -LiteralPath $sourceStatePath -PathType Leaf)) {
      throw "The selected Agent has no browser state file to adopt: $sourceStatePath"
    }
    $sourceState = Get-Content -Raw -LiteralPath $sourceStatePath | ConvertFrom-Json
    $sourcePort = [int]$sourceState.port
    $sourcePid = [int]$sourceState.pid
    $profileOwners = @(Get-ProfileOwners $sourceProfile)
    if ($profileOwners.Count -ne 1) {
      throw 'The selected Profile must have exactly one verified Chrome owner; no migration was made.'
    }
    if ([int]$profileOwners[0].ProcessId -ne $sourcePid) {
      throw 'The selected Agent PID does not own the only Chrome process using its Profile; no migration was made.'
    }
    if (-not (Test-CDPProcess -ProcessId $sourcePid -Profile $sourceProfile -Port $sourcePort)) {
      throw 'The selected Agent Profile/PID/CDP tuple is not live and verifiable; no migration was made.'
    }
    if ($ProfilePath -and (Resolve-PathValue $ProfilePath) -ine $sourceProfile) {
      throw 'The requested Browser Host Profile differs from the selected Agent Profile.'
    }
    if ($previous -and (Resolve-PathValue ([string]$previous.profile)) -ine $sourceProfile) {
      throw "A different Browser Host Profile is already registered: $($previous.profile)"
    }
    $adopted = New-HostManifest -ProcessId $sourcePid -Profile $sourceProfile -Port $sourcePort -Previous $previous
    Write-HostManifest $adopted
    $adopted | ConvertTo-Json -Depth 8 -Compress
    exit 0
  }

  if (-not $ProfilePath -and $previous -and $previous.profile) {
    $ProfilePath = [string]$previous.profile
  }
  if (-not $ProfilePath) {
    throw 'No Browser Host Profile is registered. Supply -ProfilePath for an existing signed-in Chrome user-data directory. The manager never creates a new Profile.'
  }
  $ProfilePath = Resolve-PathValue $ProfilePath
  if ($previous -and (Resolve-PathValue ([string]$previous.profile)) -ine $ProfilePath) {
    throw "The requested Profile differs from the registered Browser Host Profile: $($previous.profile)"
  }
  if (-not (Test-ExistingChromeUserDataDir $ProfilePath)) {
    throw "The selected Profile is not an existing Chrome user-data directory with Local State and a saved profile. No Profile was created: $ProfilePath"
  }
  if ($ChromeExecutable) {
    $ChromeExecutable = (Resolve-Path -LiteralPath $ChromeExecutable).Path
  } else {
    $candidates = @(
      (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
      (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
      (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    $ChromeExecutable = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $ChromeExecutable) { throw 'Chrome or Edge was not found. Supply -ChromeExecutable.' }
    $ChromeExecutable = (Resolve-Path -LiteralPath $ChromeExecutable).Path
  }

  $state = Get-HostManifest
  if ($state -and (Test-HostProcess $state $ProfilePath)) {
    $state | ConvertTo-Json -Depth 8 -Compress
    exit 0
  }

  $existingHost = Get-ExistingProfileHost $ProfilePath
  if ($existingHost) {
    Write-HostManifest $existingHost
    $existingHost | ConvertTo-Json -Depth 8 -Compress
    exit 0
  }

  $defaultChromeProfile = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
  if (
    $ChromeExecutable -match '(?i)\\Google\\Chrome\\Application\\chrome\.exe$' -and
    $ProfilePath.TrimEnd('\') -ieq $defaultChromeProfile.TrimEnd('\')
  ) {
    $chromeVersion = [version](Get-Item -LiteralPath $ChromeExecutable).VersionInfo.ProductVersion
    if ($chromeVersion.Major -ge 136) {
      throw "Chrome $($chromeVersion.Major)+ does not expose this CDP mode for the default user-data directory. The manager will not create a replacement Profile. Select an existing CDP-enabled shared Profile or stop here."
    }
  }

  $port = New-FreePort
  $arguments = @(
    "--user-data-dir=`"$ProfilePath`"",
    '--profile-directory=Default',
    "--remote-debugging-port=$port",
    '--remote-debugging-address=127.0.0.1',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-mode',
    '--start-maximized',
    '--new-window',
    $StartUrl
  )
  $started = Start-Process -FilePath $ChromeExecutable -ArgumentList $arguments -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  $hostProcess = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    $candidate = Get-ProfileOwners $ProfilePath | Select-Object -First 1
    if ($candidate -and (Test-CDPProcess -ProcessId ([int]$candidate.ProcessId) -Profile $ProfilePath -Port $port)) {
      $hostProcess = $candidate
      break
    }
    Start-Sleep -Milliseconds 150
  }
  if (-not $hostProcess) {
    throw "Chrome did not expose the expected CDP endpoint for Profile $ProfilePath on port $port."
  }
  if ((Get-CDPPortFromCommandLine $hostProcess.CommandLine) -ne $port) {
    throw 'The Chrome process command line does not match the newly allocated CDP port.'
  }

  $state = New-HostManifest -ProcessId ([int]$hostProcess.ProcessId) -Profile $ProfilePath -Port $port -Previous $previous
  Write-HostManifest $state
  $state | ConvertTo-Json -Depth 8 -Compress
} finally {
  if ($mutexHeld) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
