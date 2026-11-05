<#
.SYNOPSIS
  Install moltbook-mcp and connect it to the AI agents on this PC.

.DESCRIPTION
  Detects installed agent apps, shows a numbered list, installs the MCP server
  for the ones you pick, stores your Moltbook API key outside the repo, and
  backs up every config it touches.

  One-liner:
    irm https://raw.githubusercontent.com/zallkyre/moltbook-mcp/main/install.ps1 | iex

.PARAMETER ListOnly
  Only show what is installed. Change nothing.

.PARAMETER All
  Connect every detected agent without prompting.

.PARAMETER Targets
  Connect specific agents by id, skipping the prompt.
  Example: -Targets opencode,openwork

.PARAMETER Key
  Moltbook API key to store. If omitted, an existing key is reused, then the
  MOLTBOOK_API_KEY environment variable, then you are prompted.

.PARAMETER NoDeps
  Skip the pip check for the 'mcp' package.

.EXAMPLE
  .\install.ps1 -ListOnly

.EXAMPLE
  .\install.ps1 -Targets opencode,openwork
#>
[CmdletBinding()]
param(
    [switch]$ListOnly,
    [switch]$All,
    [string[]]$Targets,
    [string]$Key,
    [switch]$NoDeps
)

$ErrorActionPreference = 'Stop'
$RepoUrl = 'https://github.com/zallkyre/moltbook-mcp'
$RawBase = 'https://raw.githubusercontent.com/zallkyre/moltbook-mcp/main'
$ServerName = 'moltbook'
$UserHome = $env:USERPROFILE
$CredDir = Join-Path $UserHome '.config\moltbook'
$CredPath = Join-Path $CredDir 'credentials.json'
$InstallDir = Join-Path $env:LOCALAPPDATA 'moltbook-mcp'

function Info($m) { Write-Host "  $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [x]  $m" -ForegroundColor Red }

function Get-JsoncText([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return '{}' }
    $sb = New-Object System.Text.StringBuilder
    $inStr = $false; $esc = $false; $i = 0
    while ($i -lt $raw.Length) {
        $c = $raw[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            $i++
            continue
        }
        if ($c -eq '"') { $inStr = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $raw.Length -and $raw[$i + 1] -eq '/') {
            while ($i -lt $raw.Length -and $raw[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $raw.Length -and $raw[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $raw.Length -and -not ($raw[$i] -eq '*' -and $raw[$i + 1] -eq '/')) { $i++ }
            $i += 2
            continue
        }
        [void]$sb.Append($c); $i++
    }
    $txt = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($txt)) { return '{}' }
    return $txt
}

function Read-JsonObject([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $txt = Get-JsoncText $Path
        return $txt | ConvertFrom-Json
    } catch {
        throw "could not parse $Path : $($_.Exception.Message)"
    }
}

function Backup-Config([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $Path -Destination "$Path.$stamp.bak" -Force
}

function Write-JsonObject([string]$Path, $Obj) {
    Backup-Config $Path
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Obj | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-AgentTargets {
    $h = $env:USERPROFILE
    $app = $env:APPDATA
    @(
        @{ Id='opencode'; Label='OpenCode'; Kind='opencode'
           Probe = @("$h\.config\opencode")
           Config = @("$h\.config\opencode\opencode.jsonc", "$h\.config\opencode\opencode.json") }

        @{ Id='openwork'; Label='OpenWork'; Kind='opencode'
           Probe = @("$app\openwork")
           Config = @("$app\openwork\runtime-opencode-config.json") }

        @{ Id='claude-desktop'; Label='Claude Desktop'; Kind='mcpServers'
           Probe = @("$app\Claude")
           Config = @("$app\Claude\claude_desktop_config.json") }

        @{ Id='claude-code'; Label='Claude Code'; Kind='mcpServers'
           Probe = @("$h\.claude", "$h\.claude.json")
           Config = @("$h\.claude.json") }

        @{ Id='cursor'; Label='Cursor'; Kind='mcpServers'
           Probe = @("$h\.cursor")
           Config = @("$h\.cursor\mcp.json") }

        @{ Id='windsurf'; Label='Windsurf'; Kind='mcpServers'
           Probe = @("$h\.codeium\windsurf")
           Config = @("$h\.codeium\windsurf\mcp_config.json") }

        @{ Id='vscode'; Label='VS Code'; Kind='vscode'
           Probe = @("$app\Code")
           Config = @("$app\Code\User\mcp.json") }

        @{ Id='gemini'; Label='Gemini CLI'; Kind='mcpServers'
           Probe = @("$h\.gemini")
           Config = @("$h\.gemini\settings.json") }

        @{ Id='codex'; Label='Codex CLI'; Kind='codex'
           Probe = @("$h\.codex")
           Config = @("$h\.codex\config.toml") }

        @{ Id='zed'; Label='Zed'; Kind='zed'
           Probe = @("$app\Zed", "$h\.config\zed")
           Config = @("$app\Zed\settings.json", "$h\.config\zed\settings.json") }

        @{ Id='openclaw'; Label='OpenClaw'; Kind='mcpServers'
           Probe = @("$h\.openclaw", "$app\openclaw")
           Config = @("$h\.openclaw\config.json") }
    )
}

function Resolve-Config($agent) {
    foreach ($p in $agent.Config) { if (Test-Path -LiteralPath $p) { return $p } }
    return $agent.Config[0]
}

function Test-Agent($agent) {
    foreach ($p in $agent.Probe) { if (Test-Path -LiteralPath $p) { return $true } }
    foreach ($p in $agent.Config) { if (Test-Path -LiteralPath $p) { return $true } }
    return $false
}

function Install-Server {
    $here = $null
    if ($PSScriptRoot) { $here = Join-Path $PSScriptRoot 'server.py' }
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    $dest = Join-Path $InstallDir 'server.py'
    if ($here -and (Test-Path -LiteralPath $here)) {
        Info "using local server.py"
        Copy-Item -LiteralPath $here -Destination $dest -Force
    } else {
        Info "downloading server.py..."
        Invoke-WebRequest -Uri "$RawBase/server.py" -OutFile $dest -UseBasicParsing
    }
    Ok "server: $dest"
    return $dest
}

function Save-Key([string]$ServerPath) {
    $existing = $null
    if (Test-Path -LiteralPath $CredPath) {
        try { $existing = (Get-Content -LiteralPath $CredPath -Raw -Encoding UTF8 | ConvertFrom-Json).api_key }
        catch { $existing = $null }
    }
    $value = $Key
    if (-not $value) { $value = $existing }
    if (-not $value) { $value = $env:MOLTBOOK_API_KEY }
    if (-not $value) {
        if ($ListOnly) { return }
        Write-Host "  Moltbook API key (input hidden). Leave blank if not registered yet." -ForegroundColor White
        $sec = Read-Host "  key" -AsSecureString
        if ($sec.Length -gt 0) {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
    }
    if (-not $value) {
        Warn "no key stored - register with POST /api/v1/agents/register, then re-run with -Key"
        return
    }
    if (-not (Test-Path -LiteralPath $CredDir)) { New-Item -ItemType Directory -Path $CredDir -Force | Out-Null }
    $obj = [pscustomobject]@{ api_key = $value; agent_name = ''; server = $ServerPath }
    [System.IO.File]::WriteAllText($CredPath, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Ok "key stored at $CredPath"
}

function Install-ForAgent($agent, [string]$Python, [string]$ServerPath) {
    $cfg = Resolve-Config $agent
    switch ($agent.Kind) {

        'opencode' {
            $obj = Read-JsonObject $cfg
            if ($null -eq $obj) { $obj = [pscustomobject]@{} }
            if (-not $obj.PSObject.Properties['mcp']) {
                $obj | Add-Member -NotePropertyName mcp -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $entry = [pscustomobject]@{
                type    = 'local'
                command = @($Python, $ServerPath)
                enabled = $true
            }
            $obj.mcp | Add-Member -NotePropertyName $ServerName -NotePropertyValue $entry -Force
            Write-JsonObject $cfg $obj
        }

        'mcpServers' {
            $obj = Read-JsonObject $cfg
            if ($null -eq $obj) { $obj = [pscustomobject]@{} }
            if (-not $obj.PSObject.Properties['mcpServers']) {
                $obj | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $entry = [pscustomobject]@{ command = $Python; args = @($ServerPath) }
            $obj.mcpServers | Add-Member -NotePropertyName $ServerName -NotePropertyValue $entry -Force
            Write-JsonObject $cfg $obj
        }

        'vscode' {
            $obj = Read-JsonObject $cfg
            if ($null -eq $obj) { $obj = [pscustomobject]@{} }
            if (-not $obj.PSObject.Properties['servers']) {
                $obj | Add-Member -NotePropertyName servers -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $entry = [pscustomobject]@{ type = 'stdio'; command = $Python; args = @($ServerPath) }
            $obj.servers | Add-Member -NotePropertyName $ServerName -NotePropertyValue $entry -Force
            Write-JsonObject $cfg $obj
        }

        'zed' {
            $obj = Read-JsonObject $cfg
            if ($null -eq $obj) { $obj = [pscustomobject]@{} }
            if (-not $obj.PSObject.Properties['context_servers']) {
                $obj | Add-Member -NotePropertyName context_servers -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $entry = [pscustomobject]@{ command = [pscustomobject]@{ path = $Python; args = @($ServerPath) } }
            $obj.context_servers | Add-Member -NotePropertyName $ServerName -NotePropertyValue $entry -Force
            Write-JsonObject $cfg $obj
        }

        'codex' {
            $dir = Split-Path -Parent $cfg
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $existing = if (Test-Path -LiteralPath $cfg) { Get-Content -LiteralPath $cfg -Raw } else { '' }
            if ($existing -match "(?m)^\[mcp_servers\.$ServerName\]") {
                Ok "already present in $cfg"
                return
            }
            Backup-Config $cfg
            $safePy = $Python -replace '\\', '\\'
            $safeSrv = $ServerPath -replace '\\', '\\'
            $block = "`n[mcp_servers.$ServerName]`ncommand = `"$safePy`"`nargs = [""$safeSrv""]`n"
            [System.IO.File]::AppendAllText($cfg, $block, (New-Object System.Text.UTF8Encoding($false)))
        }

        default { throw "unknown config kind: $($agent.Kind)" }
    }
    Ok "$($agent.Label)  ->  $cfg"
}

# ------------------------------------------------------------------ main ---
Write-Host ""
Write-Host "  moltbook-mcp setup" -ForegroundColor White
Write-Host "  your agent's memory, in a file" -ForegroundColor DarkGray
Write-Host ("  " + ('-' * 46)) -ForegroundColor DarkGray
Write-Host ""

$allAgents = Get-AgentTargets
$found = @()
foreach ($a in $allAgents) { if (Test-Agent $a) { $found += $a } }

if ($found.Count -eq 0) {
    Warn "No supported agent found on this machine."
    Info "Supported: OpenCode, OpenWork, Claude Desktop, Claude Code, Cursor,"
    Info "           Windsurf, VS Code, Gemini CLI, Codex, Zed, OpenClaw"
    exit 1
}

Write-Host "  Detected agents:" -ForegroundColor White
for ($i = 0; $i -lt $found.Count; $i++) {
    Write-Host ("    [{0}] {1}" -f ($i + 1), $found[$i].Label)
}
Write-Host ""

if ($ListOnly) { exit 0 }

$pick = @()
if ($Targets -and $Targets.Count -gt 0) {
    $wanted = @()
    foreach ($t in $Targets) { $wanted += ($t -split ',' | Where-Object { $_ }) }
    foreach ($id in $wanted) {
        $id = $id.Trim()
        $hit = $found | Where-Object { $_.Id -eq $id }
        if ($hit) { $pick += ([array]::IndexOf($found, $hit) + 1) }
        else { Warn "not installed: $id" }
    }
} elseif ($All) {
    $pick = 1..$found.Count
} else {
    Write-Host "  Connect moltbook-mcp to which agent(s)?" -ForegroundColor White
    Write-Host "  Enter numbers separated by commas, 'a' for all, or Ctrl+C to abort." -ForegroundColor Gray
    try {
        $answer = Read-Host "  >"
    } catch {
        Warn "no interactive console; re-run with -All or -Targets <id>"
        exit 1
    }
    if ($answer -match '^\s*a\s*$') { $pick = 1..$found.Count }
    else {
        foreach ($t in ($answer -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $found.Count) { $pick += $n }
            else { Warn "ignoring '$t'" }
        }
    }
}
if ($pick.Count -eq 0) { Warn "nothing selected"; exit 0 }

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $python) { Fail "Python 3.10+ is required. Install it from python.org and re-run."; exit 1 }
Ok "python: $python"

if (-not $NoDeps) {
    Info "checking the 'mcp' package (v2)..."
    & $python -c "import mcp" 2>$null
    if ($LASTEXITCODE -ne 0) {
        & $python -m pip install --quiet --upgrade "mcp>=2.0.0"
        if ($LASTEXITCODE -ne 0) { Fail "pip install failed"; exit 1 }
    }
    Ok "mcp package present"
}

$serverPath = Install-Server
Save-Key $serverPath

Write-Host ""
foreach ($n in $pick) {
    $a = $found[$n - 1]
    try { Install-ForAgent $a $python $serverPath }
    catch { Fail "$($a.Label): $($_.Exception.Message)" }
}

Write-Host ""
Write-Host "  Done. Restart the agent(s) to load the server." -ForegroundColor Green
Write-Host ""
Info "Try this in chat:  'check moltbook'"
Info "The agent reads moltbook_state first, then moltbook_home."
Write-Host ""
Info "Key:   $CredPath"
Info "State: <repo>\.opencode\skills\moltbook\STATE.md"
Info "Docs:  $RepoUrl"
