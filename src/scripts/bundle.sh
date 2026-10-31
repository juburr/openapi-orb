#!/bin/bash
#
# Bundles an OpenAPI document split across files into one, with vacuum's
# bundle command, for the bundle command: every $ref to another file, and with
# remote references allowed every $ref to a URL, is inlined, so the result
# can be published, served or given to a tool that reads one file.
#
# vacuum writes what it could bundle and exits 0 even when a reference
# couldn't be resolved, so the orb bundles to JSON first and checks that
# document: an OpenAPI (or AsyncAPI) document, every $ref in it local (#...)
# and pointing at something that exists. Only then is it written to output,
# as JSON or YAML. vacuum reads a vacuum.conf.* from the working directory and
# VACUUM_* variables, so it runs with neither.

set -euo pipefail

if [[ -z "${SCRIPT_OPENAPI_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_OPENAPI_LIB is not set; run this script through the orb's bundle command." >&2
    exit 1
fi
eval "${SCRIPT_OPENAPI_LIB}"

SPEC=$(oa_subst "${PARAM_SPEC}")
OUTPUT=$(oa_subst "${PARAM_OUTPUT}")
FORMAT=$(oa_subst "${PARAM_FORMAT}")
COMPOSED=$(oa_bool composed "${PARAM_COMPOSED}")
oa_words extra_args "$(oa_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${OA_WORDS[@]+"${OA_WORDS[@]}"})

# --- Parameters ---
if [[ -z "${SPEC}" || "${SPEC}" == -* || ! -f "${SPEC}" ]]; then
    echo "ERROR: spec must name the document to bundle; '${SPEC}' is not a file in $(pwd)." >&2
    exit 1
fi
if [[ -z "${OUTPUT}" || "${OUTPUT}" == -* || "${OUTPUT}" == */ || "${OUTPUT}" == *$'\n'* ]]; then
    echo "ERROR: output must name the file to write the bundled document to, not '${OUTPUT}'." >&2
    exit 1
fi
if [[ -d "${OUTPUT}" ]]; then
    echo "ERROR: output names ${OUTPUT}, which is a directory; name the file to write." >&2
    exit 1
fi
if [[ -e "${OUTPUT}" && "${OUTPUT}" -ef "${SPEC}" ]]; then
    echo "ERROR: output is the document itself (${SPEC}); bundling would overwrite the file it reads." >&2
    exit 1
fi
case "${FORMAT}" in
    auto)
        case "${OUTPUT,,}" in
            *.json) FORMAT=json ;;
            *) FORMAT=yaml ;;
        esac
        ;;
    yaml | json) ;;
    *)
        echo "ERROR: format must be auto, yaml or json, not '${FORMAT}'." >&2
        exit 1
        ;;
esac
expect_value=false
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    if [[ "${expect_value}" == true ]]; then
        expect_value=false
        continue
    fi
    case "${word}" in
        --stdin | --stdout | --format | --format=* | --base | --base=* | --config | --config=* | --composed | --composed=* \
            | -i* | -o* | -p* | -c*)
            echo "ERROR: extra_args can't hold '${word}': the bundle command sets it (spec, output, format, composed)." >&2
            exit 1
            ;;
        -d | -g | --delimiter | --timeout | --lookup-timeout | --fetch-timeout | --cert-file | --key-file | --ca-file)
            expect_value=true
            ;;
        -*) ;;
        *)
            echo "ERROR: extra_args can't hold '${word}', which vacuum would read as a document or output path." >&2
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
TEMP=""
trap 'rm -rf "${WORK}" ${TEMP:+"${TEMP}"}' EXIT
printf '# openapi-orb: vacuum runs with the bundle command parameters alone.\n' > "${WORK}/vacuum.conf.yaml"
ENV_UNSET=()
while IFS= read -r name; do
    if [[ "${name}" == VACUUM_* ]]; then
        ENV_UNSET+=(-u "${name}")
    fi
done < <(compgen -e)
# vacuum looks for references from --base, the working directory by default,
# not from the document's directory.
BASE=$(cd "$(dirname "${SPEC}")" && pwd)
ARGS=(bundle --config "${WORK}/vacuum.conf.yaml" --no-update-check --no-style --base "${BASE}")
if [[ "${COMPOSED}" == true ]]; then
    ARGS+=(--composed)
fi
ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

# bundle FORMAT FILE: bundles SPEC to FILE as FORMAT, or stops the step.
# vacuum reports a reference it couldn't open with a "✗" line and still
# exits 0, having left the reference out of the bundle, so those lines fail
# the step too.
bundle() {
    local code=0
    oa_show_command vacuum "${ARGS[@]}" --format "$1" -- "${SPEC}" "$2" | sed 's/^/  /'
    env ${ENV_UNSET[@]+"${ENV_UNSET[@]}"} CI=true "${OA_TOOL}" "${ARGS[@]}" --format "$1" -- "${SPEC}" "$2" \
        > "${WORK}/vacuum.log" 2>&1 || code=$?
    if [[ "${code}" -ne 0 || ! -s "$2" ]]; then
        oa_tail "${WORK}/vacuum.log" 30
        echo "ERROR: vacuum could not bundle ${SPEC} (exit code ${code})." >&2
        exit 1
    fi
    if LC_ALL=C grep -qF '✗' "${WORK}/vacuum.log"; then
        oa_tail "${WORK}/vacuum.log" 30
        echo "ERROR: vacuum reported errors while bundling ${SPEC}, so the bundle is incomplete." >&2
        exit 1
    fi
}

echo "Bundling ${SPEC}:"
bundle json "${WORK}/bundled.json"
if ! oa_json_is "${WORK}/bundled.json" 'type == "object" and (has("openapi") or has("swagger") or has("asyncapi"))'; then
    oa_tail "${WORK}/vacuum.log" 30
    echo "ERROR: vacuum's bundle of ${SPEC} is not an OpenAPI or AsyncAPI document." >&2
    exit 1
fi
# Every $ref left must point inside the document, at something that is
# there: a reference vacuum couldn't resolve stays as it was. A pointer is
# followed key by key (~1 is /, ~0 is ~), an array index only into an array;
# one with a percent-escape isn't decoded, and is only reported. vacuum
# resolves references inside extensions only with --ext-refs, so without it
# an x- key's value is data: an x- key is an extension unless it names a
# property, a component, or an entry of another map keyed by names.
EXT_REFS=false
for word in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    case "${word}" in
        --ext-refs | --ext-refs=true) EXT_REFS=true ;;
        --ext-refs=*) EXT_REFS=false ;;
    esac
done
# shellcheck disable=SC2016 # jq program, not shell
if ! jq -r --argjson ext_refs "${EXT_REFS}" '. as $doc
    | ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "schemas", "parameters",
       "examples", "requestBodies", "headers", "securitySchemes", "links", "pathItems", "encoding", "webhooks"] as $named
    | def named($p; $i): $i > 0
          and (($p[$i - 1] as $k | any($named[]; . == $k)) or ($i > 1 and $p[$i - 2] == "components"));
      def in_extension($p): any(range(0; $p | length); . as $i
          | ($p[$i] | type == "string" and startswith("x-")) and (named($p; $i) | not));
      def found($parts): reduce $parts[] as $k ([true, $doc];
        if .[0] | not then .
        else .[1] as $v
          | if ($v | type) == "object" then (if ($v | has($k)) then [true, $v[$k]] else [false, null] end)
            elif ($v | type) == "array" and ($k | test("^(0|[1-9][0-9]*)$")) and (($k | tonumber) < ($v | length))
              then [true, $v[$k | tonumber]]
            else [false, null] end
        end) | .[0];
      [paths(type == "object" and has("$ref")) as $p | select($ext_refs or (in_extension($p) | not))
          | getpath($p)["$ref"] | select(type == "string")] | unique[]
      | if startswith("#") | not then "unresolved \(.)"
        elif . == "#" then empty
        elif test("%") then "escaped \(.)"
        elif (startswith("#/") | not) then "unresolved \(.)"
        elif found(ltrimstr("#/") | split("/") | map(gsub("~1"; "/") | gsub("~0"; "~"))) then empty
        else "unresolved \(.)" end' "${WORK}/bundled.json" > "${WORK}/refs.txt"; then
    echo "ERROR: Could not read the references in vacuum's bundle of ${SPEC}." >&2
    exit 1
fi
sed -n 's/^unresolved //p' "${WORK}/refs.txt" > "${WORK}/unresolved.txt"
if grep -q '^escaped ' "${WORK}/refs.txt"; then
    echo "WARN: These references have percent-escapes, so the bundle command didn't check where they point:" >&2
    sed -n 's/^escaped /  /p' "${WORK}/refs.txt" | awk 'NR <= 20' >&2
fi
if [[ -s "${WORK}/unresolved.txt" ]]; then
    oa_tail "${WORK}/vacuum.log" 30
    echo "ERROR: The bundle of ${SPEC} still has references it couldn't resolve:" >&2
    awk 'NR <= 20 { print "  " $0 }' "${WORK}/unresolved.txt" >&2
    echo "  A reference to a file that doesn't exist, a URL that wasn't fetched (remote references need" >&2
    echo "  --remote, which vacuum turns on by default), or a pointer to nothing stays in the document." >&2
    exit 1
fi
if [[ "${FORMAT}" == json ]]; then
    RESULT="${WORK}/bundled.json"
else
    bundle yaml "${WORK}/bundled.yaml"
    RESULT="${WORK}/bundled.yaml"
fi
mkdir -p "$(dirname "${OUTPUT}")"
TEMP=$(mktemp "$(dirname "${OUTPUT}")/.bundle.XXXXXX")
cp "${RESULT}" "${TEMP}"
chmod 644 "${TEMP}"
mv -f "${TEMP}" "${OUTPUT}"
echo "Bundled ${SPEC} into ${OUTPUT} (${FORMAT}, $(jq '[paths(type == "object" and has("$ref"))] | length' "${WORK}/bundled.json") local references)."
