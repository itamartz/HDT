# A *user* extension script that both traces to the host AND emits an object.
#
# DESIGN 4.4.4: "anything a user script writes to the standard streams is
# captured too, so an existing script that only uses Write-Host still lands in
# the log without modification - a hard requirement, since real fleets carry
# years of such scripts". This fixture is what proves it: the host line must
# reach the transcript, and it must NOT be mistaken for the script's result.
param([System.Collections.IDictionary] $Variable)

Write-Host 'checking vendor BIOS level'

[pscustomobject] @{ HDTBiosBaseline = 'ok' }
