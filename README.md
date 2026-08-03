# addon-devops

The shared build, lint, test and release scripts behind the [Mini\* addons](https://github.com/Verubato)
and FrameSort. Every addon mounts this repository at `<addon>/build` as a git submodule, so a fix
here lands in all of them at once — after each addon's pointer is bumped.

## Layout

Paths at the top level are a **contract**: every addon's `.github/workflows/Test.yml` and every
addon's `tests/RunAll.lua` reference them by path, across thirty-odd repositories. Moving one
means editing all of them. Everything under a subfolder is internal and free to rearrange.

```
Lint.ps1        Runs the source checks. Called by every addon's workflow.
Test.ps1        Runs the addon's suite if it has one. Called by every addon's workflow.

Lua/            The test harness an addon's suite requires. On its package.path.
Checks/         Every check. All of them fail the build.
Release/        Packaging and publishing. Run by hand.
Setup/          One-time developer machine setup. Run by hand.
```

### Checks — all of these fail the build

Three are driven by `Lint.ps1`; three are separate workflow steps, so a failure names the
concern rather than lumping everything under "lint failed".

| Script | Invoked by | What it catches |
| --- | --- | --- |
| `Linter.lua` | `Lint.ps1` | luacheck over `src/` and `tests/`, using the addon's own `.luacheckrc` |
| `CheckForwardRefs.py` | `Lint.ps1` | a file-local Lua function referenced above its declaration, which luacheck can't see because every `.luacheckrc` suppresses undefined globals |
| `CheckConventions.py` | `Lint.ps1` | file layout, module-table naming, and TOC load order |
| `CheckSubmodule.ps1` | workflow | the addon's pinned `build` commit is behind this repository |
| `CheckLocales.py` | workflow | `L["..."]` keys the code asks for with no translation behind them |
| `CheckTocVersions.py` | workflow | TOC interface numbers behind a **live** client, which greys the addon out |

Three things are reported without failing, because failing on them would punish the wrong
change:

- **Orphaned locale entries** — dead weight left by a reworded string. Failing would mean every
  wording change broke the build until eleven locale files had been tidied.
- **Test-realm builds** — an addon is free to wait for a PTR build to go live.
- **An unreachable wiki page** — whether the build passes must not depend on a third party site
  being up, so `CheckTocVersions.py` exits 0 with a note when it cannot read the build list.

Two of these fail on their own schedule rather than on yours. The day Blizzard ships a patch,
every addon not yet bumped fails `CheckTocVersions`; the moment this repository gains a commit,
every addon still on the old pin fails `CheckSubmodule`. Both are the point — the bump is the
work that just got created — but it does mean an unrelated change can be blocked by one.

### Lua — the test harness

Required by an addon's `tests/RunAll.lua` via `package.path = "build/Lua/?.lua;..."`.

| Module | Role |
| --- | --- |
| `TestFramework.lua` | describe/it, assertions, and the run summary |
| `Toc.lua` | parses a `.toc` (and any `.xml` it names) into an ordered file list |
| `WowMock.lua` | a stand-in WoW client: widgets, events, timers, and the API surface these addons call |
| `AddonHarness.lua` | loads an addon from its TOC and fires the login sequence |
| `SmokeTest.lua` | the suite every addon runs |

`WowMock.lua` leaves globals it does not know as `nil` on purpose — addons feature-detect
constantly, and a mock where every name is truthy sends them down branches that cannot run on
a real client. A missing API failing a smoke test is the signal to add it here.

## Running things

From an addon's root:

```powershell
./build/Lint.ps1
./build/Test.ps1
./build/Checks/CheckSubmodule.ps1
python ./build/Checks/CheckLocales.py
python ./build/Checks/CheckTocVersions.py
```

Packaging, from `build/Release` (the zip is written to the working directory, which is where
`Publish.ps1` looks for it):

```powershell
./Build.ps1
./Publish.ps1
```

Machine setup, once:

```powershell
./Setup/Deps.ps1
```

## Changing this repository

1. Commit and push here first. An addon's submodule pointer must reference a published commit
   or CI cannot resolve it.
2. Bump every addon in the same pass: `cd <addon>/build && git fetch origin main &&
   git checkout <sha>`, then commit the pointer in the addon. This is not optional any more —
   `Checks/CheckSubmodule.ps1` fails an addon still on the old pin, and the workflow checks
   these scripts out at their default branch rather than at the pin, so a path change here
   breaks every addon that has not been bumped.

Note that `cd build` also switches git context, which silently breaks `git status` and
`git stash` run from what looks like the parent repository.
