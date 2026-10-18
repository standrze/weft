# Runs native console tests in the test process's own private Windows console.
# Build the tests first with `swift test`; this command never builds concurrently.
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This smoke check requires Windows and PowerShell 7.' }

$previous = [Environment]::GetEnvironmentVariable('WEFT_WINDOWS_CONSOLE_TEST')
try {
    $listed = swift test list --skip-build | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Could not list the built Swift tests.' }
    if ($listed -notmatch 'WindowsConsoleTests') { throw 'Native Windows console tests are missing from the test binary.' }
    $env:WEFT_WINDOWS_CONSOLE_TEST = '1'
    swift test --skip-build --filter WindowsConsoleTests
    if ($LASTEXITCODE -ne 0) { throw "Windows console smoke failed with exit code $LASTEXITCODE." }
} finally {
    if ($null -eq $previous) {
        Remove-Item Env:WEFT_WINDOWS_CONSOLE_TEST -ErrorAction SilentlyContinue
    } else {
        $env:WEFT_WINDOWS_CONSOLE_TEST = $previous
    }
}
