#!/bin/bash

# Shared helpers for the openapi-orb commands. Each command passes this file
# to its step as SCRIPT_OPENAPI_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions and variables.

# oa_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-" would
# be parsed as a flag. Without the CircleCI CLI (GitHub Actions and local
# runs), the value is used as is.
oa_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# oa_bool NAME VALUE: prints true or false. CircleCI passes boolean parameters
# as 1 or 0; GitHub Actions and local callers use true or false.
oa_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# oa_words PARAMETER VALUE: sets OA_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool as
# text inside quotes, and fails the step outside them.
oa_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    OA_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# oa_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, setting
# BASH_REMATCH. In other locales a range such as [a-z] can match letters such
# as é (cimg images set LC_ALL=en_US.UTF-8), so checks with ranges use this.
oa_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# oa_list PARAMETER VALUE: sets OA_LIST to VALUE, with environment variables
# expanded, split on commas and spaces.
oa_list() {
    local value
    OA_LIST=()
    value=$(oa_subst "$2")
    if [[ "${value}" == *$'\n'* ]]; then
        echo "ERROR: ${1} must be separated by commas or spaces, not newlines." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -a OA_LIST <<< "${value//,/ }"
}

# oa_require_jq: stops the step unless jq, which the reports are built with,
# is on the PATH.
oa_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is not on the PATH, and this command needs it to write its reports." >&2
        echo "  CircleCI's cimg images and GitHub's hosted runners have it; elsewhere, install jq in an earlier step." >&2
        exit 1
    fi
}

# oa_output DIR NAME: checks output_dir and report_name, creates DIR, and sets
# OA_OUT to DIR and OA_BASE to the path every report of this run starts with.
oa_output() {
    if [[ "$1" != /* || "$1" == *$'\n'* ]]; then
        echo "ERROR: output_dir must be an absolute path, not '$1'." >&2
        exit 1
    fi
    if ! oa_match "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "ERROR: report_name must be letters, digits, '.', '_' and '-', not '$2'." >&2
        exit 1
    fi
    if ! mkdir -p "$1"; then
        echo "ERROR: Could not create output_dir $1." >&2
        exit 1
    fi
    OA_OUT=${1%/}
    OA_OUT=${OA_OUT:-/}
    # shellcheck disable=SC2034 # read by the script that evals this file
    OA_BASE="${OA_OUT%/}/$2"
}

# oa_uint PARAMETER VALUE [MIN]: stops the step unless VALUE is a whole number
# of at least MIN (default 0).
oa_uint() {
    if ! oa_match "$2" '^[0-9]{1,9}$' || ((10#$2 < ${3:-0})); then
        echo "ERROR: ${1} must be a whole number of at least ${3:-0}, not '$2'." >&2
        exit 1
    fi
}

# oa_junit FILE SUITE CASES: writes JUnit XML to FILE, for CircleCI's Tests
# tab or any other JUnit reader, from CASES, a JSON array of test cases:
#   {"classname": ..., "name": ..., "status": "failed" | "skipped" | "passed",
#    "message": ..., "detail": ...}
# A run with no cases gets one passing case, so the tab shows it ran.
oa_junit() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg suite "$2" '
        (if length == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else . end) as $cases
        | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<testsuites>",
          "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
          ($cases[] |
            "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
            + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
               elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
               else "" end)
            + "</testcase>"),
          "  </testsuite>",
          "</testsuites>"
    ' <<< "$3" > "$1"
}

# oa_gate FINDINGS REPORT_ONLY SUMMARY: ends a check. Without findings it
# succeeds. With findings it fails with SUMMARY, unless REPORT_ONLY is true,
# when it only warns: the reports are written either way.
oa_gate() {
    if [[ "$1" == false ]]; then
        echo "Passed: $3"
        exit 0
    fi
    if [[ "$2" == true ]]; then
        echo "WARN: $3" >&2
        echo "WARN: report_only is true, so this step passes. The reports are in ${OA_OUT}." >&2
        exit 0
    fi
    echo "ERROR: $3" >&2
    echo "  The reports are in ${OA_OUT}. Set report_only to true to report findings without failing." >&2
    exit 1
}

# oa_plural COUNT SINGULAR PLURAL: prints COUNT and the word that goes with
# it, such as "1 file" or "2 files".
oa_plural() {
    if [[ "$1" -eq 1 ]]; then
        printf '%s %s\n' "$1" "$2"
    else
        printf '%s %s\n' "$1" "$3"
    fi
}

# oa_tail FILE [LINES]: prints the last LINES (default 40) lines of FILE to
# stderr, indented, to show why a tool failed. A Python traceback ends with
# the exception, so the tail holds it.
oa_tail() {
    tail -n "${2:-40}" "$1" | sed 's/^/  /' >&2
}

# oa_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV (on GitHub Actions, the action passes it on through
# GITHUB_ENV).
oa_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# oa_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
oa_env_var_name() {
    if ! oa_match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# oa_json_is FILE FILTER [JQ_OPTION...]: whether FILE holds one JSON value for
# which FILTER is true. It compares jq's output instead of using -e, since jq
# 1.6 (as on Ubuntu 22.04 and some cimg images) exits 0 with -e when the file
# is empty, as a tool that failed before writing its report leaves it.
oa_json_is() {
    local file=$1 filter=$2 options=()
    if [[ $# -gt 2 ]]; then
        options=("${@:3}")
    fi
    [[ "$(jq -c ${options[@]+"${options[@]}"} "(${filter}) | if . then true else false end" "${file}" 2> /dev/null)" == true ]]
}

# oa_sha256 FILE: prints FILE's SHA-256.
oa_sha256() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

# oa_url_public URL: prints URL without the userinfo, query and fragment,
# which can hold credentials, so it can go in a log or an artifact.
oa_url_public() {
    local url=$1
    if [[ "${url}" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)?([^?#]*) ]]; then
        printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${url%%[?#]*}"
    fi
}

# oa_ci_json: describes the CI job this runs in, for run records: a CircleCI
# job or a GitHub Actions run, or null elsewhere.
oa_ci_json() {
    if [[ -n "${CIRCLE_BUILD_URL:-}" ]]; then
        jq -cn --arg url "${CIRCLE_BUILD_URL}" --arg sha "${CIRCLE_SHA1:-}" --arg job "${CIRCLE_JOB:-}" \
            --arg repo "${CIRCLE_PROJECT_USERNAME:-}${CIRCLE_PROJECT_REPONAME:+/${CIRCLE_PROJECT_REPONAME}}" \
            '{provider: "circleci", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        jq -cn --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}/attempts/${GITHUB_RUN_ATTEMPT:-1}" \
            --arg sha "${GITHUB_SHA:-}" --arg job "${GITHUB_JOB:-}" --arg repo "${GITHUB_REPOSITORY:-}" \
            '{provider: "github-actions", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    else
        echo null
    fi
}

# oa_tool_json PATH VERSION: describes a tool that ran for the run record:
# its SHA-512, and how the orb installed it, from the install record beside
# it when that record describes this very file.
oa_tool_json() {
    local sha="" install="null" entry
    if [[ -n "$1" && -f "$1" ]]; then
        # Without sha512sum the record says so with a null SHA-512, as oa_tool
        # only warns.
        sha=$(sha512sum -- "$1" 2> /dev/null | awk '{ print $1 }') || sha=""
        entry="$(dirname "$1")/.${1##*/}.install.json"
        # shellcheck disable=SC2016 # jq program, not shell
        if [[ -f "${entry}" ]] && oa_json_is "${entry}" '.binary_sha512 == $sha' --arg sha "${sha}"; then
            install=$(jq -c 'del(.binary_sha512)' "${entry}")
        fi
    fi
    jq -cn --arg name "${1##*/}" --arg path "$1" --arg version "$2" --arg sha "${sha}" --argjson install "${install}" \
        '{name: $name, path: $path, version: $version, sha512: (if $sha == "" then null else $sha end), install: $install}'
}

# oa_tool NAME: sets OA_TOOL to NAME's path on the PATH, or stops the step
# saying how to install it. Warns when it is not the binary this orb's install
# verified, as the install record beside it says, such as a copy that came
# with the image.
oa_tool() {
    local record sha
    if ! OA_TOOL=$(command -v "$1"); then
        echo "ERROR: $1 is not on the PATH. Install it in an earlier step with this orb's install (tools: $1)," >&2
        echo "  or with install_$1." >&2
        exit 1
    fi
    record="$(dirname "${OA_TOOL}")/.$1.install.json"
    sha=$(sha512sum -- "${OA_TOOL}" 2> /dev/null | awk '{ print $1 }') || sha=""
    # shellcheck disable=SC2016 # jq program, not shell
    if [[ -n "${sha}" && -f "${record}" ]] && oa_json_is "${record}" '.binary_sha512 == $sha' --arg sha "${sha}"; then
        if [[ "$(jq -r '.verified' "${record}")" != true ]]; then
            echo "WARN: ${OA_TOOL} was installed without verifying it against this orb's checksums (verify_checksums)." >&2
        fi
        return 0
    fi
    echo "WARN: ${OA_TOOL} is not the $1 this orb's install verified." >&2
    echo "WARN: Install $1 with this orb's install, and put its install_path first on the PATH, to run a verified one." >&2
}

# oa_specs PARAMETER VALUE: sets OA_FILES to the documents VALUE names,
# separated by commas or spaces, each a path or a glob relative to the working
# directory; or, when VALUE is empty, to the first of the usual names that
# exists in the working directory (openapi.yaml, openapi.yml, openapi.json,
# swagger.yaml, swagger.yml, swagger.json). Finding none fails the step.
oa_specs() {
    local name
    oa_list "$1" "$2"
    if [[ ${#OA_LIST[@]} -eq 0 ]]; then
        for name in openapi.yaml openapi.yml openapi.json swagger.yaml swagger.yml swagger.json; do
            if [[ -f "${name}" ]]; then
                OA_LIST=("${name}")
                echo "${1}: none given, so ${name} is checked."
                break
            fi
        done
        if [[ ${#OA_LIST[@]} -eq 0 ]]; then
            echo "ERROR: ${1} is empty, and $(pwd) has no openapi.yaml, openapi.yml, openapi.json, swagger.yaml," >&2
            echo "  swagger.yml or swagger.json. Name the documents to check in ${1}." >&2
            exit 1
        fi
    fi
    for name in "${OA_LIST[@]}"; do
        if [[ "${name}" == -* || "${name}" == *$'\n'* ]]; then
            echo "ERROR: ${1} can't name a file that starts with '-': '${name}'. Write it as ./${name}." >&2
            exit 1
        fi
    done
    oa_files "$1"
}

# oa_git_top: sets OA_TOP to the top of the git checkout the working
# directory is in, and OA_PREFIX to the working directory's path below it
# (empty, or ending in /), or stops the step.
oa_git_top() {
    if ! OA_TOP=$(git rev-parse --show-toplevel 2> /dev/null) || [[ -z "${OA_TOP}" ]]; then
        echo "ERROR: This command compares git revisions, and $(pwd) is not in a git checkout." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    OA_PREFIX=$(git rev-parse --show-prefix)
}

# oa_from_top PATH: prints PATH, absolute or relative to the working
# directory, as a path relative to OA_TOP, without following the symbolic
# links in PATH. The working directory is taken by its physical path, as git
# takes the top's. Stops the step when PATH is outside the checkout.
oa_from_top() {
    local path=$1
    if [[ "${path}" != /* ]]; then
        path="$(pwd -P)/${path}"
    fi
    path=$(realpath -ms --relative-to="${OA_TOP}" -- "${path}")
    if [[ "${path}" == .. || "${path}" == ../* || "${path}" == /* ]]; then
        echo "ERROR: $1 is outside the git checkout ${OA_TOP}." >&2
        exit 1
    fi
    printf '%s\n' "${path}"
}

# The long options of oasdiff's diff and changelog that take a value as the
# next word, which a check of extra_args must not read as a document.
# shellcheck disable=SC2034 # read by the scripts that eval this file
OA_OASDIFF_VALUE_OPTIONS=" match-path unmatch-path filter-extension prefix-base prefix-revision strip-prefix-base strip-prefix-revision exclude-extensions max-circular-dep lang deprecation-days-beta deprecation-days-stable attributes stability-level config "

# oa_rank KIND LEVEL: prints the rank of a severity name, higher is worse:
# for vacuum (KIND lint) hint 0, info 1, warn 2, error 3; for oasdiff (KIND
# oasdiff) info 1, warn 2, error 3. Unknown names print nothing.
oa_rank() {
    case "$1:$2" in
        lint:hint) echo 0 ;;
        lint:info | oasdiff:info) echo 1 ;;
        lint:warn | oasdiff:warn) echo 2 ;;
        lint:error | oasdiff:error) echo 3 ;;
    esac
}

# oa_oasdiff_openapi LABEL SPEC: stops the step unless oasdiff reads SPEC (a
# path, or a git revision as REV:PATH, from OA_RUN_DIR) as an OpenAPI 3
# document. oasdiff loads any YAML mapping, a Swagger 2.0 document included,
# as an empty specification, which compares as if every operation were added
# or removed; its validate command reports such a document as having no
# openapi field (openapi-required).
oa_oasdiff_openapi() {
    local out code=0 word load=()
    # validate reads the documents before the comparison does, so it gets the
    # comparison's --allow-external-refs: with false, neither fetches remote
    # references.
    for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
        case "${word}" in
            --allow-external-refs | --allow-external-refs=*) load+=("${word}") ;;
        esac
    done
    out=$(mktemp)
    (cd "${OA_RUN_DIR:-.}" && "${OA_TOOL}" validate --format json ${load[@]+"${load[@]}"} -- "$2") > "${out}" 2> "${out}.err" || code=$?
    if [[ "${code}" -ne 0 && "${code}" -ne 1 ]] || ! oa_json_is "${out}" 'type == "array"'; then
        cat "${out}.err" "${out}" 2> /dev/null | tail -n 20 | sed 's/^/  /' >&2
        rm -f "${out}" "${out}.err"
        echo "ERROR: oasdiff could not read the ${1} ($2), exit code ${code}." >&2
        exit 1
    fi
    if oa_json_is "${out}" 'any(.[]; .id == "openapi-required")'; then
        rm -f "${out}" "${out}.err"
        echo "ERROR: The ${1} ($2) is not an OpenAPI 3 document: it has no openapi field. oasdiff compares" >&2
        echo "  OpenAPI 3.0, 3.1 and 3.2 documents only; convert a Swagger 2.0 document first." >&2
        exit 1
    fi
    rm -f "${out}" "${out}.err"
}

# oa_toml_string VALUE: VALUE as a TOML basic string, quotes included.
oa_toml_string() {
    local value=${1//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/\\t}
    printf '"%s"\n' "${value}"
}

# oa_args_json ARG...: the arguments as a JSON array. They pass through jq
# NUL-separated, so arguments that start with "-" never reach jq's own option
# parsing, and a URL among them loses its userinfo, query and fragment.
oa_args_json() {
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    # Ended by a word rather than a NUL, which jq 1.6 drops from the end of
    # raw input.
    { printf '%s\0' "$@"; printf 'end'; } | jq -Rsc 'split("\u0000") | .[:-1]
        | map(gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/?#\\s]*@"; "\(.scheme)")
            | gsub("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^?#\\s]*)[?#]\\S*"; "\(.url)"))'
}

# oa_show_command ARG...: the arguments as one line to log, each quoted for
# the shell only when it needs it, and URLs stripped as oa_args_json strips
# them.
oa_show_command() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi
    oa_args_json "$@" | jq -r 'map(if test("^[A-Za-z0-9_./:=@%+,-]+$") then . else @sh end) | join(" ")'
}

# oa_files PARAMETER: sets OA_FILES to the files OA_LIST names, each a path
# or a glob relative to the working directory. A pattern that matches no
# file fails the step: a typo would otherwise check nothing.
oa_files() {
    local pattern match matches
    OA_FILES=()
    for pattern in ${OA_LIST[@]+"${OA_LIST[@]}"}; do
        matches=0
        while IFS= read -r match; do
            [[ -n "${match}" ]] || continue
            OA_FILES+=("${match}")
            matches=$((matches + 1))
        done < <(compgen -G "${pattern}" | LC_ALL=C sort || true)
        if [[ "${matches}" -eq 0 || ( "${pattern}" != *[*?[]* && ! -f "${pattern}" ) ]]; then
            echo "ERROR: $1 names '${pattern}', but there is no such file in $(pwd)." >&2
            exit 1
        fi
    done
}

# oa_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED: writes a run record,
# the JSON document schemas/run-record.v1.json describes, saying what exactly
# this command checked, so a reviewer can tell without running it again. It
# reads what the command set:
#   OA_TOOL          the tool that ran, if any (the script install put on the PATH)
#   OA_TOOL_VERSION  what it reports as its version
#   OA_ARGS          the arguments it ran with, as an array
#   OA_INPUTS        "role:path" entries, such as "lockfile:uv.lock"
#   OA_REPORTS       the report files written
#   OA_COUNTS        a JSON object of the command's counts
#   OA_RESULTS       a JSON array of per-item results, such as one per input
#   OA_TARGET_JSON   the environment checked, as JSON, if any
# OUTCOME is passed, findings, findings-reported (findings with report_only)
# or error.
oa_run_record() {
    local file=$1 entry path role sha inputs="[]" reports="[]" args
    for entry in ${OA_INPUTS[@]+"${OA_INPUTS[@]}"}; do
        role=${entry%%:*}
        path=${entry#*:}
        sha=""
        if [[ -f "${path}" ]]; then
            sha=$(oa_sha256 "${path}")
        fi
        if [[ -d "$(dirname "${path}")" ]]; then
            path=$(cd "$(dirname "${path}")" && pwd)/${path##*/}
        fi
        inputs=$(jq -c --arg role "${role}" --arg path "${path}" --arg sha "${sha}" \
            '. + [{role: $role, path: $path, sha256: (if $sha == "" then null else $sha end)}]' <<< "${inputs}")
    done
    for path in ${OA_REPORTS[@]+"${OA_REPORTS[@]}"}; do
        if [[ -f "${path}" ]]; then
            reports=$(jq -c --arg path "${path}" --arg sha "$(oa_sha256 "${path}")" '. + [{path: $path, sha256: $sha}]' <<< "${reports}")
        fi
    done
    args=$(oa_args_json ${OA_ARGS[@]+"${OA_ARGS[@]}"})
    if ! jq -n --arg command "$2" --arg outcome "$3" --argjson code "$4" --arg started "$5" \
        --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" --argjson ci "$(oa_ci_json)" \
        --argjson tool "$(if [[ -n "${OA_TOOL:-}" ]]; then oa_tool_json "${OA_TOOL}" "${OA_TOOL_VERSION:-}"; else echo null; fi)" \
        --argjson target "${OA_TARGET_JSON:-null}" \
        --argjson inputs "${inputs}" --argjson reports "${reports}" --argjson counts "${OA_COUNTS:-null}" \
        --argjson results "${OA_RESULTS:-null}" --argjson args "${args}" '{
            schema: "https://github.com/juburr/openapi-orb/blob/main/schemas/run-record.v1.json",
            command: $command, outcome: $outcome, exit_code: $code,
            started_at: $started, finished_at: $finished, ci: $ci, working_directory: $cwd,
            tool: $tool, arguments: $args, target: $target,
            inputs: $inputs, counts: $counts, results: $results, reports: $reports
        }' > "${file}"; then
        echo "WARN: Could not write the run record ${file}." >&2
        return 0
    fi
    echo "Run record: ${file}"
}
