#!/bin/bash
#
# Checks that a committed OpenAPI document still describes the API the code
# serves, for the drift command: the document an earlier step generated from
# the code (generated) against the committed one (spec), or, when the
# generator wrote over the committed file, the working tree's copy against
# the one in HEAD.
#
# oasdiff compares the documents as data, not text, so key order, YAML or
# JSON and formatting don't count. Any difference oasdiff's diff reports is
# drift, which fails the step unless report_only is true; exclude_elements
# leaves out descriptions, examples and the like. Its changelog names each
# change, and which ones break clients, for the reports. A document that
# isn't OpenAPI 3, or a comparison that couldn't run, fails the step either
# way.

set -euo pipefail

if [[ -z "${SCRIPT_OPENAPI_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_OPENAPI_LIB is not set; run this script through the orb's drift command." >&2
    exit 1
fi
eval "${SCRIPT_OPENAPI_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SPEC=$(oa_subst "${PARAM_SPEC}")
GENERATED=$(oa_subst "${PARAM_GENERATED}")
oa_list exclude_elements "${PARAM_EXCLUDE_ELEMENTS}"
EXCLUDE=(${OA_LIST[@]+"${OA_LIST[@]}"})
REPORT_NAME=$(oa_subst "${PARAM_REPORT_NAME}")
JUNIT=$(oa_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(oa_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(oa_bool report_only "${PARAM_REPORT_ONLY}")
oa_words extra_args "$(oa_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${OA_WORDS[@]+"${OA_WORDS[@]}"})

# --- Parameters ---
if [[ -z "${SPEC}" || "${SPEC}" == -* || ! -f "${SPEC}" ]]; then
    echo "ERROR: spec must name the committed document, not '${SPEC}', which is not a file in $(pwd)." >&2
    exit 1
fi
if [[ -n "${GENERATED}" && ( "${GENERATED}" == -* || ! -f "${GENERATED}" ) ]]; then
    echo "ERROR: generated names '${GENERATED}', which is not a file in $(pwd). Generate the document from the" >&2
    echo "  code in an earlier step, and name the file it wrote here." >&2
    exit 1
fi
if [[ -n "${GENERATED}" && "${GENERATED}" -ef "${SPEC}" ]]; then
    echo "ERROR: generated is the same file as spec. Leave generated empty when the generator writes over spec:" >&2
    echo "  the working tree's copy is then compared with the one in HEAD." >&2
    exit 1
fi
for element in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do
    case "${element}" in
        examples | description | title | summary | extensions | endpoints) ;;
        *)
            echo "ERROR: exclude_elements takes examples, description, title, summary, extensions and endpoints," >&2
            echo "  not '${element}'." >&2
            exit 1
            ;;
    esac
done
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    case "${word}" in
        --format | --format=* | --fail-on-diff* | --fetch | --fetch=* | --open | --open=* | --composed | --composed=* \
            | --exclude-elements* | --level | --level=* | -f* | -o* | -c* | -e*)
            echo "ERROR: extra_args can't hold '${word}': the drift command sets it, or it would change what is read." >&2
            exit 1
            ;;
        -*) ;;
        *)
            echo "ERROR: extra_args can't hold '${word}', which oasdiff would read as a document." >&2
            exit 1
            ;;
    esac
done
oa_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
oa_require_jq
oa_tool oasdiff
VERSION=$("${OA_TOOL}" --version 2> /dev/null | awk '{ print $NF; exit }') || VERSION=""

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
REPORT="${OA_BASE}.json"
DIFF="${OA_BASE}.diff.json"
CHANGELOG="${OA_BASE}.md"
JUNIT_FILE="${OA_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${OA_BASE}.run-record.json"
rm -f "${REPORT}" "${DIFF}" "${CHANGELOG}" "${JUNIT_FILE}" "${RECORD}"

# --- What to compare ---
if [[ -n "${GENERATED}" ]]; then
    OA_RUN_DIR=$(pwd)
    BASE=${SPEC}
    REVISION=${GENERATED}
    LABEL="${GENERATED} (generated) against ${SPEC} (committed)"
else
    oa_git_top
    OA_RUN_DIR=${OA_TOP}
    REVISION=$(oa_from_top "${SPEC}")
    if ! git cat-file -e "HEAD:${REVISION}" 2> /dev/null; then
        echo "ERROR: ${SPEC} is not committed, so there is nothing to compare it with. Commit the document, or name" >&2
        echo "  the generated one in generated." >&2
        exit 1
    fi
    BASE="HEAD:${REVISION}"
    LABEL="${SPEC} as generated against ${SPEC} in HEAD"
fi
echo "Comparing ${LABEL}."
oa_oasdiff_openapi "committed document" "${BASE}"
oa_oasdiff_openapi "generated document" "${REVISION}"

DIFF_ARGS=(--fetch=false)
if [[ ${#EXCLUDE[@]} -gt 0 ]]; then
    DIFF_ARGS+=("--exclude-elements=$(IFS=,; echo "${EXCLUDE[*]}")")
fi
DIFF_ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_TOOL_VERSION=${VERSION}
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_ARGS=(diff --format json "${DIFF_ARGS[@]}" -- "${BASE}" "${REVISION}")
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_INPUTS=("spec:${SPEC}")
    if [[ -n "${GENERATED}" ]]; then
        OA_INPUTS+=("generated:${GENERATED}")
    fi
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_REPORTS=("${REPORT}" "${DIFF}" "${CHANGELOG}" "${JUNIT_FILE}")
    oa_run_record "${RECORD}" drift "$1" "$2" "${STARTED}"
}

# oasdiff_run COMMAND FORMAT OUT [ARG...]: runs an oasdiff comparison, or stops
# the step. diff exits 1 with fail-on-diff, which a configuration file can
# set; anything else but 0 means it couldn't compare.
oasdiff_run() {
    local command=$1 format=$2 out=$3 code=0
    shift 3
    (cd "${OA_RUN_DIR}" && "${OA_TOOL}" "${command}" --format "${format}" "$@" -- "${BASE}" "${REVISION}") \
        > "${out}" 2> "${WORK}/oasdiff.err" || code=$?
    if [[ "${code}" -ne 0 && "${code}" -ne 1 ]]; then
        oa_tail "${WORK}/oasdiff.err" 30
        # shellcheck disable=SC2034 # read by oa_run_record
        OA_COUNTS=null
        record error "${code}"
        echo "ERROR: oasdiff ${command} could not compare the documents (exit code ${code})." >&2
        exit 1
    fi
}
oasdiff_run diff json "${DIFF}" "${DIFF_ARGS[@]}"
if ! oa_json_is "${DIFF}" 'type == "object"'; then
    oa_tail "${WORK}/oasdiff.err" 30
    echo "ERROR: oasdiff's diff is not a JSON object." >&2
    exit 1
fi
# The changelog names the changes, with the same options as the diff.
oasdiff_run changelog json "${WORK}/changelog.json" --level info --fetch=false --color never ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
oasdiff_run changelog markdown "${WORK}/changelog.md" --level info --fetch=false --color never ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
if ! oa_json_is "${WORK}/changelog.json" 'type == "array"'; then
    echo "ERROR: oasdiff's changelog is not a JSON list." >&2
    exit 1
fi
DRIFT=false
if ! oa_json_is "${DIFF}" '. == {}'; then
    DRIFT=true
fi
# shellcheck disable=SC2016 # jq program, not shell
jq --argjson drift "${DRIFT}" --slurpfile diff "${DIFF}" \
    '{drift: $drift, changes: [.[] | . + {level_name: ({"3": "error", "2": "warn", "1": "info"}[.level | tostring] // "info")}],
      diff: $diff[0]}' "${WORK}/changelog.json" > "${REPORT}"
{
    printf '## %s\n\n' "${LABEL}"
    if [[ "${DRIFT}" == true ]]; then
        cat "${WORK}/changelog.md"
        printf '\nThe full difference is in %s.\n' "${DIFF##*/}"
    else
        printf 'No differences.\n'
    fi
} > "${CHANGELOG}"

# shellcheck disable=SC2016 # jq program, not shell
COUNTS=$(jq -c '{changes: (.changes | length), breaking: ([.changes[] | select(.level >= 2)] | length),
    other: (if .drift and (.changes | length) == 0 then 1 else 0 end), sections: (.diff | keys)}' "${REPORT}")
CHANGES=$(jq -r '.changes' <<< "${COUNTS}")
BREAKING=$(jq -r '.breaking' <<< "${COUNTS}")
if [[ "${JUNIT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    oa_junit "${JUNIT_FILE}" "oasdiff drift (${REPORT_NAME})" "$(jq -c --arg spec "${SPEC}" '
        if .drift | not then []
        elif (.changes | length) == 0 then [{classname: $spec, name: "the documents differ", status: "failed",
            message: "The documents differ in \(.diff | keys | join(", "))", detail: (.diff | tojson)}]
        else [.changes[] | {classname: $spec, name: "\(.id): \(.operation // .section // "") \(.path // "")",
            status: "failed", message: "\(.level_name): \(.text)", detail: .text}] end' "${REPORT}")"
fi

# --- Summary ---
if [[ "${DRIFT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r '.changes[] | "  \(.level_name) \(.id): \(.text)\(if .operation then " (\(.operation) \(.path // ""))" else "" end)"' "${REPORT}" \
        | awk 'NR <= 100' || true
    if [[ "${CHANGES}" -eq 0 ]]; then
        echo "  The documents differ in $(jq -r '.diff | keys | join(", ")' "${REPORT}"), which the changelog doesn't name; see ${DIFF}."
    fi
    SUMMARY="The documents differ: ${LABEL}, $(oa_plural "${CHANGES}" change changes) ($(oa_plural "${BREAKING}" "breaking change" "breaking changes")). Commit the generated document, or change the code back."
else
    SUMMARY="The documents match: ${LABEL}."
fi
# shellcheck disable=SC2034 # read by oa_run_record
OA_COUNTS=${COUNTS}
if [[ "${DRIFT}" == true ]]; then
    if [[ "${REPORT_ONLY}" == true ]]; then
        record findings-reported 0
    else
        record findings 0
    fi
    oa_gate true "${REPORT_ONLY}" "${SUMMARY}"
fi
record passed 0
oa_gate false "${REPORT_ONLY}" "${SUMMARY}"
