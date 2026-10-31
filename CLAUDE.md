# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, that checks OpenAPI documents on every commit, for any language. It installs vacuum and oasdiff (checksum-verified release binaries) and Schemathesis (with a verified uv, from a lock that pins every wheel by SHA-256), and wraps the checks around them: `lint` (vacuum), `bundle` (vacuum), `breaking` (oasdiff against a git revision), `drift` (oasdiff, the generated document against the committed one) and `contract_test` (Schemathesis against the running API).

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*.sh src/install/*/*.sh actions/*.sh tests/*.sh

# Tests (offline; git, jq, python3, and jsonschema to check run records)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run one command's script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh lint specs=tests/fixtures/lint/openapi.yaml

# Table entries for a new release (vacuum's needs cosign), and a lock for a new Schemathesis release
./src/install/vacuum/install_hash.sh -v <version>
./src/install/oasdiff/install_hash.sh -v <version>
./src/install/lock.sh -t schemathesis -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/`
  - `install.yml` - Checks `tools` (`scripts/install_tools.sh`), then runs `install_vacuum`, `install_oasdiff`, `install_uv` (only without `schemathesis`, which installs it) and `install_schemathesis`, each picked by a `when: condition` on `tools` (`^(.*[ ,])?<tool>([ ,].*)?$`).
  - `install_vacuum.yml`, `install_oasdiff.yml`, `install_uv.yml` - The family's standard install command shape: cache key from `scripts/cache_key.sh`, `restore_cache`, `install/<tool>/install.sh`, `save_cache`.
  - `install_schemathesis.yml` - python-security-orb's locked-tool install: optionally `install_uv`, the Python cache key (`scripts/python_cache_key.sh`), `scripts/install_tool.sh` with `PARAM_TOOL: schemathesis` and `SCRIPT_TOOL_LOCKS: << include(install/schemathesis/locks.txt) >>`.
  - `lint`, `bundle`, `breaking`, `drift`, `contract_test` - One script each in `scripts/`.
- `install/<tool>/install.sh` and `install_hash.sh` (vacuum, oasdiff, uv), `install/lock.sh`, `install/schemathesis/locks.txt` - Kept outside `scripts/`, since `tests/shell_conventions_test.sh` exempts only `src/scripts/install.sh`, `install_hash.sh` and `cache_key.sh` by exact path. orb pack ignores the directory; commands include its files.
- `scripts/lib/openapi.sh` - Shell helpers (`oa_*`), passed to each step as `SCRIPT_OPENAPI_LIB: << include(scripts/lib/openapi.sh) >>` and `eval`ed after a check that it is set. Only defines functions; no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version
- `../schemas/run-record.v1.json` - The run record's JSON Schema. Its URL is in every run record, so fields are only ever added within v1.
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below).

### Install

- **vacuum, oasdiff, uv** (`install/<tool>/install.sh`): the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`, holding the SHA-512 of the binary inside the release archive. Each tool definition holds the `# >>> openapi-orb install helpers >>>` block, identical in all three (`tests/install_test.sh` checks): `oa_download_base_url` (an https mirror in place of `https://github.com`, refusing credentials, a query or a fragment) and `oa_install_record`, which writes `.<binary>.install.json` beside the binary (release, asset, its SHA-512, `verify_checksums`, `verified`, the binary's SHA-512), which `oa_tool` checks and the run records include.
  - vacuum: `vacuum_<version>_linux_{x86_64,arm64}.tar.gz` from `github.com/daveshanley/vacuum`, binary `vacuum` at the root. `tool_version` runs `vacuum version` from `/` with no `VACUUM_*` variables and `XDG_CONFIG_HOME` pointed nowhere, since vacuum reads `vacuum.conf.*` even for its version. `install_hash.sh` has cosign verify `checksums.txt.sigstore.json` (from 0.29.10 on; the table starts at 0.30.0): vacuum's tag workflow dispatches its publish workflow on `main`, so the certificate names `publish.yaml@refs/heads/main`, checked with the trigger (`repository_dispatch`), the repository, and the workflow commit, which must be the one the tag points to (`git ls-remote`). 0.34.0 and 0.35.3 were tagged but never released.
  - oasdiff: `oasdiff_<version>_linux_{amd64,arm64}.tar.gz` from `github.com/oasdiff/oasdiff`, binary `oasdiff` at the root, `--version` prints `oasdiff version X`. oasdiff signs nothing (no signing, SBOM or attestation step), so `install_hash.sh` anchors to `checksums.txt` alone. The table starts at 1.30.0.
  - Both `install_hash.sh` refuse a release younger than seven days (`VACUUM_MIN_RELEASE_AGE_DAYS`, from the signature's transparency log time; `OASDIFF_MIN_RELEASE_AGE_DAYS`, from `checksums.txt`'s `Last-Modified`). The defaults are the newest releases at least that old.
- **Schemathesis** (`scripts/install_tool.sh`, from python-security-orb): `uv python install --managed-python` (`python` 3.11 to 3.14; Schemathesis needs 3.11 from 4.31.0, and Hypothesis from 6.169.0), or `system`, or a path; then `uv venv` and `uv pip install --require-hashes --only-binary :all: --strict` from the lock (`# >>> schemathesis VERSION >>>` blocks in `locks.txt`), smoke-tested with `python -I -m schemathesis.cli --version`, swapped into `~/.openapi-orb/venvs/schemathesis`, and run by a script named `schemathesis` in `install_path`. `install/lock.sh` resolves with uv from wheels uploaded at least seven days earlier and keeps the wheels for CPython 3.11 to 3.14 on x86_64 and aarch64, glibc and musl. Schemathesis pins jsonschema-rs to one minor version and moves the pin often, so they are locked together.

When a default version changes, change it in `install_<tool>.yml` and `install.yml`'s `<tool>_version`, then regenerate the actions; `tests/wiring_test.sh` requires the defaults to be the newest table entry or lock.

### Command scripts (`src/scripts/`)

Every check takes `working_dir`, `output_dir`, `report_name`, `junit`, `run_record`, `report_only`, `extra_args` and `store_artifacts`, and first removes the reports an earlier run with the same `report_name` left. The rule every gate follows: findings fail the step unless `report_only` is true; a tool that didn't complete, or a check of nothing, always fails it. Each script tells them apart from the tool's report, not its exit code. `extra_args` is split with `split_shell_words` (the parser the juburr orbs share), and each script refuses the options it sets itself, those that would narrow what is checked or change how the report is read, and words that aren't options (which the tool would read as another document).

- **`lint.sh`**: `vacuum spectral-report --config <empty orb-owned vacuum.conf.yaml> --no-update-check --no-style [--ruleset R] [--hard-mode] [--functions D] [--ignore-file F] EXTRA -- SPEC OUT`, once per document, with every `VACUUM_*` variable unset and `CI=true`. `spectral-report` (in every release the table holds; `lint --format`/`-o` arrived in 0.36.0) writes Spectral's JSON (`code`, `path`, `message`, `severity` 0 error to 3 hint, `range` with 1-based lines and columns from yaml nodes, 0 when unknown, `source`), exits 0 whatever it found, and 2 for a document it can't read, a non-OpenAPI file, or a ruleset it can't load. In multi-file mode it skips a document it can't read, so the orb never uses it. The orb builds SARIF (paths relative to the top of the checkout) and JUnit from the JSON. `--turbo` (drops `oas3-schema`), `--skip-check`, `--changes` and `--original` are refused.
- **`bundle.sh`**: `vacuum bundle --base <the document's directory> --format json` (vacuum's `--base` defaults to the working directory), then checks the bundle: an OpenAPI (or AsyncAPI) object, every `$ref` local and resolving (a JSON pointer followed key by key, `~1` and `~0` unescaped, an index only into an array; a percent-escaped one is only reported). vacuum writes a partial bundle and exits 0 when a reference doesn't resolve; a file it can't open is also dropped from the bundle, reported only by a `✗` line in its output, which fails the step. Then `--format yaml` again when `output` wants YAML, and an atomic move into place.
- **`breaking.sh`**: `oasdiff changelog --format json|markdown --level info --fetch=false [--severity-levels/--err-ignore/--warn-ignore=<absolute path>] EXTRA -- <commit>:<path> <path>` from the top of the checkout (no `--color`: oasdiff refuses it with any format but text and singleline): oasdiff reads a git revision itself, `$ref`s to other files from the same revision (since 1.15.0), with paths relative to the top. The base is `base_ref`, or `origin/$GITHUB_BASE_REF`, or `origin/HEAD`, `origin/main`, `origin/master`; with `merge_base`, `git merge-base` of it and `HEAD`. A document the base lacks is new and passes. `base_file` compares with a file instead, from the working directory. Before comparing, `oa_oasdiff_openapi` runs `oasdiff validate --format json` on both documents: kin-openapi loads any YAML mapping (a Swagger 2.0 document included) as an empty specification, which `validate` reports as `openapi-required`. oasdiff exits 0, or 1 when a configuration file sets `fail-on`, after comparing, and 100 or more when it couldn't. Levels in the JSON are integers (3 ERR, 2 WARN, 1 INFO); breaking is 2 and up. SARIF holds the breaking changes, located at `revisionSource` (YAML documents only) or line 1, with oasdiff's `fingerprint`. An `.oasdiff.yaml` in the checkout still applies (policy); the orb passes every flag that decides what is read.
- **`drift.sh`**: `oasdiff diff --format json --fetch=false [--exclude-elements=...]` of `spec` and `generated` (from the working directory), or of `HEAD:<path>` and the working tree's copy (from the top), plus `changelog` json and markdown to name the changes. `diff` compares loaded documents, so key order, YAML or JSON and formatting don't count. A non-empty diff (`{}` is none) is drift, even when the changelog names nothing (descriptions, examples).
- **`contract_test.sh`**: waits (`curl`, any HTTP answer) up to `wait_for_api` seconds for `url` (or a URL `spec`), then runs `schemathesis --config-file C --no-color run SPEC --generation-database none --report-json-path W [--url --checks --exclude-checks --phases --max-examples --seed --workers --request-timeout] [--report-junit-path output_dir/junit/<report_name>.xml] [--report-<fmt>-path ...] EXTRA`, with `HYPOTHESIS_STORAGE_DIRECTORY` in the work directory and without `SCHEMATHESIS_HOOKS`, `SCHEMATHESIS_BASE_URL`, `SCHEMATHESIS_ORIGIN` and `SCHEMATHESIS_WAIT_FOR_SCHEMA`. The configuration is `config`, or one the orb writes (`[cache] enabled = false`, and `[headers]` from `headers`, which is never expanded: Schemathesis resolves its `${NAME}` placeholders from the environment, and fails on an unset one). Schemathesis discovers `schemathesis.toml` from the working directory up to a `.git` directory, so the orb always passes one. Exit codes: 0 passed, 1 failures and per-operation errors alike, 2 usage or a document it couldn't load. The JSON report (4.26.0 on) decides: no report, `complete` false, a `stop_reason` other than `completed` or `failure_limit`, or `errors` are no verdict; `operations.tested` or `test_cases.generated` 0 is a check of nothing (unless `allow_empty`); `failures` are findings. JUnit is Schemathesis's own.

### Shared helpers (`scripts/lib/openapi.sh`)

- From python-security-orb: `oa_subst` (stdin `circleci env subst`, the value as is without the CLI), `oa_bool`, `split_shell_words`/`oa_words`, `oa_match` (C locale), `oa_list`, `oa_files` (globs; no match is an error), `oa_require_jq`, `oa_output`, `oa_uint`, `oa_junit`, `oa_gate`, `oa_plural`, `oa_tail`, `oa_export`, `oa_env_var_name`, `oa_json_is` (never `jq -e` on a tool's output: jq 1.6 exits 0 on an empty file), `oa_sha256`, `oa_url_public`, `oa_ci_json`, `oa_tool_json`, `oa_args_json`, `oa_show_command`, `oa_run_record`.
- The orb's own: `oa_tool` (a binary on the `PATH`, warning when its install record doesn't describe it), `oa_specs` (`specs`, or the first of the usual document names), `oa_git_top` (`OA_TOP`, `OA_PREFIX`), `oa_from_top` (a path relative to the top, without following links), `oa_rank`, `oa_oasdiff_openapi`, `oa_toml_string`.
- Keep `schemas/run-record.v1.json` in step with `oa_run_record`; `tests/commands_test.sh` checks every run record it writes against it.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_OPENAPI_LIB=<lib> [SCRIPT_TOOL_LOCKS=<locks>]`, with `working-directory: ${{ inputs.working_dir }}`. Inputs never appear inside a `run:` script. The install actions cache with `actions/cache`, keyed as the commands are; `install` runs uv's steps when `tools` names `uv` or `schemathesis`. The checks name their artifact `openapi-reports-<report_name>-<random>` and upload `output_dir` with `if: always()` and `store_artifacts`. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. The actions were generated from the command YAML; keep them in sync by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number. The action descriptions leave out "Environment variables are expanded". `tests/actions_test.sh` checks all of this.

### Tests

- `tests/install_test.sh`: the shared install contract (`tests/install_contract.sh`, with `tests/install_fixtures/release.sh`) for uv, vacuum and oasdiff, and that their shared blocks are identical.
- `tests/install_tool_test.sh`: `install_tool.sh` against a stand-in uv and Python, for Schemathesis. It hides a real `circleci` on the `PATH` (CircleCI's images have one) from every run.
- `tests/commands_test.sh`: every check through `tests/run_command.sh` (with its YAML defaults), against stand-ins for vacuum, oasdiff, Schemathesis and curl that record their calls and answer from `tests/fixtures/stubs`, in a git repository with an origin and a branch; every run record is checked against the schema when jsonschema is installed. It passes with bash 4.0, 4.3 and 5 first on the `PATH`.
- `tests/wiring_test.sh`: every `PARAM_` a script reads is set, every parameter used, reports stored, run steps named, the README documents every command and action, defaults are the newest releases, the schema names every command with a run record.
- `tests/validate_reports.sh` (and `.py`): the CI jobs' reports: SARIF against the OASIS schema pinned by SHA-256, JUnit counts, run records (`VALIDATE_KINDS` names the kinds that must turn up).
- Fixtures: `tests/fixtures/api` (an inventory API, `openapi.yaml`; `openapi-v2.yaml`, which removes `DELETE /items/{id}` and adds a required request property; `openapi.json`, the same document as JSON with every key order reversed), `multi` and `multi-broken` (a document split across files, and one with a missing reference), `lint` (findings, a Swagger 2.0 document, a YAML file that isn't OpenAPI), `server/app.py` (the inventory API, standard library only; `BUG=1` returns prices as strings).

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install`, `test-env-subst` (env subst and shell conventions), `test-commands` (`cimg/python`, with jsonschema; then the wiring test), `test-actions`, orb-tools lint, pack and review (`orb_name: openapi`), shellcheck.
- `.circleci/test-deploy.yml` - With the real tools: `install-test` (every tool on `cimg/base`, with Python 3.11 and 3.14, the binaries the tables pin, a second install from the cache), `checksum-test` (unlisted releases fail closed; `known_versions` installs unverified), `arm64-test`, `lint-test` (the clean fixture, findings, hard mode, a non-OpenAPI file, a bundle and a broken bundle), `breaking-test` (a git repository whose branch breaks the API, a change that breaks nothing, a Swagger 2.0 document, drift both ways), `contract-test` (`cimg/python`: the fixture API started in the background, and with a bug, and an API that isn't there). Steps that must fail run through `tests/run_command.sh`. Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The same with the actions on GitHub's runners: `offline-tests`, `install` (amd64 and arm64), `install-from-cache` (the download hosts blocked), `install-hash` (both `install_hash.sh` with cosign from cosign-orb's action), `lint`, `breaking`, `contract`, with steps that must fail under `continue-on-error` and their outcomes checked.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `oa_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, so copy `"$@"` into an array only when `$#` is non-zero.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'` (`oa_export`); `eval` only runs orb code (`"${SCRIPT_OPENAPI_LIB}"`). Secrets never go on a command line: `contract_test`'s headers reach Schemathesis as `${NAME}` placeholders in a configuration file.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script.
- Variables a script sets for the lib to read carry `# shellcheck disable=SC2034 # read by ...`, since shellcheck can't see into the eval'd lib.
- The scripts must work with jq 1.6: never `jq -e` on a tool's output, and in jq bind a field before piping into another value.

## Naming

Command names say what they check or make: the job (`lint`, `bundle`, `breaking`, `drift`, `contract_test`). Parameters that map onto one tool option take its name in snake_case (`ruleset`, `hard_mode`, `functions`, `ignore_file`, `severity_levels`, `err_ignore`, `warn_ignore`, `exclude_elements`, `checks`, `exclude_checks`, `phases`, `max_examples`, `seed`, `workers`, `request_timeout`); `specs`/`spec`, `fail_on`, `formats` and `extra_args` mean what they mean in the other juburr orbs. Plumbing matches them: `working_dir`, `output_dir`, `report_name`, `junit`, `run_record`, `report_only`, `allow_empty`, `store_artifacts`; lists take commas or spaces.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck` over every script and `yamllint .`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`, and validate `.circleci/test-deploy.yml` with the packed orb spliced in under `orbs.openapi-orb`
- Run `actionlint .github/workflows/actions.yml`
- Never run the real tools on a workstation you don't control; CI runs them
