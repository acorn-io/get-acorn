#!/bin/sh
set -e
set -o noglob

# Usage:
#   curl ... | ENV_VAR=... sh -
#     or
#   ENV_VAR=... ./install.sh
#
# Example:
#   Installing the most recent version:
#   curl ... | INSTALL_ACORN_CHANNEL="latest" sh -
#
# Environment variables:
#   - INSTALL_ACORN_SKIP_DOWNLOAD
#   If set to true will not download acorn hash or binary.
#
#   - INSTALL_ACORN_SYMLINK
#   If set to 'skip' will not create symlinks, 'force' will overwrite,
#   default will symlink if command does not exist in path.
#
#   - INSTALL_ACORN_VERSION
#   Version of acorn to download from github. Will attempt to download from the
#   stable channel if not specified.
#
#   - INSTALL_ACORN_COMMIT
#   Commit of acorn to download from temporary cloud storage.
#   * (for developer & QA use)
#
#   - INSTALL_ACORN_BIN_DIR
#   Directory to install acorn binary, links, and uninstall script to, or use
#   /usr/local/bin as the default
#
#   - INSTALL_ACORN_BIN_DIR_READ_ONLY
#   If set to true will not write files to INSTALL_ACORN_BIN_DIR, forces
#   setting INSTALL_ACORN_SKIP_DOWNLOAD=true
#
#   - INSTALL_ACORN_CHANNEL_URL
#   Channel URL for fetching acorn download URL.
#   Defaults to 'https://update.acorn.io/v1-release/channels'.
#
#   - INSTALL_ACORN_CHANNEL
#   Channel to use for fetching acorn download URL.
#   Defaults to 'stable'.

GITHUB_URL=https://github.com/acorn-io/acorn/releases
STORAGE_URL=https://cdn.acrn.io/cli
DOWNLOADER=
ARCH=
SUFFIX=
SUDO=sudo

# --- helper functions for logs ---
info() {
  echo '[INFO] ' "$@"
}

warn() {
  echo '[WARN] ' "$@" >&2
}

fatal() {
  echo '[ERROR] ' "$@" >&2
  exit 1
}

# --- define needed environment variables ---
setup_env() {
  # --- don't use sudo if we are already root ---
  if [ $(id -u) -eq 0 ]; then
    SUDO=
  fi

  # --- use binary install directory if defined or create default ---
  if [ -n "${INSTALL_ACORN_BIN_DIR}" ]; then
    BIN_DIR=${INSTALL_ACORN_BIN_DIR}
  else
    # --- use /usr/local/bin if root can write to it, otherwise use /opt/bin if it exists
    BIN_DIR=/usr/local/bin
    if ! $SUDO sh -c "touch ${BIN_DIR}/acorn-ro-test && rm -rf ${BIN_DIR}/acorn-ro-test"; then
      if [ -d /opt/bin ]; then
        BIN_DIR=/opt/bin
      fi
    fi
  fi

  # --- if bin directory is read only skip download ---
  if [ "${INSTALL_ACORN_BIN_DIR_READ_ONLY}" = true ]; then
    INSTALL_ACORN_SKIP_DOWNLOAD=true
  fi

  INSTALL_ACORN_CHANNEL_URL=${INSTALL_ACORN_CHANNEL_URL:-'https://update.acorn.io/v1-release/channels'}
  INSTALL_ACORN_CHANNEL=${INSTALL_ACORN_CHANNEL:-'stable'}
}

# --- check if skip download environment variable set ---
can_skip_download() {
  if [ "${INSTALL_ACORN_SKIP_DOWNLOAD}" != true ]; then
    return 1
  fi
}

# --- verify an executable acorn binary is installed ---
verify_acorn_is_executable() {
  if [ ! -x ${BIN_DIR}/acorn ]; then
    fatal "Executable acorn binary not found at ${BIN_DIR}/acorn"
  fi
}

# --- set arch and suffix, fatal if architecture not supported ---
setup_verify_arch() {
  if [ -z "$ARCH" ]; then
    PLATFORM=$(uname)
    if [ "${PLATFORM}" = "Darwin" ]; then
      ARCH=universal
      SUFFIX=-${ARCH}
      return 0
    fi
  fi

  if [ -z "$ARCH" ]; then
    ARCH=$(uname -m)
  fi

  case $ARCH in
    amd64)
      ARCH=amd64
      SUFFIX=
      ;;
    x86_64)
      ARCH=amd64
      SUFFIX=
      ;;
    arm64)
      ARCH=arm64
      SUFFIX=-${ARCH}
      ;;
    aarch64)
      ARCH=arm64
      SUFFIX=-${ARCH}
      ;;
    *)
      fatal "Unsupported architecture $ARCH"
  esac
}

# --- verify existence of network downloader executable ---
verify_downloader() {
  # Return failure if it doesn't exist or is no executable
  [ -x "$(command -v $1)" ] || return 1

  # Set verified executable as our downloader program and return success
  DOWNLOADER=$1
  return 0
}

# --- create temporary directory and cleanup when done ---
setup_tmp() {
  TMP_DIR=$(mktemp -d -t acorn-install.XXXXXXXXXX)
  TMP_HASH=${TMP_DIR}/acorn.hash
  TMP_BIN=${TMP_DIR}/acorn.bin
  cleanup() {
    code=$?
    set +e
    trap - EXIT
    rm -rf ${TMP_DIR}
    exit $code
  }
  trap cleanup INT EXIT
}

# --- use desired acorn version if defined or find version from channel ---
get_release_version() {
  if [ -n "${INSTALL_ACORN_COMMIT}" ]; then
    VERSION_ACORN="commit ${INSTALL_ACORN_COMMIT}"
  elif [ -n "${INSTALL_ACORN_VERSION}" ]; then
    VERSION_ACORN=${INSTALL_ACORN_VERSION}
  else
    info "Finding release for channel ${INSTALL_ACORN_CHANNEL}"
    version_url="${INSTALL_ACORN_CHANNEL_URL}/${INSTALL_ACORN_CHANNEL}"
    case $DOWNLOADER in
      curl)
        VERSION_ACORN=$(curl -w '%{url_effective}' -L -s -S ${version_url} -o /dev/null | sed -e 's|.*/||')
        ;;
      wget)
        VERSION_ACORN=$(wget -SqO /dev/null ${version_url} 2>&1 | grep -i Location | sed -e 's|.*/||')
        ;;
      *)
        fatal "Incorrect downloader executable '$DOWNLOADER'"
        ;;
    esac
  fi
  info "Using ${VERSION_ACORN} as release"
}

# --- download from github url ---
download() {
  [ $# -eq 2 ] || fatal 'download needs exactly 2 arguments'

  case $DOWNLOADER in
    curl)
      curl -o $1 -sfL $2
      ;;
    wget)
      wget -qO $1 $2
      ;;
    *)
      fatal "Incorrect executable '$DOWNLOADER'"
      ;;
  esac

  # Abort if download command failed
  [ $? -eq 0 ] || fatal 'Download failed'
}

# --- download hash from github url ---
download_hash() {
  if [ -n "${INSTALL_ACORN_COMMIT}" ]; then
    HASH_URL=${STORAGE_URL}/acorn${SUFFIX}-${INSTALL_ACORN_COMMIT}.sha256sum
  else
    HASH_URL=${GITHUB_URL}/download/${VERSION_ACORN}/sha256sum-${ARCH}.txt
  fi
  info "Downloading hash ${HASH_URL}"
  download ${TMP_HASH} ${HASH_URL}
  HASH_EXPECTED=$(grep " acorn${SUFFIX}$" ${TMP_HASH})
  HASH_EXPECTED=${HASH_EXPECTED%%[[:blank:]]*}
}

# --- check hash against installed version ---
installed_hash_matches() {
  if [ -x ${BIN_DIR}/acorn ]; then
    HASH_INSTALLED=$(shasum -a 256 ${BIN_DIR}/acorn)
    HASH_INSTALLED=${HASH_INSTALLED%%[[:blank:]]*}
    if [ "${HASH_EXPECTED}" = "${HASH_INSTALLED}" ]; then
      return
    fi
  fi
  return 1
}

# --- download binary from github url ---
download_binary() {
  if [ -n "${INSTALL_ACORN_COMMIT}" ]; then
    BIN_URL=${STORAGE_URL}/acorn${SUFFIX}-${INSTALL_ACORN_COMMIT}
  else
    BIN_URL=${GITHUB_URL}/download/${VERSION_ACORN}/acorn${SUFFIX}
  fi
  info "Downloading binary ${BIN_URL}"
  download ${TMP_BIN} ${BIN_URL}
}

# --- verify downloaded binary hash ---
verify_binary() {
  info "Verifying binary download"
  HASH_BIN=$(shasum -a 256 ${TMP_BIN})
  HASH_BIN=${HASH_BIN%%[[:blank:]]*}
  if [ "${HASH_EXPECTED}" != "${HASH_BIN}" ]; then
    fatal "Download sha256 does not match ${HASH_EXPECTED}, got ${HASH_BIN}"
  fi
}

# --- setup permissions and move binary to system directory ---
setup_binary() {
  chmod 775 ${TMP_BIN}
  info "Installing acorn to ${BIN_DIR}/acorn"
  $SUDO chown root:root ${TMP_BIN}
  $SUDO mv -f ${TMP_BIN} ${BIN_DIR}/acorn
}

# --- download and verify acorn ---
download_and_verify() {
  if can_skip_download; then
     info 'Skipping acorn download and verify'
     verify_acorn_is_executable
     return
  fi

  setup_verify_arch
  verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
  setup_tmp
  get_release_version
  download_hash

  if installed_hash_matches; then
    info 'Skipping binary downloaded, installed acorn matches hash'
    return
  fi

  download_binary
  verify_binary
  setup_binary
}

# --- get hashes of the current acorn bin and service files
get_installed_hashes() {
  $SUDO shasum -a 256 ${BIN_DIR}/acorn ${FILE_ACORN_SERVICE} ${FILE_ACORN_ENV} 2>&1 || true
}

# --- run the install process --
{
  setup_env "$@"
  download_and_verify
}
