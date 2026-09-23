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
rem NuGetAudit=false: upstream vs18.0 references OpenTelemetry.Api 1.9.0, which SDK 10's
rem NuGet audit flags (NU1902) and TreatWarningsAsErrors promotes to a restore error. We are
rem repackaging upstream MSBuild, not owning its deps, so disable the audit.
rem -warnAsError:$false: arcade defaults warnAsError=$true and appends the MSBuild /warnaserror
rem switch INDEPENDENTLY of /p:TreatWarningsAsErrors, so a /p:...=false does NOT stop it. The
rem known promoted warnings (CS1591, SYSLIB0037) are also NoWarn'd in the Converter; this is
rem belt-and-suspenders for any others. Use ':$false' (not '0'/'false': [bool]"false"=$true).
rem 'call' is required: arcade's build.cmd ends with 'exit /b', so without call, control never
rem returns here and the BUILD_RC capture / rmdir / exit below would never run.
call .\build.cmd -pack -projects "%proj%" -configuration Release -msbuildEngine dotnet -warnAsError:$false /p:NuGetAudit=false
set BUILD_RC=%errorlevel%
echo BUILD_RC=%BUILD_RC%
if not "%BUILD_RC%"=="0" ( popd & exit /b %BUILD_RC% )
rem Packing the Build csproj emits only SamHowes.Microsoft.Build.nupkg. The Framework csproj is
rem built as a mere ProjectReference of that pack, where its GeneratePackageOnBuild is not honored,
rem so pack it explicitly to also emit SamHowes.Microsoft.Build.Framework.nupkg (release.sh needs both).
call .\build.cmd -pack -projects "%fwproj%" -configuration Release -msbuildEngine dotnet -warnAsError:$false /p:NuGetAudit=false
set BUILD_RC=%errorlevel%
echo FRAMEWORK_BUILD_RC=%BUILD_RC%
popd

rmdir /s /q %USERPROFILE%\.nuget\packages\samhowes.microsoft.build
exit /b %BUILD_RC%
