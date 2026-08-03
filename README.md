# addon-devops

The shared build, lint, test and release scripts behind the [Mini\* addons](https://github.com/Verubato)
and FrameSort. Every addon mounts this repository at `<addon>/build` as a git submodule, so a fix
here lands in all of them at once — after each addon's pointer is bumped.

## Layout

Paths at the top level are a **contract**: every addon's `.github/workflows/Test.yml` and every
addon's `tests/RunAll.lua` reference them by path, across thirty-odd repositories. Moving one
means editing all of them. Everything under a subfolder is internal and free to rearrange.

```
Lint.ps1        Runs the checks that fail a build. Called by every addon's workflow.
Test.ps1        Runs the addon's suite if it has one. Called by every addon's workflow.

Lua/            The test harness an addon's suite requires. On its package.path.
Checks/         Enforce: these fail the build. Driven by Lint.ps1.
Reports/        Inform: these never fail. Called directly by the workflow.
Release/        Packaging and publishing. Run by hand.
Setup/          One-time developer machine setup. Run by hand.
```

### Checks — fail the build

| Script | What it catches |
| --- | --- |
| `Linter.lua` | luacheck over `src/` and `tests/`, using the addon's own `.luacheckrc` |
| `CheckForwardRefs.py` | a file-local Lua function referenced above its declaration, which luacheck can't see because every `.luacheckrc` suppresses undefined globals |
| `CheckConventions.py` | file layout, module-table naming, and TOC load order |

### Reports — never fail

A translation backlog, a deliberately pinned submodule and a client patch that landed this
morning are all normal states, not build breakages. These print to the step summary and exit 0.

| Script | What it reports |
| --- | --- |
| `CheckSubmodule.ps1` | the addon's pinned `build` commit is behind this repository |
| `CheckLocales.py` | `L["..."]` keys missing from a locale file, and orphaned locale entries |
| `CheckTocVersions.py` | TOC interface numbers behind a live client, which greys the addon out |

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
./build/Reports/CheckSubmodule.ps1
python ./build/Reports/CheckLocales.py
python ./build/Reports/CheckTocVersions.py
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
2. Bump each addon: `cd <addon>/build && git fetch origin main && git checkout <sha>`, then
   commit the pointer in the addon.
3. `Reports/CheckSubmodule.ps1` reports addons still on an older pin.

Note that `cd build` also switches git context, which silently breaks `git status` and
`git stash` run from what looks like the parent repository.
