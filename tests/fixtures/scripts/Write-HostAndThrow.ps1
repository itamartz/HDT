# A step script that says what it was doing and THEN fails.
#
# THE CASE THE TRANSCRIPT EXISTS FOR. A script that succeeds can be diagnosed
# from its result; a script that throws can only be diagnosed from what it
# printed before it threw. The real adapter used to lose exactly that - it
# assigned $LastTranscript after the enumeration finished, so an exception on
# the last line discarded every line before it - and a failing PowerShell step
# reached the log carrying nothing but the exception.
#
# Found on a real Server 2025 build: an eight-hour WSUS catalogue sync failed
# and its step log held one line, the exception, with none of the per-attempt
# progress the script had written.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'The fixture exists to prove Write-Host output survives a throw.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Variable',
    Justification = 'Required by the IScriptInvoker calling convention.')]
param([System.Collections.IDictionary] $Variable)

Write-Host 'checking vendor BIOS level'
Write-Host 'contacting the vendor service'

throw 'the vendor service refused the request'
