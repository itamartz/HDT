# A setFrom: script - a USER extension point, not an HDT command.
#
# DESIGN 15.1's Verb-HDTNoun rule governs HDT's own commands. A script in a
# customer's workspace is theirs to name, so this one deliberately carries no HDT
# prefix, and samples/ sits outside Get-HDTSourceFile precisely so the naming
# contract does not claim it.
#
# The contract a setFrom script must honour:
#
#   * it takes one parameter, the current variable scope, as an IDictionary;
#   * it emits exactly ONE object; every property of it becomes a variable;
#   * a property named _HDT* is a configuration error - those are engine-owned;
#   * emitting nothing is allowed and sets nothing.
#
# The engine never runs this file directly: it calls it through an IScriptInvoker,
# which is what lets every rule be tested without executing anything.

param([System.Collections.IDictionary] $Variable)

[pscustomobject] @{ HDTAssetTag = ('ASSET-{0}' -f $Variable['HDTSerialNumber']) }
