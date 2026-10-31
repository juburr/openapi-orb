#!/bin/bash
#
# Finds the changes to OpenAPI documents that break their clients, with
# oasdiff, for the breaking command: each document as it is in the working
# tree against itself at a base revision (by default the merge base with the
# remote's default branch, or a pull request's base branch on GitHub
# Actions), or against base_file.
#
# oasdiff reads a git revision itself (REV:PATH), $refs to other files
# included, from the same revision, so no checkout of the base is made. It
# runs from the top of the checkout, since a revision's paths are relative to
# it. oasdiff's changelog lists every change with its level (ERR, WARN or
# INFO); breaking changes are WARN and ERR. Those at or above fail_on are
# findings, which fail the step unless report_only is true. oasdiff exits 0,
# or 1 when a configuration file sets fail-on, after a comparison, and 100 or
# more when it couldn't compare, which fails the step either way. So does a
# document that isn't OpenAPI 3: oasdiff loads any YAML mapping as an empty
# specification, which would compare as if every operation were added.

set -euo pipefail

if [[ -z "${SCRIPT_OPENAPI_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_OPENAPI_LIB is not set; run this script through the orb's breaking command." >&2
    exit 1
fi
eval "${SCRIPT_OPENAPI_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The reports an earlier run with this report_name left go first, so a check
# that stops on its inputs leaves none behind to be stored as its own.
REPORT_NAME=$(oa_subst "${PARAM_REPORT_NAME}")
oa_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${OA_BASE}.json"
CHANGELOG="${OA_BASE}.md"
SARIF="${OA_BASE}.sarif"
JUNIT_FILE="${OA_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${OA_BASE}.run-record.json"
rm -f "${REPORT}" "${CHANGELOG}" "${SARIF}" "${JUNIT_FILE}" "${RECORD}"

oa_specs specs "${PARAM_SPECS}"
SPECS=("${OA_FILES[@]}")
BASE_REF=$(oa_subst "${PARAM_BASE_REF}")
MERGE_BASE=$(oa_bool merge_base "${PARAM_MERGE_BASE}")
BASE_SPEC=$(oa_subst "${PARAM_BASE_SPEC}")
BASE_FILE=$(oa_subst "${PARAM_BASE_FILE}")
FAIL_ON=$(oa_subst "${PARAM_FAIL_ON}")
SEVERITY_LEVELS=$(oa_subst "${PARAM_SEVERITY_LEVELS}")
ERR_IGNORE=$(oa_subst "${PARAM_ERR_IGNORE}")
WARN_IGNORE=$(oa_subst "${PARAM_WARN_IGNORE}")
JUNIT=$(oa_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(oa_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(oa_bool report_only "${PARAM_REPORT_ONLY}")
oa_words extra_args "$(oa_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${OA_WORDS[@]+"${OA_WORDS[@]}"})

# --- Parameters ---
case "${FAIL_ON}" in
    error | warn) ;;
    *)
        echo "ERROR: fail_on must be error or warn, not '${FAIL_ON}'." >&2
        exit 1
        ;;
esac
FAIL_RANK=$(oa_rank oasdiff "${FAIL_ON}")
if [[ (-n "${BASE_SPEC}" || -n "${BASE_FILE}") && ${#SPECS[@]} -ne 1 ]]; then
    echo "ERROR: base_spec and base_file name the base of one document, but specs names ${#SPECS[@]}." >&2
    exit 1
fi
if [[ -n "${BASE_FILE}" && ( -n "${BASE_REF}" || -n "${BASE_SPEC}" ) ]]; then
    echo "ERROR: base_file is the base itself, so base_ref and base_spec must be empty with it." >&2
    exit 1
fi
if [[ -n "${BASE_FILE}" && ( "${BASE_FILE}" == -* || ! -f "${BASE_FILE}" ) ]]; then
    echo "ERROR: base_file names '${BASE_FILE}', which is not a file in $(pwd)." >&2
    exit 1
fi
if [[ "${BASE_REF}" == -* || "${BASE_REF}" == *[[:space:]:]* ]]; then
    echo "ERROR: base_ref must name a commit, such as origin/main, not '${BASE_REF}'." >&2
    exit 1
fi
# Files oasdiff reads for its policy are made absolute, since it runs from
# the top of the checkout.
POLICY=()
for entry in severity-levels:"${SEVERITY_LEVELS}" err-ignore:"${ERR_IGNORE}" warn-ignore:"${WARN_IGNORE}"; do
    flag=${entry%%:*}
    file=${entry#*:}
    if [[ -z "${file}" ]]; then
        continue
    fi
    if [[ ! -f "${file}" ]]; then
        echo "ERROR: ${flag//-/_} names '${file}', which doesn't exist in $(pwd)." >&2
        exit 1
    fi
    POLICY+=("--${flag}=$(cd "$(dirname "${file}")" && pwd)/${file##*/}")
done
# extra_args: oasdiff's own options, never the ones that decide what the
# command reads (format, level), that fetch or upload (fetch, open), or a
# word that isn't an option, which oasdiff would read as a document.
expect_value=false
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    if [[ "${expect_value}" == true ]]; then
        expect_value=false
        continue
    fi
    case "${word}" in
        --format | --format=* | --level | --level=* | --fail-on | --fail-on=* | --fetch | --fetch=* | --open | --open=* \
            | --review-token* | --review-meta* | --composed | --composed=* | --template* | --color | --color=* \
            | --severity-levels* | --err-ignore* | --warn-ignore* | -f* | -o* | -c*)
            echo "ERROR: extra_args can't hold '${word}': the breaking command sets it, or it would change what is read." >&2
            exit 1
            ;;
        -p | -q | -l)
            expect_value=true
            ;;
        --*)
            name=${word#--}
            if [[ "${OA_OASDIFF_VALUE_OPTIONS}" == *" ${name} "* ]]; then
                expect_value=true
            fi
            ;;
        -*) ;;
        *)
            echo "ERROR: extra_args can't hold '${word}', which oasdiff would read as a document." >&2
            exit 1
            ;;
    esac
done
if [[ "${expect_value}" == true ]]; then
    echo "ERROR: extra_args ends in an option without its value." >&2
    exit 1
fi
oa_require_jq
oa_tool oasdiff
VERSION=$("${OA_TOOL}" --version 2> /dev/null | awk '{ print $NF; exit }') || VERSION=""

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# --- The base ---
BASE_COMMIT=""
BASE_LABEL=""
if [[ -n "${BASE_FILE}" ]]; then
    OA_RUN_DIR=$(pwd)
    BASE_LABEL=${BASE_FILE}
    echo "Comparing with ${BASE_FILE}."
else
    oa_git_top
    OA_RUN_DIR=${OA_TOP}
    if [[ -z "${BASE_REF}" ]]; then
        # A pull request's base branch on GitHub Actions; elsewhere the
        # remote's default branch.
        if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
            BASE_REF="origin/${GITHUB_BASE_REF}"
        elif head=$(git symbolic-ref -q refs/remotes/origin/HEAD 2> /dev/null); then
            BASE_REF=${head#refs/remotes/}
        else
            for candidate in origin/main origin/master; do
                if git rev-parse --verify --quiet "${candidate}^{commit}" > /dev/null; then
                    BASE_REF=${candidate}
                    break
                fi
            done
        fi
        if [[ -z "${BASE_REF}" ]]; then
            echo "ERROR: base_ref is empty, and this checkout has no origin/HEAD, origin/main or origin/master to" >&2
            echo "  compare with. Set base_ref to the branch, tag or commit whose documents clients use." >&2
            exit 1
        fi
    fi
    if ! tip=$(git rev-parse --verify --quiet "${BASE_REF}^{commit}"); then
        echo "ERROR: base_ref ${BASE_REF} is not a commit in this checkout. Fetch it in an earlier step, such as" >&2
        echo "  git fetch origin ${BASE_REF#origin/}, or check out with all history (actions/checkout: fetch-depth: 0)." >&2
        exit 1
    fi
    if [[ "${MERGE_BASE}" == true ]]; then
        if ! BASE_COMMIT=$(git merge-base "${tip}" HEAD 2> /dev/null); then
            echo "ERROR: ${BASE_REF} and HEAD have no common ancestor in this checkout, which is usually a shallow" >&2
            echo "  clone. Fetch more history (actions/checkout: fetch-depth: 0), or set merge_base to false to" >&2
            echo "  compare with ${BASE_REF} itself." >&2
            exit 1
        fi
        BASE_LABEL="${BASE_REF} (merge base ${BASE_COMMIT:0:12})"
    else
        BASE_COMMIT=${tip}
        BASE_LABEL="${BASE_REF} (${BASE_COMMIT:0:12})"
    fi
    echo "Comparing with ${BASE_LABEL}."
    if [[ "${BASE_COMMIT}" == "$(git rev-parse HEAD)" ]]; then
        echo "The base is this commit, so only uncommitted changes can show."
    fi
fi

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_TOOL_VERSION=${VERSION}
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_ARGS=(changelog "<base>" "<revision>" ${CHANGELOG_ARGS[@]+"${CHANGELOG_ARGS[@]}"})
    OA_INPUTS=()
    for spec in "${SPECS[@]}"; do
        OA_INPUTS+=("spec:${spec}")
    done
    if [[ -n "${BASE_FILE}" ]]; then
        OA_INPUTS+=("base:${BASE_FILE}")
    fi
    for entry in severity_levels:"${SEVERITY_LEVELS}" err_ignore:"${ERR_IGNORE}" warn_ignore:"${WARN_IGNORE}"; do
        if [[ -n "${entry#*:}" ]]; then
            OA_INPUTS+=("${entry}")
        fi
    done
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_TARGET_JSON=$(jq -cn --arg ref "${BASE_REF}" --arg commit "${BASE_COMMIT}" --arg file "${BASE_FILE}" \
        --argjson merge "${MERGE_BASE}" \
        '{base_ref: (if $ref == "" then null else $ref end), base_commit: (if $commit == "" then null else $commit end),
          merge_base: (if $file == "" then $merge else null end), base_file: (if $file == "" then null else $file end)}')
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_REPORTS=("${REPORT}" "${CHANGELOG}" "${SARIF}" "${JUNIT_FILE}")
    oa_run_record "${RECORD}" breaking "$1" "$2" "${STARTED}"
}

# oasdiff runs FORMAT BASE REVISION OUT: runs oasdiff changelog, or stops the
# step. Every flag that decides what is read is passed, so an .oasdiff.yaml
# in the checkout (which can set the policy, such as severity-levels) can't
# change the format, the level or fetching.
CHANGELOG_ARGS=(--level info --fetch=false ${POLICY[@]+"${POLICY[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
changelog() {
    local code=0
    (cd "${OA_RUN_DIR}" && "${OA_TOOL}" changelog --format "$1" "${CHANGELOG_ARGS[@]}" -- "$2" "$3") \
        > "$4" 2> "${WORK}/oasdiff.err" || code=$?
    if [[ "${code}" -ne 0 && "${code}" -ne 1 ]]; then
        oa_tail "${WORK}/oasdiff.err" 30
        # shellcheck disable=SC2034 # read by oa_run_record
        OA_COUNTS=null
        record error "${code}"
        echo "ERROR: oasdiff could not compare $2 with $3 (exit code ${code}). This is not a result: check the" >&2
        echo "  documents and the policy files above." >&2
        exit 1
    fi
}

# --- Compare each document ---
echo '[]' > "${WORK}/all.json"
: > "${CHANGELOG}"
RESULTS='[]'
for spec in "${SPECS[@]}"; do
    if [[ -n "${BASE_FILE}" ]]; then
        base=${BASE_FILE}
        revision=${spec}
        sarif_file=${spec}
    else
        revision=$(oa_from_top "${spec}")
        base_path=${revision}
        if [[ -n "${BASE_SPEC}" ]]; then
            base_path=$(oa_from_top "${BASE_SPEC}")
        fi
        sarif_file=${revision}
        if ! git cat-file -e "${BASE_COMMIT}:${base_path}" 2> /dev/null; then
            echo "${spec}: not in ${BASE_LABEL} (${base_path}), so it is new and nothing in it can break a client."
            # shellcheck disable=SC2016 # jq program, not shell
            RESULTS=$(jq -c --arg spec "${spec}" '. + [{spec: $spec, outcome: "new", changes: 0, breaking: 0}]' <<< "${RESULTS}")
            continue
        fi
        base="${BASE_COMMIT}:${base_path}"
    fi
    echo "${spec}: comparing with ${base}"
    oa_oasdiff_openapi "base document" "${base}"
    oa_oasdiff_openapi "document" "${revision}"
    changelog json "${base}" "${revision}" "${WORK}/one.json"
    if ! oa_json_is "${WORK}/one.json" 'type == "array"'; then
        oa_tail "${WORK}/oasdiff.err" 30
        echo "ERROR: oasdiff's changelog of ${spec} is not a JSON list." >&2
        exit 1
    fi
    changelog markdown "${base}" "${revision}" "${WORK}/one.md"
    {
        printf '## %s\n\nCompared with %s.\n\n' "${spec}" "${BASE_LABEL}"
        cat "${WORK}/one.md"
        printf '\n'
    } >> "${CHANGELOG}"
    # The file oasdiff found each change in, which for a document split
    # across files can be another one than spec: relative to the directory
    # oasdiff ran in, as spec_file is, unless it is a URL or outside it.
    sources='{}'
    jq -r '[.[] | .revisionSource.file // empty | strings] | unique[]' "${WORK}/one.json" > "${WORK}/sources.txt"
    while IFS= read -r source; do
        if [[ -z "${source}" || "${source}" == *://* ]]; then
            continue
        fi
        path=${source}
        if [[ "${path}" != /* ]]; then
            path="${OA_RUN_DIR}/${path}"
        fi
        path=$(realpath -ms --relative-to="${OA_RUN_DIR}" -- "${path}")
        if [[ "${path}" != .. && "${path}" != ../* && "${path}" != /* ]]; then
            # shellcheck disable=SC2016 # jq program, not shell
            sources=$(jq -c --arg from "${source}" --arg to "${path}" '. + {($from): $to}' <<< "${sources}")
        fi
    done < "${WORK}/sources.txt"
    # shellcheck disable=SC2016 # jq program, not shell
    jq --arg spec "${spec}" --arg file "${sarif_file}" --argjson sources "${sources}" \
        '[.[] | . + {spec: $spec, spec_file: $file, source_file: ((.revisionSource.file // "") as $f | $sources[$f]),
                     level_name: ({"3": "error", "2": "warn", "1": "info"}[.level | tostring] // "info")}]' \
        "${WORK}/one.json" > "${WORK}/tagged.json"
    jq -s '.[0] + .[1]' "${WORK}/all.json" "${WORK}/tagged.json" > "${WORK}/next.json"
    mv "${WORK}/next.json" "${WORK}/all.json"
    # shellcheck disable=SC2016 # jq program, not shell
    RESULTS=$(jq -c --arg spec "${spec}" --slurpfile one "${WORK}/tagged.json" \
        '. + [{spec: $spec, outcome: "compared", changes: ($one[0] | length), breaking: ([$one[0][] | select(.level >= 2)] | length)}]' \
        <<< "${RESULTS}")
done
cp "${WORK}/all.json" "${REPORT}"

# --- Reports ---
PREFIX=""
if [[ -n "${BASE_FILE}" ]] && git rev-parse --show-toplevel > /dev/null 2>&1; then
    PREFIX=$(git rev-parse --show-prefix)
fi
# Breaking changes only: an added operation isn't a problem to show. A
# change is located where oasdiff found it in the new document, in the file
# it names, or, for a removal or a file SARIF can't name, at the document's
# first line.
# shellcheck disable=SC2016 # jq program, not shell
jq --arg version "${VERSION}" --arg prefix "${PREFIX}" '
    def uri: ($prefix + ltrimstr("./")) | @uri | gsub("%2F"; "/");
    [.[] | select(.level >= 2)] as $changes
    | ([$changes[].id] | unique) as $rules
    | {"$schema": "https://json.schemastore.org/sarif-2.1.0.json", version: "2.1.0",
       runs: [{
         tool: {driver: {name: "oasdiff", version: $version, informationUri: "https://www.oasdiff.com",
                         rules: [$rules[] | {id: ., name: ., shortDescription: {text: .}}]}},
         results: [$changes[] | {
             ruleId: .id, ruleIndex: (.id as $i | $rules | index($i)),
             level: (if .level >= 3 then "error" else "warning" end),
             message: {text: (.text + (if .operation then " (\(.operation) \(.path // ""))" else "" end))},
             partialFingerprints: (if .fingerprint then {"oasdiffFingerprint/v1": .fingerprint} else {} end),
             locations: [{physicalLocation: (if (.revisionSource.line // 0) > 0 and .source_file != null
                 then {artifactLocation: {uri: (.source_file | uri)},
                       region: {startLine: .revisionSource.line, startColumn: ([.revisionSource.column // 1, 1] | max)}}
                 else {artifactLocation: {uri: (.spec_file | uri)}, region: {startLine: 1}} end)}]}]}]}
' "${REPORT}" > "${SARIF}"

# shellcheck disable=SC2016 # jq program, not shell
COUNTS=$(jq -c --argjson min "${FAIL_RANK}" '{
    error: [.[] | select(.level == 3)] | length,
    warn: [.[] | select(.level == 2)] | length,
    info: [.[] | select(.level == 1)] | length,
    breaking: [.[] | select(.level >= 2)] | length,
    findings: [.[] | select(.level >= $min)] | length,
    documents: '"${#SPECS[@]}"'}' "${REPORT}")
FINDINGS=$(jq -r '.findings' <<< "${COUNTS}")
BREAKING=$(jq -r '.breaking' <<< "${COUNTS}")
if [[ "${JUNIT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    oa_junit "${JUNIT_FILE}" "oasdiff (${REPORT_NAME})" "$(jq -c --argjson min "${FAIL_RANK}" '[.[] | select(.level >= 2) | {
        classname: .spec, name: "\(.id): \(.operation // .section // "") \(.path // "")",
        status: (if .level >= $min then "failed" else "skipped" end),
        message: "\(.level_name): \(.text)", detail: .text}]' "${REPORT}")"
fi

# --- Summary ---
# shellcheck disable=SC2016 # jq program, not shell
jq -r '.[] | select(.level >= 2) | "  \(.spec): \(.level_name) \(.id): \(.text)\(if .operation then " (\(.operation) \(.path // ""))" else "" end)"' "${REPORT}" \
    | awk 'NR <= 100' || true
if [[ "${BREAKING}" -gt 100 ]]; then
    echo "  ... and $((BREAKING - 100)) more, in ${REPORT}."
fi
SUMMARY="$(oa_plural "${BREAKING}" "breaking change" "breaking changes") since ${BASE_LABEL} in $(oa_plural "${#SPECS[@]}" document documents) ($(jq -r '"\(.error) error, \(.warn) warn; \(.info) other changes"' <<< "${COUNTS}")); $(oa_plural "${FINDINGS}" finding findings) at or above ${FAIL_ON}. The changelog is in ${CHANGELOG}."
# shellcheck disable=SC2034 # read by oa_run_record
OA_COUNTS=${COUNTS}
# shellcheck disable=SC2034 # read by oa_run_record
OA_RESULTS=${RESULTS}
if [[ "${FINDINGS}" -gt 0 ]]; then
    if [[ "${REPORT_ONLY}" == true ]]; then
        record findings-reported 0
    else
        record findings 0
    fi
    oa_gate true "${REPORT_ONLY}" "${SUMMARY}"
fi
record passed 0
oa_gate false "${REPORT_ONLY}" "${SUMMARY}"
