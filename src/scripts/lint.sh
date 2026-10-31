#!/bin/bash
#
# Lints OpenAPI documents with vacuum, for the lint command: the document's
# validity against the OpenAPI schema (vacuum's oas3-schema and oas2-schema
# rules), then the rules of its recommended ruleset, of a Spectral-compatible
# ruleset, or with hard_mode every built-in rule and the OWASP API security
# rules.
#
# vacuum runs once per document, as spectral-report, which writes the results
# as JSON and exits 0 whatever it found; a document it can't read, a ruleset
# it can't load and any other failure exit non-zero (2). The orb gates on the
# JSON: results at or above fail_on are findings, which fail the step unless
# report_only is true; a run that didn't complete fails it either way. vacuum
# reads a vacuum.conf.* from the working directory and VACUUM_* variables,
# either of which could turn rules off or change what is read, so it runs
# with neither: its settings come from the parameters.

set -euo pipefail

if [[ -z "${SCRIPT_OPENAPI_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_OPENAPI_LIB is not set; run this script through the orb's lint command." >&2
    exit 1
fi
eval "${SCRIPT_OPENAPI_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The reports an earlier run with this report_name left go first, so a check
# that stops on its inputs leaves none behind to be stored as its own.
REPORT_NAME=$(oa_subst "${PARAM_REPORT_NAME}")
oa_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${OA_BASE}.json"
SARIF="${OA_BASE}.sarif"
JUNIT_FILE="${OA_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${OA_BASE}.run-record.json"
rm -f "${REPORT}" "${SARIF}" "${JUNIT_FILE}" "${RECORD}"

oa_specs specs "${PARAM_SPECS}"
SPECS=("${OA_FILES[@]}")
RULESET=$(oa_subst "${PARAM_RULESET}")
HARD_MODE=$(oa_bool hard_mode "${PARAM_HARD_MODE}")
FUNCTIONS=$(oa_subst "${PARAM_FUNCTIONS}")
IGNORE_FILE=$(oa_subst "${PARAM_IGNORE_FILE}")
FAIL_ON=$(oa_subst "${PARAM_FAIL_ON}")
JUNIT=$(oa_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(oa_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(oa_bool report_only "${PARAM_REPORT_ONLY}")
oa_words extra_args "$(oa_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${OA_WORDS[@]+"${OA_WORDS[@]}"})

# --- Parameters ---
FAIL_RANK=$(oa_rank lint "${FAIL_ON}")
if [[ -z "${FAIL_RANK}" ]]; then
    echo "ERROR: fail_on must be error, warn, info or hint, not '${FAIL_ON}'." >&2
    exit 1
fi
if [[ -n "${RULESET}" && "${RULESET}" != https://* && ! -f "${RULESET}" ]]; then
    echo "ERROR: ruleset must be a ruleset file or an https:// URL; '${RULESET}' is neither in $(pwd)." >&2
    exit 1
fi
if [[ -n "${FUNCTIONS}" && ! -d "${FUNCTIONS}" ]]; then
    echo "ERROR: functions must be a directory of custom functions; '${FUNCTIONS}' is not one in $(pwd)." >&2
    exit 1
fi
if [[ -n "${IGNORE_FILE}" && ! -f "${IGNORE_FILE}" ]]; then
    echo "ERROR: ignore_file names '${IGNORE_FILE}', which doesn't exist in $(pwd)." >&2
    exit 1
fi
for value in "${RULESET}" "${FUNCTIONS}" "${IGNORE_FILE}"; do
    if [[ "${value}" == -* ]]; then
        echo "ERROR: ruleset, functions and ignore_file can't start with '-': '${value}'. Write ./${value}." >&2
        exit 1
    fi
done
# extra_args: vacuum's own options, never the ones the command sets itself or
# ones that would narrow what is checked (turbo leaves out the schema rules,
# skip-check the document check, changes and original the results outside a
# change), and no words that aren't options, which vacuum would read as
# another document or the report's path.
refused=" stdin stdout no-pretty output-dir globbed-files config ruleset hard-mode functions ignore-file turbo skip-check changes original breaking-config warn-on-changes error-on-breaking "
refused_short="ionrzfTk"
takes_value=" base timeout lookup-timeout fetch-timeout cert-file key-file ca-file "
takes_value_short="pg"
expect_value=false
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    if [[ "${expect_value}" == true ]]; then
        expect_value=false
        continue
    fi
    case "${word}" in
        --*)
            name=${word#--}
            name=${name%%=*}
            if [[ -z "${name}" || " ${refused} " == *" ${name} "* ]]; then
                echo "ERROR: extra_args can't hold '${word}': the lint command sets it, or it would narrow what is checked." >&2
                exit 1
            fi
            if [[ " ${takes_value} " == *" ${name} "* && "${word}" != *=* ]]; then
                expect_value=true
            fi
            ;;
        -?*)
            letters=${word#-}
            for ((i = 0; i < ${#letters}; i++)); do
                letter=${letters:i:1}
                if [[ "${refused_short}" == *"${letter}"* ]]; then
                    echo "ERROR: extra_args can't hold '${word}': the lint command sets -${letter}, or it would narrow what is checked." >&2
                    exit 1
                fi
                if [[ "${takes_value_short}" == *"${letter}"* ]]; then
                    if ((i == ${#letters} - 1)); then
                        expect_value=true
                    fi
                    break
                fi
            done
            ;;
        *)
            echo "ERROR: extra_args can't hold '${word}', which vacuum would read as a document or report path." >&2
            echo "  Name the documents in specs." >&2
            exit 1
            ;;
    esac
done
if [[ "${expect_value}" == true ]]; then
    echo "ERROR: extra_args ends in an option without its value." >&2
    exit 1
fi
oa_require_jq
oa_tool vacuum

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# vacuum reads only this empty configuration, and no VACUUM_* variable.
printf '# openapi-orb: vacuum runs with the lint command parameters alone.\n' > "${WORK}/vacuum.conf.yaml"
ENV_UNSET=()
while IFS= read -r name; do
    if [[ "${name}" == VACUUM_* ]]; then
        ENV_UNSET+=(-u "${name}")
    fi
done < <(compgen -e)
vacuum_run() {
    env ${ENV_UNSET[@]+"${ENV_UNSET[@]}"} CI=true "${OA_TOOL}" "$@"
}
VERSION=$(vacuum_run version --config "${WORK}/vacuum.conf.yaml" 2> /dev/null | head -n 1) || VERSION=""
VERSION=${VERSION#v}

ARGS=(spectral-report --config "${WORK}/vacuum.conf.yaml" --no-update-check --no-style)
if [[ -n "${RULESET}" ]]; then
    ARGS+=(--ruleset "${RULESET}")
fi
if [[ "${HARD_MODE}" == true ]]; then
    ARGS+=(--hard-mode)
fi
if [[ -n "${FUNCTIONS}" ]]; then
    ARGS+=(--functions "${FUNCTIONS}")
fi
if [[ -n "${IGNORE_FILE}" ]]; then
    ARGS+=(--ignore-file "${IGNORE_FILE}")
fi
ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_TOOL_VERSION=${VERSION}
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_ARGS=("${ARGS[@]}" -- "<spec>" "<report>")
    OA_INPUTS=()
    for spec in "${SPECS[@]}"; do
        OA_INPUTS+=("spec:${spec}")
    done
    if [[ -n "${RULESET}" && "${RULESET}" != https://* ]]; then
        OA_INPUTS+=("ruleset:${RULESET}")
    fi
    if [[ -n "${IGNORE_FILE}" ]]; then
        OA_INPUTS+=("ignore_file:${IGNORE_FILE}")
    fi
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_REPORTS=("${REPORT}" "${SARIF}" "${JUNIT_FILE}")
    oa_run_record "${RECORD}" lint "$1" "$2" "${STARTED}"
}

# --- Lint each document ---
echo '[]' > "${WORK}/all.json"
index=0
for spec in "${SPECS[@]}"; do
    index=$((index + 1))
    out="${WORK}/report-${index}.json"
    echo "Linting ${spec} with vacuum ${VERSION:-(version unknown)}:"
    oa_show_command vacuum "${ARGS[@]}" -- "${spec}" "${out}" | sed 's/^/  /'
    code=0
    vacuum_run "${ARGS[@]}" -- "${spec}" "${out}" > "${WORK}/vacuum.log" 2>&1 || code=$?
    if [[ "${code}" -ne 0 ]] || ! oa_json_is "${out}" 'type == "array"'; then
        oa_tail "${WORK}/vacuum.log" 30
        # shellcheck disable=SC2034 # read by oa_run_record
        OA_COUNTS=null
        record error "${code}"
        if [[ "${code}" -ne 0 ]]; then
            echo "ERROR: vacuum could not lint ${spec} (exit code ${code}). This is not a lint result: check the" >&2
            echo "  document, the ruleset and the functions above." >&2
        else
            echo "ERROR: vacuum exited 0 but wrote no report for ${spec}." >&2
        fi
        exit 1
    fi
    # Each result keeps vacuum's Spectral fields, plus the document it came
    # from and its severity's name.
    # shellcheck disable=SC2016 # jq program, not shell
    jq --arg spec "${spec}" '[.[] | . + {spec: $spec,
            severity_name: (["error", "warn", "info", "hint"][.severity] // "warn")}]' "${out}" > "${WORK}/one.json"
    jq -s '.[0] + .[1]' "${WORK}/all.json" "${WORK}/one.json" > "${WORK}/next.json"
    mv "${WORK}/next.json" "${WORK}/all.json"
done
cp "${WORK}/all.json" "${REPORT}"

# --- Reports ---
RANKS='{"hint": 0, "info": 1, "warn": 2, "error": 3}'
# SARIF paths are relative to the top of the git checkout, which is what
# GitHub code scanning expects; outside a checkout, to the working directory.
PREFIX=""
if TOP=$(git rev-parse --show-toplevel 2> /dev/null) && [[ -n "${TOP}" ]]; then
    PREFIX=$(git rev-parse --show-prefix)
fi
# shellcheck disable=SC2016 # jq program, not shell
jq --arg version "${VERSION}" --arg prefix "${PREFIX}" '
    def uri: (if startswith("/") then . else $prefix + (ltrimstr("./")) end) | @uri | gsub("%2F"; "/");
    def level: {"error": "error", "warn": "warning", "info": "note", "hint": "note"}[.severity_name] // "warning";
    ([.[].code] | unique) as $rules
    | {"$schema": "https://json.schemastore.org/sarif-2.1.0.json", version: "2.1.0",
       runs: [{
         tool: {driver: {name: "vacuum", version: $version, informationUri: "https://quobix.com/vacuum/",
                         rules: [$rules[] | {id: ., name: ., shortDescription: {text: .}}]}},
         results: [.[] | {
             ruleId: .code, ruleIndex: (.code as $c | $rules | index($c)), level: level,
             message: {text: .message},
             locations: [{physicalLocation: {
                 artifactLocation: {uri: ((if (.source // "") == "" then .spec else .source end) | uri)},
                 region: {startLine: ([.range.start.line, 1] | max), startColumn: ([.range.start.character, 1] | max)}}}]}]}]}
' "${REPORT}" > "${SARIF}"

# shellcheck disable=SC2016 # jq program, not shell
COUNTS=$(jq -c --argjson ranks "${RANKS}" --argjson min "${FAIL_RANK}" '{
    error: [.[] | select(.severity_name == "error")] | length,
    warn: [.[] | select(.severity_name == "warn")] | length,
    info: [.[] | select(.severity_name == "info")] | length,
    hint: [.[] | select(.severity_name == "hint")] | length,
    findings: [.[] | select($ranks[.severity_name] >= $min)] | length,
    documents: '"${#SPECS[@]}"'}' "${REPORT}")
FINDINGS=$(jq -r '.findings' <<< "${COUNTS}")
TOTAL=$(jq length "${REPORT}")
if [[ "${JUNIT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    oa_junit "${JUNIT_FILE}" "vacuum (${REPORT_NAME})" "$(jq -c --argjson ranks "${RANKS}" --argjson min "${FAIL_RANK}" '[.[] | {
        classname: .spec, name: "\(.code): \(.path | join("."))",
        status: (if $ranks[.severity_name] >= $min then "failed" else "skipped" end),
        message: "\(.severity_name): \(.message)",
        detail: "\(.spec):\(.range.start.line):\(.range.start.character) \(.severity_name) \(.code) \(.message)"}]' "${REPORT}")"
fi

# --- Summary ---
# shellcheck disable=SC2016 # jq program, not shell
jq -r '.[] | "  \(.spec):\(.range.start.line):\(.range.start.character) \(.severity_name) \(.code): \(.message)"' "${REPORT}" \
    | awk 'NR <= 100' || true
if [[ "${TOTAL}" -gt 100 ]]; then
    echo "  ... and $((TOTAL - 100)) more, in ${REPORT}."
fi
SUMMARY="vacuum reported $(oa_plural "${TOTAL}" result results) in $(oa_plural "${#SPECS[@]}" document documents) ($(jq -r '"\(.error) error, \(.warn) warn, \(.info) info, \(.hint) hint"' <<< "${COUNTS}")); $(oa_plural "${FINDINGS}" finding findings) at or above ${FAIL_ON}."
# shellcheck disable=SC2034 # read by oa_run_record
OA_COUNTS=${COUNTS}
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
