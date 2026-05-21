# PasteAutoma

PasteAutoma is a tiny Windows helper for repetitive data entry.

Give it a CSV file, focus the target field, press a hotkey, and it will paste each row using this sequence:

```text
F2 -> paste row -> Enter
```

It is useful for tools where each value must be edited one field at a time and normal bulk paste does not work.

## Features

- Reads values from a CSV file.
- Starts from a global hotkey, default `Ctrl+Alt+P`.
- Preserves your previous clipboard contents when it finishes.
- Supports configurable delays, including a separate delay after `Enter`.
- Logs every row and action in the terminal while it runs.
- Can use clipboard paste mode or direct typing mode.
- Can paste either a whole row as tab-separated text or only the first column.
- Optional `Escape` stop behavior while a run is active.

## Requirements

- Windows
- PowerShell
- No extra packages

## Quick Start

Create a CSV file, for example `input.csv`:

```csv
First value
Second value
Third value
```

Run the script:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv
```

Then:

1. Put the cursor in the target field or cell.
2. Press `Ctrl+Alt+P`.
3. Keep hands clear while the script runs.

By default, each row sends:

```text
F2, paste row text, Enter
```

## Delay Tuning

Defaults:

```text
StartDelayMs = 5000
StepDelayMs  = 5000
EnterDelayMs = 5000
ClipboardTimeoutMs = 5000
InputMode = Clipboard
```

Increase only the pause after `Enter`:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -EnterDelayMs 1500
```

Slow all normal steps:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -StepDelayMs 600
```

Give yourself more time after pressing the shortcut:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -StartDelayMs 2000
```

Increase the time allowed for the clipboard to accept and verify each value:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -ClipboardTimeoutMs 5000
```

Bypass the clipboard and type each row directly:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -InputMode Type
```

## Options

Paste only the first CSV column:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -PasteFirstColumnOnly
```

Use a CSV with headers:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -HasHeader
```

Use another hotkey:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -Hotkey Ctrl+Alt+V
```

Allow holding `Escape` to stop during a run:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\PasteAutoma.ps1 -CsvPath .\input.csv -StopOnEscape
```

## CSV Behavior

Without `-HasHeader`, every non-empty line is treated as a value row.

With multiple columns, PasteAutoma pastes the row as tab-separated text by default. This is useful when the target accepts spreadsheet-like row input.

Use `-PasteFirstColumnOnly` when the target should receive only one value per row.

If clipboard mode occasionally misses a paste, try `-InputMode Type`. It avoids the Windows clipboard entirely and sends the row as keyboard text.

## Safety Notes

- Test with two or three rows before running a large list.
- Keep the target app focused while the automation is running.
- Watch the terminal logs. Each row prints `F2`, clipboard load, paste, `Enter`, and completion.
- Your real `input.csv` is ignored by git so it is not accidentally committed.
- Use `input.example.csv` as a template for sharing.
