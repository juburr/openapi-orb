#!/usr/bin/env bash
#
# Tests the command scripts offline, each run by tests/run_command.sh with its
# parameters' defaults from the command's YAML, against stand-ins for vacuum,
# oasdiff and Schemathesis that record every call (arguments, working
# directory, and the environment that matters) and answer from the fixtures
# in tests/fixtures/stubs:
#
#   lint: vacuum's arguments and the configuration it may not read, the gate
#     at each fail_on, SARIF and JUnit, a run that can't complete, the
#     extra_args it refuses
#   bundle: the base directory, both formats, and a bundle with a reference
#     left unresolved, which fails
#   breaking: the base (a pull request's on GitHub Actions, the remote's
#     default branch, the merge base), documents new at the base, a moved
#     document, base_file, the OpenAPI 3 check, the gate and the reports
#   drift: a generated document, or the working tree's against HEAD, and
#     differences the changelog doesn't name
#   contract_test: the configuration the orb writes (headers never
#     expanded), waiting for the API, and every way Schemathesis's run can
#     end without a verdict
#
# The breaking and drift tests run in a real git repository with an origin.
# Every run record is checked against schemas/run-record.v1.json. The
# scripts run with the bash first on the PATH, so putting an older bash there
# checks it. A stand-in circleci CLI expands $ORB_TEST_VAR.
#
# Run from a checkout:
#   bash <this file>

# The checks run small scripts in single quotes, which expand their own
# arguments.
# shellcheck disable=SC2016

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
FIX="${ROOT}/tests/fixtures"
STUBS="${FIX}/stubs"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUB="${WORK}/stub"
HOME_DIR="${WORK}/home"
JOB="${WORK}/job"
OUT="${WORK}/reports"
mkdir -p "${WORK}/bin" "${STUB}/calls" "${HOME_DIR}"

# The PATH without a real circleci CLI, which CircleCI's images have, or a
# real vacuum, oasdiff or schemathesis.
CLEAN_PATH=""
IFS=: read -ra PATH_DIRS <<< "${PATH}"
for dir in "${PATH_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue
    if [[ -e "${dir}/circleci" || -e "${dir}/vacuum" || -e "${dir}/oasdiff" || -e "${dir}/schemathesis" ]]; then
        shadow=$(mktemp -d "${WORK}/path.XXXXXX")
        for file in "${dir}"/*; do
            case "${file##*/}" in
                circleci | vacuum | oasdiff | schemathesis) ;;
                *) ln -s "${file}" "${shadow}/" ;;
            esac
        done
        dir=${shadow}
    fi
    CLEAN_PATH+="${CLEAN_PATH:+:}${dir}"
done

# Like `circleci env subst`, expands $NAME and ${NAME} references, from stdin.
cat > "${WORK}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "$*" != "env subst" ]]; then
    echo "circleci stub: expected 'env subst' with the value on stdin, got: $*" >&2
    exit 1
fi
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s' "${output}${input}"
EOF
# Waits without delaying the tests.
printf '#!/bin/sh\nexit 0\n' > "${WORK}/bin/sleep"
# The API contract_test waits for: up (HTTP 200) unless STUB_API_DOWN is set.
cat > "${WORK}/bin/curl" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_DIR}/curl.log"
if [[ -n "${STUB_API_DOWN:-}" ]]; then
    printf '000'
    exit 7
fi
printf '200'
EOF

# The common part of every stand-in: records the call.
cat > "${WORK}/record.sh" << 'EOF'
set +o errexit +o nounset +o pipefail +o xtrace
calls="${STUB_DIR}/calls"
n=$(($(find "${calls}" -name '*.args' | wc -l) + 1))
printf '%s\n' "${0##*/}" "$@" > "${calls}/${n}.args"
{
    printf 'cwd=%s\n' "${PWD}"
    env | grep -E '^(VACUUM_|SCHEMATHESIS_|HYPOTHESIS_|CI=|NO_COLOR=)' | sort
} > "${calls}/${n}.meta"
args=("$@")
# opt NAME: the value of --NAME VALUE or --NAME=VALUE.
opt() {
    local i
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            "--$1") printf '%s\n' "${args[i + 1]}"; return 0 ;;
            "--$1="*) printf '%s\n' "${args[i]#*=}"; return 0 ;;
        esac
    done
    return 1
}
# The positional arguments after --.
positional() {
    local i seen=false
    for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "${seen}" == true ]]; then printf '%s\n' "${args[i]}"; fi
        [[ "${args[i]}" == -- ]] && seen=true
    done
}
EOF

# The stand-in vacuum. Settings:
#   STUB_VACUUM_REPORT     the results spectral-report writes (default none)
#   STUB_VACUUM_EXIT       its exit code, after an error
#   STUB_VACUUM_NO_REPORT  exit 0 without writing the report
#   STUB_BUNDLE_JSON       the document bundle writes as JSON
#   STUB_BUNDLE_EXIT       bundle's exit code
cat > "${WORK}/bin/vacuum" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
case "$1" in
    version)
        echo "0.35.2"
        exit 0
        ;;
    spectral-report)
        if [[ -n "${STUB_VACUUM_EXIT:-}" ]]; then
            echo "ERROR  unable to parse specification: yaml: line 3: mapping values are not allowed"
            exit "${STUB_VACUUM_EXIT}"
        fi
        spec=$(positional | sed -n 1p)
        out=$(positional | sed -n 2p)
        echo "Report generated for '${spec}', written to '${out}'"
        [[ -n "${STUB_VACUUM_NO_REPORT:-}" ]] && exit 0
        if [[ -n "${STUB_VACUUM_REPORT:-}" ]]; then
            jq --arg spec "${spec}" 'map(.source = $spec)' "${STUB_VACUUM_REPORT}" > "${out}"
        else
            echo '[]' > "${out}"
        fi
        ;;
    bundle)
        [[ -n "${STUB_BUNDLE_EXIT:-}" ]] && { echo "ERROR cannot read file"; exit "${STUB_BUNDLE_EXIT}"; }
        out=$(positional | sed -n 2p)
        if [[ "$(opt format)" == json ]]; then
            cat "${STUB_BUNDLE_JSON:-/dev/null}" > "${out}"
        else
            printf 'openapi: 3.1.0\ninfo:\n  title: bundled\n' > "${out}"
        fi
        ;;
esac
exit 0
EOF

# The stand-in oasdiff. Settings:
#   STUB_NOT_OPENAPI      a glob: documents it matches have no openapi field
#   STUB_CHANGELOG        what changelog -f json prints (default [])
#   STUB_CHANGELOG_EXIT   changelog's exit code, after an error
#   STUB_DIFF             what diff -f json prints (default {})
cat > "${WORK}/bin/oasdiff" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
case "$1" in
    --version)
        echo "oasdiff version 1.34.1"
        exit 0
        ;;
    validate)
        spec=$(positional)
        # shellcheck disable=SC2053 # a glob
        if [[ -n "${STUB_NOT_OPENAPI:-}" && "${spec}" == ${STUB_NOT_OPENAPI} ]]; then
            echo '[{"id": "openapi-required", "text": "openapi version field is missing", "level": 3, "section": "", "source": {"file": "x"}}]'
            exit 1
        fi
        echo '[]'
        exit 0
        ;;
    changelog)
        if [[ -n "${STUB_CHANGELOG_EXIT:-}" ]]; then
            echo "Error: failed to load base spec from \"x\": open x: no such file or directory" >&2
            exit "${STUB_CHANGELOG_EXIT}"
        fi
        if [[ "$(opt format)" == markdown ]]; then
            printf '# API Changelog\n\n%s\n' "$(positional | tr '\n' ' ')"
        else
            cat "${STUB_CHANGELOG:-/dev/null}" 2> /dev/null || true
            [[ -z "${STUB_CHANGELOG:-}" ]] && echo '[]'
        fi
        ;;
    diff)
        if [[ -n "${STUB_DIFF_EXIT:-}" ]]; then
            echo "Error: failed to load revision spec" >&2
            exit "${STUB_DIFF_EXIT}"
        fi
        if [[ -n "${STUB_DIFF:-}" ]]; then cat "${STUB_DIFF}"; else echo '{}'; fi
        ;;
esac
exit 0
EOF

# The stand-in Schemathesis (the script install_schemathesis puts on the
# PATH). Settings:
#   STUB_ST_REPORT     the JSON report it writes (default st-pass.json)
#   STUB_ST_NO_REPORT  write no JSON report
#   STUB_ST_EXIT       its exit code (default the report's exit_code)
cat > "${WORK}/bin/schemathesis" << 'EOF'
#!/usr/bin/env bash
source "${STUB_RECORD}"
if [[ "$1" == --version ]]; then
    echo "python -m schemathesis.cli, version 4.32.4"
    exit 0
fi
config=$(opt config-file)
cp "${config}" "${STUB_DIR}/config.toml" 2> /dev/null
report=${STUB_ST_REPORT:-${STUB_FIXTURES}/st-pass.json}
if [[ -z "${STUB_ST_NO_REPORT:-}" ]]; then
    cp "${report}" "$(opt report-json-path)"
fi
if junit=$(opt report-junit-path); then
    echo '<testsuites><testsuite name="schemathesis" tests="1"><testcase name="GET /items"/></testsuite></testsuites>' > "${junit}"
fi
for format in har vcr ndjson; do
    if path=$(opt "report-${format}-path"); then echo "${format}" > "${path}"; fi
done
exit "${STUB_ST_EXIT:-$(jq -r '.exit_code' "${report}")}"
EOF
chmod +x "${WORK}/bin/"*

# The bundle the stand-in vacuum writes: the multi-file document with its
# references inlined.
BUNDLED="${WORK}/bundled.json"
cat > "${BUNDLED}" << 'EOF'
{"openapi": "3.1.0", "info": {"title": "bundled", "version": "1.0.0"},
 "paths": {"/items": {"get": {"responses": {"200": {"description": "The items.",
   "content": {"application/json": {"schema": {"type": "array", "items": {"$ref": "#/components/schemas/item"}}}}}}}}},
 "components": {"schemas": {"item": {"type": "object", "properties": {"id": {"type": "integer"}}}}}}
EOF

# --- The job: a git checkout with an origin, on a branch off main ---
git_q() { git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main "$@" > /dev/null 2>&1; }
git_q init --bare "${WORK}/origin.git"
git_q init "${JOB}"
cp "${FIX}/api/openapi.yaml" "${JOB}/openapi.yaml"
cp -R "${FIX}/lint" "${FIX}/multi" "${FIX}/multi-broken" "${JOB}/"
mkdir -p "${JOB}/services/orders"
cp "${FIX}/api/openapi.yaml" "${JOB}/services/orders/openapi.yaml"
cp "${FIX}/api/openapi.yaml" "${JOB}/old-name.yaml"
git_q -C "${JOB}" add -A
git_q -C "${JOB}" commit -m base
BASE_COMMIT=$(git -C "${JOB}" rev-parse HEAD)
git_q -C "${JOB}" remote add origin "${WORK}/origin.git"
git_q -C "${JOB}" push origin main
git_q -C "${JOB}" remote set-head origin main
git_q -C "${JOB}" checkout -b feature
cp "${FIX}/api/openapi-v2.yaml" "${JOB}/openapi.yaml"
cp "${FIX}/api/openapi.yaml" "${JOB}/new-api.yaml"
git_q -C "${JOB}" mv old-name.yaml renamed.yaml
git_q -C "${JOB}" add -A
git_q -C "${JOB}" commit -m feature
# main moves on after the branch left it.
git_q -C "${JOB}" checkout main
printf '# a later change on main\n' >> "${JOB}/openapi.yaml"
git_q -C "${JOB}" commit -am later
git_q -C "${JOB}" push origin main
MAIN_TIP=$(git -C "${JOB}" rev-parse HEAD)
git_q -C "${JOB}" fetch origin
git_q -C "${JOB}" checkout feature

FAILURES=0
RC=0
OUTPUT=""

# run COMMAND [NAME=VALUE ...] [-- VAR=value ...]: runs COMMAND's script in
# the job directory through tests/run_command.sh, with the parameters given
# and the environment settings after --. Recorded calls and BASH_ENV start
# empty, and output_dir is OUT unless given.
RECORDS=0
mkdir -p "${WORK}/records"
run() {
    local command=$1 params=() envs=() record
    shift
    while [[ $# -gt 0 && "$1" != -- ]]; do
        params+=("$1")
        shift
    done
    if [[ $# -gt 0 ]]; then
        shift
        envs=("$@")
    fi
    if [[ "${command}" != bundle && " ${params[*]-} " != *" output_dir="* ]]; then
        params=("output_dir=${OUT}" ${params[@]+"${params[@]}"})
    fi
    rm -rf "${STUB}/calls" "${STUB}/config.toml" "${STUB}/curl.log" "${OUT}"
    mkdir -p "${STUB}/calls"
    : > "${WORK}/bash_env"
    OUTPUT=$(cd "${JOB}" && env -u GITHUB_BASE_REF -u GITHUB_ACTIONS -u CIRCLE_BUILD_URL HOME="${HOME_DIR}" \
        PATH="${WORK}/bin:${CLEAN_PATH}" BASH_ENV="${WORK}/bash_env" STUB_DIR="${STUB}" STUB_FIXTURES="${STUBS}" \
        STUB_RECORD="${WORK}/record.sh" ${envs[@]+"${envs[@]}"} \
        bash "${ROOT}/tests/run_command.sh" "${command}" ${params[@]+"${params[@]}"} 2>&1)
    RC=$?
    for record in "${OUT}"/*.run-record.json; do
        [[ -f "${record}" ]] || continue
        RECORDS=$((RECORDS + 1))
        cp "${record}" "${WORK}/records/${RECORDS}.json"
    done
}

check() {
    local description=$1 call
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        while IFS= read -r line; do
            printf '    | %s\n' "${line}"
        done <<< "${OUTPUT}"
        for call in "${STUB}/calls/"*.args; do
            [[ -f "${call}" ]] || continue
            printf '    call %s: %s\n' "$(basename "${call}" .args)" "$(tr '\n' ' ' < "${call}")"
        done
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is() { [[ "${RC}" -eq "$1" ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
script_lacks() { ! grep -v '^Running scripts/' <<< "${OUTPUT}" | grep -qF -- "$1"; }
no_calls() { [[ -z "$(find "${STUB}/calls" -name '*.args')" ]]; }
call_count() { [[ "$(find "${STUB}/calls" -name '*.args' | wc -l)" -eq "$1" ]]; }
# call TOOL WORD: the arguments file of the first call of TOOL with WORD as
# its first argument.
call() {
    local file
    for file in $(find "${STUB}/calls" -name '*.args' | sort -t/ -k1 -V); do
        if [[ "$(sed -n 1p "${file}")" == "$1" && "$(sed -n 2p "${file}")" == "$2" ]]; then
            printf '%s\n' "${file}"
            return 0
        fi
    done
    return 1
}
# calls_of TOOL WORD: how many calls of TOOL with WORD as their first argument.
calls_of() {
    local file n=0
    for file in "${STUB}/calls/"*.args; do
        [[ -f "${file}" ]] || continue
        if [[ "$(sed -n 1p "${file}")" == "$1" && "$(sed -n 2p "${file}")" == "$2" ]]; then
            n=$((n + 1))
        fi
    done
    printf '%s\n' "${n}"
}
# has TOOL WORD ARG...: the first such call got these arguments, in this
# order, next to each other.
has() {
    local file
    file=$(call "$1" "$2") || return 1
    shift 2
    grep -qzF -- "$(printf '%s\n' "$@")" "${file}"
}
lacks() {
    local file
    file=$(call "$1" "$2") || return 1
    ! grep -qxF -- "$3" "${file}"
}
# meta TOOL WORD LINE: the first such call's recorded working directory or
# environment has LINE.
meta() {
    local file
    file=$(call "$1" "$2") || return 1
    grep -qxF -- "$3" "${file%.args}.meta"
}
no_meta() {
    local file
    file=$(call "$1" "$2") || return 1
    ! grep -q -- "$3" "${file%.args}.meta"
}
report() { [[ -s "${OUT}/$1" ]]; }
no_report() { [[ ! -e "${OUT}/$1" ]]; }
json_is() { [[ "$(jq -c "$2" "$1" 2> /dev/null)" == "$3" ]]; }
report_is() { json_is "${OUT}/$1" "$2" "$3"; }
junit_has() { grep -qF -- "$1" "${OUT}/junit/$2.xml"; }

echo "=== lint: arguments and the configuration vacuum may not read"
run lint -- VACUUM_FAIL_SEVERITY=none VACUUM_TURBO=true
check "a clean document passes" rc_is 0
check "openapi.yaml is found when specs is empty" said "specs: none given, so openapi.yaml is checked."
check "vacuum runs spectral-report on it" has vacuum spectral-report --no-update-check --no-style --
check "the document follows --, then the report" bash -c 'tail -n 2 "$1" | head -n 1 | grep -qx openapi.yaml' _ "$(call vacuum spectral-report)"
check "with a configuration of the orb's own" bash -c 'grep -A1 -x -- --config "$1" | tail -n 1 | grep -q "/vacuum.conf.yaml$"' _ "$(call vacuum spectral-report)"
check "and none of the job's VACUUM_* variables" no_meta vacuum spectral-report '^VACUUM_'
check "with CI set, so it never checks for updates" meta vacuum spectral-report CI=true
check "no ruleset: vacuum's recommended rules" lacks vacuum spectral-report --ruleset
check "the results are in lint.json" report_is lint.json 'length' 0
check "the SARIF has no results" report_is lint.sarif '.runs[0].results | length' 0
check "and names vacuum" report_is lint.sarif '.runs[0].tool.driver.name + " " + .runs[0].tool.driver.version' '"vacuum 0.35.2"'
check "JUnit says the run passed" junit_has 'name="no findings"' lint
check "the summary" said "Passed: vacuum reported 0 results in 1 document"

echo "=== lint: the gate"
run lint specs=lint/openapi.yaml -- STUB_VACUUM_REPORT="${STUBS}/vacuum-results.json"
check "errors fail the step" rc_is 1
check "counting the results at or above error" said "vacuum reported 5 results in 1 document (2 error, 1 warn, 1 info, 1 hint); 2 findings at or above error."
check "each is listed" said "lint/openapi.yaml:7:5 error path-params: operation must define parameter"
check "the report holds every result, with its document" report_is lint.json '[.[] | .spec + " " + .severity_name] | unique' '["lint/openapi.yaml error","lint/openapi.yaml hint","lint/openapi.yaml info","lint/openapi.yaml warn"]'
check "SARIF has every result" report_is lint.sarif '.runs[0].results | length' 5
check "at its level" report_is lint.sarif '[.runs[0].results[].level]' '["error","error","warning","note","note"]'
check "in its file, relative to the top of the checkout" report_is lint.sarif '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' '"lint/openapi.yaml"'
check "at its line and column" report_is lint.sarif '.runs[0].results[0].locations[0].physicalLocation.region' '{"startLine":7,"startColumn":5}'
check "line 0 is line 1" report_is lint.sarif '.runs[0].results[4].locations[0].physicalLocation.region' '{"startLine":1,"startColumn":1}'
check "every rule is named" report_is lint.sarif '[.runs[0].tool.driver.rules[].id] | length' 5
check "JUnit fails the errors" bash -c '[[ "$(grep -o "<failure" "$1" | wc -l)" -eq 2 ]]' _ "${OUT}/junit/lint.xml"
check "and skips the rest" bash -c '[[ "$(grep -o "<skipped" "$1" | wc -l)" -eq 3 ]]' _ "${OUT}/junit/lint.xml"
run lint specs=lint/openapi.yaml report_only=true -- STUB_VACUUM_REPORT="${STUBS}/vacuum-results.json"
check "report_only reports them and passes" rc_is 0
check "with a warning" said "WARN: report_only is true, so this step passes."
run lint specs=lint/openapi.yaml fail_on=warn -- STUB_VACUUM_REPORT="${STUBS}/vacuum-results.json"
check "fail_on warn counts warnings too" said "3 findings at or above warn."
run lint specs=lint/openapi.yaml fail_on=hint -- STUB_VACUUM_REPORT="${STUBS}/vacuum-results.json"
check "fail_on hint counts everything" said "5 findings at or above hint."
run lint specs=lint/openapi.yaml fail_on=warning
check "an unknown fail_on is refused" rc_is 1
check "naming the levels" said "fail_on must be error, warn, info or hint, not 'warning'."
check "before vacuum runs" no_calls

echo "=== lint: documents"
run lint specs='openapi.yaml lint/*.yaml' -- STUB_VACUUM_REPORT="${STUBS}/vacuum-results.json"
check "a list with a glob lints each document" bash -c '[[ "$(grep -l spectral-report "$1"/*.args | wc -l)" -eq 4 ]]' _ "${STUB}/calls"
check "one at a time, every result with its document" report_is lint.json '[.[].spec] | unique' '["lint/not-openapi.yaml","lint/openapi.yaml","lint/swagger.yaml","openapi.yaml"]'
run lint specs=lint/missing.yaml
check "a document that doesn't exist fails" rc_is 1
check "naming it" said "specs names 'lint/missing.yaml', but there is no such file"
check "before vacuum runs" no_calls
run lint working_dir=multi/schemas
check "no specs and no openapi.yaml fails" rc_is 1
check "saying what it looked for" said "has no openapi.yaml, openapi.yml, openapi.json"
run lint working_dir=lint specs=openapi.yaml -- STUB_VACUUM_REPORT="${STUBS}/vacuum-results.json"
check "from a directory below the top" rc_is 1
check "SARIF paths stay relative to the top" report_is lint.sarif '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' '"lint/openapi.yaml"'
check "while the report names the document as given" report_is lint.json '.[0].spec' '"openapi.yaml"'

echo "=== lint: a run that can't complete"
run lint report_only=true run_record=true -- STUB_VACUUM_EXIT=2
check "vacuum failing fails the step, report_only or not" rc_is 1
check "with vacuum's output" said "unable to parse specification"
check "saying it is not a lint result" said "vacuum could not lint openapi.yaml (exit code 2). This is not a lint result"
check "and an error run record" report_is lint.run-record.json '.outcome' '"error"'
run lint -- STUB_VACUUM_NO_REPORT=1
check "vacuum writing no report fails" rc_is 1
check "saying so" said "vacuum exited 0 but wrote no report for openapi.yaml."

echo "=== lint: rules"
printf 'extends: [[vacuum:oas, recommended]]\n' > "${JOB}/.vacuum.yaml"
mkdir -p "${JOB}/functions"
printf 'operation-description:\n  - $.paths./things.get\n' > "${JOB}/ignore.yaml"
run lint ruleset=.vacuum.yaml hard_mode=true functions=functions ignore_file=ignore.yaml
check "ruleset, hard_mode, functions and ignore_file" rc_is 0
check "reach vacuum" has vacuum spectral-report --ruleset .vacuum.yaml --hard-mode --functions functions --ignore-file ignore.yaml
run lint ruleset=https://rules.example/ruleset.yaml
check "a ruleset URL is passed on" has vacuum spectral-report --ruleset https://rules.example/ruleset.yaml
for setting in ruleset=missing.yaml functions=missing ignore_file=missing.yaml; do
    run lint "${setting}"
    check "${setting%%=*} that doesn't exist fails" rc_is 1
    check "before vacuum runs" no_calls
done
run lint extra_args='--base /specs --remote=false -g 30'
check "extra_args vacuum takes" rc_is 0
check "reach it" has vacuum spectral-report --base /specs --remote=false -g 30 --
for words in --turbo -T -qT --skip-check --changes=x.json --config=x.yaml '--ruleset x' --hard-mode -o other.yaml --base; do
    run lint extra_args="${words}"
    check "extra_args '${words}' is refused" rc_is 1
    check "before vacuum runs" no_calls
done
run lint extra_args='--remote=false other.yaml'
check "a word that isn't an option is refused" rc_is 1
check "saying vacuum would read it as a document" said "which vacuum would read as a document or report path"

echo "=== lint: the run record"
run lint specs=lint/openapi.yaml run_record=true ruleset=.vacuum.yaml -- STUB_VACUUM_REPORT="${STUBS}/vacuum-results.json"
check "is written" report lint.run-record.json
check "with the outcome" report_is lint.run-record.json '.outcome + " " + .command' '"findings lint"'
check "the tool" report_is lint.run-record.json '.tool.name + " " + .tool.version' '"vacuum 0.35.2"'
check "its inputs" report_is lint.run-record.json '[.inputs[].role]' '["spec","ruleset"]'
check "and the counts" report_is lint.run-record.json '.counts.findings' 2

echo "=== bundle"
run bundle spec=multi/openapi.yaml output=dist/openapi.yaml -- STUB_BUNDLE_JSON="${BUNDLED}"
check "a multi-file document bundles" rc_is 0
check "into output" test -s "${JOB}/dist/openapi.yaml"
check "as YAML" grep -q '^openapi: 3.1.0$' "${JOB}/dist/openapi.yaml"
check "vacuum looks for references from the document's directory" has vacuum bundle --base "${JOB}/multi"
check "bundling to JSON first, to check it" has vacuum bundle --format json -- multi/openapi.yaml
check "then to YAML" [ "$(calls_of vacuum bundle)" -eq 2 ]
check "with its own configuration" bash -c 'grep -A1 -x -- --config "$1" | tail -n 1 | grep -q "/vacuum.conf.yaml$"' _ "$(call vacuum bundle)"
check "saying how many local references are left" said "Bundled multi/openapi.yaml into dist/openapi.yaml (yaml, 1 local references)."
run bundle spec=multi/openapi.yaml output=dist/openapi.json composed=true -- STUB_BUNDLE_JSON="${BUNDLED}"
check "an output ending in .json is JSON" json_is "${JOB}/dist/openapi.json" '.openapi' '"3.1.0"'
check "bundled once" [ "$(calls_of vacuum bundle)" -eq 1 ]
check "composed reaches vacuum" has vacuum bundle --composed
jq '.components.schemas.tag = {"$ref": "./schemas/tag.yaml"} | .paths["/items"].get.responses["200"].content["application/json"].schema.items = {"$ref": "#/components/schemas/missing"}' \
    "${BUNDLED}" > "${WORK}/unresolved.json"
rm -f "${JOB}/dist/left.yaml"
run bundle spec=multi/openapi.yaml output=dist/left.yaml -- STUB_BUNDLE_JSON="${WORK}/unresolved.json"
check "a bundle with references left unresolved fails" rc_is 1
check "naming a file it couldn't inline" said "./schemas/tag.yaml"
check "and a pointer to nothing" said "#/components/schemas/missing"
check "writing no output" test ! -e "${JOB}/dist/left.yaml"
printf '{"title": "not a document"}\n' > "${WORK}/not-openapi.json"
run bundle spec=multi/openapi.yaml output=dist/left.yaml -- STUB_BUNDLE_JSON="${WORK}/not-openapi.json"
check "a bundle that isn't an OpenAPI document fails" rc_is 1
check "saying so" said "is not an OpenAPI or AsyncAPI document"
run bundle spec=multi/openapi.yaml output=dist/left.yaml -- STUB_BUNDLE_EXIT=2
check "vacuum failing fails the step" rc_is 1
check "with its output" said "cannot read file"
run bundle spec=multi/openapi.yaml output=multi/openapi.yaml
check "output can't be the document itself" rc_is 1
check "before vacuum runs" no_calls
run bundle spec=multi/openapi.yaml output=dist/x.yaml extra_args=--format=json
check "extra_args can't set the format" rc_is 1
run bundle spec=multi/openapi.yaml output=dist/x.yaml format=toml
check "an unknown format is refused" rc_is 1

echo "=== breaking: the base"
run breaking -- STUB_CHANGELOG="${STUBS}/oasdiff-changelog.json"
check "breaking changes fail the step" rc_is 1
check "compared with the merge base of origin/main, the remote's default branch" said "Comparing with origin/main (merge base ${BASE_COMMIT:0:12})."
check "which oasdiff reads from git" has oasdiff changelog -- "${BASE_COMMIT}:openapi.yaml" openapi.yaml
check "from the top of the checkout" meta oasdiff changelog "cwd=${JOB}"
check "with every flag that decides what it reads" has oasdiff changelog --format json --level info --fetch=false --color never --
check "both documents are checked to be OpenAPI 3 first" has oasdiff validate --format json -- "${BASE_COMMIT}:openapi.yaml"
check "the summary" said "3 breaking changes since origin/main (merge base ${BASE_COMMIT:0:12}) in 1 document (2 error, 1 warn; 1 other changes); 2 findings at or above error."
check "each is listed" said "openapi.yaml: error api-removed-without-deprecation: api removed without deprecation (DELETE /items/{id})"
run breaking merge_base=false -- STUB_CHANGELOG="${STUBS}/oasdiff-changelog.json"
check "merge_base false compares with the branch itself" has oasdiff changelog -- "${MAIN_TIP}:openapi.yaml" openapi.yaml
run breaking base_ref=origin/main -- GITHUB_BASE_REF=release STUB_CHANGELOG="${STUBS}/oasdiff-changelog-info.json"
check "base_ref wins over a pull request's base" said "Comparing with origin/main"
git_q -C "${JOB}" branch release "${BASE_COMMIT}"
git_q -C "${JOB}" push origin release
git_q -C "${JOB}" fetch origin
run breaking -- GITHUB_BASE_REF=release STUB_CHANGELOG="${STUBS}/oasdiff-changelog-info.json"
check "on GitHub Actions, a pull request's base branch" said "Comparing with origin/release"
check "and changes that break nothing pass" rc_is 0
check "naming them" said "0 breaking changes since origin/release"
run breaking base_ref=origin/nothing
check "a base_ref that isn't there fails" rc_is 1
check "saying how to fetch it" said "Fetch it in an earlier step, such as"
for value in -x 'main branch' HEAD:openapi.yaml; do
    run breaking base_ref="${value}"
    check "base_ref '${value}' is refused" rc_is 1
    check "before oasdiff runs" no_calls
done

echo "=== breaking: documents"
run breaking specs=new-api.yaml
check "a document the base doesn't have is new, and passes" rc_is 0
check "saying so" said "new-api.yaml: not in origin/main (merge base ${BASE_COMMIT:0:12}) (new-api.yaml), so it is new"
check "without comparing it" [ "$(calls_of oasdiff changelog)" -eq 0 ]
run breaking specs=renamed.yaml base_spec=old-name.yaml
check "base_spec names where a moved document was" has oasdiff changelog -- "${BASE_COMMIT}:old-name.yaml" renamed.yaml
run breaking specs='openapi.yaml renamed.yaml' base_spec=old-name.yaml
check "base_spec takes one document" rc_is 1
run breaking working_dir=services/orders -- STUB_CHANGELOG="${STUBS}/oasdiff-changelog-info.json"
check "from a directory below the top, paths are the top's" has oasdiff changelog -- "${BASE_COMMIT}:services/orders/openapi.yaml" services/orders/openapi.yaml
run breaking specs='openapi.yaml services/orders/openapi.yaml' -- STUB_CHANGELOG="${STUBS}/oasdiff-changelog.json"
check "several documents are each compared" [ "$(calls_of oasdiff changelog)" -eq 4 ]
check "and reported with their document" report_is breaking.json '[.[].spec] | unique' '["openapi.yaml","services/orders/openapi.yaml"]'
check "the changelog has a section for each" bash -c '[[ "$(grep -c "^## " "$1")" -eq 2 ]]' _ "${OUT}/breaking.md"
run breaking base_file=renamed.yaml -- STUB_CHANGELOG="${STUBS}/oasdiff-changelog-info.json"
check "base_file is compared with as it is" has oasdiff changelog -- renamed.yaml openapi.yaml
check "from the working directory" meta oasdiff changelog "cwd=${JOB}"
run breaking base_file=renamed.yaml base_ref=origin/main
check "base_file and base_ref can't both be set" rc_is 1
run breaking specs=lint/swagger.yaml -- 'STUB_NOT_OPENAPI=*swagger*'
check "a document that isn't OpenAPI 3 fails" rc_is 1
check "saying so, since oasdiff would compare it as empty" said "is not an OpenAPI 3 document: it has no openapi field"
check "before comparing" [ "$(calls_of oasdiff changelog)" -eq 0 ]
run breaking report_only=true run_record=true -- STUB_CHANGELOG_EXIT=102
check "a comparison that can't run fails, report_only or not" rc_is 1
check "with oasdiff's error" said "failed to load base spec"
check "saying it is not a result" said "oasdiff could not compare"
check "and an error run record" report_is breaking.run-record.json '.outcome' '"error"'
mkdir -p "${WORK}/elsewhere"
cp "${FIX}/api/openapi.yaml" "${WORK}/elsewhere/"
run breaking working_dir="${WORK}/elsewhere"
check "outside a git checkout, without base_file, fails" rc_is 1
check "saying so" said "is not in a git checkout"

echo "=== breaking: the gate and the reports"
run breaking fail_on=warn -- STUB_CHANGELOG="${STUBS}/oasdiff-changelog.json"
check "fail_on warn counts WARN changes too" said "3 findings at or above warn."
run breaking report_only=true -- STUB_CHANGELOG="${STUBS}/oasdiff-changelog.json"
check "report_only reports them and passes" rc_is 0
check "every change is in breaking.json" report_is breaking.json 'length' 4
check "with its level's name" report_is breaking.json '[.[].level_name]' '["error","error","warn","info"]'
check "the changelog is in breaking.md" grep -q '^# API Changelog' "${OUT}/breaking.md"
check "SARIF has the breaking changes alone" report_is breaking.sarif '.runs[0].results | length' 3
check "ERR as error, WARN as warning" report_is breaking.sarif '[.runs[0].results[].level]' '["error","error","warning"]'
check "where oasdiff found them in the new document" report_is breaking.sarif '.runs[0].results[1].locations[0].physicalLocation' '{"artifactLocation":{"uri":"openapi.yaml"},"region":{"startLine":106,"startColumn":9}}'
check "a removal at the document's first line" report_is breaking.sarif '.runs[0].results[0].locations[0].physicalLocation.region' '{"startLine":1}'
check "with oasdiff's fingerprint" report_is breaking.sarif '.runs[0].results[0].partialFingerprints' '{"oasdiffFingerprint/v1":"a1b2c3d4e5f6"}'
check "JUnit fails the ERR changes" bash -c '[[ "$(grep -o "<failure" "$1" | wc -l)" -eq 2 ]]' _ "${OUT}/junit/breaking.xml"
printf 'api-removed-without-deprecation warn\n' > "${JOB}/levels.txt"
printf 'DELETE /items/{id} api removed without deprecation\n' > "${JOB}/err-ignore.txt"
run breaking severity_levels=levels.txt err_ignore=err-ignore.txt warn_ignore=err-ignore.txt
check "policy files reach oasdiff by their absolute paths" has oasdiff changelog "--severity-levels=${JOB}/levels.txt" \
    "--err-ignore=${JOB}/err-ignore.txt" "--warn-ignore=${JOB}/err-ignore.txt"
run breaking severity_levels=missing.txt
check "a policy file that doesn't exist fails" rc_is 1
run breaking extra_args='--flatten-allof -p /items --deprecation-days-stable 30'
check "extra_args oasdiff takes" rc_is 0
check "reach it" has oasdiff changelog --flatten-allof -p /items --deprecation-days-stable 30 --
for words in --format=yaml '--level err' --fetch --open -o ERR --composed '--err-ignore x' openapi.yaml -p; do
    run breaking extra_args="${words}"
    check "extra_args '${words}' is refused" rc_is 1
    check "before oasdiff runs" no_calls
done
run breaking run_record=true -- STUB_CHANGELOG="${STUBS}/oasdiff-changelog.json"
check "the run record names the base" report_is breaking.run-record.json '.target' "{\"base_ref\":\"origin/main\",\"base_commit\":\"${BASE_COMMIT}\",\"merge_base\":true,\"base_file\":null}"
check "and each document's result" report_is breaking.run-record.json '.results' '[{"spec":"openapi.yaml","outcome":"compared","changes":4,"breaking":3}]'

echo "=== drift"
printf '{"openapi": "3.1.0"}\n' > "${JOB}/generated.json"
run drift spec=openapi.yaml generated=generated.json
check "a generated document that matches passes" rc_is 0
check "saying so" said "The documents match: generated.json (generated) against openapi.yaml (committed)."
check "oasdiff's diff compares them" has oasdiff diff --format json --fetch=false -- openapi.yaml generated.json
check "both are checked to be OpenAPI 3" [ "$(calls_of oasdiff validate)" -eq 2 ]
check "drift.json says there is no drift" report_is drift.json '.drift' false
run drift spec=openapi.yaml generated=generated.json -- STUB_DIFF="${STUBS}/oasdiff-diff.json" STUB_CHANGELOG="${STUBS}/oasdiff-changelog-info.json"
check "a difference is drift, which fails" rc_is 1
check "naming each change" said "info endpoint-added: endpoint added (GET /health)"
check "the summary" said "The documents differ: generated.json (generated) against openapi.yaml (committed), 1 change (0 breaking changes)."
check "the difference is in drift.diff.json" report_is drift.diff.json '.paths.added' '["/health"]'
check "and drift.json" report_is drift.json '.drift' true
check "JUnit fails each change" junit_has 'endpoint-added' drift
run drift spec=openapi.yaml generated=generated.json report_only=true -- STUB_DIFF="${STUBS}/oasdiff-diff-description.json"
check "report_only reports drift and passes" rc_is 0
check "a difference the changelog doesn't name is drift too" said "The documents differ in info, which the changelog doesn't name"
check "JUnit says so" junit_has 'the documents differ' drift
printf '# regenerated\n' >> "${JOB}/openapi.yaml"
run drift spec=openapi.yaml
check "without generated, the working tree's copy is compared with HEAD's" has oasdiff diff -- HEAD:openapi.yaml openapi.yaml
check "from the top of the checkout" meta oasdiff diff "cwd=${JOB}"
git -C "${JOB}" checkout -q -- openapi.yaml
printf 'openapi: 3.1.0\n' > "${JOB}/untracked.yaml"
run drift spec=untracked.yaml
check "a document that isn't committed fails without generated" rc_is 1
check "saying so" said "untracked.yaml is not committed"
run drift spec=openapi.yaml generated=openapi.yaml
check "generated can't be spec" rc_is 1
run drift spec=openapi.yaml generated=missing.json
check "a generated document that doesn't exist fails" rc_is 1
check "saying to generate it first" said "Generate the document from the"
run drift spec=openapi.yaml generated=generated.json exclude_elements='description, examples'
check "exclude_elements reaches oasdiff's diff" has oasdiff diff --exclude-elements=description,examples
run drift spec=openapi.yaml generated=generated.json exclude_elements=comments
check "an unknown element is refused" rc_is 1
run drift spec=openapi.yaml generated=generated.json report_only=true -- STUB_DIFF_EXIT=102
check "a diff that can't run fails, report_only or not" rc_is 1
run drift spec=lint/swagger.yaml generated=generated.json -- 'STUB_NOT_OPENAPI=*swagger*'
check "a committed document that isn't OpenAPI 3 fails" rc_is 1
run drift spec=openapi.yaml generated=generated.json run_record=true -- STUB_DIFF="${STUBS}/oasdiff-diff.json"
check "the run record" report_is drift.run-record.json '.outcome + " " + ([.inputs[].role] | join(","))' '"findings spec,generated"'
run drift spec=openapi.yaml generated=generated.json extra_args=--fail-on-diff
check "extra_args can't set fail-on-diff" rc_is 1

echo "=== contract_test: the run"
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 -- SCHEMATHESIS_HOOKS=evil.hooks SCHEMATHESIS_BASE_URL=http://evil.example
check "an API that passes every check passes" rc_is 0
check "the summary" said "Schemathesis tested 4 operations with 240 test cases (seed 12345): 0 kinds of failure, 0 failures."
check "Schemathesis runs with the orb's configuration" bash -c 'grep -A1 -x -- --config-file "$1" | tail -n 1 | grep -q "/schemathesis.toml$"' _ "$(call schemathesis --config-file)"
check "and the document and URL" has schemathesis --config-file --no-color run openapi.yaml --generation-database none
check "the URL" has schemathesis --config-file --url http://localhost:8080
check "one worker" has schemathesis --config-file --workers 1
check "JUnit where CircleCI stores it" has schemathesis --config-file --report-junit-path "${OUT}/junit/contract-test.xml"
check "which turns off the request cache" grep -qx 'enabled = false' "${STUB}/config.toml"
check "without SCHEMATHESIS_HOOKS, which would run a module" no_meta schemathesis --config-file '^SCHEMATHESIS_HOOKS='
check "or SCHEMATHESIS_BASE_URL" no_meta schemathesis --config-file '^SCHEMATHESIS_BASE_URL='
check "Hypothesis keeps its files out of the checkout" bash -c 'grep -q "^HYPOTHESIS_STORAGE_DIRECTORY=/tmp/" "${1%.args}.meta"' _ "$(call schemathesis --config-file)"
check "the JSON report is contract-test.json" report_is contract-test.json '.stop_reason' '"completed"'
check "it didn't wait" test ! -e "${STUB}/curl.log"
run contract_test spec=openapi.yaml url=http://localhost:8080 -- STUB_ST_REPORT="${STUBS}/st-failures.json"
check "a failed check fails the step" rc_is 1
check "naming it" said "ST104 Response violates schema (12): GET /items"
check "and counting" said "1 kind of failure, 12 failures."
check "it waited for the API first" said "It answered (HTTP 200)."
check "at the URL" grep -qF -- 'http://localhost:8080' "${STUB}/curl.log"
run contract_test spec=openapi.yaml url=http://localhost:8080 report_only=true -- STUB_ST_REPORT="${STUBS}/st-failures.json"
check "report_only reports failures and passes" rc_is 0

echo "=== contract_test: no verdict"
run contract_test spec=openapi.yaml url=http://localhost:8080 report_only=true run_record=true -- STUB_ST_REPORT="${STUBS}/st-errors.json"
check "errors fail the step, report_only or not" rc_is 1
check "naming them" said "Connection refused (3)"
check "as errors, not findings" said "These are errors, not findings"
check "with an error run record" report_is contract-test.run-record.json '.outcome' '"error"'
run contract_test spec=openapi.yaml url=http://localhost:8080 -- STUB_ST_REPORT="${STUBS}/st-empty.json"
check "a run that tested nothing fails" rc_is 1
check "saying so" said "so nothing"
run contract_test spec=openapi.yaml url=http://localhost:8080 allow_empty=true -- STUB_ST_REPORT="${STUBS}/st-empty.json"
check "unless allow_empty" rc_is 0
run contract_test spec=openapi.yaml url=http://localhost:8080 report_only=true -- STUB_ST_REPORT="${STUBS}/st-incomplete.json"
check "a run that didn't complete fails" rc_is 1
check "naming why" said "did not complete (server_unavailable)"
run contract_test spec=openapi.yaml url=http://localhost:8080 report_only=true -- STUB_ST_NO_REPORT=1 STUB_ST_EXIT=2
check "no report fails" rc_is 1
check "saying the API was not tested" said "wrote no JSON report, so the API was not tested"
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=2 -- STUB_API_DOWN=1
check "an API that never answers fails" rc_is 1
check "after waiting" said "http://localhost:8080 did not answer within 2 seconds"
check "before Schemathesis runs" [ "$(calls_of schemathesis --config-file)" -eq 0 ]

echo "=== contract_test: headers and configuration"
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 \
    headers=$'Authorization: Bearer ${API_TOKEN}\n# a comment\nX-Tenant: acme "quoted"' -- API_TOKEN=s3cret-token
check "headers" rc_is 0
check "go in the configuration, with their placeholders as written" grep -qxF '"Authorization" = "Bearer ${API_TOKEN}"' "${STUB}/config.toml"
check "quoted for TOML" grep -qxF '"X-Tenant" = "acme \"quoted\""' "${STUB}/config.toml"
check "never on the command line" lacks schemathesis --config-file -H
check "and the secret appears nowhere" script_lacks "s3cret-token"
check "not even in the configuration" bash -c '! grep -q s3cret "$1"' _ "${STUB}/config.toml"
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 headers='Bad Header: x'
check "a header name with a space is refused" rc_is 1
printf '[generation]\nmode = "positive"\n' > "${JOB}/st.toml"
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 config=st.toml
check "config is the configuration Schemathesis reads" has schemathesis --config-file "${JOB}/st.toml"
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 config=st.toml headers='A: b'
check "config and headers can't both be set" rc_is 1
printf '[cache]\nenabled = true\n' > "${JOB}/schemathesis.toml"
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0
check "a schemathesis.toml in the checkout is not read" said "Not reading ${JOB}/schemathesis.toml"
rm -f "${JOB}/schemathesis.toml"

echo "=== contract_test: parameters"
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 checks='not_a_server_error, response_schema_conformance' \
    exclude_checks=negative_data_rejection phases='examples fuzzing' max_examples=50 seed=7 workers=auto request_timeout=5 formats='har ndjson'
check "every setting" rc_is 0
check "checks" has schemathesis --config-file --checks not_a_server_error,response_schema_conformance
check "exclude_checks" has schemathesis --config-file --exclude-checks negative_data_rejection
check "phases" has schemathesis --config-file --phases examples,fuzzing
check "max_examples and seed" has schemathesis --config-file --max-examples 50 --seed 7 --workers auto --request-timeout 5
check "formats" has schemathesis --config-file --report-har-path "${OUT}/contract-test.har.json"
check "write their reports" report contract-test.ndjson
for setting in phases=everything workers=0 seed=abc max_examples=-1 formats=pdf checks=Not-A-Check wait_for_api=soon; do
    run contract_test spec=openapi.yaml url=http://localhost:8080 "${setting}"
    check "${setting} is refused" rc_is 1
    check "before Schemathesis runs" no_calls
done
run contract_test spec=openapi.yaml wait_for_api=0
check "a file document needs url" rc_is 1
check "saying so" said "url is empty"
run contract_test spec=http://localhost:8080/openapi.json wait_for_api=1
check "a URL document needs no url" rc_is 0
check "and is waited for" grep -qF -- 'http://localhost:8080/openapi.json' "${STUB}/curl.log"
run contract_test spec=missing.yaml url=http://localhost:8080
check "a document that doesn't exist fails" rc_is 1
run contract_test spec=openapi.yaml url=localhost:8080
check "a url without its scheme is refused" rc_is 1
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 extra_args='--mode positive --max-failures 3'
check "extra_args Schemathesis takes" rc_is 0
check "reach it" has schemathesis --config-file --mode positive --max-failures 3
for words in '-H X:y' '--header=X:y' '--auth u:p' -a --report=har --url=http://x '--seed 1' other.yaml; do
    run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 extra_args="${words}"
    check "extra_args '${words}' is refused" rc_is 1
done
run contract_test spec=openapi.yaml url=http://localhost:8080 wait_for_api=0 run_record=true -- STUB_ST_REPORT="${STUBS}/st-failures.json"
check "the run record" report_is contract-test.run-record.json '.outcome + " " + (.counts.failures | tostring) + " " + .target.url' '"findings 12 http://localhost:8080"'
check "with the tool" report_is contract-test.run-record.json '.tool.name + " " + .tool.version' '"schemathesis 4.32.4"'

echo "=== a version from the CircleCI CLI, and without it"
run lint specs='$ORB_TEST_VAR' -- ORB_TEST_VAR=openapi.yaml PATH="${WORK}/bin:${CLEAN_PATH}"
check "the CLI expands a parameter" rc_is 0
rm -f "${WORK}/bin/circleci.off"
mv "${WORK}/bin/circleci" "${WORK}/bin/circleci.off"
run lint specs='$ORB_TEST_VAR' -- ORB_TEST_VAR=openapi.yaml
check "without it the value is taken as is" rc_is 1
check "naming it" said "specs names '\$ORB_TEST_VAR'"
mv "${WORK}/bin/circleci.off" "${WORK}/bin/circleci"

echo "=== run records against the schema"
problems=""
for record in "${WORK}/records/"*.json; do
    [[ -f "${record}" ]] || continue
    problem=$(jq -r --slurpfile schema "${ROOT}/schemas/run-record.v1.json" '$schema[0] as $schema
        | ($schema.required - keys | map("missing \(.)")[]),
          (select(.schema != $schema.properties.schema.const) | "schema is \(.schema)"),
          (select(.outcome as $o | $schema.properties.outcome.enum | index($o) | not) | "outcome \(.outcome)")' "${record}" 2>&1)
    if [[ -n "${problem}" ]]; then
        problems+="${record##*/}: ${problem}"$'\n'
    fi
done
OUTPUT=${problems}
check "every record (${RECORDS}) has the fields the schema requires" test -z "${problems}"
if command -v python3 > /dev/null 2>&1 && python3 -c 'import jsonschema' 2> /dev/null; then
    OUTPUT=$(python3 - "${ROOT}/schemas/run-record.v1.json" "${WORK}/records/"*.json 2>&1 << 'EOF'
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
validator = jsonschema.Draft202012Validator(schema)
bad = 0
for path in sys.argv[2:]:
    for error in validator.iter_errors(json.load(open(path))):
        print("%s: %s at %s" % (path.rsplit("/", 1)[-1], error.message, "/".join(map(str, error.path))))
        bad += 1
sys.exit(1 if bad else 0)
EOF
    )
    check "every record validates against schemas/run-record.v1.json" test $? -eq 0
else
    echo "skip: python3 with jsonschema is not installed, so the records were not validated against the schema"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} command check(s) failed."
    exit 1
fi
echo "All command checks passed."
