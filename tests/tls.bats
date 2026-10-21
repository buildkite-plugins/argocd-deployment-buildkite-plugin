#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$BATS_TEST_DIRNAME/.."
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export ARGOCD_SERVER="localhost:8443" ARGOCD_USERNAME="fake-user" ARGOCD_PASSWORD="fake-password"
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_ARGOCD_SERVER="$ARGOCD_SERVER"
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_ARGOCD_USERNAME="$ARGOCD_USERNAME"
  export BUILDKITE_AGENT_META_DATA_QUEUE="test"
  export CAPTURE="$BATS_TEST_TMPDIR/args" PIPELINE="$BATS_TEST_TMPDIR/pipeline.yml"
  cat > "$BATS_TEST_TMPDIR/bin/argocd" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" >> "$CAPTURE"
if [[ "$1" == login ]]; then
  [[ "$*" != *--insecure* && "$*" != *--plaintext* && "$*" == *--skip-test-tls* ]] || exit 99
  # Safe trust-error simulation, not a TLS verifier test.
  if [[ "${TRUST_FAILURE:-false}" == true ]]; then
    echo 'x509: certificate signed by unknown authority' >&2
    exit 1
  fi
fi
MOCK
  cat > "$BATS_TEST_TMPDIR/bin/buildkite-agent" <<'MOCK'
#!/bin/bash
if [[ "$1 $2" == 'pipeline upload' ]]; then
  cp "$3" "$PIPELINE"
elif [[ "$1 $2" == 'meta-data get' ]]; then
  echo rollback
fi
MOCK
  cat > "$BATS_TEST_TMPDIR/bin/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
}

normal_login() {
  bash -c 'source "$REPO_ROOT/lib/shared.bash"; source "$REPO_ROOT/lib/modules/argocd.bash"; setup_argocd_auth'
}

generate_rollback() {
  bash -c 'source "$REPO_ROOT/lib/shared.bash"; source "$REPO_ROOT/lib/modules/rollback.bash"; inject_rollback_decision_block test-app 7'
  # Extract the generated YAML literal command without requiring a YAML package.
  sed -n '/^    command: |/,$p' "$PIPELINE" | tail -n +2 | sed 's/^      //' > "$BATS_TEST_TMPDIR/rollback.sh"
  bash -n "$BATS_TEST_TMPDIR/rollback.sh"
}

@test "login verifies TLS and passes fake credentials as separate arguments" {
  run normal_login
  [ "$status" -eq 0 ]
  printf '%s\n' login localhost:8443 --username fake-user --password fake-password --skip-test-tls > "$BATS_TEST_TMPDIR/expected"
  diff "$BATS_TEST_TMPDIR/expected" "$CAPTURE"
  [[ "$output" != *fake-password* ]]
}

@test "login stops on a trust failure without insecure retry" {
  export TRUST_FAILURE=true
  run normal_login
  [ "$status" -ne 0 ]
  [[ "$output" == *'TLS certificate trust'* && "$output" != *fake-password* ]]
  [ "$(grep -c '^login$' "$CAPTURE")" -eq 1 ]
  ! grep -Eq -- '--insecure|--plaintext|^app$' "$CAPTURE"
}

@test "generated rollback verifies login before rollback" {
  generate_rollback
  run bash "$BATS_TEST_TMPDIR/rollback.sh"
  [ "$status" -eq 0 ]
  head -n 7 "$CAPTURE" > "$BATS_TEST_TMPDIR/login"
  printf '%s\n' login localhost:8443 --username fake-user --password fake-password --skip-test-tls > "$BATS_TEST_TMPDIR/expected"
  diff "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/login"
  grep -q '^rollback$' "$CAPTURE"
  ! grep -Eq -- '--insecure|--plaintext' "$CAPTURE"
  [[ "$output" != *fake-password* ]]
}

@test "generated rollback stops on a trust failure without executing rollback" {
  generate_rollback
  export TRUST_FAILURE=true
  run bash "$BATS_TEST_TMPDIR/rollback.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'TLS certificate trust'* && "$output" != *fake-password* ]]
  [ "$(grep -c '^login$' "$CAPTURE")" -eq 1 ]
  ! grep -Eq -- '--insecure|--plaintext|^app$' "$CAPTURE"
}
