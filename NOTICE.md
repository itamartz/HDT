# NOTICE

The Hephaestus Deployment Toolkit contains code derived from third-party
projects. Their notices are reproduced below, as their licences require.

HDT itself depends on, installs and ships **no Microsoft Deployment Toolkit
component** — that constraint is the reason HDT exists, and it is enforced by
`tests/contract/NoMdtDependency.Contract.Tests.ps1`. The attribution below is to
a separately licensed open-source project, not to MDT.

---

## PSD — PowerShell Deployment Extension Kit (friendsOfMDT)

<https://github.com/FriendsOfMDT/PSD>

PSD is MIT licensed, so reuse is permitted with attribution. HDT mines it for
*mechanism* — which CIM property actually yields which fact, which registry
value Winlogon really reads, which DISM argument works on real hardware — and
not for structure: PSD is procedural and calls hardware directly, while HDT
takes injected services so the engine can run under test with no machine
attached.

### Files in this repository containing derived logic

| File | Derived from | What was derived |
|---|---|---|
| `src/Hephaestus/Public/Get-HDTMachineFact.ps1` | `Scripts/PSDGather.psm1`, function `Get-PSDLocalInfo` | The chassis-type classification tables (laptop 8, 9, 10, 11, 12, 14, 18, 21; desktop 3, 4, 5, 6, 7, 15, 16; server 23), the virtual-machine manufacturer list, and the `PROCESSOR_ARCHITEW6432` over `PROCESSOR_ARCHITECTURE` precedence |

The derived facts are also recorded in a `.NOTES` block on the function itself,
so a reader of the code finds the attribution without opening this file.

### MIT License

```
MIT License

Copyright (c) 2020

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
