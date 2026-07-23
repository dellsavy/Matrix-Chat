$port = 9999
$myNick = "Dale"
$filesDir = Join-Path $PSScriptRoot "ReceivedFiles"
$maxFileSize = 15MB
$chunkSize = 65535 # 64KB-ish, must be a multiple of 3 so base64 chunks concatenate cleanly
$notifySoundPath = "C:\Users\space\Desktop\Matrix Chat\ReceivedFiles\Windows Proximity Notification.wav"

# --- Color scheme: true black background, amber for what you send, green for what you receive ---
try { $Host.UI.RawUI.BackgroundColor = "Black" } catch { }
$ansiEsc = [char]27
$colorSenderText = "$ansiEsc[38;2;255;176;0m"   # #FFB000 Phosphor Amber
$colorReceiverText = "$ansiEsc[38;2;0;255;102m" # #00FF66 Classic Terminal Green
$colorReset = "$ansiEsc[0m"

function Write-SenderLine {
    param([string]$text)
    Write-Host "$colorSenderText$text$colorReset"
}

function Write-ReceiverLine {
    param([string]$text)
    Write-Host "$colorReceiverText$text$colorReset"
}


# --- Auto-update config ---
$scriptVersion = "2.9.0"
$versionCheckUrl = "https://raw.githubusercontent.com/dellsavy/Matrix-Chat/refs/heads/main/version.txt"
$scriptDownloadUrl = "https://raw.githubusercontent.com/dellsavy/Matrix-Chat/refs/heads/main/server.ps1"
$repoUrl = "https://github.com/dellsavy/Matrix-Chat"
$updateNoticePath = Join-Path $env:TEMP "matrixchat_update_notice_server.txt"

# --- Gemini AI config ---
# Key lives in a local, untracked file - NEVER commit this or paste it in the repo.
$geminiKeyPath = Join-Path $PSScriptRoot "gemini_key.txt"
$geminiModel = "gemini-flash-latest"

# --- Recent update history, shown with /updates ---
$recentUpdates = @(
    "v2.9.0 - Added /drop drag-and-drop file sending, /update command, amber/green color scheme",
    "v2.7.1 - Fixed 404 error, switched to gemini-flash-latest",
    "v2.7.0 - Added chat-history context to /ai",
    "v2.6.0 - Added /ai command to ask Gemini AI",
    "v2.5.1 - Fixed update banner disappearing too fast",
    "v2.5.0 - Added /playmusic, /pause, /stop for shared music",
    "v2.4.0 - Added /tray command to minimize to system tray",
    "v2.3.0 - Auto-open received images, videos, and audio"
)

Add-Type -Name Win32 -Namespace ConsoleUtils -MemberDefinition @"
[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll")]
public static extern int GetWindowTextLength(IntPtr hWnd);
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
"@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$myWindowTitle = "MatrixChat-Dale-$PID"
$Host.UI.RawUI.WindowTitle = $myWindowTitle

function Test-IsWindowFocused {
    $hwnd = [ConsoleUtils.Win32]::GetForegroundWindow()
    $len = [ConsoleUtils.Win32]::GetWindowTextLength($hwnd)
    if ($len -eq 0) { return $false }
    $sb = New-Object System.Text.StringBuilder ($len + 1)
    [ConsoleUtils.Win32]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    return $sb.ToString() -eq $myWindowTitle
}

# --- System tray support ---
$global:trayIcon = New-Object System.Windows.Forms.NotifyIcon
$global:trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().Path)
$global:trayIcon.Text = "Matrix Chat - $myNick"
$global:trayIcon.Visible = $false

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuShow = $trayMenu.Items.Add("Show Matrix Chat")
$menuExit = $trayMenu.Items.Add("Exit")
$global:trayIcon.ContextMenuStrip = $trayMenu

$global:trayIcon.add_DoubleClick({ Restore-Console })
$menuShow.add_Click({ Restore-Console })
$menuExit.add_Click({
    $global:trayIcon.Visible = $false
    $global:trayIcon.Dispose()
    Stop-Process -Id $PID
})

function Hide-ToTray {
    $hwnd = [ConsoleUtils.Win32]::GetConsoleWindow()
    [ConsoleUtils.Win32]::ShowWindow($hwnd, 0) | Out-Null   # SW_HIDE
    $global:trayIcon.Visible = $true
    $global:trayIcon.ShowBalloonTip(1500, "Matrix Chat", "Still running - double-click the tray icon to reopen.", [System.Windows.Forms.ToolTipIcon]::Info)
}

function Restore-Console {
    $hwnd = [ConsoleUtils.Win32]::GetConsoleWindow()
    [ConsoleUtils.Win32]::ShowWindow($hwnd, 5) | Out-Null   # SW_SHOW
    [ConsoleUtils.Win32]::SetForegroundWindow($hwnd) | Out-Null
    $global:trayIcon.Visible = $false
}

# --- Drag-and-drop file sending ---
$global:dropForm = New-Object System.Windows.Forms.Form
$global:dropForm.Text = "Drop file to send"
$global:dropForm.Size = New-Object System.Drawing.Size(220, 100)
$global:dropForm.TopMost = $true
$global:dropForm.AllowDrop = $true
$global:dropForm.StartPosition = "Manual"
$global:dropForm.Location = New-Object System.Drawing.Point(20, 20)

$dropLabel = New-Object System.Windows.Forms.Label
$dropLabel.Text = "Drag a file here to send it"
$dropLabel.Dock = "Fill"
$dropLabel.TextAlign = "MiddleCenter"
$global:dropForm.Controls.Add($dropLabel)

$global:dropForm.add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [Windows.Forms.DragDropEffects]::Copy
    }
})

$global:dropForm.add_DragDrop({
    param($sender, $e)
    $droppedFiles = $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    foreach ($f in $droppedFiles) {
        if ((Test-Path $f -PathType Leaf) -and $global:writer) {
            write-host "* Dropped file detected, sending: $f *" -ForegroundColor Cyan
            Send-FileChunked $global:writer $f
        }
    }
})

function Play-Notify {
    if (Test-IsWindowFocused) { return }
    if ($notifySoundPath -ne "" -and (Test-Path $notifySoundPath)) {
        try {
            $player = New-Object System.Media.SoundPlayer($notifySoundPath)
            $player.Play()
        } catch {
            [System.Media.SystemSounds]::Asterisk.Play()
        }
    } else {
        [System.Media.SystemSounds]::Asterisk.Play()
    }
}

# Extensions that auto-open on receive - images, video, audio only.
# Anything else (zip, exe, docx, etc.) is left alone for safety/sanity.
$autoOpenExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", `
                        ".mp4", ".mov", ".mkv", ".avi", ".webm", `
                        ".mp3", ".wav", ".flac", ".ogg", ".m4a")

function Open-IfMedia {
    param([string]$path)
    try {
        $ext = [IO.Path]::GetExtension($path).ToLower()
        if ($autoOpenExtensions -contains $ext) {
            Start-Process -FilePath $path
        }
    } catch {
        write-host "* Couldn't auto-open '$path': $($_.Exception.Message) *" -ForegroundColor DarkYellow
    }
}

function Ask-Gemini {
    param([string]$question)
    if (-not (Test-Path $geminiKeyPath)) {
        write-host "* No Gemini API key set up. Create a file named 'gemini_key.txt' next to this script containing just your key. *" -ForegroundColor Red
        return $null
    }
    $key = (Get-Content $geminiKeyPath -Raw).Trim()
    if (-not $key) {
        write-host "* gemini_key.txt is empty. Paste your API key inside it (no quotes). *" -ForegroundColor Red
        return $null
    }
    try {
        $bodyObj = @{ contents = @(@{ parts = @(@{ text = $question }) }) }
        $body = $bodyObj | ConvertTo-Json -Depth 6
        $uri = "https://generativelanguage.googleapis.com/v1beta/models/$geminiModel`:generateContent"
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers @{ "x-goog-api-key" = $key; "Content-Type" = "application/json" } -Body $body -TimeoutSec 30
        return $resp.candidates[0].content.parts[0].text
    } catch {
        write-host "* AI request failed: $($_.Exception.Message) *" -ForegroundColor Red
        return $null
    }
}

# --- Shared music playback ---
Add-Type -AssemblyName PresentationCore
$audioExtensions = @(".mp3", ".wav", ".flac", ".ogg", ".m4a", ".wma")
$global:musicPlayer = New-Object System.Windows.Media.MediaPlayer

function Start-MusicLocal {
    param([string]$path)
    try {
        $global:musicPlayer.Open([Uri]::new($path))
        $global:musicPlayer.Play()
        write-host "* Now playing: $([IO.Path]::GetFileName($path)) *" -ForegroundColor Cyan
    } catch {
        write-host "* Couldn't play '$path': $($_.Exception.Message) *" -ForegroundColor Red
    }
}

function Pause-MusicLocal {
    try { $global:musicPlayer.Pause() } catch { }
}

function Stop-MusicLocal {
    try { $global:musicPlayer.Stop() } catch { }
}

# --- Rolling chat history, used as context for /ai ---
$global:chatHistory = New-Object System.Collections.Generic.List[string]
$chatHistoryMax = 30

function Add-ChatHistory {
    param([string]$line)
    $global:chatHistory.Add($line)
    while ($global:chatHistory.Count -gt $chatHistoryMax) {
        $global:chatHistory.RemoveAt(0)
    }
}


function Auto-Update {
    try {
        $remote = Invoke-RestMethod -Uri $versionCheckUrl -TimeoutSec 5
        $line = ($remote -split "`n")[0].Trim()
        $parts = $line -split '\|', 2
        $remoteVersion = $parts[0].Trim()
        $note = if ($parts.Length -gt 1) { $parts[1].Trim() } else { "" }

        if (-not $remoteVersion -or $remoteVersion -eq $scriptVersion) { return $false }

        write-host "==================================================" -ForegroundColor Magenta
        write-host "  UPDATE FOUND: v$remoteVersion (you're on v$scriptVersion)" -ForegroundColor Magenta
        if ($note) { write-host "  Changes: $note" -ForegroundColor Magenta }
        write-host "  Downloading update..." -ForegroundColor Magenta
        write-host "==================================================" -ForegroundColor Magenta

        $newCode = Invoke-RestMethod -Uri $scriptDownloadUrl -TimeoutSec 10
        if (-not $newCode -or $newCode.Length -lt 100) {
            write-host "* Update download looked empty/broken, skipping. *" -ForegroundColor Red
            return $false
        }

        $selfPath = $PSCommandPath
        $backupPath = "$selfPath.bak"
        Copy-Item -Path $selfPath -Destination $backupPath -Force
        Set-Content -Path $selfPath -Value $newCode -Encoding UTF8
        Set-Content -Path $updateNoticePath -Value "$remoteVersion|$note" -Encoding UTF8

        write-host "* Updated to v$remoteVersion. Restarting... *" -ForegroundColor Green
        Start-Sleep -Seconds 1

        Start-Process powershell -ArgumentList "-NoExit", "-File", "`"$selfPath`""
        return $true
    } catch {
        write-host "* Update check failed, continuing on current version. *" -ForegroundColor DarkYellow
        return $false
    }
}

$global:pendingUpdateNotice = $null
function Consume-UpdateNoticeIfAny {
    if (Test-Path $updateNoticePath) {
        $content = (Get-Content $updateNoticePath -Raw).Trim()
        $global:pendingUpdateNotice = $content
        Remove-Item $updateNoticePath -Force -ErrorAction SilentlyContinue
    }
}

function Print-UpdateNoticeIfAny {
    if ($global:pendingUpdateNotice) {
        $parts = $global:pendingUpdateNotice -split '\|', 2
        $v = $parts[0].Trim()
        $note = if ($parts.Length -gt 1) { $parts[1].Trim() } else { "" }
        write-host "==================================================" -ForegroundColor Magenta
        write-host "  UPDATED TO v$v" -ForegroundColor Magenta
        if ($note) { write-host "  Changes: $note" -ForegroundColor Magenta }
        write-host "==================================================" -ForegroundColor Magenta
        write-host ""
        $global:pendingUpdateNotice = $null
    }
}

Clear-Host
write-host "==================================================" -ForegroundColor Cyan
write-host "=== WAITING FOR XORE TO CONNECT ON PORT $port ===" -ForegroundColor Cyan
write-host "==================================================" -ForegroundColor Cyan
if (Auto-Update) { exit }
Consume-UpdateNoticeIfAny
Print-UpdateNoticeIfAny

function Get-Timestamp { (Get-Date).ToString("HH:mm") }
function Get-Prefix { "[$myNick]: " }

function Clear-CurrentLine {
    $width = $Host.UI.RawUI.BufferSize.Width
    write-host ("`r" + (" " * ($width - 1)) + "`r") -NoNewline
}

function Redraw-InputLine {
    param($text, $statusText)
    $width = $Host.UI.RawUI.BufferSize.Width
    $prefix = Get-Prefix
    $suffix = ""
    if ($statusText) { $suffix = "  ($statusText)" }
    $maxInputLen = [Math]::Max(0, $width - $prefix.Length - $suffix.Length - 1)
    $displayText = $text
    if ($displayText.Length -gt $maxInputLen) {
        $displayText = $displayText.Substring($displayText.Length - $maxInputLen)
    }
    Clear-CurrentLine
    write-host "$prefix$displayText$suffix" -NoNewline
}

function Write-ProgressLine {
    param($label, $pct)
    $width = $Host.UI.RawUI.BufferSize.Width
    $barWidth = 20
    $filled = [Math]::Floor($barWidth * $pct / 100.0)
    $bar = ("#" * $filled) + ("-" * ($barWidth - $filled))
    $text = "$label [$bar] $pct%"
    if ($text.Length -gt ($width - 1)) { $text = $text.Substring(0, $width - 1) }
    write-host ("`r" + $text.PadRight($width - 1)) -NoNewline -ForegroundColor DarkGray
}

function Show-Help {
    write-host ""
    write-host "Commands:" -ForegroundColor DarkGray
    write-host "  /nick <name>     - change your display name" -ForegroundColor DarkGray
    write-host "  /shout <msg>     - send a loud message" -ForegroundColor DarkGray
    write-host "  /sendfile <path> - send a file (under 15MB)" -ForegroundColor DarkGray
    write-host "  /playmusic <path>- play a song for both of you (send it first)" -ForegroundColor DarkGray
    write-host "  /pause           - pause the shared music" -ForegroundColor DarkGray
    write-host "  /stop            - stop the shared music" -ForegroundColor DarkGray
    write-host "  /ai <question>   - ask Gemini AI, both of you see the answer" -ForegroundColor DarkGray
    write-host "  /updates         - show recent update history" -ForegroundColor DarkGray
    write-host "  /update          - show only the latest update" -ForegroundColor DarkGray
    write-host "  /drop            - open a window to drag-and-drop a file to send" -ForegroundColor DarkGray
    write-host "  /clear           - clear your screen" -ForegroundColor DarkGray
    write-host "  /tray            - minimize to system tray" -ForegroundColor DarkGray
    write-host "  /help            - show this list" -ForegroundColor DarkGray
    write-host "  exit             - quit chat" -ForegroundColor DarkGray
    write-host ""
}

function Send-FileChunked {
    param($writer, $path)
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt $maxFileSize) {
        write-host "* File too large (max 15MB) *" -ForegroundColor Red
        return
    }
    $fname = [IO.Path]::GetFileName($path)
    $totalChunks = [Math]::Ceiling($bytes.Length / [double]$chunkSize)
    $writer.WriteLine("FILESTART|$fname|$totalChunks")

    write-host "Sending $fname..."
    $lastShownPct = -1

    for ($i = 0; $i -lt $totalChunks; $i++) {
        $offset = $i * $chunkSize
        $len = [Math]::Min($chunkSize, $bytes.Length - $offset)
        $chunkBytes = New-Object byte[] $len
        [Array]::Copy($bytes, $offset, $chunkBytes, 0, $len)
        $b64 = [Convert]::ToBase64String($chunkBytes)
        $writer.WriteLine("FILECHUNK|$i|$b64")
        $pct = [Math]::Floor((($i + 1) / [double]$totalChunks) * 100)
        if ($pct -ne $lastShownPct) {
            try { Write-ProgressLine "Sending $fname" $pct } catch { }
            $lastShownPct = $pct
        }
    }
    $writer.WriteLine("FILEEND|$fname")
    write-host ""
    write-host "* File sent: $fname *" -ForegroundColor Green
}

try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
    $listener.Start()

    $client = $listener.AcceptTcpClient()
    $stream = $client.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $writer.AutoFlush = $true
    $global:writer = $writer
    $reader = [System.IO.StreamReader]::new($stream)

    Clear-Host
    write-host "==================================================" -ForegroundColor Green
    write-host "===       XORE CONNECTED! CHAT ACTIVE          ===" -ForegroundColor Green
    write-host "==================================================" -ForegroundColor Green
    write-host "Start typing! Type /help to see commands.`n"
    Print-UpdateNoticeIfAny

    $currentInput = ""
    $typingActive = $false
    $statusText = $null
    Redraw-InputLine $currentInput $statusText

    # File receive state
    $recvFileName = $null
    $recvTotalChunks = 0
    $recvChunkCount = 0
    $recvSB = $null
    $recvLastShownPct = -1

    while ($client.Connected) {

        [System.Windows.Forms.Application]::DoEvents()

        # Branch A: Poll Incoming Network Packets
        if ($stream.DataAvailable) {
            $line = $reader.ReadLine()
            if ($line -ne $null) {
                $parts = $line -split '\|', 4
                $type = $parts[0]

                if ($type -eq "FILESTART") {
                    Clear-CurrentLine
                    $recvFileName = $parts[1]
                    $recvTotalChunks = [int]$parts[2]
                    $recvChunkCount = 0
                    $recvSB = New-Object System.Text.StringBuilder
                    $recvLastShownPct = -1
                    write-host "Receiving $recvFileName..."
                } elseif ($type -eq "FILECHUNK") {
                    if ($recvSB -ne $null) {
                        $recvSB.Append($parts[2]) | Out-Null
                        $recvChunkCount++
                        $pct = [Math]::Floor(($recvChunkCount / [double]$recvTotalChunks) * 100)
                        if ($pct -ne $recvLastShownPct) {
                            try { Write-ProgressLine "Receiving $recvFileName" $pct } catch { }
                            $recvLastShownPct = $pct
                        }
                    }
                } elseif ($type -eq "FILEEND") {
                    if ($recvSB -ne $null) {
                        write-host ""
                        try {
                            if (!(Test-Path $filesDir)) { New-Item -ItemType Directory -Path $filesDir | Out-Null }
                            $allBytes = [Convert]::FromBase64String($recvSB.ToString())
                            $savePath = Join-Path $filesDir $recvFileName
                            [IO.File]::WriteAllBytes($savePath, $allBytes)
                            Play-Notify
                            write-host "* Received file '$recvFileName' -> saved to $savePath *" -ForegroundColor Green
                            Open-IfMedia $savePath
                        } catch {
                            write-host "* Failed to save file: $($_.Exception.Message) *" -ForegroundColor Red
                        }
                        $recvFileName = $null; $recvSB = $null
                    }
                    $statusText = $null
                    Redraw-InputLine $currentInput $statusText
                } elseif ($type -eq "MUSIC") {
                    Clear-CurrentLine
                    $action = $parts[1]
                    if ($action -eq "PLAY") {
                        $fname = $parts[2]
                        $localPath = Join-Path $filesDir $fname
                        if (Test-Path $localPath -PathType Leaf) {
                            Start-MusicLocal $localPath
                            write-host "* Xore started playing '$fname' *" -ForegroundColor Cyan
                        } else {
                            write-host "* Xore wants to play '$fname' but you don't have it - ask them to /sendfile it first *" -ForegroundColor Red
                        }
                    } elseif ($action -eq "PAUSE") {
                        Pause-MusicLocal
                        write-host "* Music paused (by Xore) *" -ForegroundColor Cyan
                    } elseif ($action -eq "STOP") {
                        Stop-MusicLocal
                        write-host "* Music stopped (by Xore) *" -ForegroundColor Cyan
                    }
                    $statusText = $null
                    Redraw-InputLine $currentInput $statusText
                } elseif ($type -eq "AI") {
                    Clear-CurrentLine
                    try {
                        $q = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
                        $a = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[2]))
                        write-host "[Gemini] Xore asked: $q" -ForegroundColor DarkYellow
                        write-host $a -ForegroundColor Yellow
                        Add-ChatHistory "[Xore asked Gemini]: $q"
                        Add-ChatHistory "[Gemini]: $a"
                    } catch {
                        write-host "* Couldn't read AI message *" -ForegroundColor Red
                    }
                    $statusText = $null
                    Redraw-InputLine $currentInput $statusText
                } else {
                    Clear-CurrentLine
                    switch ($type) {
                        "MSG" {
                            $ts = $parts[1]; $nick = $parts[2]; $text = $parts[3]
                            if ($text.StartsWith("SHOUT:")) {
                                Play-Notify
                                write-host "[$ts] [$nick]: $($text.Substring(6).ToUpper())" -ForegroundColor Red
                                Add-ChatHistory "[$nick]: $($text.Substring(6))"
                            } else {
                                Play-Notify
                                Write-ReceiverLine "[$ts] [$nick]: $text"
                                Add-ChatHistory "[$nick]: $text"
                            }
                            $statusText = $null
                        }
                        "TYPING" {
                            $nick = $parts[1]; $state = $parts[2]
                            if ($state -eq "1") { $statusText = "$nick is typing..." } else { $statusText = $null }
                        }
                        "SYS" {
                            write-host "* $($parts[1]) *" -ForegroundColor DarkYellow
                            $statusText = $null
                        }
                    }
                    Redraw-InputLine $currentInput $statusText
                }
            }
        }

        # Branch B: Poll Keyboard State
        if ([System.Console]::KeyAvailable) {
            $keyInfo = [System.Console]::ReadKey($true)

            if ($keyInfo.Key -eq [System.ConsoleKey]::Enter) {
                if ($currentInput -eq "exit") { break }

                if ($currentInput -ne "") {
                    if ($typingActive) { $writer.WriteLine("TYPING|$myNick|0"); $typingActive = $false }

                    Clear-CurrentLine

                    if ($currentInput.StartsWith("/nick ")) {
                        $newNick = $currentInput.Substring(6).Trim()
                        if ($newNick -ne "") {
                            $old = $myNick
                            $myNick = $newNick
                            $writer.WriteLine("SYS|$old changed their name to $myNick")
                            write-host "* You changed your name to $myNick *" -ForegroundColor DarkYellow
                        }
                    } elseif ($currentInput.StartsWith("/shout ")) {
                        $text = $currentInput.Substring(7)
                        $writer.WriteLine("MSG|$(Get-Timestamp)|$myNick|SHOUT:$text")
                        write-host "[$(Get-Timestamp)] [$myNick]: $($text.ToUpper())" -ForegroundColor Red
                        Add-ChatHistory "[$myNick]: $text"
                    } elseif ($currentInput.StartsWith("/sendfile ")) {
                        $path = $currentInput.Substring(10).Trim().Trim('"')
                        if (Test-Path $path -PathType Leaf) {
                            Send-FileChunked $writer $path
                        } else {
                            write-host "* File not found: $path *" -ForegroundColor Red
                        }
                    } elseif ($currentInput.StartsWith("/playmusic ")) {
                        $path = $currentInput.Substring(11).Trim().Trim('"')
                        $ext = [IO.Path]::GetExtension($path).ToLower()
                        if (-not (Test-Path $path -PathType Leaf)) {
                            write-host "* File not found: $path *" -ForegroundColor Red
                        } elseif ($audioExtensions -notcontains $ext) {
                            write-host "* Not a supported audio file (mp3/wav/flac/ogg/m4a/wma) *" -ForegroundColor Red
                        } else {
                            $fname = [IO.Path]::GetFileName($path)
                            Start-MusicLocal $path
                            $writer.WriteLine("MUSIC|PLAY|$fname")
                            write-host "* Tip: Xore needs this file already received via /sendfile to hear it too *" -ForegroundColor DarkGray
                        }
                    } elseif ($currentInput -eq "/pause") {
                        Pause-MusicLocal
                        $writer.WriteLine("MUSIC|PAUSE|")
                        write-host "* Music paused *" -ForegroundColor Cyan
                    } elseif ($currentInput -eq "/stop") {
                        Stop-MusicLocal
                        $writer.WriteLine("MUSIC|STOP|")
                        write-host "* Music stopped *" -ForegroundColor Cyan
                    } elseif ($currentInput.StartsWith("/ai ")) {
                        $question = $currentInput.Substring(4).Trim()
                        if ($question -eq "") {
                            write-host "* Usage: /ai <question> *" -ForegroundColor Red
                        } else {
                            write-host "* Asking Gemini... *" -ForegroundColor DarkGray
                            $historyText = if ($global:chatHistory.Count -gt 0) { $global:chatHistory -join "`n" } else { "" }
                            $prompt = if ($historyText) {
                                "You're a helpful AI joining a private two-person chat between Dale and Xore. Here's the recent conversation for context:`n$historyText`n`nNow answer this question naturally, using that context only if it's relevant:`n$question"
                            } else {
                                $question
                            }
                            $answer = Ask-Gemini $prompt
                            if ($answer) {
                                write-host "[Gemini]: " -NoNewline -ForegroundColor Yellow
                                write-host $answer -ForegroundColor Yellow
                                Add-ChatHistory "[$myNick asked Gemini]: $question"
                                Add-ChatHistory "[Gemini]: $answer"
                                $qB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($question))
                                $aB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($answer))
                                $writer.WriteLine("AI|$qB64|$aB64")
                            }
                        }
                    } elseif ($currentInput -eq "/updates") {
                        write-host ""
                        write-host "Recent updates:" -ForegroundColor DarkGray
                        foreach ($update in $recentUpdates) {
                            write-host "  $update" -ForegroundColor DarkGray
                        }
                        write-host ""
                    } elseif ($currentInput -eq "/update") {
                        write-host ""
                        write-host "Latest update:" -ForegroundColor DarkGray
                        write-host "  $($recentUpdates[0])" -ForegroundColor DarkGray
                        write-host ""
                    } elseif ($currentInput -eq "/drop") {
                        $global:dropForm.Show()
                        write-host "* Drop window opened - drag a file onto it to send *" -ForegroundColor Cyan
                    } elseif ($currentInput -eq "/help") {
                        Show-Help
                    } elseif ($currentInput -eq "/tray") {
                        Hide-ToTray
                    } elseif ($currentInput -eq "/clear") {
                        Clear-Host
                        write-host "==================================================" -ForegroundColor Green
                        write-host "===              CHAT ACTIVE                   ===" -ForegroundColor Green
                        write-host "==================================================" -ForegroundColor Green
                    } else {
                        $writer.WriteLine("MSG|$(Get-Timestamp)|$myNick|$currentInput")
                        Write-SenderLine "[$(Get-Timestamp)] [$myNick]: $currentInput"
                        Add-ChatHistory "[$myNick]: $currentInput"
                    }

                    $currentInput = ""
                    Redraw-InputLine $currentInput $statusText
                }
            } elseif ($keyInfo.Key -eq [System.ConsoleKey]::Backspace) {
                if ($currentInput.Length -gt 0) {
                    $currentInput = $currentInput.SubString(0, $currentInput.Length - 1)
                    if ($currentInput.Length -eq 0 -and $typingActive) {
                        $writer.WriteLine("TYPING|$myNick|0")
                        $typingActive = $false
                    }
                    Redraw-InputLine $currentInput $statusText
                }
            } else {
                $wasEmpty = ($currentInput.Length -eq 0)
                $currentInput += $keyInfo.KeyChar
                if ($wasEmpty -and -not $typingActive) {
                    $writer.WriteLine("TYPING|$myNick|1")
                    $typingActive = $true
                }
                Redraw-InputLine $currentInput $statusText
            }
        }

        Start-Sleep -Milliseconds 10
    }

    write-host "`nChat session ended." -ForegroundColor Red
} catch {
    write-host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    write-host "(Check Windows Firewall allows inbound TCP on port $port, and that your VPN is active.)" -ForegroundColor Red
} finally {
    if ($client) { $client.Close() }
    if ($listener) { $listener.Stop() }
    Start-Sleep -Seconds 15
}
