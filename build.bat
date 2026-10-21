rem Start Visual Studio developer command prompt
rem build.bat

set version=vs18.0
rem Pin to a fixed vs18.0 commit: the branch tip drifts (arcade dep bumps) and
rem breaks the Converter's UpdateBuildManager transform. 149ded8b1c = VersionPrefix
rem 18.0.3, no IMetadataContainer.RemoveMetadataRange -> interface-compatible with
rem SDK 10.0.112's bundled MSBuild 18.0.11.
set commit=149ded8b1c83b130ec8124cb2c52f628b7158a1e
pushd _work\msbuild
git fetch origin %version%
git checkout -B rules_msbuild/%version% %commit%
git reset --hard %commit%
popd

pushd Converter
set version=18.0.11
dotnet run
popd

pushd _work\msbuild
set "proj=%cd%\src\Build\Microsoft.Build.csproj"
set "fwproj=%cd%\src\Framework\Microsoft.Build.Framework.csproj"
set "utilproj=%cd%\src\Utilities\Microsoft.Build.Utilities.csproj"
rem Shared flag rationale (applies to every build.cmd call below):
rem NuGetAudit=false: upstream vs18.0 references OpenTelemetry.Api 1.9.0, which SDK 10's
rem NuGet audit flags (NU1902) and TreatWarningsAsErrors promotes to a restore error. We are
rem repackaging upstream MSBuild, not owning its deps, so disable the audit.
rem -warnAsError:$false: arcade defaults warnAsError=$true and appends the MSBuild /warnaserror
rem switch INDEPENDENTLY of /p:TreatWarningsAsErrors, so a /p:...=false does NOT stop it. The
rem known promoted warnings (CS1591, SYSLIB0037) are also NoWarn'd in the Converter; this is
rem belt-and-suspenders for any others. Use ':$false' (not '0'/'false': [bool]"false"=$true).
rem 'call' is required: arcade's build.cmd ends with 'exit /b', so without call, control never
rem returns here and the BUILD_RC capture / rmdir / exit below would never run.

rem 1. Pack Framework FIRST. Besides emitting SamHowes.Microsoft.Build.Framework.nupkg (release.sh
rem    needs it), this first build.cmd call also initializes arcade's repo-local .dotnet SDK. That
rem    matters for step 2: the Utilities/Tasks pack resolves Microsoft.NET.Sdk via .dotnet (MSBuild
rem    18.x) only once .dotnet exists; as the very first call it would instead fall back to the
rem    .tools bootstrap MSBuild (17.13), which is too old for the SDK in global.json and fails SDK
rem    resolution. Framework is the lowest layer (no in-repo deps beyond StringTools), so it builds
rem    cleanly as the warm-up call.
call .\build.cmd -pack -projects "%fwproj%" -configuration Release -msbuildEngine dotnet -warnAsError:$false /p:NuGetAudit=false
set BUILD_RC=%errorlevel%
echo FRAMEWORK_BUILD_RC=%BUILD_RC%
if not "%BUILD_RC%"=="0" ( popd & exit /b %BUILD_RC% )

rem 2. Pack Utilities.Core from the same source/version so the Microsoft.Build pack (step 3) can
rem    bundle it into lib/net10.0 via the <None Pack="true"> item the Converter injected. The builder
rem    runs ILLink/AOT tasks in-process (see Converter UpdateTypeLoader), so the runtime must find
rem    their base class Microsoft.Build.Utilities.Task -> Microsoft.Build.Utilities.Core.dll next to
rem    builder.dll (MSB4062 otherwise). This MUST run before step 3: the DLL has to exist in
rem    artifacts/bin when that pack copies it. The extra Utilities nupkg is harmless -- release.sh
rem    only ships Build + Framework.
rem    (Tasks.Core is intentionally NOT built/bundled: the ILLink tasks derive from Utilities.Task,
rem    not from anything in Tasks.Core, and Tasks.csproj re-compiles Shared helpers that collide with
rem    the publicized copies in the referenced Utilities.Core -> CS0121. Utilities.Core alone suffices.)
rem    Pack as a SINGLE-project call: a multi-project '-projects "a;b"' makes arcade build a traversal
rem    that ignores -msbuildEngine dotnet and falls back to the .tools bootstrap MSBuild (17.13), which
rem    cannot resolve the SDK in global.json (needs 18.7+). Single-project packs build via .dotnet.
rem    EnablePackageValidation=false: packing runs Microsoft.NET.ApiCompat.ValidatePackage, which fails
rem    because Publicize (internal->public) changed the cross-TFM API surface. The Build/Framework packs
rem    get this via the Converter (SetPackageId/SetFrameworkPackageId); Utilities isn't PackageId-
rem    rewritten, so disable it here. We only consume its net10.0 DLL, not a validated package.
call .\build.cmd -pack -projects "%utilproj%" -configuration Release -msbuildEngine dotnet -warnAsError:$false /p:NuGetAudit=false /p:EnablePackageValidation=false
set BUILD_RC=%errorlevel%
echo UTILITIES_BUILD_RC=%BUILD_RC%
if not "%BUILD_RC%"=="0" ( popd & exit /b %BUILD_RC% )

rem 3. Pack Build LAST -- its <None> item bundles the Utilities.Core DLL from step 2 into
rem    SamHowes.Microsoft.Build.nupkg's lib/net10.0.
call .\build.cmd -pack -projects "%proj%" -configuration Release -msbuildEngine dotnet -warnAsError:$false /p:NuGetAudit=false
set BUILD_RC=%errorlevel%
echo BUILD_RC=%BUILD_RC%
popd

rmdir /s /q %USERPROFILE%\.nuget\packages\samhowes.microsoft.build
exit /b %BUILD_RC%
