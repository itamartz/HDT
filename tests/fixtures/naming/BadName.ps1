# Fixture: every function below violates DESIGN 15.1 in a different way, one
# per line so the line number is assertable. Fixtures are excluded from
# Get-HDTSourceFile, so these names never reach the naming contract.

function Get-Thing { Write-Output 'no HDT prefix' }
function Get-HdtThing { Write-Output 'lowercase dt' }
function Get-hdtThing { Write-Output 'lowercase hdt' }
function GetHDTThing { Write-Output 'no hyphen' }
function Frobnicate-HDTThing { Write-Output 'verb not in Get-Verb' }
function Get-HDT { Write-Output 'no noun after the prefix' }
function Get-HDTthing { Write-Output 'lowercase first noun letter' }
