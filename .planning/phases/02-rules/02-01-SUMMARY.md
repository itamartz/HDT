---
phase: 02-rules
plan: 01
subsystem: rules
tags: [cim, registry, environment, script-invoker, fact-gathering, ztigather, service-contracts, adapters, fixtures]

# Dependency graph
requires:
  - phase: 01-harness plan 01
    provides: build.ps1 task runner, Pester 5 harness, Get-HDTSourceFile
  - phase: 01-harness plan 02
    provides: naming / PS5.1 / no-MDT contracts, which now cover every new file automatically
  - phase: 01-harness plan 03
    provides: HDTFakes module, the $Operations record shape, the $script:HDTImplementation contract-registry pattern, the first four CIM fixtures
provides:
  - "Get-HDTMachineFact - the ZTIGather.wsf replacement, DESIGN 3.2 facts from injected services"
  - "New-HDTCimProvider - real ICimProvider over Get-CimInstance"
  - "New-HDTRegistryService - real IRegistryService, read subset"
  - "New-HDTEnvironmentProvider - real IEnvironmentProvider"
  - "New-HDTScriptInvoker - real IScriptInvoker for setFrom: rules"
  - "New-HDTFakeRegistryService / New-HDTFakeEnvironmentProvider / New-HDTFakeScriptInvoker"
  - "New-HDTFakeCimProvider -NamespaceFixturePath - seeds a second CIM namespace from a directory"
  - "tests/contract/RegistryService|EnvironmentProvider|ScriptInvoker.Contract.Tests.ps1"
  - "tests/fixtures/cim/Win32_SystemEnclosure.json, Win32_NetworkAdapterConfiguration.json"
  - "tests/fixtures/cim-microsofttpm/Win32_Tpm.json, tests/fixtures/cim-vm/*"
  - "tests/fixtures/scripts/Get-ComputerName.ps1, Get-Nothing.ps1 - real setFrom: scripts"
  - "NOTICE.md - PSD attribution, enforced by the no-MDT contract"
affects: [02-rules plan 02, 02-rules plan 03, 03-sequence-engine, 04-imaging, 05-bootimage, 06-drivers, 07-apps-fullos]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A real service adapter is a [pscustomobject] with Add-Member ScriptMethod members, never a PowerShell class: a dot-sourced class is the known-flaky path across -Force re-imports"
    - "Every array-returning ScriptMethod uses the unary comma, or a one-element array collapses to a scalar"
    - "One ScriptMethod serves both contract overloads by dispatching on an empty second positional argument"
    - "Contract exception-TYPE assertions unwrap to the innermost exception, because a class fake throws unwrapped and a ScriptMethod adapter throws wrapped twice"
    - "A contract's engine-conditional skip goes on a Context INSIDE the Describe, never on a -ForEach Describe, where -Skip: binds before the row's keys exist"
    - "Get-Member -MemberType Method, ScriptMethod in every contract's method-presence assertion"
    - "Real adapters record into $Operations exactly as the fakes do, so provenance assertions hold against either implementation"
    - "Every New-HDT* function carries the PSUseShouldProcessForStateChangingFunctions suppression"

key-files:
  created:
    - src/Hephaestus/Public/Get-HDTMachineFact.ps1
    - src/Hephaestus/Public/New-HDTCimProvider.ps1
    - src/Hephaestus/Public/New-HDTRegistryService.ps1
    - src/Hephaestus/Public/New-HDTEnvironmentProvider.ps1
    - src/Hephaestus/Public/New-HDTScriptInvoker.ps1
    - tests/unit/Get-HDTMachineFact.Tests.ps1
    - tests/unit/New-HDTFakeRegistryService.Tests.ps1
    - tests/unit/New-HDTFakeEnvironmentProvider.Tests.ps1
    - tests/unit/New-HDTFakeScriptInvoker.Tests.ps1
    - tests/contract/RegistryService.Contract.Tests.ps1
    - tests/contract/EnvironmentProvider.Contract.Tests.ps1
    - tests/contract/ScriptInvoker.Contract.Tests.ps1
    - tests/fixtures/cim/Win32_SystemEnclosure.json
    - tests/fixtures/cim/Win32_NetworkAdapterConfiguration.json
    - tests/fixtures/cim-microsofttpm/Win32_Tpm.json
    - tests/fixtures/cim-vm/Win32_ComputerSystem.json
    - tests/fixtures/cim-vm/Win32_ComputerSystemProduct.json
    - tests/fixtures/scripts/Get-ComputerName.ps1
    - tests/fixtures/scripts/Get-Nothing.ps1
    - NOTICE.md
  modified:
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/HDTFakes/HDTFakes.psd1
    - tests/helpers/README.md
    - tests/fixtures/README.md
    - tests/unit/New-HDTFakeCimProvider.Tests.ps1
    - tests/contract/CimProvider.Contract.Tests.ps1
    - tests/contract/FileSystemService.Contract.Tests.ps1
    - src/Hephaestus/Hephaestus.psd1

key-decisions:
  - "Real adapters are pscustomobjects with ScriptMethod members, not PowerShell classes, because a dot-sourced class is the known-flaky path across -Force re-imports; the fakes stay classes because they are defined inline"
  - "New-HDTCimProvider catches and rethrows naming the class: Get-CimInstance's message is exactly 'Invalid class ' and does NOT name it, while the ICimProvider contract requires the name"
  - "Contract exception-type assertions unwrap to the innermost exception; tests/helpers/README.md section 5 was corrected, because the old -ExceptionType rule only held while every implementation was a class"
  - "The engine-conditional skip lives on a Context inside the Describe: -Skip: on a -ForEach Describe binds before the row's keys exist and silently skips nothing"
  - "IRegistryService ships the read subset only (TestPath, GetValue), named so phase 03's autologon writes are additive"
  - "GetValue returns $null for a missing key or value and never throws: a BIOS machine genuinely has no SecureBoot\\State key"
  - "Win32_SystemEnclosure, Win32_NetworkAdapterConfiguration and Win32_Tpm are optional and degrade to 'no instances'; the other four CIM classes are required and throw"
  - "HDTMemory floors rather than casts, because [int] on a double rounds to even and would make the number depend on the machine"
  - "tests/fixtures/cim-vm is DERIVED, not captured - no HDT test VM exists until phase 04 and the lab VMs are off-limits - and says so in tests/fixtures/README.md"
  - "The first sanitised DefaultIPGateway is 10.20.30.1 on purpose: DESIGN 3.3's Lab subnet rule matches exactly that, so plan 02-03 tests the design's own worked example"

# Metrics
duration: 195min
completed: 2026-08-13
---

# Phase 02 Plan 01: Fact gathering and its services Summary

**`Get-HDTMachineFact` replaces `ZTIGather.wsf`: it produces the full DESIGN 3.2 fact set from four injected services and touches no CIM, registry or environment itself — proven fact by fact against fixtures captured off this machine with nothing attached, and proven again against the live machine through the four new real adapters, which are `pscustomobject`s carrying `ScriptMethod` members rather than PowerShell classes.**

## Test evidence — every count from a real run

| Step | pwsh 7.5.8 | Windows PowerShell 5.1.26100.8655 |
|---|---|---|
| Baseline, before this plan | 323 passed / 0 failed / 9 skipped | — |
| Task 1a RED — enclosure and adapter assertions, unseeded | 2 failed / 10 passed (one file) | — |
| Task 1d RED — `-NamespaceFixturePath` absent | 7 failed / 16 passed (one file) | — |
| Task 1 GREEN | 332 passed / 0 failed / 9 skipped | 327 passed / 0 failed / 14 skipped |
| Task 2a+2b RED — seven factories absent | **92 failed** / 344 passed | — |
| Task 2 GREEN (`-Task ci`) | 444 passed / 0 failed / 9 skipped, lint 0 across 48 files | 439 passed / 0 failed / 14 skipped |
| Task 3 RED — `Get-HDTMachineFact` absent | **50 failed** / 447 passed | — |
| **Final, `-Task ci`** | **499 passed / 0 failed / 9 skipped**, lint **0 diagnostics across 50 files**, selfcheck 4/4 | **494 passed / 0 failed / 14 skipped** |

Every RED count above was observed, and the failure reason checked, before the
code that turns it green was written. The 9/14 skips are the pre-existing
engine-conditional tests from phase 01; **no contract row skipped** — the Pester
output shows all nine `Describing I*Provider|Service contract: *` blocks ran,
including the four real rows.

The live-machine proof, gathered through the real adapters (values are this
machine's, printed to the console only — nothing was written to disk):

```
HDTMake LENOVO   HDTModel 82RF   HDTIsLaptop True   HDTIsUEFI True
HDTSecureBootEnabled True   HDTTPMVersion 2.0   HDTIsVM False
HDTMacAddress {4 addresses}   HDTMemory 65260
```

`HDTMemory` differs by one megabyte between the fixture (65261) and the live run
(65260) because the machine reports slightly less physical memory than when the
fixture was captured. That is the point of computing the expectation from the
fixture rather than hard-coding it.

## What plans 02-02 and 02-03 code against

### `Get-HDTMachineFact` — final signature

```powershell
Get-HDTMachineFact -CimProvider <object> -RegistryService <object> -EnvironmentProvider <object>
```

All three mandatory and `[ValidateNotNull()]`. Returns
`[System.Collections.Specialized.OrderedDictionary]` constructed with
`[System.StringComparer]::OrdinalIgnoreCase` — **ordered** so a `facts.json` diff
stays readable, **case-insensitive** so a hand-written `rules.yaml` may spell
`HDTmodel` however it likes.

### The fact table — exact keys and value types

| Key | Type | Fixture value on the captured machine |
|---|---|---|
| `HDTMake` | `string` | `LENOVO` |
| `HDTModel` | `string` | `82RF` |
| `HDTProduct` | `string` | `LNVNB161216` |
| `HDTSerialNumber` | `string` | `FIXTURE-SERIAL-0001` |
| `HDTUUID` | `string`, upper case | `4C4C4544-0031-3610-8052-B7C04F515A31` |
| `HDTSystemSKU` | `string` | `LENOVO_MT_82RF_BU_idea_FM_Legion 5 Pro 16IAH7H` |
| `HDTMemory` | `int`, whole MB floored | `65261` |
| `HDTArchitecture` | `string` | `x64` |
| `HDTIsUEFI` | `bool` | `$true` |
| `HDTSecureBootEnabled` | `bool` | `$true` |
| `HDTTPMVersion` | `string` or `$null` | `2.0` |
| `HDTIsDesktop` | `bool` | `$false` |
| `HDTIsLaptop` | `bool` | `$true` |
| `HDTIsServer` | `bool` | `$false` |
| `HDTIsVM` | `bool` | `$false` |
| `HDTMacAddress` | `string[]` | 8 entries, `00:15:5D:0A:00:01` first |
| `HDTIPAddress` | `string[]` | 23 entries |
| `HDTDefaultGateway` | `string[]` | `10.20.30.1`, `10.20.30.254` |

**Not produced, and a test asserts so:** `HDTBootMode` (phase 05 owns it),
`HDTComputerName` and `HDTTimeZoneName` (rules decide those), and anything
starting `_` (engine-owned, DESIGN 3.2). Every key starts with `HDT`.

**The fixture values 02-03's rule tests will match on:** `HDTModel` = `82RF`,
`HDTSerialNumber` = `FIXTURE-SERIAL-0001`, `HDTIsLaptop` = `$true`, and
`HDTDefaultGateway` containing **`10.20.30.1`** — the value DESIGN 3.3's
`Lab subnet` rule matches, sanitised into the fixture deliberately so the
end-to-end demonstration runs against the design's own worked example.

### Query order — asserted, not assumed

Each class is queried **exactly once**, into a local, and everything is derived
from those locals; the Make/Model fallbacks reuse the single `Win32_BaseBoard`
result, and a test proves there is no second query. The order:

```
Win32_ComputerSystem, Win32_ComputerSystemProduct, Win32_BaseBoard, Win32_BIOS,
Win32_SystemEnclosure, Win32_NetworkAdapterConfiguration, Win32_Tpm
```

The first four are **required** — a deployment that cannot read
`Win32_ComputerSystem` has no facts to rule on and must fail loudly. The last
three are **optional**: each is wrapped in its own `try`/`catch` yielding "no
instances", because WinPE without the TPM optional component, a VM with no
enclosure data and a machine with no IP-enabled adapter are all normal.
`Win32_Tpm` is queried in `root/cimv2/security/microsofttpm`.

### The three new contracts

**IRegistryService — read subset.** Phase 03 extends the *same* interface with
`SetValue` as a recorded operation, `RemoveValue` and `RemoveKey` for the DESIGN
4.5 autologon lifecycle; these two names were chosen so that is additive.

| Method | Behaviour |
|---|---|
| `[bool] TestPath([string] $Path)` | `$true` if the key exists |
| `[object] GetValue([string] $Path, [string] $Name)` | the value, or **`$null`** when the key or the name is absent — **never throws** |

Paths are provider paths (`HKLM:\...`); `HKEY_LOCAL_MACHINE\` (and `HKCU`, `HKCR`,
`HKU`) are accepted as synonyms, compared case-insensitively with a trailing `\`
trimmed. Fake-only seeding: `SetValue`, plus the factory's `-Value` hashtable.

**IEnvironmentProvider.**

| Method | Behaviour |
|---|---|
| `[string] GetVariable([string] $Name)` | the value, or `$null` when unset. Case-insensitive |

**IScriptInvoker.**

| Method | Behaviour |
|---|---|
| `[object] Invoke([string] $Path, [System.Collections.IDictionary] $Variable)` | runs the script and returns its **last** output object; throws `[System.IO.FileNotFoundException]` naming the script when it does not exist; `$null` when the script emits nothing |

`New-HDTScriptInvoker -Root <string>` resolves a relative `$Path` against the
workspace root, so `Scripts\Get-ComputerName.ps1` from `rules.yaml` works from a
share or from standalone media. The script is invoked as
`& $resolved -Variable $Variable`.

All three record into `$Operations` (`Sequence` / `Operation` / `Arguments`) with
`GetOperationName()`, before the call can throw, seeding never recorded — **on
the real adapters as well as the fakes**, so a provenance assertion in a contract
file holds against either row.

### `New-HDTFakeCimProvider` — new parameter

```
New-HDTFakeCimProvider [-Instance <hashtable>] [-Namespace <string> = 'root/cimv2']
                       [-FixturePath <string>] [-NamespaceFixturePath <hashtable>]
```

`-NamespaceFixturePath` keys are namespaces, values are directory paths; each
directory loads exactly as `-FixturePath` does but into that namespace, through
the same private per-directory loader so the two cannot drift. A missing
directory throws naming it. Canonical use:

```powershell
New-HDTFakeCimProvider -FixturePath ./tests/fixtures/cim `
    -NamespaceFixturePath @{ 'root/cimv2/security/microsofttpm' = './tests/fixtures/cim-microsofttpm' }
```

## Findings that cost time and are now written down

All of these are recorded in `tests/helpers/README.md` **section 11** (new) and
in a corrected **section 5**, so a later phase does not pay for them again.

- **`Get-Member -MemberType Method` does not list a `ScriptMethod`.** Every
  contract's method-presence assertion now says `Method, ScriptMethod`, with a
  comment, in all five files.
- **An array-returning `ScriptMethod` collapses a one-element array to a scalar**
  without the unary comma.
- **An exception thrown inside a `ScriptMethod` reaches the caller wrapped
  twice** (`MethodInvocationException` → `RuntimeException` → the original),
  while a PowerShell class method throws unwrapped. `Should -Throw -ExceptionType`
  therefore passes against a fake and fails against a real adapter. Contracts now
  unwrap to the innermost exception; messages need no unwrapping. This
  **corrected `tests/helpers/README.md` section 5**, which had stated the
  `-ExceptionType` rule as universal.
- **`Get-CimInstance` does not name the class** in its invalid-class message — it
  is exactly `Invalid class `. `New-HDTCimProvider` rethrows with the class and
  namespace attached, which is why the contract's `*Win32_NoSuchClassHDT*`
  assertion holds for both rows.
- **`-Skip:` on a `-ForEach` `Describe` skips nothing.** Verified by flipping one
  row to `Skip = $true` and watching Pester report **10 passed / 10 skipped**,
  then reverting. The skip lives on a `Context` inside the block.
- **An `if` statement's output is enumerated**, so
  `$a.DefaultIPGateway = if (...) { @('10.20.30.1') }` writes a *scalar* and
  `ConvertTo-Json` emits `"10.20.30.1"` instead of `["10.20.30.1"]`. Caught while
  sanitising; the rule is now in `tests/fixtures/README.md`.
- **Returning an array from a function suppresses enumeration differently on each
  engine.** A unary comma suppresses it on pwsh 7; an `[object[]]` cast in a
  `return` suppresses it on Windows PowerShell 5.1. The test fixture helper
  returns the parse result raw and every caller wraps in `@()`. This one produced
  a genuinely misleading test: `Where-Object` member-enumerated the nested array
  instead of filtering it, so "9 IP-enabled adapters" silently became "all 28",
  and every single-instance assertion kept passing by accident.

## Deviations from plan

### Auto-fixed issues

**1. [Rule 1 - Bug] `New-HDTScriptInvoker` help leaked this machine's real BIOS serial**
- **Found during:** Task 3 verification, step 5 (`git log --all -S`)
- **Issue:** the `.EXAMPLE` block carried `PF3EKMR0`, copied verbatim from the
  plan document's `verified_facts` table. The 01-03 rule is that this machine's
  identifiers never enter git history.
- **Fix:** replaced with `FIXTURE-SERIAL-0001`, the sanitised value every other
  example uses.
- **Files modified:** `src/Hephaestus/Public/New-HDTScriptInvoker.ps1`
- **Commit:** `e7ee6a8`

**2. [Rule 1 - Bug] The network expectations in `Get-HDTMachineFact.Tests.ps1` were computed from a nested array**
- **Found during:** Task 3 GREEN
- **Issue:** the fixture helper returned `, ([object[]] @(...))`, so `@(...)` at
  the call site produced a one-element array holding the 28-element array;
  `Where-Object { $_.IPEnabled }` member-enumerated it rather than filtering, and
  the expected MAC count came out as 16 (every adapter) instead of 8 (IP-enabled
  adapters that have one). The implementation was right and the test was wrong.
- **Fix:** the helper returns the parse result raw; the network assertions were
  also made self-contained rather than sharing `$script:` state across blocks.
- **Files modified:** `tests/unit/Get-HDTMachineFact.Tests.ps1`
- **Commit:** folded into `faca8f3`

**3. [Rule 3 - Blocking] Pester's own `Pester.ps1` was overwritten during verification step 3a**
- **Found during:** Task 2 verification
- **Issue:** the throwaway script that proves the `Context` skip works held the
  contract file's path in `$p`, ran `Invoke-Pester`, and restored the file from a
  backup in a `finally`. By the time the `finally` ran, `$p` no longer held the
  contract path — it held
  `C:\Users\Itamartz\Documents\PowerShell\Modules\Pester\5.7.1\Pester.ps1`, which
  was then overwritten with the contract file. Every subsequent Pester run in the
  session discovered that contract as if it were part of Pester itself, so the
  whole suite went red with no output — a genuinely confusing failure that looked
  like the new tests had broken everything.
- **Fix:** restored `Pester.ps1` byte-for-byte from the untouched machine-wide
  install at `C:\Program Files\WindowsPowerShell\Modules\Pester\5.7.1\`, verified
  identical (`Pester.psm1`, `Pester.psd1` and `Pester.Format.ps1xml` compare equal
  between the two installs), and confirmed the suite returned to 444 passed / 0
  failed. **No repository file was affected**, and nothing was committed while the
  environment was in that state.
- **Standing rule this produces:** never restore a file by a path held in a
  variable across an `Invoke-Pester` call, and never use a one-letter variable
  name around one. Prefer `git checkout -- <path>`, which is what was ultimately
  used to restore the contract file.

### Deliberate additions beyond the plan

- `It 'does not seed a namespace fixture into root/cimv2'` — the plan listed five
  `-NamespaceFixturePath` assertions; the negative case matters as much, because
  a loader that seeded both namespaces would pass all five.
- `It 'queries Win32_Tpm in the microsofttpm namespace'` and
  `It 'names every fact with the HDT prefix'` — the ordered-query assertion checks
  only class names, so nothing otherwise proved the namespace, and DESIGN 3.2's
  prefix rule deserved an assertion rather than a convention.
- `It 'trims a leading dot-slash from the path'` and
  `It 'records an invocation that threw'` on the script invoker fake, mirroring
  the equivalent CIM fake tests.

## Known gaps, stated plainly

- **`tests/fixtures/cim-vm/` is derived, not captured.** Four properties were
  substituted into the real physical capture with the values PSD documents for a
  Hyper-V guest. There is no HDT test VM until phase 04 and the lab's `CM01` and
  `DC01` are off-limits, so `HDTIsVM` has no honest capture available today. The
  substitution is recorded under **`## Derived fixtures`** in
  `tests/fixtures/README.md`, which also says to replace the directory with a
  real capture from the first `HDT-*` VM in phase 04.
- **`HDTIsVM` for VMware, VirtualBox, QEMU, KVM, Xen and Parallels is proven only
  against hand-built objects**, not captures. Those manufacturers' strings come
  from PSD, which has run on real hardware; HDT has not seen them.
- **The `IFileSystem` contract still has one row.** It was converted to the
  `Context`-skip shape so all five files match, but its real adapter does not
  arrive until phase 04.
- **This machine's real BIOS serial is present in git history** in the plan
  document `.planning/phases/02-rules/02-01-PLAN.md`, committed in `f9bdcc3`
  before this plan began, and in `409f5bf` from the help example fixed above. No
  fixture contains it, and no history rewrite was attempted.

## Self-Check: PASSED

All twenty-one created files verified present on disk; all ten commits verified
present in `git log`.
