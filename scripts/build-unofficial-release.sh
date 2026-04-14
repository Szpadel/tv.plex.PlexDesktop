#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_PLEX_PACKAGE_URL="https://repo.jjgaming.net/jjgaming-aur/x86_64/plex-desktop-1.112.0.359-1-x86_64.pkg.tar.zst"
readonly DEFAULT_RUNTIME_REPO_URL="https://flathub.org/repo/flathub.flatpakrepo"

usage() {
  cat <<'EOF'
Usage: scripts/build-unofficial-release.sh [options]

Build the unofficial Flatpak bundle from the Arch plex-desktop package and emit
release-ready artifacts.

Options:
  --release-tag TAG         Tag used in the bundle filename (default: local)
  --output-dir DIR          Directory for release artifacts (default: flatpak/dist)
  --work-dir DIR            Directory for build state and generated manifest (default: flatpak/work)
  --plex-package-url URL    Plex desktop package source URL
  --runtime-repo-url URL    Runtime repo URL embedded into the bundle
  -h, --help                Show this help
EOF
}

require_command() {
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

normalize_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve(strict=False))
PY
}

assert_safe_cleanup_dir() {
  local label="$1"
  local target="$2"
  local root="$3"
  local resolved_target
  local resolved_root

  resolved_target="$(normalize_path "$target")"
  resolved_root="$(normalize_path "$root")"

  case "$resolved_target" in
    ""|"/"|"$resolved_root")
      echo "Refusing to clean unsafe ${label}: $resolved_target" >&2
      exit 1
      ;;
    "$resolved_root"/*)
      ;;
    *)
      echo "${label} must stay within $resolved_root: $resolved_target" >&2
      exit 1
      ;;
  esac
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest_source="$repo_root/tv.plex.PlexDesktop.yml"
release_tag="local"
output_dir="$repo_root/flatpak/dist"
work_dir="$repo_root/flatpak/work"
plex_package_url="$DEFAULT_PLEX_PACKAGE_URL"
runtime_repo_url="$DEFAULT_RUNTIME_REPO_URL"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-tag)
      release_tag="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    --work-dir)
      work_dir="$2"
      shift 2
      ;;
    --plex-package-url)
      plex_package_url="$2"
      shift 2
      ;;
    --runtime-repo-url)
      runtime_repo_url="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "$repo_root"

case "$output_dir" in
  /*) ;;
  *) output_dir="$repo_root/$output_dir" ;;
esac

case "$work_dir" in
  /*) ;;
  *) work_dir="$repo_root/$work_dir" ;;
esac

artifacts_root="$repo_root/flatpak"
mkdir -p "$artifacts_root"

assert_safe_cleanup_dir "output_dir" "$output_dir" "$artifacts_root"
assert_safe_cleanup_dir "work_dir" "$work_dir" "$artifacts_root"

for cmd in curl flatpak flatpak-builder python3 tar zstd sha256sum; do
  require_command "$cmd"
done

if ! flatpak info org.freedesktop.Sdk//23.08 >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Missing Flatpak SDK: org.freedesktop.Sdk//23.08
Install it first with:
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y flathub org.freedesktop.Sdk//23.08 org.freedesktop.Platform//23.08
EOF
  exit 1
fi

mkdir -p "$output_dir" "$work_dir"
rm -rf "$output_dir"/* "$work_dir"/*

download_path="$work_dir/plex-desktop.pkg.tar.zst"
pkg_root="$work_dir/pkg-root"
source_dir="$work_dir/plex-source"
build_dir="$work_dir/build-dir"
state_dir="$work_dir/flatpak-builder-state"
repo_dir="$work_dir/repo"
manifest_path="$work_dir/tv.plex.PlexDesktop.local.yml"
metadata_path="$output_dir/build-metadata.txt"
checksums_path="$output_dir/SHA256SUMS.txt"

mapfile -t manifest_info < <(
  python3 - "$manifest_source" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()

app_id_match = re.search(r'^app-id:\s*(\S+)', text, re.MULTILINE)
if not app_id_match:
    raise SystemExit("failed to parse app-id from manifest")

version_match = re.search(
    r'https://artifacts\.plex\.tv/plex-desktop-stable/([^/]+)/linux/Plex-[^/]+-linux-x86_64\.tar\.bz2',
    text,
)
if not version_match:
    raise SystemExit("failed to parse Plex version from manifest")

print(app_id_match.group(1))
print(version_match.group(1))
PY
)

app_id="${manifest_info[0]}"
manifest_version="${manifest_info[1]}"
safe_release_tag="$(printf '%s' "$release_tag" | tr -cs 'A-Za-z0-9._-' '-')"
bundle_path="$output_dir/${app_id}-unofficial-${safe_release_tag}.flatpak"

echo "Downloading Plex package mirror artifact..."
curl -L --fail --continue-at - -o "$download_path" "$plex_package_url"

mkdir -p "$pkg_root" "$source_dir"

echo "Extracting package into $source_dir..."
tar --zstd -xf "$download_path" -C "$pkg_root"
cp -a "$pkg_root/opt/plex-desktop/." "$source_dir/"

echo "Generating local manifest $manifest_path..."
python3 - "$manifest_source" "$manifest_path" "$repo_root" "$work_dir" "$source_dir" <<'PY'
import os
from pathlib import Path
import re
import sys

manifest_source = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
repo_root = Path(sys.argv[3])
work_dir = Path(sys.argv[4])
source_dir = Path(sys.argv[5])
manifest = manifest_source.read_text()

source_block = re.compile(
    r'^    sources:\n'
    r'      - type: archive\n'
    r'        url: https://artifacts\.plex\.tv/plex-desktop-stable/.*\n'
    r'        sha256: .*\n',
    re.MULTILINE,
)

manifest, replacements = source_block.subn(
    "    sources:\n"
    f"      - type: dir\n"
    f"        path: {source_dir.relative_to(work_dir)}\n",
    manifest,
    count=1,
)
if replacements != 1:
    raise SystemExit("expected a single plex-binaries source block")

for filename in (
    "tv.plex.PlexDesktop.desktop",
    "tv.plex.PlexDesktop.png",
    "tv.plex.PlexDesktop.metainfo.xml",
    "plex-ffmpeg-compat.c",
    "plex-ffmpeg-compat.map",
):
    relative_path = Path(os.path.relpath(repo_root / filename, work_dir))
    old = f"path: {filename}"
    new = f"path: {relative_path}"
    if old not in manifest:
        raise SystemExit(f"expected manifest path not found: {old}")
    manifest = manifest.replace(old, new)

manifest_path.write_text(manifest)
PY

echo "Building Flatpak into $build_dir..."
flatpak-builder \
  --disable-rofiles-fuse \
  --force-clean \
  --repo="$repo_dir" \
  --state-dir="$state_dir" \
  "$build_dir" \
  "$manifest_path"

echo "Bundling $bundle_path..."
flatpak build-bundle \
  --runtime-repo="$runtime_repo_url" \
  "$repo_dir" \
  "$bundle_path" \
  "$app_id" \
  master

git_commit="$(git -C "$repo_root" rev-parse HEAD)"

python3 - "$metadata_path" "$release_tag" "$manifest_version" "$app_id" "$plex_package_url" "$bundle_path" "$git_commit" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import sys

metadata_path = Path(sys.argv[1])
release_tag = sys.argv[2]
manifest_version = sys.argv[3]
app_id = sys.argv[4]
plex_package_url = sys.argv[5]
bundle_path = Path(sys.argv[6])
git_commit = sys.argv[7]

metadata_path.write_text(
    "\n".join(
        [
            f"release_tag={release_tag}",
            f"app_id={app_id}",
            f"manifest_version={manifest_version}",
            f"git_commit={git_commit}",
            f"bundle_name={bundle_path.name}",
            f"plex_package_url={plex_package_url}",
            f"built_at_utc={datetime.now(timezone.utc).isoformat()}",
        ]
    )
    + "\n"
)
PY

(
  cd "$output_dir"
  sha256sum "$(basename "$bundle_path")" "$(basename "$metadata_path")" > "$(basename "$checksums_path")"
)

cat <<EOF

Build completed.
Bundle:   $bundle_path
Checksums: $checksums_path
Metadata: $metadata_path
Build dir: $build_dir
EOF
