#!/bin/bash
#
# Tests a running API against its OpenAPI document with Schemathesis, for the
# contract_test command: Schemathesis generates requests from the document,
# sends them to url, and checks each response against it (server errors,
# status codes, content types, headers and bodies the document doesn't
# allow, and requests the API should have refused or accepted).
#
# Schemathesis exits 1 for failed checks and for requests that never got an
# answer alike, so its JSON report decides: failures are findings, which
# fail the step unless report_only is true; an error (a document it couldn't
# load, an operation it couldn't test, an API that stopped answering), a run
# that didn't complete, or one that tested nothing fails the step either way.
# It runs with a configuration file the orb writes (or the one config names),
# never one it finds in the checkout, and keeps Hypothesis's example database
# and its own request cache out of the working directory.

set -euo pipefail

if [[ -z "${SCRIPT_OPENAPI_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_OPENAPI_LIB is not set; run this script through the orb's contract_test command." >&2
    exit 1
fi
eval "${SCRIPT_OPENAPI_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The reports an earlier run with this report_name left go first, so a check
# that stops on its inputs leaves none behind to be stored as its own.
REPORT_NAME=$(oa_subst "${PARAM_REPORT_NAME}")
oa_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${OA_BASE}.json"
JUNIT_FILE="${OA_OUT%/}/junit/${REPORT_NAME}.xml"
RECORD="${OA_BASE}.run-record.json"
rm -f "${REPORT}" "${JUNIT_FILE}" "${RECORD}" "${OA_BASE}.har.json" "${OA_BASE}.vcr.yaml" "${OA_BASE}.ndjson"
rm -rf "${OA_BASE}.html"

SPEC=$(oa_subst "${PARAM_SPEC}")
URL=$(oa_subst "${PARAM_URL}")
oa_list checks "${PARAM_CHECKS}"
CHECKS=(${OA_LIST[@]+"${OA_LIST[@]}"})
oa_list exclude_checks "${PARAM_EXCLUDE_CHECKS}"
EXCLUDE_CHECKS=(${OA_LIST[@]+"${OA_LIST[@]}"})
oa_list phases "${PARAM_PHASES}"
PHASES=(${OA_LIST[@]+"${OA_LIST[@]}"})
MAX_EXAMPLES=$(oa_subst "${PARAM_MAX_EXAMPLES}")
SEED=$(oa_subst "${PARAM_SEED}")
WORKERS=$(oa_subst "${PARAM_WORKERS}")
REQUEST_TIMEOUT=$(oa_subst "${PARAM_REQUEST_TIMEOUT}")
WAIT_FOR_API=$(oa_subst "${PARAM_WAIT_FOR_API}")
# headers is not expanded: its ${NAME} placeholders are Schemathesis's, which
# it fills in from the environment as it runs, so a secret never reaches a
# file or a command line.
HEADERS=${PARAM_HEADERS}
CONFIG=$(oa_subst "${PARAM_CONFIG}")
oa_list formats "${PARAM_FORMATS}"
FORMATS=(${OA_LIST[@]+"${OA_LIST[@]}"})
ALLOW_EMPTY=$(oa_bool allow_empty "${PARAM_ALLOW_EMPTY}")
JUNIT=$(oa_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(oa_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(oa_bool report_only "${PARAM_REPORT_ONLY}")
oa_words extra_args "$(oa_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${OA_WORDS[@]+"${OA_WORDS[@]}"})

# --- Parameters ---
SPEC_URL=false
if oa_match "${SPEC}" '^https?://'; then
    SPEC_URL=true
elif [[ -z "${SPEC}" || "${SPEC}" == -* || ! -f "${SPEC}" ]]; then
    echo "ERROR: spec must be the API's OpenAPI document, a file or an http(s):// URL; '${SPEC}' is neither in $(pwd)." >&2
    exit 1
fi
if [[ -n "${URL}" ]] && ! oa_match "${URL}" '^https?://[^[:space:]]+$'; then
    echo "ERROR: url must be the API's base URL, http:// or https://, not '$(oa_url_public "${URL}")'." >&2
    exit 1
fi
if [[ -z "${URL}" && "${SPEC_URL}" == false ]]; then
    echo "ERROR: url is empty: name the base URL of the API to test, such as http://localhost:8080, which the" >&2
    echo "  document's paths are relative to." >&2
    exit 1
fi
for name in ${CHECKS[@]+"${CHECKS[@]}"} ${EXCLUDE_CHECKS[@]+"${EXCLUDE_CHECKS[@]}"}; do
    if ! oa_match "${name}" '^[a-z_]+$'; then
        echo "ERROR: checks and exclude_checks take Schemathesis check names, such as not_a_server_error, not '${name}'." >&2
        exit 1
    fi
done
for phase in ${PHASES[@]+"${PHASES[@]}"}; do
    case "${phase}" in
        examples | coverage | fuzzing | stateful) ;;
        *)
            echo "ERROR: phases takes examples, coverage, fuzzing and stateful, not '${phase}'." >&2
            exit 1
            ;;
    esac
done
for entry in max_examples:"${MAX_EXAMPLES}" request_timeout:"${REQUEST_TIMEOUT}"; do
    if [[ -n "${entry#*:}" ]]; then
        oa_uint "${entry%%:*}" "${entry#*:}" 1
    fi
done
# Schemathesis's seeds are 128-bit numbers, too large for shell arithmetic.
if [[ -n "${SEED}" ]] && ! oa_match "${SEED}" '^[0-9]{1,40}$'; then
    echo "ERROR: seed must be a whole number, such as the seed a failed run printed, not '${SEED}'." >&2
    exit 1
fi
if [[ "${WORKERS}" != auto ]]; then
    oa_uint workers "${WORKERS}" 1
fi
oa_uint wait_for_api "${WAIT_FOR_API}"
for format in ${FORMATS[@]+"${FORMATS[@]}"}; do
    case "${format}" in
        har | vcr | ndjson | html) ;;
        *)
            echo "ERROR: formats takes har, vcr, ndjson and html, not '${format}'; the JSON and JUnit reports are" >&2
            echo "  always written." >&2
            exit 1
            ;;
    esac
done
if [[ -n "${CONFIG}" ]]; then
    if [[ "${CONFIG}" == -* || ! -f "${CONFIG}" ]]; then
        echo "ERROR: config names '${CONFIG}', which is not a file in $(pwd)." >&2
        exit 1
    fi
    if [[ -n "${HEADERS}" ]]; then
        echo "ERROR: headers and config can't both be set: put the headers in the configuration file, as" >&2
        echo "  [headers] entries." >&2
        exit 1
    fi
fi
HEADER_LINES=()
while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]]; then
        continue
    fi
    name=${line%%:*}
    if [[ "${line}" != *:* ]] || ! oa_match "${name}" "^[A-Za-z0-9!#\$%&'*+.^_\`|~-]+\$"; then
        echo "ERROR: headers takes one 'Name: value' per line; '${line%%:*}' is not a header name." >&2
        exit 1
    fi
    HEADER_LINES+=("${line}")
done <<< "${HEADERS}"
# extra_args: Schemathesis's own options, never the ones the command sets,
# the ones that put a secret on the command line (headers and auth belong in
# headers or config), or a word that isn't an option.
previous=""
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    case "${word}" in
        --report | --report=* | --report-* | --url | --url=* | --origin* | --config-file* | --checks* | --exclude-checks* \
            | --phases* | --max-examples* | --seed* | --workers* | --request-timeout* | --wait-for-schema* | --header* \
            | --auth* | --generation-database* | --baseline-update* | --baseline-prune* | -H* | -a* | -u* | -c* | -n* | -w*)
            echo "ERROR: extra_args can't hold '${word}': the contract_test command sets it, or it would put a secret on the" >&2
            echo "  command line (use headers, with \${NAME} placeholders, or config)." >&2
            exit 1
            ;;
        -*) ;;
        *)
            # A word that isn't an option is the value of the option before it,
            # or Schemathesis would take it for another document, and refuse it.
            if [[ "${previous}" != -* || "${previous}" == *=* ]]; then
                echo "ERROR: extra_args can't hold '${word}', which Schemathesis would read as another document." >&2
                exit 1
            fi
            ;;
    esac
    previous=${word}
done
oa_require_jq
oa_tool schemathesis
VERSION=$("${OA_TOOL}" --version 2> /dev/null | awk '{ print $NF; exit }') || VERSION=""

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# --- Configuration ---
if [[ -n "${CONFIG}" ]]; then
    CONFIG_FILE=$(cd "$(dirname "${CONFIG}")" && pwd)/${CONFIG##*/}
else
    # Schemathesis would read a schemathesis.toml it finds from here up to the
    # top of the checkout; this one holds only what the parameters say, and
    # turns off its request cache, which replays earlier runs' answers.
    CONFIG_FILE="${WORK}/schemathesis.toml"
    {
        printf '# openapi-orb: Schemathesis runs with the contract_test command parameters alone.\n'
        printf '[cache]\nenabled = false\n'
        if [[ ${#HEADER_LINES[@]} -gt 0 ]]; then
            printf '\n[headers]\n'
            for line in "${HEADER_LINES[@]}"; do
                value=${line#*:}
                value=${value#"${value%%[![:space:]]*}"}
                printf '%s = %s\n' "$(oa_toml_string "${line%%:*}")" "$(oa_toml_string "${value}")"
            done
        fi
    } > "${CONFIG_FILE}"
    found=$(pwd)
    while true; do
        if [[ -f "${found}/schemathesis.toml" ]]; then
            echo "Not reading ${found}/schemathesis.toml: Schemathesis runs with the command's parameters. Name it in" \
                "config to use it."
            break
        fi
        if [[ -d "${found}/.git" || "${found}" == / ]]; then
            break
        fi
        found=$(dirname "${found}")
    done
fi

# --- Wait for the API ---
# Messages name URLs without credentials, as the run record does.
TARGET=${URL:-${SPEC}}
SHOWN_TARGET=$(oa_url_public "${TARGET}")
SHOWN_SPEC=${SPEC}
if [[ "${SPEC_URL}" == true ]]; then
    SHOWN_SPEC=$(oa_url_public "${SPEC}")
fi
if [[ "${WAIT_FOR_API}" -gt 0 ]]; then
    echo "Waiting up to ${WAIT_FOR_API}s for ${SHOWN_TARGET} to answer..."
    deadline=$((SECONDS + WAIT_FOR_API))
    until status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -- "${TARGET}" 2> /dev/null) && [[ "${status}" != 000 ]]; do
        if ((SECONDS >= deadline)); then
            echo "ERROR: ${SHOWN_TARGET} did not answer within ${WAIT_FOR_API} seconds, so the API was not tested. Start it in an" >&2
            echo "  earlier step (in the background), or raise wait_for_api." >&2
            exit 1
        fi
        sleep 1
    done
    echo "It answered (HTTP ${status})."
fi

# --- Run ---
ARGS=(--config-file "${CONFIG_FILE}" --no-color run "${SPEC}" --generation-database none
    --report-json-path "${WORK}/report.json")
if [[ -n "${URL}" ]]; then
    ARGS+=(--url "${URL}")
fi
if [[ ${#CHECKS[@]} -gt 0 ]]; then
    ARGS+=(--checks "$(IFS=,; echo "${CHECKS[*]}")")
fi
if [[ ${#EXCLUDE_CHECKS[@]} -gt 0 ]]; then
    ARGS+=(--exclude-checks "$(IFS=,; echo "${EXCLUDE_CHECKS[*]}")")
fi
if [[ ${#PHASES[@]} -gt 0 ]]; then
    ARGS+=(--phases "$(IFS=,; echo "${PHASES[*]}")")
fi
if [[ -n "${MAX_EXAMPLES}" ]]; then
    ARGS+=(--max-examples "${MAX_EXAMPLES}")
fi
if [[ -n "${SEED}" ]]; then
    ARGS+=(--seed "${SEED}")
fi
ARGS+=(--workers "${WORKERS}")
if [[ -n "${REQUEST_TIMEOUT}" ]]; then
    ARGS+=(--request-timeout "${REQUEST_TIMEOUT}")
fi
if [[ "${JUNIT}" == true ]]; then
    mkdir -p "${OA_OUT%/}/junit"
    ARGS+=(--report-junit-path "${JUNIT_FILE}")
fi
for format in ${FORMATS[@]+"${FORMATS[@]}"}; do
    case "${format}" in
        har) ARGS+=(--report-har-path "${OA_BASE}.har.json") ;;
        vcr) ARGS+=(--report-vcr-path "${OA_BASE}.vcr.yaml") ;;
        ndjson) ARGS+=(--report-ndjson-path "${OA_BASE}.ndjson") ;;
        html) ARGS+=(--report-html-path "${OA_BASE}.html") ;;
    esac
done
ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

# record OUTCOME CODE: writes the run record when run_record is on.
record() {
    if [[ "${RUN_RECORD}" != true ]]; then
        return 0
    fi
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_TOOL_VERSION=${VERSION}
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_ARGS=("${ARGS[@]}")
    OA_INPUTS=()
    if [[ "${SPEC_URL}" == false ]]; then
        OA_INPUTS+=("spec:${SPEC}")
    fi
    if [[ -n "${CONFIG}" ]]; then
        OA_INPUTS+=("config:${CONFIG}")
    fi
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_TARGET_JSON=$(jq -cn --arg url "$(oa_url_public "${URL:-${SPEC}}")" --arg spec "$(oa_url_public "${SPEC}")" \
        '{url: $url, spec: $spec}')
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_REPORTS=("${REPORT}" "${JUNIT_FILE}" "${OA_BASE}.har.json" "${OA_BASE}.vcr.yaml" "${OA_BASE}.ndjson")
    oa_run_record "${RECORD}" contract_test "$1" "$2" "${STARTED}"
}

if [[ -n "${URL}" ]]; then
    echo "Testing ${SHOWN_TARGET} against ${SHOWN_SPEC} with Schemathesis ${VERSION:-(version unknown)}:"
else
    echo "Testing the API ${SHOWN_SPEC} names against it with Schemathesis ${VERSION:-(version unknown)}:"
fi
oa_show_command schemathesis "${ARGS[@]}" | sed 's/^/  /'
CODE=0
# Hypothesis keeps its example database and caches beside the work directory,
# not in the checkout, and SCHEMATHESIS_HOOKS, which would run a Python
# module, and the variables that stand in for parameters are left out.
env -u SCHEMATHESIS_HOOKS -u SCHEMATHESIS_BASE_URL -u SCHEMATHESIS_ORIGIN -u SCHEMATHESIS_WAIT_FOR_SCHEMA \
    HYPOTHESIS_STORAGE_DIRECTORY="${WORK}/hypothesis" NO_COLOR=1 "${OA_TOOL}" "${ARGS[@]}" || CODE=$?
echo "Schemathesis exited with ${CODE}."

# --- The verdict ---
if [[ ! -s "${WORK}/report.json" ]] || ! oa_json_is "${WORK}/report.json" 'type == "object" and has("complete")'; then
    # shellcheck disable=SC2034 # read by oa_run_record
    OA_COUNTS=null
    record error "${CODE}"
    echo "ERROR: Schemathesis exited with ${CODE} and wrote no JSON report, so the API was not tested: see its output" >&2
    echo "  above (a document it couldn't load, a bad option)." >&2
    exit 1
fi
cp "${WORK}/report.json" "${REPORT}"
# The seed as the report writes it: jq 1.6 reads numbers as doubles, which
# round a 128-bit seed, so it is taken from the text, the "seed" whose value
# is the report's seed.
# shellcheck disable=SC2016 # jq program, not shell
RUN_SEED=$(jq -r -R -s --slurpfile report "${REPORT}" \
    '[scan("\"seed\"\\s*:\\s*([0-9]+)")[0] | select(tonumber == $report[0].seed)] | first // empty' "${REPORT}")
# shellcheck disable=SC2016 # jq program, not shell
COUNTS=$(jq -c --arg seed "${RUN_SEED}" '{
    operations_tested: (.operations.tested // 0), operations_selected: (.operations.selected // 0),
    test_cases: (.test_cases.generated // 0), failures: ([.failures[]?.count] | add // 0),
    failure_kinds: (.failures | length), errors: ([.errors[]?.count] | add // 0),
    seed: (if $seed == "" then null else $seed end), stop_reason: .stop_reason}' "${REPORT}")
# shellcheck disable=SC2034 # read by oa_run_record
OA_COUNTS=${COUNTS}
if [[ "${CODE}" -ne 0 && "${CODE}" -ne 1 ]]; then
    record error "${CODE}"
    echo "ERROR: Schemathesis exited with ${CODE}, so its run is not a result." >&2
    exit 1
fi
if ! oa_json_is "${REPORT}" '.complete == true and (.stop_reason == "completed" or .stop_reason == "failure_limit")'; then
    record error "${CODE}"
    echo "ERROR: Schemathesis's run did not complete ($(jq -r '.stop_reason // "no stop reason"' "${REPORT}")), so it is not a result." >&2
    exit 1
fi
if oa_json_is "${REPORT}" '(.errors | length) > 0'; then
    record error "${CODE}"
    echo "ERROR: Schemathesis could not test everything it was asked to:" >&2
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r '.errors[] | "  \(.title) (\(.count))"' "${REPORT}" >&2
    echo "  These are errors, not findings: an operation the document describes in a way Schemathesis can't use," >&2
    echo "  or an API that didn't answer. Its output above has the details." >&2
    exit 1
fi
TESTED=$(jq -r '.operations_tested' <<< "${COUNTS}")
CASES=$(jq -r '.test_cases' <<< "${COUNTS}")
if [[ "${TESTED}" -eq 0 || "${CASES}" -eq 0 ]]; then
    if [[ "${ALLOW_EMPTY}" != true ]]; then
        record error "${CODE}"
        echo "ERROR: Schemathesis tested $(oa_plural "${TESTED}" operation operations) with $(oa_plural "${CASES}" "test case" "test cases"), so nothing" >&2
        echo "  was checked. Check the document's operations and the phases; allow_empty lets such a run pass." >&2
        exit 1
    fi
    echo "WARN: Schemathesis checked nothing; allow_empty is true, so this step passes." >&2
fi
# shellcheck disable=SC2016 # jq program, not shell
jq -r '.failures[] | "  \(.code // "") \(.title) (\(.count)): \(.operations | join(", "))"' "${REPORT}" | awk 'NR <= 50' || true
FAILURES=$(jq -r '.failures' <<< "${COUNTS}")
KINDS=$(jq -r '.failure_kinds' <<< "${COUNTS}")
SUMMARY="Schemathesis tested $(oa_plural "${TESTED}" operation operations) with $(oa_plural "${CASES}" "test case" "test cases") (seed $(jq -r '.seed // "unknown"' <<< "${COUNTS}")): $(oa_plural "${KINDS}" "kind of failure" "kinds of failure"), $(oa_plural "${FAILURES}" failure failures)."
if [[ "${KINDS}" -gt 0 ]]; then
    if [[ "${REPORT_ONLY}" == true ]]; then
        record findings-reported "${CODE}"
    else
        record findings "${CODE}"
    fi
    oa_gate true "${REPORT_ONLY}" "${SUMMARY}"
fi
record passed "${CODE}"
oa_gate false "${REPORT_ONLY}" "${SUMMARY}"
