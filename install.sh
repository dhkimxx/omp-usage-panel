#!/bin/sh
# OMP Usage one-line installer (macOS).
#   curl -fsSL https://raw.githubusercontent.com/dhkimxx/omp-usage-panel/main/install.sh | sh
# All logic lives in functions and main runs last, so a truncated download never executes a partial command.
set -eu

REPO='dhkimxx/omp-usage-panel'
API_BASE="https://api.github.com/repos/$REPO/releases"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/"

TMP_DIR=''
MOUNTED=0

say() { printf '%s\n' "$*"; }
fail() { printf 'OMP Usage installer: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [--version X.Y.Z] [--omp /absolute/path] [--profile NAME]

Downloads the OMP Usage release from GitHub, verifies its SHA-256 digest and installs it.

  --version X.Y.Z    install this release instead of the latest (or set OMP_USAGE_VERSION)
  --omp PATH         absolute path of the omp executable (default: auto-detect)
  --profile NAME     omp profile to monitor (default: the default profile)
  --help             show this help
EOF
}

usage_error() {
  printf 'OMP Usage installer: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

cleanup() {
  status=$?
  set +e
  trap - EXIT INT TERM
  if [ "$MOUNTED" = 1 ] && [ -n "$TMP_DIR" ]; then
    attempt=0
    detached=0
    while [ "$attempt" -lt 3 ]; do
      if hdiutil detach "$TMP_DIR/mnt" -quiet >/dev/null 2>&1; then detached=1; break; fi
      attempt=$((attempt + 1))
      sleep 1
    done
    if [ "$detached" = 0 ]; then hdiutil detach "$TMP_DIR/mnt" -force -quiet >/dev/null 2>&1; fi
    MOUNTED=0
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
  TMP_DIR=''
  exit "$status"
}

check_platform() {
  [ "$(uname -s)" = Darwin ] || fail 'macOS is required.'
  [ "$(id -u)" != 0 ] || fail 'do not run as root or with sudo.'
  macos=$(sw_vers -productVersion) || fail 'cannot read the macOS version.'
  major=${macos%%.*}
  case $major in
    '' | *[!0-9]*) fail 'cannot read the macOS version.' ;;
  esac
  [ "$major" -ge 13 ] || fail "macOS 13 or later is required (found $macos)."
}

# Prints the plutil raw value of a JSON key path, or fails.
json_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null
}

resolve_release() {
  pinned=$1
  if [ -n "$pinned" ]; then url="$API_BASE/tags/v$pinned"; else url="$API_BASE/latest"; fi
  if [ -n "$pinned" ]; then label="v$pinned"; else label=latest; fi
  say "Looking up the release: $label"
  json="$TMP_DIR/release.json"
  curl -fsSL -H 'Accept: application/vnd.github+json' -o "$json" "$url" || fail 'cannot fetch the release information from GitHub.'

  tag=$(json_value tag_name "$json") || fail 'release information is invalid.'
  version=${tag#v}
  [ "$version" != "$tag" ] || fail 'release tag is invalid.'
  case $version in
    '' | *[!0-9.]* | .* | *. | *..*) fail 'release version is invalid.' ;;
  esac
  [ "$(printf '%s' "$version" | tr -cd '.' | wc -c | tr -d ' ')" = 2 ] || fail 'release version is invalid.'
  if [ -n "$pinned" ] && [ "$version" != "$pinned" ]; then fail 'release version does not match the request.'; fi

  if json_value assets.1.name "$json" >/dev/null; then fail 'release must contain exactly one asset.'; fi
  asset=$(json_value assets.0.name "$json") || fail 'release has no downloadable asset.'
  [ "$asset" = "OMP-Usage-$version.dmg" ] || fail 'release asset name is unexpected.'

  digest=$(json_value assets.0.digest "$json") || fail 'release asset has no SHA-256 digest.'
  case $digest in
    sha256:*) expected_sha=${digest#sha256:} ;;
    *) fail 'release asset digest is not SHA-256.' ;;
  esac
  [ "${#expected_sha}" = 64 ] || fail 'release asset digest is malformed.'
  case $expected_sha in
    *[!0-9a-f]*) fail 'release asset digest is malformed.' ;;
  esac

  expected_size=$(json_value assets.0.size "$json") || fail 'release asset has no size.'
  case $expected_size in
    '' | *[!0-9]*) fail 'release asset size is invalid.' ;;
  esac

  download_url=$(json_value assets.0.browser_download_url "$json") || fail 'release asset has no download URL.'
  case $download_url in
    "$DOWNLOAD_PREFIX"*) ;;
    *) fail 'release asset URL is not a GitHub release download.' ;;
  esac
  case $download_url in
    *[!A-Za-z0-9._~:/%+-]*) fail 'release asset URL is malformed.' ;;
  esac
}

download_and_verify() {
  dmg="$TMP_DIR/OMP-Usage.dmg"
  say "Downloading OMP Usage $version..."
  curl -fL --progress-bar --proto '=https' --tlsv1.2 -o "$dmg" "$download_url" || fail 'download failed.'
  size=$(wc -c <"$dmg" | tr -d ' ')
  [ "$size" = "$expected_size" ] || fail 'downloaded file size does not match GitHub; nothing was installed.'
  actual_sha=$(/usr/bin/shasum -a 256 "$dmg" | cut -d ' ' -f 1) || fail 'cannot compute the SHA-256 digest.'
  [ "$actual_sha" = "$expected_sha" ] || fail 'SHA-256 digest does not match GitHub; nothing was installed.'
  say 'Verified SHA-256 digest.'
}

mount_and_install() {
  mnt="$TMP_DIR/mnt"
  say 'Mounting the disk image...'
  MOUNTED=1
  hdiutil attach -readonly -nobrowse -noverify -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null </dev/null || fail 'cannot mount the disk image.'
  binary="$mnt/OMP Usage.app/Contents/MacOS/OMPUsagePanel"
  [ -f "$binary" ] && [ -x "$binary" ] || fail 'the disk image does not contain OMP Usage.app.'

  set -- --install
  if [ -n "$omp_path" ]; then set -- "$@" --omp "$omp_path"; fi
  if [ -n "$profile" ]; then set -- "$@" --profile "$profile"; fi
  say 'Installing...'
  app_status=0
  "$binary" "$@" </dev/null || app_status=$?
  if [ "$app_status" != 0 ]; then
    printf 'OMP Usage installer: the app installer failed (exit %s).\n' "$app_status" >&2
    exit "$app_status"
  fi
}

main() {
  version_arg=${OMP_USAGE_VERSION:-}
  omp_path=''
  profile=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --help | -h) usage; exit 0 ;;
      --version | --omp | --profile)
        [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a non-empty value."
        case $1 in
          --version) version_arg=$2 ;;
          --omp) omp_path=$2 ;;
          --profile) profile=$2 ;;
        esac
        shift 2
        ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
  if [ -n "$version_arg" ]; then
    case $version_arg in
      *[!0-9.]* | .* | *. | *..*) usage_error 'version must look like 1.2.3.' ;;
    esac
    [ "$(printf '%s' "$version_arg" | tr -cd '.' | wc -c | tr -d ' ')" = 2 ] || usage_error 'version must look like 1.2.3.'
  fi
  if [ -n "$omp_path" ]; then
    case $omp_path in /*) ;; *) usage_error '--omp must be an absolute path.' ;; esac
  fi


  check_platform

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omp-usage-install.XXXXXX") || fail 'cannot create a temporary directory.'

  resolve_release "$version_arg"
  download_and_verify
  mount_and_install

  say ''
  say "OMP Usage $version is installed (see the path printed above)."
  say 'It registers a per-user login LaunchAgent; no sudo was used.'
  say 'To upgrade, run the same one-line command again.'
  say "To uninstall, follow the Uninstall section of the README: https://github.com/$REPO#uninstall"
}

main "$@"
