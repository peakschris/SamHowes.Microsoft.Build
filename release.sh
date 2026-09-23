#!/usr/bin/env bash

set -e
if [[ ! -f .gitignore ]]; then echo >&2 "not at root"; exit 1; fi

version="v18.0.11a"
msbuild_version="18.0.11"
msbuild_root="$(realpath "$(pwd)/_work/msbuild")"
configuration="Release"
artifacts=(
    "$msbuild_root/artifacts/packages/$configuration/Shipping/SamHowes.Microsoft.Build.$msbuild_version.nupkg"
    "$msbuild_root/artifacts/packages/$configuration/Shipping/SamHowes.Microsoft.Build.Framework.$msbuild_version.nupkg"
)

gh_args=()
echo "checking artifacts..."
for a in "${artifacts[@]}"
do
    display_name="$(basename "$a")"
    gha="$a#$display_name"
    gh_args+=( "$gha" )
    echo "  -  $gha"
    if [[ ! -f "$a" ]]; then 
        echo "missing!"
        exit 1
    fi
done

echo "all artifacts present"

echo "using version '$version'"
if [[ "${1:-}" == "clean" ]]; then
  set +e
  echo "deleting release and tag..."
  gh release delete "$version" -y
  git push --delete origin "$version"
  exit 0
fi

echo "Checking for existing release..."
function get_url() {
  gh release view "$version" --json tarballUrl --jq .tarballUrl 2> /dev/null || echo ""
}
url=$(get_url)

if [[ "$url" == "" ]]; then
  echo "Creating release..."
  gh release create "$version" -F ReleaseNotes.md "${gh_args[@]}"
  url=$(get_url)
else
  echo "Release exists, can't continue."
  exit 1
fi

# echo "uploading artifacts..."
# for a in "${artifacts[@]}"
# do
#     echo "  -  $a"
#     if [[ ! -f "$a" ]]; then 
#         echo "missing!"
#         exit 1
#     fi
# done
# gh release upload "$tag" "$tarfile" --clobber
# # download_url=$(gh release view "$tag" --json assets --jq ".assets.[0].url")

