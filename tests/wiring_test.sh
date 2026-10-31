#!/usr/bin/env bash
#
# Checks how the command YAML and the scripts fit together, offline:
#
#   - every PARAM_ variable a script reads is set by each command that runs
#     it, from the parameter of the same name where a parameter sets it, and
#     every parameter a command declares is used;
#   - every script that evals SCRIPT_OPENAPI_LIB gets it;
#   - a command that writes into output_dir stores it as artifacts under
#     openapi-reports/ with when: always;
#   - install_vacuum, install_oasdiff and install_uv default to the newest
#     release in their checksum tables, install_schemathesis to the newest
#     release in its locks, and install to the same;
#   - the run record schema names every command that writes one;
#   - the README documents every command and names its GitHub Action;
#   - every run step has a name, as orb-tools review's RC008 asks;
#   - tests/run_command.sh runs each command's own script, with each PARAM_
#     variable once.
#
# Run from a checkout:
#   bash tests/wiring_test.sh

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"
FAILURES=0
fail() {
    printf 'FAIL: %s\n' "$*"
    FAILURES=$((FAILURES + 1))
}

# param_vars SCRIPT: the PARAM_ variables SCRIPT reads.
param_vars() {
    grep -oE '\$\{PARAM_[A-Z0-9_]+' "$1" | sed 's/^\${//' || true
}

# unnamed_runs FILE: "<line>: <problem>" for each run step in FILE without a
# name: a "- run:" mapping whose own keys have no name, or an empty one, and
# a "- run: <command>" string, which can't have one.
unnamed_runs() {
    awk '
        function close_step() {
            if (open && !named) { print start ": this run step has no name" }
            open = 0
        }
        {
            match($0, /^ */)
            indent = RLENGTH
            if (open && NF && indent <= dash) { close_step() }
            if ($0 ~ /^ *- run:/) {
                close_step()
                dash = indent
                rest = $0
                sub(/^ *- run:[ ]*/, "", rest)
                if (rest != "") { print FNR ": this run step is a string, which has no name" }
                else { open = 1; named = 0; keys = -1; start = FNR }
                next
            }
            if (open && NF) {
                if (keys < 0) { keys = indent }
                if (indent == keys && $0 ~ /^ *name:/) {
                    value = $0
                    sub(/^ *name:[ ]*/, "", value)
                    gsub(/["\047 ]/, "", value)
                    if (value != "") { named = 1 }
                }
            }
        }
        END { close_step() }
    ' "$1"
}

# params FILE: the parameters a command declares.
params() {
    awk '/^parameters:/ { p = 1; next } /^[^ ]/ { p = 0 } p && /^  [a-z_0-9]+:$/ { sub(/:$/, ""); print $1 }' "$1"
}

# default FILE PARAMETER: the default of PARAMETER in FILE, without quotes.
default() {
    awk -v name="  $2:" '$0 == name { p = 1; next } p && /^  [^ ]/ { exit } p && /^    default:/ { sub(/^    default: */, ""); gsub(/"/, ""); print; exit }' "$1"
}

for yml in src/commands/*.yml; do
    command=${yml##*/}
    command=${command%.yml}
    mapfile -t declared < <(params "${yml}")
    mapfile -t scripts < <(grep -oE 'command: << include\([^)]+\.sh\) >>' "${yml}" \
        | sed -E 's/command: << include\(([^)]+)\) >>/\1/' | sort -u)
    passed=$(grep -oE 'PARAM_[A-Z0-9_]+: << parameters\.[a-z0-9_]+ >>' "${yml}" || true)
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        var=${line%%:*}
        name=${line##*parameters.}
        name=${name% >>}
        if [[ "${var}" != "PARAM_${name^^}" ]]; then
            fail "${command}: ${var} is set from parameters.${name}"
        fi
    done <<< "${passed}"
    for script in ${scripts[@]+"${scripts[@]}"}; do
        mapfile -t read_vars < <(param_vars "src/${script}" | sort -u)
        for var in ${read_vars[@]+"${read_vars[@]}"}; do
            if ! grep -qE "^ +${var}: " "${yml}"; then
                fail "${command}: src/${script} reads ${var}, which ${command}.yml doesn't set"
            fi
        done
        if grep -q SCRIPT_OPENAPI_LIB "src/${script}" && ! grep -q "SCRIPT_OPENAPI_LIB: << include(scripts/lib/openapi.sh) >>" "${yml}"; then
            fail "${command}: src/${script} needs SCRIPT_OPENAPI_LIB, which ${command}.yml doesn't pass"
        fi
    done
    for name in ${declared[@]+"${declared[@]}"}; do
        if ! grep -qE "<< parameters\.${name} >>" "${yml}"; then
            fail "${command}: the parameter ${name} is never used"
        fi
    done
    if grep -q 'parameters.output_dir' "${yml}"; then
        if ! grep -qE '^ +destination: openapi-reports$' "${yml}" || ! grep -qE '^ +path: << parameters\.output_dir >>$' "${yml}"; then
            fail "${command}: doesn't store output_dir as artifacts under openapi-reports/"
        fi
        if [[ "$(grep -c 'when: always' "${yml}")" -lt "$(grep -cE '^ +- store_(artifacts|test_results):' "${yml}")" ]]; then
            fail "${command}: a store step doesn't run when the step fails (when: always)"
        fi
    fi
    if ! grep -q "### \`openapi/${command}\`" README.md 2> /dev/null; then
        fail "${command}: the README has no section for it"
    fi
    if ! grep -q "juburr/openapi-orb/actions/${command}@" README.md 2> /dev/null; then
        fail "${command}: the README doesn't name its GitHub Action, juburr/openapi-orb/actions/${command}"
    fi
    while IFS= read -r problem; do
        [[ -n "${problem}" ]] && fail "${yml}:${problem}"
    done < <(unnamed_runs "${yml}")
done

# The install commands default to the newest release they can verify, and
# install to the same ones.
# newest TOOL: the newest release in TOOL's checksum table.
newest() {
    sed -n '/^declare -A sha512sums=($/,/^)$/p' "src/install/$1/install.sh" | grep -oE '^    \["[0-9.]+/' \
        | tr -d ' ["/' | sort -uV | tail -n 1
}
uv=$(newest uv)
for file in install_uv:version install:uv_version install_schemathesis:uv_version; do
    value=$(default "src/commands/${file%%:*}.yml" "${file#*:}")
    if [[ "${value}" != "${uv}" ]]; then
        fail "${file%%:*}'s ${file#*:} defaults to ${value}, not ${uv}, the newest uv in the checksum table"
    fi
done
for tool in vacuum oasdiff; do
    release=$(newest "${tool}")
    if [[ "$(default "src/commands/install_${tool}.yml" version)" != "${release}" ]]; then
        fail "install_${tool} defaults to $(default "src/commands/install_${tool}.yml" version), not ${release}, the newest in its table"
    elif [[ "$(default src/commands/install.yml "${tool}_version")" != "${release}" ]]; then
        fail "install's ${tool}_version defaults to $(default src/commands/install.yml "${tool}_version"), not ${release}"
    fi
done
tool=schemathesis
release=$(sed -n "s/^# >>> ${tool} \\([0-9.]*\\) >>>\$/\\1/p" "src/install/${tool}/locks.txt" | sort -V | tail -n 1)
command=install_${tool}
if [[ -z "${release}" ]]; then
    fail "src/install/${tool}/locks.txt holds no lock"
elif [[ "$(default "src/commands/${command}.yml" version)" != "${release}" ]]; then
    fail "${command} defaults to $(default "src/commands/${command}.yml" version), not ${release}, the newest in its locks"
elif [[ "$(default src/commands/install.yml "${tool}_version")" != "${release}" ]]; then
    fail "install's ${tool}_version defaults to $(default src/commands/install.yml "${tool}_version"), not ${release}"
fi
if [[ "$(default src/commands/install.yml python)" != "$(default src/commands/install_schemathesis.yml python)" ]]; then
    fail "install and install_schemathesis default to different Pythons"
fi

# Every command that writes a run record is in the schema's command enum.
enum=$(jq -r '.properties.command.enum | sort | join(" ")' schemas/run-record.v1.json)
commands=$(grep -l '^  run_record:$' src/commands/*.yml | sed 's|.*/||; s|\.yml$||' | sort | tr '\n' ' ')
if [[ "${enum}" != "${commands% }" ]]; then
    fail "the run record schema names the commands '${enum}', not '${commands% }'"
fi

# tests/run_command.sh, which test-deploy.yml runs the steps that must fail
# with, picks each command's own script. /dev/null/none can't be a
# directory, so the script stops at cd, after naming what it would run.
for yml in src/commands/*.yml; do
    grep -q '^  working_dir:$' "${yml}" || continue
    command=${yml##*/}
    command=${command%.yml}
    required=()
    while IFS= read -r name; do
        [[ -n "${name}" ]] && required+=("${name}=x")
    done < <(awk '/^parameters:/ { p = 1; next } /^[^ ]/ { p = 0 }
        p && /^  [a-z_0-9]+:$/ { if (name != "" && !seen) print name; name = $1; sub(/:$/, "", name); seen = 0; next }
        p && /^    default:/ { seen = 1 }
        END { if (name != "" && !seen) print name }' "${yml}")
    running=$(bash tests/run_command.sh "${command}" working_dir=/dev/null/none ${required[@]+"${required[@]}"} 2> /dev/null \
        | awk 'NR == 1' || true)
    if [[ "${running}" != "Running scripts/${command}.sh in /dev/null/none with "* ]]; then
        fail "run_command.sh ${command} doesn't run scripts/${command}.sh: ${running:-it printed nothing}"
    fi
    repeated=$(tr ' ' '\n' <<< "${running#* with }" | grep -oE '^PARAM_[A-Z0-9_]+=' | sort | uniq -d | tr -d '=' | tr '\n' ' ' || true)
    if [[ -n "${repeated}" ]]; then
        fail "run_command.sh ${command} sets ${repeated% } more than once"
    fi
done

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "ok: every command passes every parameter its scripts read, uses every parameter it declares, stores its reports, names its run steps, and installs the newest releases it can verify"
