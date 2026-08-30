# A PowerShell step script - a USER extension point, not an HDT command, so it
# carries no HDT prefix (DESIGN 15.1 governs HDT's own commands, not a
# customer's workspace).
#
# WHAT THIS IS FOR. It is the Customize group's one real piece of work, and it
# exists so the captured WIM can be proved to be a WIM OF THIS BUILD. A capture
# that merely produces a valid file proves that dism ran; it proves nothing
# about WHICH machine was read. This writes an unmistakable stamp carrying the
# run id, and the verification mounts the WIM and looks for that exact run id
# back.
#
# WHERE IT WRITES, AND WHY NOT UNDER \HDT. The obvious place for an HDT marker
# would be the HDT folder on the OS volume, and it is precisely the wrong one:
# Templates\Capture\wimscript.ini excludes \HDT as a tree, so a marker put there
# would be excluded from the very image it is supposed to identify - and the
# capture would still be green. It goes at the root under its own folder
# instead, whose name shares no prefix with anything on the exclusion list.
#
# TWO STAMPS, NOT ONE. The file is what a mounted WIM can be checked for with
# no hive loading at all, which makes it the cheap assertion. The registry value
# goes into the machine's SOFTWARE hive, which is the one that TRAVELS INSIDE
# the image rather than sitting beside it, so finding it back after a mount is
# evidence about the operating system and not merely about the volume.
#
# IT DEFINES NO FUNCTIONS, ON PURPOSE. The engine DOT-SOURCES a step script into
# its own session, so a function declared here would sit in the engine's scope
# for the rest of the deployment and shadow whatever else answered to that name.
# Everything below is straight-line for that reason, and the variables it leaves
# behind are named refMarker* so they cannot collide either.

# Write-Host IS THE RIGHT CALL IN A STEP SCRIPT, WHICH IS WHY THIS IS
# SUPPRESSED RATHER THAN REWRITTEN. New-HDTScriptInvoker keeps everything the
# script wrote and hands it to Write-HDTLog line by line, and what it keeps is
# an InformationRecord - which is exactly what Write-Host emits. The step's own
# documentation makes the promise out loud: "an existing script that only uses
# Write-Host still lands in the log without modification". Swapping these three
# lines for Write-Output would put them in the step's RETURN VALUE instead,
# where the engine reads a result rather than a message.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'IScriptInvoker captures InformationRecords into the step log; Write-Host is the documented idiom for a step script.')]
param([System.Collections.IDictionary] $Variable)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# THE RUN ID IS THE WHOLE POINT. _HDTRunId is engine-owned and unique per
# deployment, so a WIM carrying it can only have come from this run. Read
# defensively: a missing key must not take the reference build down at the one
# step whose failure would be pure own-goal.
$refMarkerRunId = 'unknown'
if ($Variable.Contains('_HDTRunId')) { $refMarkerRunId = [string] $Variable['_HDTRunId'] }

$refMarkerSequence = ''
if ($Variable.Contains('HDTTaskSequenceID')) { $refMarkerSequence = [string] $Variable['HDTTaskSequenceID'] }

$refMarkerComputer = ''
if ($Variable.Contains('HDTComputerName')) { $refMarkerComputer = [string] $Variable['HDTComputerName'] }

# WHICH VOLUME IS THE ONE BEING CAPTURED, AND IT DEPENDS ON THE LEG.
#
# In the FULL OS the installation is its own system drive, and $env:SystemDrive
# is the honest answer - HDTOSVolume still holds the letter WinPE gave it, which
# is not a drive that exists here.
#
# In WinPE there is no system drive to speak of: X: is the RAM disk and the
# applied installation is wherever the partition step put it, which is exactly
# what HDTOSVolume was published for. Writing to $env:SystemDrive there would
# stamp the marker onto the boot media's RAM disk, where the capture would never
# see it - and the step would report success.
#
# NEITHER IS GUESSED AND NEITHER IS HARDCODED TO C:.
$refMarkerPhase = ''
if ($Variable.Contains('_HDTPhase')) { $refMarkerPhase = [string] $Variable['_HDTPhase'] }

$refMarkerVolume = [string] $env:SystemDrive

if ($refMarkerPhase -eq 'WinPE') {
    if (-not $Variable.Contains('HDTOSVolume') -or
        [string]::IsNullOrWhiteSpace([string] $Variable['HDTOSVolume'])) {
        throw 'this step runs in WinPE and HDTOSVolume is not set, so there is no operating system volume to stamp. The partition step publishes it.'
    }

    $refMarkerVolume = ([string] $Variable['HDTOSVolume']).Trim().TrimEnd('\').TrimEnd(':') + ':'
}

$refMarkerRoot = Join-Path -Path $refMarkerVolume -ChildPath 'ReferenceBuild'
$refMarkerFile = Join-Path -Path $refMarkerRoot -ChildPath 'marker.txt'

if (-not (Test-Path -LiteralPath $refMarkerRoot)) {
    New-Item -Path $refMarkerRoot -ItemType Directory -Force | Out-Null
}

$refMarkerLine = @(
    'HDT reference build marker'
    ('RunId        : {0}' -f $refMarkerRunId)
    ('TaskSequence : {0}' -f $refMarkerSequence)
    ('ComputerName : {0}' -f $refMarkerComputer)
    ('CapturedFrom : {0}' -f $env:COMPUTERNAME)
    ('StampedUtc   : {0}' -f ([datetime]::UtcNow.ToString('o')))
)

Set-Content -LiteralPath $refMarkerFile -Value $refMarkerLine -Encoding UTF8

# THE HIVE COPY, AND ONLY FROM THE FULL OS. HKLM\SOFTWARE is inside the captured
# volume at Windows\System32\config\SOFTWARE, so a value written here is carried
# by the operating system itself rather than sitting beside it - which is what
# makes it evidence about the OS and not merely about the volume. Verification
# loads that hive out of the mounted WIM and reads the value straight back.
#
# IN WinPE THIS WOULD BE THE WRONG HIVE. HKLM there is the BOOT IMAGE's registry,
# not the applied installation's; stamping it would write into a RAM disk that
# evaporates at the next restart, and the capture would carry nothing. Reaching
# the right one would mean loading the offline hive off the OS volume, which is
# the capture step's business and not a marker's. So the file above is the
# WinPE-leg evidence and this is the full-OS leg's, and the run says which it
# wrote.
if ($refMarkerPhase -ne 'WinPE') {
    $refMarkerKey = 'HKLM:\SOFTWARE\HDT\ReferenceBuild'
    if (-not (Test-Path -LiteralPath $refMarkerKey)) {
        New-Item -Path $refMarkerKey -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $refMarkerKey -Name 'RunId' -Value $refMarkerRunId
    Set-ItemProperty -LiteralPath $refMarkerKey -Name 'TaskSequenceID' -Value $refMarkerSequence
    Set-ItemProperty -LiteralPath $refMarkerKey -Name 'StampedUtc' -Value ([datetime]::UtcNow.ToString('o'))

    Write-Host ('reference marker registry {0}' -f $refMarkerKey)
}

# EVERYTHING WRITTEN HERE LANDS IN THE LOG. Invoke-HDTPowerShellStep hands the
# invoker's transcript to Write-HDTLog line by line, so these are the record of
# what the marker actually stamped - which is what a failed verification is read
# against.
Write-Host ('reference marker written to {0}' -f $refMarkerFile)
Write-Host ('reference marker run id {0}' -f $refMarkerRunId)

