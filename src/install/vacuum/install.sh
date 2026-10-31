#!/bin/bash
#
# Installs vacuum, the OpenAPI linter, for the install_vacuum command, verified
# against the checksum table in this file before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (vacuum only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# openapi-orb installs several tools, so it has one such script per tool, in
# src/install/<tool>/.
#
# Add the checksums for a new release with:
#   src/install/vacuum/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing vacuum needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="openapi-orb-vacuum"
TOOL_NAME="vacuum"
TOOL_BINARY="vacuum"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME. Not bin, like most juburr orbs: no
# image puts this directory on the PATH, so the install puts it first, ahead
# of any vacuum an image or a project ships.
TOOL_DEFAULT_INSTALL_DIR=".openapi-orb/bin"

# tool_asset_name VERSION ARCH: the release asset to download. vacuum names
# amd64 x86_64.
tool_asset_name() {
    case "$2" in
        amd64) printf 'vacuum_%s_linux_x86_64.tar.gz\n' "$1" ;;
        *) printf 'vacuum_%s_linux_%s.tar.gz\n' "$1" "$2" ;;
    esac
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf '%s/daveshanley/vacuum/releases/download/v%s/%s\n' "${OA_DOWNLOAD_BASE_URL:-https://github.com}" "$1" "$3"
}

# tool_archive_member VERSION ARCH: the binary's path inside the asset. The
# checksum table holds the SHA-512 of that file.
tool_archive_member() {
    printf 'vacuum\n'
}

# tool_version BINARY: prints the installed version without using the
# network. vacuum reads a vacuum.conf.* from the working directory and from
# $XDG_CONFIG_HOME (or ~/.config), and VACUUM_* variables, even for its
# version, so a broken one could fail the smoke test: it runs from / with
# neither.
tool_version() {
    local name unset=()
    while IFS= read -r name; do
        if [[ "${name}" == VACUUM_* ]]; then
            unset+=(-u "${name}")
        fi
    done < <(compgen -e)
    (cd / && env ${unset[@]+"${unset[@]}"} XDG_CONFIG_HOME=/nonexistent "$1" version)
}

# >>> openapi-orb install helpers >>>
# Identical in every tool definition of openapi-orb (uv, vacuum, oasdiff), so
# change them in all of them together. They run inside the shared install
# logic, through tool_install, and only after orb_init has read the
# parameters.

# oa_download_base_url DEFAULT: sets OA_DOWNLOAD_BASE_URL from the
# download_base_url parameter, which replaces DEFAULT (https://github.com) in
# the download URL, so the same file comes from an internal mirror such as
# Artifactory, Nexus or S3. The checksum table, not the mirror, decides what
# is installed.
oa_download_base_url() {
    local authority
    OA_DOWNLOAD_BASE_URL=$(orb_subst "${PARAM_DOWNLOAD_BASE_URL:-}")
    OA_DOWNLOAD_BASE_URL=${OA_DOWNLOAD_BASE_URL%/}
    if [[ -z "${OA_DOWNLOAD_BASE_URL}" ]]; then
        return 0
    fi
    # Credentials in the URL would show in the log and on curl's command
    # line, so they are refused before the URL is printed anywhere.
    authority=${OA_DOWNLOAD_BASE_URL#*://}
    if [[ "${authority%%/*}" == *@* ]]; then
        orb_die "download_base_url must not hold credentials (user:password@ before the host): they would show in the log and on curl's command line."
    fi
    # Nor can a query or fragment, which can hold a token too, and would end
    # up in the middle of every download URL.
    if [[ "${OA_DOWNLOAD_BASE_URL}" == *[?#]* ]]; then
        orb_die "download_base_url must not have a query or fragment (? or #): it could hold a token, which would show in the log."
    fi
    if [[ ! "${OA_DOWNLOAD_BASE_URL}" =~ ^https://[^[:space:]\"\'\<\>\\]+$ ]]; then
        orb_die "download_base_url must be an https:// URL, not '${OA_DOWNLOAD_BASE_URL}'."
    fi
    orb_info "  download mirror:  ${OA_DOWNLOAD_BASE_URL} (in place of $1)"
}

# oa_install_record: writes what was installed, and how, beside the binary
# (.<binary>.install.json), which the commands' run records include when it
# describes the binary they ran: the release, the asset and its checksum, the
# verify_checksums mode, whether the checksum table listed the release, and
# the binary's SHA-512.
oa_install_record() {
    local file="${ORB_BIN_DIR}/.${TOOL_BINARY}.install.json" sha512="" verified=false
    if command -v sha512sum > /dev/null 2>&1; then
        sha512=$(sha512sum "${ORB_BIN_DIR}/${TOOL_BINARY}" | awk '{ print $1 }')
    fi
    if [[ -n "${ORB_EXPECTED_SHA512:-}" && "${ORB_VERIFY_CHECKSUMS}" != false ]]; then
        verified=true
    fi
    if ! orb_temp_beside "${file}" || ! printf '{"tool":"%s","version":"%s","arch":"%s","asset":"%s","asset_sha512":"%s","verify_checksums":"%s","verified":%s,"binary_sha512":"%s"}\n' \
        "${TOOL_NAME}" "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}" "${ORB_EXPECTED_SHA512:-}" \
        "${ORB_VERIFY_CHECKSUMS}" "${verified}" "${sha512}" > "${ORB_TEMP}" || ! mv -f "${ORB_TEMP}" "${file}"; then
        orb_warn "Could not write ${file}; run records will not say how ${TOOL_NAME} was installed."
    fi
}
# <<< openapi-orb install helpers <<<

# Installs the release binary, from the mirror when download_base_url is set.
tool_install() {
    oa_download_base_url https://github.com
    orb_install_binary
    oa_install_record
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers: the vacuum binary
# inside the release archive.
#
# The table starts at 0.30.0. Every release from 0.29.10 on signs its
# checksums.txt with Sigstore, which install_hash.sh verifies; 0.34.0 and
# 0.35.3 were tagged but never released. A release goes in once it is seven
# days old.
declare -A sha512sums=(
    ["0.35.1/amd64"]="e3baf50c3d5b838d800b8e5a01e13a42e7e7aa01910897e54c57c30d4267ac218ce786534d955ee8b83e5d6e34ad2e15750ed95acceb23de926f4813912fae28"
    ["0.35.1/arm64"]="69c2e801134bb0850991d8f0a3bc836c9d0aad8045c1c9e16b0323bc62a677e0f769a55e5ccfbd5f67fb464eba237ee9a786608a734f1228d47c3910a922e66c"
    ["0.35.0/amd64"]="8989606070381a20fff539d130f1a82c0be3ac0534120ec0d47686feec5ebfc0857038d9c54620ff8969a0126eaf083d4cff2fa7165ac8158f6174cc19bd1e69"
    ["0.35.0/arm64"]="a8b40a61982f7adfe468e980a3134f1e5876fd74397e9f37d064933f6a164eb31475c0c59bce22c66499734db4a9833db90e724924a2ca82cca9839e2c2bbb7d"
    ["0.33.2/amd64"]="75a8e7238802f19f254af2a9aa98849c1023190096a3ba3174acdddbf61775c61cead3e3a8328d92ad707ef9eed633f9172b44e1254daae422b6af7ab5c3b483"
    ["0.33.2/arm64"]="f51936bb2dcb61f01a2dd4be2039bcd5f20c4a5c9aabfa5467a52e4e5ae5857dc091580bd3cd037e4a221f19fe0f2493bc0a66bc9a1a1b66922eef8de5ab6e63"
    ["0.33.1/amd64"]="37d2f0c10c46a5267ff7b454f984be268bf484c3a05ba66536ea072cf83197c808dddd448e8a951a72d64765d96e33bb1f1019d1e63fdf03d881ab88519a3dd5"
    ["0.33.1/arm64"]="0d0f2258e13c582f2173689094979a4b13c705d1b05a95cb8c5523cb62c8bc895c9509f20cebd781a7c3e9dca75d3b6c8e78c749ecbbf7eb48331f6956260fa1"
    ["0.33.0/amd64"]="5a11eec86f02dee0ce1bb8e8fbf2ebb3c8cd7705ffd67ef67c2973cbe0ce3053a4a83b528e23132a4c48bc81c00ec430d298e3daa3eb338456078c9dc66f4257"
    ["0.33.0/arm64"]="cf8e7a7849985c434611ec8ea4c8e0c75dc5c16a966272a932bb98d9321ad0f79c1903404bae6b8ae04d6ba43532ecbf7a7a7488b7c93235c5c6b60a4d459b61"
    ["0.32.0/amd64"]="6a6c1828e54f94ff5134940d82a1d785620f2ac201221998f65365112b9309b4f7c56d3591aa4e7799401cc50557fca805083558117ccd67879245bb112909af"
    ["0.32.0/arm64"]="1c597fbb6ccac23ca793bd7e8f7e3f77af8e6713f142d3c4a6d596df10b09baf95aecd75d919edad94ec98656dda38abf7c4902b64d11c114c55a87a170dc6fb"
    ["0.31.0/amd64"]="cecac3cdffea1663455ccd438bd3da268019ca00629c8cc51e6209ab9930df0927927ee8c9988de556526239f2f6de528a99e2ab375c8909d7157b258af28baa"
    ["0.31.0/arm64"]="de612de9038e67ad92a92c006f4a6f036bbb92777b47e3d365872f3c76e7e06769cde303f9d2efde97f96f43468bd3f557edae73f3cd60cb09f13c7409ac5d73"
    ["0.30.6/amd64"]="1757ef410fb71b83af03d7d9809deee2187b56a7e262df80a59e06b605e81ba6387b89225c5a95f1e2bbb06218be3eb61cee408660a3a1ad13026def5e3a177e"
    ["0.30.6/arm64"]="2c69d65cbf35882fbd19c5759aedc4af92f59c6f2eda2b6149f44ff638149555225208609db2b558fbb054be2792b247ac2597e6fa7a1a9a279ce7fbad0ee903"
    ["0.30.5/amd64"]="35e8567303969c790f2c4f75c47ad4507926057d6a84b76ebe3014c5b9da51f091e5384ab1bfc210b3eb0444b734c5ae3c95aa98fea8928d55f22429df869504"
    ["0.30.5/arm64"]="eb9715530049e20b2fa84c36d488b481ad12894e2f030d8d98895dfb7cfc75ce3f17ba903471710473c57c686d32eb6d8291ed826e98bdaba3e0cd25933d1869"
    ["0.30.4/amd64"]="93fff0fb6752bc74fed4353aa8f006b6d331867a52c7217be5aba55964b34e3ed7c04581b574faf1a5ca8677d7958daaacef50cfd4e2c19ea0bfbfc1328b5009"
    ["0.30.4/arm64"]="7c4cdea5b690c8eb51fd5017f8dbefe944e897e8d333ccf960423215a9eae2ffddd45261e7d3515f326336ba95e4366ca84f97f92a42de98e5cb18e6cf855b9c"
    ["0.30.3/amd64"]="8584599534e625e3313b293ff303fc7deb524cf9253ea8ff8a0269e72c0d0c937a9734f8aa8e9f869707dc13b89c4253a0482cdd2fa5c476a6a6f814a7bc6614"
    ["0.30.3/arm64"]="bd2ded3b24482d1a7e8bb9427c7ee608ff8b4b1bc35ee4cfb34e80a84a0286cf6fbc9ee0771944bb538a994e7ca571687a00738365464651ef7660aad6d7a1cb"
    ["0.30.2/amd64"]="4366078b945817500d803b3028d68e2556f7d3f6061811cb69329ca2981098357177e2857d96d050c0b3b8e57817e34cfde06e6d40a71f17079f31e358ce044e"
    ["0.30.2/arm64"]="c72855254a4071d71409c2fee194ae90a5bdcc8c402644c3ece777cb2f5b4a15b704a4bc9323ce2c6d51d10e7dddcce527fc81518776fe81e581fb0ea0730941"
    ["0.30.1/amd64"]="c9ffe266dfc6bdced513280423f5a86f8bb3821e7e9363af958e3a084ff523aa319ef52f23e8e15dcc8331f96d62f746a4c45bf8e9e945105049a00774fd11b9"
    ["0.30.1/arm64"]="cf582c9d910d126da5c5226f9d5a1366d43e69d6a8a812938353250b7f4f074999690aa3d15801c18144e07ea6ac3003f20005a3028780206352285afc36c431"
    ["0.30.0/amd64"]="0f043080e7890d345f3c26fca2bd9c12282b18e2109d965cfae7540a6bf6418fb8aab3d2d764a3bf5cfa4dbf057caf74680651d86d080ca25815f1a4c0599e3a"
    ["0.30.0/arm64"]="01a9c05ab04d8d086e812ef49196a30f563892493c3f7a80c07f72b61ab1cd96bbf781c442d688269f47d7eb1697f8c892feaddf66ed84b3b4b205da0882dd89"
)
# <<< checksum table <<<

orb_install_main
