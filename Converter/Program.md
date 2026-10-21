# Understanding `Converter/Program.cs` — How `SamHowes.Microsoft.Build` Is Created

## What `Program.cs` actually is

`Converter` is a **source-patching tool**. It is *not* MSBuild itself. Its entire job is:

1. Take a clean checkout of Microsoft's official **msbuild** source tree.
2. Apply a precise series of edits to it.
3. Commit each edit to git.
4. Let a separate build step (`build.bat`) compile and pack the result into the NuGet packages **`SamHowes.Microsoft.Build`** and **`SamHowes.Microsoft.Build.Framework`**.

So "how SamHowes is created" = "this program rewrites Microsoft's MSBuild to expose internals and change a few runtime behaviors so it can be embedded inside the `rules_msbuild` Bazel builder."

The msbuild source is expected at `_work/msbuild` under the repo root.

---

## The orchestrator: `Main` (lines 24–81)

This is the recipe. Everything else is a helper.

1. **Find the repo root** (lines 26–35): walks up from the current directory until it finds a `.git` folder. If it never does, `Die` prints a message and exits with code 1 (`MyLog.cs`).
2. **Locate the msbuild source** (lines 36–40): `repoRoot/_work/msbuild`. Dies if missing. Then `SetCurrentDirectory(sourceRoot)` so all the `git` commands run inside the msbuild clone, not the Converter repo.
3. **Create a `Processor`** (line 41) pointing at the msbuild tree, with a `Files` object for file I/O.
4. **Run each transformation, then commit it** (lines 42–80). Each step is a self-contained edit followed by `Commit("message")`. Committing after each step gives you a clean, reviewable git history inside the msbuild clone — you can see exactly what each patch changed.

The order matters and is enforced by comments (e.g. line 296: `BundleTaskHostAssemblies` *must* run before `SetPackageId` because of DOM-caching interactions).

### `Commit` / `Git` (lines 83–96)

- `Commit` just runs `git add .` then `git commit -m "<message>"`.
- `Git` shells out to the `git` executable, waits, and throws if the exit code is non-zero.
- The final `SetVersion` step (lines 72–80) is wrapped in `try/catch {}` — version-setting failures are deliberately ignored so a version-prop mismatch doesn't abort the whole run.

---

## Helper classes

### `Files` (lines 99–105)

A thin, **virtual** wrapper over `File`/`Directory`. Everything is `virtual` so it can be subclassed/mocked in tests. All file reads and writes in `Processor` go through this, not directly through `System.IO`.

### `Editor` (lines 659–682)

A wrapper around **Roslyn** (the C# compiler API). It spins up an in-memory `AdhocWorkspace` + a fake project, and `LoadDocument` parses a `.cs` file into a syntax tree (`SyntaxNode root`) plus a `DocumentEditor` you can use to make structural edits (change accessibility, insert members, replace nodes). Used wherever an edit needs to understand C# structure rather than just match text.

### `MyLog.Die` (`MyLog.cs`)

Prints a message and `Environment.Exit(1)`.

---

## The transformations (the heart of it)

There are **two editing strategies** used throughout, and understanding which is used where is key:

- **Regex / plain text edits** (`_files.GetContents` → `Replace` → `WriteContents`) — fast, used when Roslyn can't be trusted.
- **Roslyn AST edits** (via `Editor`) — structural, used when the edit must be syntactically precise.

There's even a comment (lines 532–536) explaining *why* some edits fall back to text: the vs18.0 source uses C# 12 collection-expression syntax (`?? []`) that the pinned Roslyn 3.10.0 can't parse, so AST traversal silently returns nothing — text editing is safer there.

### 1. `Publicize()` (lines 128–243) — the big one

The core trick behind the whole package: **turn `internal` members into `public`** so the Bazel builder can call MSBuild's internals.

- **`MakePublic` evaluator** (134–165): rewrites `internal` → `public`, preserving modifiers like `static`/`sealed`/`abstract`. Two subtleties:
  - It drops a leading `protected` (you can't have `protected public`, line 157).
  - For **property setters** (`internal set`) it keeps them `internal` (lines 144–152), not public. Widening an override of an `internal` base setter to public is illegal (CS0507). The builder reflects with `Public|NonPublic` flags anyway, so internal setters are still reachable.
- **`SearchForPublic` evaluator** (167–171): finds `BindingFlags.NonPublic` reflection calls and appends `| BindingFlags.Public`, so reflection that used to find only non-public members now also finds the newly-public ones.
- **The two regexes** (173–180) implement exactly those two rewrites, compiled, multiline, case-insensitive.
- **`blockList`** (182–200): files that must NOT be publicized — native interop, pipe/communications code, task-host networking. Publicizing these causes accessibility-consistency compile errors or exposes interop plumbing that shouldn't be public.
- **`Walk`** (202–224): recursively walks `Framework`, `Shared`, and `Build` directories (`targetDirectories`, line 130), skips non-`.cs` and blocklisted files, applies both regexes, writes back only if something changed (`replaced` flag).
- **`ReInternalizeClass`** (233–242): after the blanket publicize, two static helper classes (`NodePacketTypeExtensions`, `NamedPipeUtil`) are forced *back* to `internal`. Publicizing them turned methods truly public whose parameter types stay internal → CS0051 inconsistent accessibility. The builder doesn't use them, so re-internalizing is the faithful fix.

### 2. `BundleTaskHostAssemblies()` (lines 301–332)

Adds `Microsoft.Build.Utilities.Core.dll` as a packed file into the NuGet package under `lib/net10.0`. Why (comment 302–313): the builder runs ILLink/trimmer/AOT tasks **in-process** (because of steps 7/8), so the runtime must find their base class `Microsoft.Build.Utilities.Task` right next to `builder.dll`. No stock package ships a copy matching this *forked* Framework (18.0.11), so it bundles the fork-built one. It uses MSBuild's `ProjectRootElement` API to add a `None` item with `Pack=true`, `PackagePath=lib/net10.0`, `Visible=false`. The path uses Arcade's output layout (`$(ArtifactsBinDir)...`).

The ordering note (296–300): this opens `Microsoft.Build.csproj` through the **shared** `GlobalProjectCollection`, so it must run *before* `SetPackageId` — otherwise `SetPackageId`'s final *text-level* regex edit would get clobbered when this step saves a stale cached DOM.

### 3. `SetPackageId()` (lines 245–294)

Edits `Microsoft.Build.csproj`:

- `GetOrAddProperty` helper finds or creates an MSBuild property.
- Sets `NoWarn` to suppress a pile of warnings that appear *because* internals were publicized (missing XML docs CS1591, CLS-compliance CS3xxx, accessibility CS0050/CS0051, etc.).
- Sets `PackageId = SamHowes.Microsoft.Build`.
- Sets `EnablePackageValidation = false` (so the extra bundled assembly and modified surface don't trip validation).
- Saves via the DOM, then does a **text regex** (289–293) to flip `internal sealed partial class NuGetFrameworkWrapper` → `public` — that class is defined in inline CDATA in the csproj that the DOM doesn't reach, hence the text fallback.

### 4. `SetFrameworkPackageId()` (lines 334–372)

Same idea for `Microsoft.Build.Framework.csproj`: sets `NoWarn` (seeding it with `$(NoWarn)` so root suppressions like `SYSLIB0037` are inherited, lines 356–359), `PackageId = SamHowes.Microsoft.Build.Framework`, and disables package validation. Also suppresses IDE style-as-error warnings (IDE0040/IDE0051) since `EnforceCodeStyleInBuild=true`.

### 5. `UpdateTranslator()` (lines 374–473) — Roslyn edits

Enables **custom string interning** for binary serialization, which the Bazel builder needs to rewrite paths during caching. Two parts:

- **`CustomizeReader`** (428–473) edits `InterningBinaryReader.cs`:
  - Makes nested classes public.
  - Loads a patch file `InterningBinaryReader.patch.cs` from the repo root, grabs an interface declaration from it, and injects a **static `Strings` property** of that interface type into the class (452–466). The builder sets this property at runtime with a path-replacing interner.
  - Inserts the patch interface after the class, and changes the `Create` method's return type to `InterningBinaryReader`.
- **`CustomizeTranslator`** (383–426) edits `BinaryTranslator.cs`:
  - Makes a nested class public.
  - Injects a static `Func<Stream, BinaryWriter> BinaryWriterFactory` property (397–412).
  - Rewrites the last statement of the constructor so instead of directly `new`-ing a writer, it calls `BinaryWriterFactory(...)` — letting the builder inject its own writer.

`UpdateTranslator` and `DisableCLS` both start with a dummy `typeof(CSharpFormattingOptions)` line (376, 477) — a hack to force the Roslyn formatting assembly to load before `Formatter.FormatAsync` is used.

### 6. `DisableCLS()` (lines 475–511) — Roslyn edits

Flips `[assembly: CLSCompliant(true)]` → `CLSCompliant(false)` in several `AssemblyInfo.cs` files (Framework, Build, optionally Deprecated/Engine and Framework/Utilities). Making internals public exposed non-CLS-compliant members; turning off the assembly-level CLS claim avoids a cascade of CS3xxx warnings/errors. `DisableCLSAssemblyInfo` (493–511) finds the `CLSCompliant` attribute node and replaces its argument with the `false` literal.

### 7. `UpdateBuildManager()` (lines 530–567) — text edits

Patches `BuildManager.cs` so the builder can inject its own caches:

- Makes `GetNewConfigurationId()` public (`Publicize` only handles `internal`, not `private`).
- Inserts a new public `ReuseOldCaches(IConfigCache, IResultsCache)` overload, anchored right before `private void LogMessage` (549–564). Uses text insertion precisely because Roslyn can't parse this file (the C# 12 syntax issue, 532–536).

### 8. `UpdateResultsCache()` (lines 569–595) — Roslyn edits

Makes `ClearResultsForConfiguration` in `ResultsCache.cs` **virtual**, so the builder can override it. Structured as a loop over `(file, methodNames)` pairs for easy extension.

### 9. `UpdateTypeLoader()` (597–623) + `UpdateAssemblyTaskFactory()` (625–656) — the task-host pair

Companions (explained at length in both comment blocks). The problem: the SDK declares ILLink/AOT tasks with `TaskFactory="TaskHostFactory"`, which forces MSBuild to run them **out-of-process**. That breaks the builder's hermetic `PathMapper` (exec-root paths get tokenized to `$exec_root` and the child process can't resolve them → MSB4027/MSB4181/MSB4028).

- `UpdateTypeLoader` drops the `useTaskHost ||` term in the `ShouldUseMetadataLoadContext` expression so *type loading* decides on runtime/arch match only.
- `UpdateAssemblyTaskFactory` drops the `_taskHostFactoryExplicitlyRequested` term in two `useTaskFactory` assignments so the *run* decision also ignores the explicit request.

Together: **same-runtime task-host tasks run in-process**, but a genuine runtime/arch mismatch still goes out-of-process (correct). Both throw if the expected source text isn't found — a guard against patching a drifted source version.

### 10. `SetVersion()` (lines 520–528)

Opens `eng/Versions.props` and sets `VersionPrefix` to `18.0.11`. Wrapped in `try/catch` in `Main`.

---

## The mental model to take away

Think of it as **three layers of concern**:

| Concern | Steps | Technique |
|---|---|---|
| **Expose internals** so the builder can call them | `Publicize`, `UpdateBuildManager`, `UpdateResultsCache` | regex + Roslyn |
| **Change runtime behavior** for hermetic/embedded use | `UpdateTranslator`, `DisableCLS`, `UpdateTypeLoader`, `UpdateAssemblyTaskFactory` | Roslyn + text |
| **Repackage** as a NuGet package under a new id | `SetPackageId`, `SetFrameworkPackageId`, `BundleTaskHostAssemblies`, `SetVersion` | MSBuild DOM + text |

Every step is idempotent-ish, commits itself to git, and many throw loudly if the upstream source doesn't match what they expect — because this patch set is pinned to a specific MSBuild version (18.0.11). When Microsoft bumps the MSBuild version, these anchors are exactly what you'd fix.
