param(
    [string]$CsvPath = ".\input.csv",
    [int]$StartDelayMs = 2000,
    [int]$StepDelayMs = 500,
    [int]$EnterDelayMs = 3000,
    [int]$ClipboardTimeoutMs = 5000,
    [ValidateSet("Clipboard", "Type")]
    [string]$InputMode = "Clipboard",
    [string]$Hotkey = "Ctrl+Alt+P",
    [switch]$HasHeader,
    [switch]$PasteFirstColumnOnly,
    [switch]$StopOnEscape
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeHotkey {
    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int pt_x;
        public int pt_y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}

public static class NativeKeyboard {
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION u;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)]
        public MOUSEINPUT mi;

        [FieldOffset(0)]
        public KEYBDINPUT ki;

        [FieldOffset(0)]
        public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public static void SendVirtualKey(ushort virtualKey) {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = virtualKey;

        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = virtualKey;
        inputs[1].u.ki.dwFlags = KEYEVENTF_KEYUP;

        SendAll(inputs, "virtual key " + virtualKey);
    }

    public static void SendCtrlV() {
        INPUT[] inputs = new INPUT[4];

        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = 0x11;

        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = 0x56;

        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].u.ki.wVk = 0x56;
        inputs[2].u.ki.dwFlags = KEYEVENTF_KEYUP;

        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].u.ki.wVk = 0x11;
        inputs[3].u.ki.dwFlags = KEYEVENTF_KEYUP;

        SendAll(inputs, "Ctrl+V");
    }

    public static void SendUnicodeCharacter(char character) {
        INPUT[] inputs = new INPUT[2];

        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wScan = character;
        inputs[0].u.ki.dwFlags = KEYEVENTF_UNICODE;

        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wScan = character;
        inputs[1].u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;

        SendAll(inputs, "unicode character");
    }

    private static void SendAll(INPUT[] inputs, string label) {
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent != inputs.Length) {
            int error = Marshal.GetLastWin32Error();
            throw new InvalidOperationException(
                "SendInput failed for " + label + ". Sent " + sent + " of " + inputs.Length +
                " input event(s). Win32 error: " + error + "."
            );
        }
    }
}
"@

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$timestamp][$Level] $Message"
}

function Get-HotkeyParts {
    param([string]$Value)

    $modifiers = 0
    $key = $null

    foreach ($part in ($Value -split "\+" | ForEach-Object { $_.Trim().ToUpperInvariant() })) {
        switch ($part) {
            "ALT" { $modifiers = $modifiers -bor 0x0001; continue }
            "CTRL" { $modifiers = $modifiers -bor 0x0002; continue }
            "CONTROL" { $modifiers = $modifiers -bor 0x0002; continue }
            "SHIFT" { $modifiers = $modifiers -bor 0x0004; continue }
            "WIN" { $modifiers = $modifiers -bor 0x0008; continue }
            default { $key = $part }
        }
    }

    if (-not $key -or $key.Length -ne 1) {
        throw "Hotkey must end with a single letter or digit, for example Ctrl+Alt+P."
    }

    return @{
        Modifiers = [uint32]$modifiers
        VirtualKey = [uint32][char]$key
    }
}

function Read-CsvRows {
    param(
        [string]$Path,
        [bool]$TreatFirstRowAsHeader,
        [bool]$FirstColumnOnly
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "CSV file not found: $Path"
    }

    if ($TreatFirstRowAsHeader) {
        $items = Import-Csv -LiteralPath $Path
        foreach ($item in $items) {
            $values = @($item.PSObject.Properties | ForEach-Object { [string]$_.Value })
            if ($FirstColumnOnly) {
                $values[0]
            } else {
                $values -join "`t"
            }
        }
        return
    }

    $lines = Get-Content -LiteralPath $Path
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $headers = 1..100 | ForEach-Object { "c$_" }
        $values = @((ConvertFrom-Csv -InputObject $line -Header $headers).PSObject.Properties |
            Where-Object { $_.Value -ne $null } |
            ForEach-Object { [string]$_.Value })

        if ($FirstColumnOnly) {
            $values[0]
        } else {
            $values -join "`t"
        }
    }
}

function Send-Key {
    param(
        [uint16]$VirtualKey,
        [int]$DelayMs = 40
    )

    [NativeKeyboard]::SendVirtualKey($VirtualKey)
    Start-Sleep -Milliseconds $DelayMs
}

function Send-CtrlV {
    param([int]$DelayMs = 40)

    [NativeKeyboard]::SendCtrlV()
    Start-Sleep -Milliseconds $DelayMs
}

function Send-Text {
    param(
        [string]$Text,
        [int]$ChunkDelayMs = 20
    )

    foreach ($character in $Text.ToCharArray()) {
        [NativeKeyboard]::SendUnicodeCharacter($character)
        if ($ChunkDelayMs -gt 0) {
            Start-Sleep -Milliseconds $ChunkDelayMs
        }
    }
}

function Set-ClipboardTextWithRetry {
    param(
        [string]$Text,
        [int]$TimeoutMs
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $lastError = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            [System.Windows.Forms.Clipboard]::SetDataObject($Text, $true, 10, 100)
            Start-Sleep -Milliseconds 120
            if ([System.Windows.Forms.Clipboard]::GetText() -eq $Text) {
                return
            }
        } catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Milliseconds 100
    }

    if ($lastError) {
        throw "Clipboard did not accept text within $TimeoutMs ms. Last error: $lastError"
    }

    throw "Clipboard did not contain the expected text within $TimeoutMs ms."
}

function Get-Preview {
    param([string]$Text)

    $oneLine = $Text -replace "\s+", " "
    if ($oneLine.Length -le 80) {
        return $oneLine
    }

    return "$($oneLine.Substring(0, 77))..."
}

function Invoke-PasteRows {
    param(
        [string[]]$Rows,
        [int]$InitialDelayMs,
        [int]$DelayMs,
        [int]$AfterEnterDelayMs,
        [int]$ClipboardWaitMs,
        [string]$Mode,
        [bool]$CanStopWithEscape
    )

    Write-Log "Starting in $InitialDelayMs ms. Keep the target cell/field focused..."
    Start-Sleep -Milliseconds $InitialDelayMs

    $oldClipboard = $null
    try {
        $oldClipboard = [System.Windows.Forms.Clipboard]::GetText()
    } catch {
        $oldClipboard = $null
    }

    try {
        for ($i = 0; $i -lt $Rows.Count; $i++) {
            if ($CanStopWithEscape -and ([NativeHotkey]::GetAsyncKeyState(0x1B) -band 0x8000)) {
                Write-Log "Stopped on Escape after $i row(s)." "WARN"
                return
            }

            $rowNumber = $i + 1
            $preview = Get-Preview -Text $Rows[$i]
            Write-Log "Row $rowNumber/$($Rows.Count): F2. Value: $preview"
            Send-Key -VirtualKey 0x71
            Start-Sleep -Milliseconds $DelayMs

            if ($Mode -eq "Type") {
                Write-Log "Row $rowNumber/$($Rows.Count): type text."
                Send-Text -Text $Rows[$i]
            } else {
                Write-Log "Row $rowNumber/$($Rows.Count): loading clipboard."
                Set-ClipboardTextWithRetry -Text $Rows[$i] -TimeoutMs $ClipboardWaitMs

                Write-Log "Row $rowNumber/$($Rows.Count): paste."
                Send-CtrlV
            }
            Start-Sleep -Milliseconds $DelayMs

            Write-Log "Row $rowNumber/$($Rows.Count): Enter."
            Send-Key -VirtualKey 0x0D
            Start-Sleep -Milliseconds $AfterEnterDelayMs

            Write-Log "Row $rowNumber/$($Rows.Count): done."
        }

        Write-Log "Done. Pasted $($Rows.Count) row(s)."
    } finally {
        if ($null -ne $oldClipboard) {
            try { [System.Windows.Forms.Clipboard]::SetDataObject($oldClipboard, $true, 10, 100) } catch {}
        }
    }
}

$resolvedCsvPath = (Resolve-Path -LiteralPath $CsvPath).Path
$rows = @(Read-CsvRows -Path $resolvedCsvPath -TreatFirstRowAsHeader:$HasHeader.IsPresent -FirstColumnOnly:$PasteFirstColumnOnly.IsPresent)
if ($rows.Count -eq 0) {
    throw "No rows found in CSV: $resolvedCsvPath"
}

$hotkeyParts = Get-HotkeyParts -Value $Hotkey
$hotkeyId = 9182
$registered = [NativeHotkey]::RegisterHotKey([IntPtr]::Zero, $hotkeyId, $hotkeyParts.Modifiers, $hotkeyParts.VirtualKey)
if (-not $registered) {
    throw "Could not register hotkey $Hotkey. Another app may already be using it."
}

Write-Log "Loaded $($rows.Count) row(s) from $resolvedCsvPath"
Write-Log "Put the cursor in the target place, then press $Hotkey."
Write-Log "Input mode: $InputMode"
Write-Log "Keep this PowerShell window open. Press Ctrl+C here to quit."
if ($StopOnEscape) {
    Write-Log "While running, hold Escape to stop after the current step."
}

try {
    while ($true) {
        $message = New-Object NativeHotkey+MSG
        while ([NativeHotkey]::PeekMessage([ref]$message, [IntPtr]::Zero, 0, 0, 1)) {
            if ($message.message -eq 0x0312 -and $message.wParam.ToInt32() -eq $hotkeyId) {
                Invoke-PasteRows -Rows $rows -InitialDelayMs $StartDelayMs -DelayMs $StepDelayMs -AfterEnterDelayMs $EnterDelayMs -ClipboardWaitMs $ClipboardTimeoutMs -Mode $InputMode -CanStopWithEscape:$StopOnEscape.IsPresent
                Write-Log "Ready again. Press $Hotkey to run from the first CSV row."
            }
        }

        Start-Sleep -Milliseconds 35
    }
} finally {
    [void][NativeHotkey]::UnregisterHotKey([IntPtr]::Zero, $hotkeyId)
}
