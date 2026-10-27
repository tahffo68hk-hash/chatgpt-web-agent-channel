[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^ag-[a-z0-9][a-z0-9-]{7,80}$')]
  [string]$AgentId,

  [string]$Root = (Join-Path $env:USERPROFILE '.chatgpt-web-mcp'),
  [string]$BrowserHostRoot,
  [string]$BrowserHostProfile
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$rootPath = [System.IO.Path]::GetFullPath($Root)
$agentRoot = Join-Path $rootPath "agents\$AgentId"
$instancePath = Join-Path $agentRoot 'instance.json'
if (-not (Test-Path -LiteralPath $instancePath -PathType Leaf)) {
  throw "No existing Agent instance was found: $instancePath"
}
$instance = Get-Content -Raw -LiteralPath $instancePath | ConvertFrom-Json
if ($instance.agent_id -ne $AgentId) { throw 'Selected instance.json contains a different AGENT_ID.' }

$launchScript = [System.IO.Path]::GetFullPath([string]$instance.launch_script)
$liveLaunchers = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
  $_.Name -match '^(node|node\.exe)$' -and
  $_.CommandLine -and
  $_.CommandLine.IndexOf($launchScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
if ($liveLaunchers.Count -gt 0) {
  throw "The selected Agent MCP appears to be running (PID $($liveLaunchers[0].ProcessId)). Disconnect this Agent normally, then rerun migration; the script will not stop it."
}

$bindingPath = [System.IO.Path]::GetFullPath([string]$instance.binding_file)
if (-not (Test-Path -LiteralPath $bindingPath -PathType Leaf)) { throw "Agent binding file is missing: $bindingPath" }
$binding = Get-Content -Raw -LiteralPath $bindingPath | ConvertFrom-Json
if ($binding.agent_id -ne $AgentId -or -not $binding.conversation_id -or -not $binding.conversation_url) {
  throw 'The selected Agent must have a valid persistent conversation binding before migration.'
}
$parsedUrl = $null
if (-not [Uri]::TryCreate([string]$binding.conversation_url, [UriKind]::Absolute, [ref]$parsedUrl)) {
  throw 'The selected Agent conversation_url is invalid.'
}
$urlParts = @($parsedUrl.AbsolutePath.Trim('/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))
if ($parsedUrl.Host -ne 'chatgpt.com' -or $urlParts.Count -ne 2 -or $urlParts[0] -ne 'c' -or $urlParts[1] -ne [string]$binding.conversation_id) {
  throw 'The selected Agent conversation URL does not match its conversation_id.'
}
if (($instance.conversation_id -and $instance.conversation_id -ne $binding.conversation_id) -or
    ($instance.conversation_url -and $instance.conversation_url -ne $binding.conversation_url)) {
  throw 'The selected instance route differs from its binding file.'
}

$bindingsRoot = Split-Path -Parent $bindingPath
Get-ChildItem -LiteralPath $bindingsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_.FullName -ine $bindingPath) {
    $other = Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
    if ($other.conversation_id -eq $binding.conversation_id -and $other.agent_id -ne $AgentId) {
      throw "Conversation $($binding.conversation_id) is already bound to Agent $($other.agent_id)."
    }
  }
}

$sourceRoot = [System.IO.Path]::GetFullPath([string]$instance.shared_source_dir)
$packagePath = Join-Path $sourceRoot 'package.json'
$sourceNodeModules = Join-Path $sourceRoot 'node_modules'
if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf) -or -not (Test-Path -LiteralPath $sourceNodeModules -PathType Container)) {
  throw 'The selected instance source checkout or its existing dependencies are unavailable.'
}
$package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
$runtimeMetadata = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'templates\runtime-template.json') | ConvertFrom-Json
if ($package.version -ne $runtimeMetadata.upstream_version) {
  throw "Runtime overlay expects upstream $($runtimeMetadata.upstream_version), but the selected source is $($package.version)."
}
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git -and (Test-Path -LiteralPath (Join-Path $sourceRoot '.git'))) {
  $commit = (& $git.Source -C $sourceRoot rev-parse HEAD 2>$null | Out-String).Trim()
  if ($LASTEXITCODE -eq 0 -and $commit -ne $runtimeMetadata.upstream_commit) {
    throw "Runtime overlay expects commit $($runtimeMetadata.upstream_commit), but the selected source is $commit."
  }
}

$hostRootPath = [System.IO.Path]::GetFullPath(
  $(if ($BrowserHostRoot) { $BrowserHostRoot } else { Join-Path $rootPath 'browser-host' })
)
$hostManifestPath = Join-Path $hostRootPath 'host.json'
$hostManagerPath = Join-Path $hostRootPath 'browser-host.ps1'
$hostManagerSource = Join-Path $skillRoot 'scripts\browser-host.ps1'
$profileWasProvided = -not [string]::IsNullOrWhiteSpace($BrowserHostProfile)
$requestedProfile = if ($profileWasProvided) { [System.IO.Path]::GetFullPath($BrowserHostProfile) } else { $null }
if (-not (Test-Path -LiteralPath $hostManagerSource -PathType Leaf)) { throw "Bundled Browser Host manager is missing: $hostManagerSource" }
if (-not $PSCmdlet.ShouldProcess("Agent $AgentId joining Browser Host at $hostRootPath", 'Connect and migrate to the existing signed-in browser')) {
  return
}

if (Test-Path -LiteralPath $hostManagerPath -PathType Leaf) {
  if ((Get-FileHash -LiteralPath $hostManagerPath -Algorithm SHA256).Hash -ne
      (Get-FileHash -LiteralPath $hostManagerSource -Algorithm SHA256).Hash) {
    throw "A different Browser Host manager already exists at $hostManagerPath. Review and upgrade it explicitly first."
  }
} else {
  $null = New-Item -ItemType Directory -Path $hostRootPath -Force
  $temporaryManagerPath = "$hostManagerPath.$PID.tmp"
  Copy-Item -LiteralPath $hostManagerSource -Destination $temporaryManagerPath
  try {
    [System.IO.File]::Move($temporaryManagerPath, $hostManagerPath)
  } catch {
    if (-not (Test-Path -LiteralPath $hostManagerPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $hostManagerPath -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $hostManagerSource -Algorithm SHA256).Hash) {
      throw
    }
  } finally {
    if (Test-Path -LiteralPath $temporaryManagerPath) { Remove-Item -LiteralPath $temporaryManagerPath -Force -ErrorAction SilentlyContinue }
  }
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $hostManifestPath -PathType Leaf) {
  $hostOutput = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hostManagerPath -Action Status -HostRoot $hostRootPath 2>&1
} else {
  if (-not $profileWasProvided) {
    throw "No shared Browser Host exists at $hostRootPath. Supply -BrowserHostProfile with the existing signed-in Chrome user-data directory; this migration never creates a new Profile."
  }
  $hostOutput = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hostManagerPath `
    -Action Ensure -HostRoot $hostRootPath -ProfilePath $requestedProfile -ChromeExecutable ([string]$instance.chrome_executable) 2>&1
}
if ($LASTEXITCODE -ne 0) { throw "The selected shared Browser Host could not be verified. No Agent files were changed. $($hostOutput -join [Environment]::NewLine)" }
$hostInfo = ($hostOutput -join [Environment]::NewLine) | ConvertFrom-Json
$profilePath = [System.IO.Path]::GetFullPath([string]$hostInfo.profile)
if ($profileWasProvided -and $profilePath.TrimEnd('\') -ine $requestedProfile.TrimEnd('\')) {
  throw 'The verified Browser Host Profile differs from -BrowserHostProfile. No Agent files were changed.'
}

$runtimeSource = Join-Path $skillRoot 'templates\runtime-src'
$runtimeTargetRoot = Join-Path $agentRoot 'runtime'
if (-not (Test-Path -LiteralPath $runtimeTargetRoot -PathType Container)) { throw "Runtime folder is missing: $runtimeTargetRoot" }
foreach ($name in @('index.js', 'browser.js', 'config.js', 'agent-policy.js', 'browser-host.js')) {
  if (-not (Test-Path -LiteralPath (Join-Path $runtimeSource $name) -PathType Leaf)) { throw "Bundled runtime is missing $name." }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backupRoot = Join-Path (Join-Path $rootPath 'archives') "$AgentId-shared-host-migration-$timestamp"
$runtimeTarget = Join-Path $runtimeTargetRoot "shared-host-runtime-$timestamp"
if (Test-Path -LiteralPath $backupRoot) { throw "Backup path already exists: $backupRoot" }
if (Test-Path -LiteralPath $runtimeTarget) { throw "Runtime target already exists: $runtimeTarget" }
$null = New-Item -ItemType Directory -Path $backupRoot -Force
Copy-Item -LiteralPath $instancePath -Destination (Join-Path $backupRoot 'instance.json')
Copy-Item -LiteralPath $bindingPath -Destination (Join-Path $backupRoot 'binding.json')
Copy-Item -LiteralPath (Join-Path $runtimeTargetRoot 'src') -Destination (Join-Path $backupRoot 'runtime-src') -Recurse

$null = New-Item -ItemType Directory -Path $runtimeTarget -Force
Get-ChildItem -LiteralPath $runtimeSource -Force | Copy-Item -Destination $runtimeTarget -Recurse
$instance.runtime_source_dir = $runtimeTarget
$instance.browser_host_root = $hostRootPath
$instance.browser_host_manifest = $hostManifestPath
$instance.browser_host_manager_script = $hostManagerPath
$instance.browser_host_id = $hostInfo.host_id
$instance.browser_profile = $profilePath
$instance.browser_state_file = $hostManifestPath
$instance.browser_operation_lock_dir = Join-Path $hostRootPath 'locks'
$instance.send_scheduler_file = Join-Path $hostRootPath 'send-scheduler.json'
$instance.network_log_file = Join-Path ([string]$instance.log_dir) 'network-diagnostics.jsonl'
$instance.context_archive_dir = Join-Path ([string]$instance.state_dir) 'conversation-context'
$instance.cdp_port = [int]$hostInfo.port
$binding.browser_host_id = $hostInfo.host_id
$binding.browser_profile = $profilePath
$binding.cdp_port = [int]$hostInfo.port

function Write-AtomicJson([string]$Path, $Value) {
  $temporaryPath = "$Path.$PID.tmp"
  $backupPath = "$Path.$PID.bak"
  $json = $Value | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
  if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
}

Write-AtomicJson $instancePath $instance
Write-AtomicJson $bindingPath $binding
Copy-Item -LiteralPath (Join-Path $skillRoot 'templates\launcher.mjs') -Destination "$($instance.launch_script).$PID.tmp"
[System.IO.File]::Replace("$($instance.launch_script).$PID.tmp", $instance.launch_script, "$($instance.launch_script).$PID.bak")
if (Test-Path -LiteralPath "$($instance.launch_script).$PID.bak") { Remove-Item -LiteralPath "$($instance.launch_script).$PID.bak" -Force -ErrorAction SilentlyContinue }
Copy-Item -LiteralPath (Join-Path $skillRoot 'templates\agent-call.mjs') -Destination (Join-Path $agentRoot "agent-call.mjs.$PID.tmp")
[System.IO.File]::Replace((Join-Path $agentRoot "agent-call.mjs.$PID.tmp"), (Join-Path $agentRoot 'agent-call.mjs'), (Join-Path $agentRoot "agent-call.mjs.$PID.bak"))
if (Test-Path -LiteralPath (Join-Path $agentRoot "agent-call.mjs.$PID.bak")) { Remove-Item -LiteralPath (Join-Path $agentRoot "agent-call.mjs.$PID.bak") -Force -ErrorAction SilentlyContinue }

[pscustomobject]@{
  AgentId = $AgentId
  Server = $instance.mcp_server_name
  BrowserHostId = $hostInfo.host_id
  BrowserHostRoot = $hostRootPath
  BrowserProfile = $profilePath
  CdpPort = [int]$hostInfo.port
  ConversationId = $binding.conversation_id
  ConversationUrl = $binding.conversation_url
  Backup = $backupRoot
  NextStep = 'Restart this Agent MCP to attach to the existing signed-in Browser Host. Its conversation binding is unchanged.'
}
