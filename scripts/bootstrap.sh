#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$PROJECT_ROOT/.tools"
BIN_DIR="$TOOLS_DIR/bin"
VENV_DIR="$TOOLS_DIR/venv"
PYTHON_BIN="$VENV_DIR/bin/python"
TOFU_VERSION="${TOFU_VERSION:-1.12.0}"
JQ_VERSION="${JQ_VERSION:-1.7.1}"
AUTO_YES=0
NEED_DOCKER=0

usage() {
  cat <<USAGE
Usage: $0 [--batch] [--yes]

  --batch  Also verify Docker and Docker Buildx.
  --yes    Approve supported package-manager installations.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch) NEED_DOCKER=1; shift ;;
    --yes) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

mkdir -p "$BIN_DIR"
TMP_DIR="$TOOLS_DIR/tmp"
mkdir -p "$TMP_DIR"
export TMPDIR="$TMP_DIR"

confirm_install() {
  local reason="$1"
  if [[ "$AUTO_YES" -eq 1 ]]; then
    return
  fi
  if [[ ! -t 0 ]]; then
    die "$reason. Install the missing packages manually or rerun ./scripts/bootstrap.sh --yes."
  fi
  printf "%s Install now? [y/N] " "$reason"
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Installation cancelled."
}

run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "Administrator access is required to install host packages."
  fi
}

install_host_packages() {
  local reason="$1"
  confirm_install "$reason"
  case "$host_os" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get update
        run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl unzip python3 python3-venv gzip coreutils
      elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y ca-certificates curl unzip python3 gzip coreutils
      elif command -v yum >/dev/null 2>&1; then
        run_as_root yum install -y ca-certificates curl unzip python3 gzip coreutils
      else
        die "No supported Linux package manager found. Install curl, unzip, python3, gzip, and base64 manually."
      fi
      ;;
    Darwin)
      command -v brew >/dev/null 2>&1 || die "Homebrew is required to install missing macOS command-line packages. Install it from https://brew.sh/."
      brew install curl unzip python
      ;;
  esac
}

install_host_requirements() {
  local command
  local missing=()
  for command in curl unzip python3 gzip base64; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    install_host_packages "Missing host commands: ${missing[*]}."
  fi
  for command in curl unzip python3 gzip base64; do
    command -v "$command" >/dev/null 2>&1 || die "Required host command is still unavailable: $command"
  done
}

make_temp_dir() {
  mktemp -d "$TMP_DIR/1trc-tools.XXXXXX" 2>/dev/null || mktemp -d -t 1trc-tools
}

binary_works() {
  local binary="$1"
  shift
  [[ -x "$binary" ]] && "$binary" "$@" >/dev/null 2>&1
}

host_os="$(uname -s)"
host_arch="$(uname -m)"

case "$host_os" in
  Linux)
    tofu_os="linux"
    jq_os="linux"
    ;;
  Darwin)
    tofu_os="darwin"
    jq_os="macos"
    ;;
  *)
    echo "Unsupported operating system: $host_os" >&2
    exit 1
    ;;
esac

case "$host_arch" in
  x86_64|amd64)
    aws_arch="x86_64"
    tofu_arch="amd64"
    jq_arch="amd64"
    ;;
  aarch64|arm64)
    aws_arch="aarch64"
    tofu_arch="arm64"
    jq_arch="arm64"
    ;;
  *)
    echo "Unsupported architecture: $host_arch" >&2
    exit 1
    ;;
esac

install_host_requirements

install_tofu() {
  if binary_works "$BIN_DIR/tofu" version; then
    return
  fi
  if [[ -e "$BIN_DIR/tofu" ]]; then
    echo "Removing incompatible local OpenTofu binary: $BIN_DIR/tofu"
    rm -f "$BIN_DIR/tofu"
  fi

  local tmpdir url
  tmpdir="$(make_temp_dir)"
  url="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_${tofu_os}_${tofu_arch}.zip"
  echo "Installing OpenTofu $TOFU_VERSION for $host_os/$host_arch into $BIN_DIR"
  curl -fsSL "$url" -o "$tmpdir/tofu.zip"
  unzip -q "$tmpdir/tofu.zip" -d "$tmpdir/tofu"
  install -m 0755 "$tmpdir/tofu/tofu" "$BIN_DIR/tofu"
  rm -rf "$tmpdir"
}

install_aws_cli() {
  if binary_works "$BIN_DIR/aws" --version; then
    return
  fi
  if [[ -e "$BIN_DIR/aws" ]]; then
    echo "Removing incompatible local AWS CLI binary: $BIN_DIR/aws"
    rm -f "$BIN_DIR/aws"
  fi

  if command -v aws >/dev/null 2>&1 && aws --version >/dev/null 2>&1; then
    echo "Using existing AWS CLI from PATH: $(command -v aws)"
    return
  fi

  if [[ "$host_os" == "Darwin" ]]; then
    command -v brew >/dev/null 2>&1 || die "AWS CLI v2 is missing. Install Homebrew from https://brew.sh/ or install the official AWS CLI package."
    confirm_install "AWS CLI v2 is missing and can be installed with Homebrew."
    brew install awscli
    aws --version >/dev/null 2>&1 || die "AWS CLI installation did not produce a working aws command."
    return
  fi

  local tmpdir url
  tmpdir="$(make_temp_dir)"
  url="https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip"
  echo "Installing AWS CLI v2 for $host_os/$host_arch into $BIN_DIR"
  curl -fsSL "$url" -o "$tmpdir/awscliv2.zip"
  unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
  "$tmpdir/aws/install" -i "$TOOLS_DIR/aws-cli" -b "$BIN_DIR" --update
  rm -rf "$tmpdir"
}

install_jq() {
  if binary_works "$BIN_DIR/jq" --version; then
    return
  fi
  if [[ -e "$BIN_DIR/jq" ]]; then
    echo "Removing incompatible local jq binary: $BIN_DIR/jq"
    rm -f "$BIN_DIR/jq"
  fi

  if command -v jq >/dev/null 2>&1 && jq --version >/dev/null 2>&1; then
    echo "Using existing jq from PATH: $(command -v jq)"
    return
  fi

  local url
  url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${jq_os}-${jq_arch}"
  echo "Installing jq $JQ_VERSION for $host_os/$host_arch into $BIN_DIR"
  curl -fsSL "$url" -o "$BIN_DIR/jq"
  chmod 0755 "$BIN_DIR/jq"
}

install_python_venv() {
  if ! binary_works "$PYTHON_BIN" --version; then
    if [[ -e "$VENV_DIR" ]]; then
      echo "Removing incompatible project Python environment: $VENV_DIR"
      rm -rf "$VENV_DIR"
    fi
    echo "Creating project Python virtual environment at $VENV_DIR"
    if ! python3 -m venv "$VENV_DIR"; then
      install_host_packages "Python virtual-environment support is missing."
      rm -rf "$VENV_DIR"
      python3 -m venv "$VENV_DIR" || die "Failed to create the project Python virtual environment."
    fi
  fi

  local requirements_file
  requirements_file="$PROJECT_ROOT/requirements.txt"
  if [[ -f "$requirements_file" ]] && grep -Eq "^[[:space:]]*[^#[:space:]]" "$requirements_file"; then
    echo "Installing Python requirements into $VENV_DIR"
    "$PYTHON_BIN" -m pip install -r "$requirements_file"
  fi
}

verify_docker() {
  if [[ "$NEED_DOCKER" -ne 1 ]]; then
    return
  fi
  command -v docker >/dev/null 2>&1 || die "Docker is required for the Batch implementation. Install Docker Desktop or Docker Engine, then rerun this bootstrap."
  docker version >/dev/null 2>&1 || die "Docker is installed but its daemon is not reachable. Start Docker, then retry."
  docker buildx version >/dev/null 2>&1 || die "Docker Buildx is required for the Batch ARM64 image build. Install or enable Buildx, then retry."
}

install_tofu
install_aws_cli
install_jq
install_python_venv
verify_docker

export PATH="$BIN_DIR:$PATH"
echo "Bootstrap complete. Installed/available tools:"
aws --version
"$BIN_DIR/tofu" version | head -n 1
jq --version
"$PYTHON_BIN" --version
