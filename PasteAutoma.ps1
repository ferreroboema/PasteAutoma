param(
    [string]$CsvPath = ".\input.csv",
    [int]$StartDelayMs = 1000,
    [int]$StepDelayMs = 350,
    [int]$EnterDelayMs = 900,
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
"@

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

function Invoke-PasteRows {
    param(
        [string[]]$Rows,
        [int]$InitialDelayMs,
        [int]$DelayMs,
        [int]$AfterEnterDelayMs,
        [bool]$CanStopWithEscape
    )

    Write-Host "Starting in $InitialDelayMs ms. Keep the target cell/field focused..."
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
                Write-Host "Stopped on Escape after $i row(s)."
                return
            }

            [System.Windows.Forms.SendKeys]::SendWait("{F2}")
            Start-Sleep -Milliseconds $DelayMs

            [System.Windows.Forms.Clipboard]::SetText($Rows[$i])
            Start-Sleep -Milliseconds 60

            [System.Windows.Forms.SendKeys]::SendWait("^v")
            Start-Sleep -Milliseconds $DelayMs

            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            Start-Sleep -Milliseconds $AfterEnterDelayMs

            Write-Progress -Activity "Pasting CSV rows" -Status "$($i + 1) / $($Rows.Count)" -PercentComplete ((($i + 1) / $Rows.Count) * 100)
        }

        Write-Progress -Activity "Pasting CSV rows" -Completed
        Write-Host "Done. Pasted $($Rows.Count) row(s)."
    } finally {
        if ($null -ne $oldClipboard) {
            try { [System.Windows.Forms.Clipboard]::SetText($oldClipboard) } catch {}
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

Write-Host "Loaded $($rows.Count) row(s) from $resolvedCsvPath"
Write-Host "Put the cursor in the target place, then press $Hotkey."
Write-Host "Keep this PowerShell window open. Press Ctrl+C here to quit."
if ($StopOnEscape) {
    Write-Host "While running, hold Escape to stop after the current step."
}

try {
    while ($true) {
        $message = New-Object NativeHotkey+MSG
        while ([NativeHotkey]::PeekMessage([ref]$message, [IntPtr]::Zero, 0, 0, 1)) {
            if ($message.message -eq 0x0312 -and $message.wParam.ToInt32() -eq $hotkeyId) {
                Invoke-PasteRows -Rows $rows -InitialDelayMs $StartDelayMs -DelayMs $StepDelayMs -AfterEnterDelayMs $EnterDelayMs -CanStopWithEscape:$StopOnEscape.IsPresent
                Write-Host "Ready again. Press $Hotkey to run from the first CSV row."
            }
        }

        Start-Sleep -Milliseconds 35
    }
} finally {
    [void][NativeHotkey]::UnregisterHotKey([IntPtr]::Zero, $hotkeyId)
}
