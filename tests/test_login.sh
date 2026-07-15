#!/bin/bash
# Dependency-free tests for scripts/login. Fake aws/docker executables exercise
# the IAM handoff without requiring network access, jq, real credentials, or a
# Docker daemon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dmc-navigator-login.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '$unexpected' in $file"
  fi
}

make_fixture() {
  local name="$1" dir
  dir="$TEST_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/home" "$dir/repo"
  : > "$dir/repo/docker-compose.yml"
  cat > "$dir/repo/.env" <<'EOF'
DMC_NAV_IMAGE=815935788477.dkr.ecr.us-east-1.amazonaws.com/on-prem/dmc-navigator
DMC_NAV_IMAGE_TAG=stable
DMC_NAV_RUNS_DIR=./runs
DMC_NAV_INPUTS_DIR=./inputs
EOF

  cat > "$dir/bin/aws" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
case "${FAKE_SCENARIO}:$1:$2" in
  restricted:sts:get-caller-identity)
    printf '%s\n' 'arn:aws:iam::815935788477:user/orion-customer'
    ;;
  restricted:sts:assume-role)
    printf 'ASIAFAKE\tsecret/fake+key\tfake-session-token\n'
    ;;
  restricted:ecr:get-login-password)
    [ "${AWS_ACCESS_KEY_ID:-}" = "ASIAFAKE" ] || exit 71
    [ "${AWS_SECRET_ACCESS_KEY:-}" = "secret/fake+key" ] || exit 72
    [ "${AWS_SESSION_TOKEN:-}" = "fake-session-token" ] || exit 73
    [ -z "${AWS_PROFILE:-}" ] || exit 74
    printf '%s\n' 'fake-ecr-password'
    ;;
  assumed:sts:get-caller-identity)
    printf '%s\n' 'arn:aws:sts::815935788477:assumed-role/navigator-onprem-pull/existing-session'
    ;;
  assumed:sts:assume-role)
    echo 'already-assumed identity must not assume the role again' >&2
    exit 75
    ;;
  assumed:ecr:get-login-password)
    [ "${AWS_ACCESS_KEY_ID:-}" = "EXISTING_ACCESS" ] || exit 76
    printf '%s\n' 'fake-ecr-password'
    ;;
  assume_failure:sts:get-caller-identity)
    printf '%s\n' 'arn:aws:iam::815935788477:user/restricted-customer'
    ;;
  assume_failure:sts:assume-role)
    echo 'simulated AccessDenied' >&2
    exit 77
    ;;
  *)
    echo "unexpected fake aws call: $*" >&2
    exit 78
    ;;
esac
EOF

  cat > "$dir/bin/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
[ -z "${AWS_ACCESS_KEY_ID:-}" ] || exit 79
[ -z "${AWS_SECRET_ACCESS_KEY:-}" ] || exit 80
[ -z "${AWS_SESSION_TOKEN:-}" ] || exit 83
[ "$*" = "login --username AWS --password-stdin 815935788477.dkr.ecr.us-east-1.amazonaws.com" ] || exit 81
IFS= read -r password || true
[ "$password" = "fake-ecr-password" ] || exit 82
printf '%s\n' 'Login Succeeded'
EOF
  chmod +x "$dir/bin/aws" "$dir/bin/docker"
  printf '%s\n' "$dir"
}

run_login() {
  local dir="$1" scenario="$2"
  shift 2
  env \
    HOME="$dir/home" \
    PATH="$dir/bin:$PATH" \
    REPO_FOLDER="$dir/repo" \
    FAKE_SCENARIO="$scenario" \
    FAKE_AWS_LOG="$dir/aws.log" \
    FAKE_DOCKER_LOG="$dir/docker.log" \
    "$@" \
    "$ROOT/scripts/login" > "$dir/stdout" 2> "$dir/stderr"
}

test_restricted_source_identity() {
  local dir
  dir="$(make_fixture restricted)"
  if ! run_login "$dir" restricted AWS_PROFILE=customer-source; then
    cat "$dir/stdout" "$dir/stderr" >&2
    fail "restricted source identity login failed"
  fi

  assert_contains "$dir/aws.log" "sts get-caller-identity --query Arn --output text"
  assert_contains "$dir/aws.log" "sts assume-role --role-arn arn:aws:iam::815935788477:role/navigator-onprem-pull"
  assert_contains "$dir/aws.log" "ecr get-login-password --region us-east-1"
  assert_contains "$dir/docker.log" "login --username AWS --password-stdin 815935788477.dkr.ecr.us-east-1.amazonaws.com"
  [ ! -e "$dir/home/.aws" ] || fail "login persisted temporary credentials under HOME"
  echo "ok - restricted source identity assumes the pull role in memory"
}

test_already_assumed_identity() {
  local dir
  dir="$(make_fixture assumed)"
  if ! run_login "$dir" assumed \
    AWS_ACCESS_KEY_ID=EXISTING_ACCESS \
    AWS_SECRET_ACCESS_KEY=existing-secret \
    AWS_SESSION_TOKEN=existing-token \
    TEMP_ACCESS_KEY=POISONED_ACCESS \
    TEMP_SECRET_KEY=poisoned-secret \
    TEMP_SESSION_TOKEN=poisoned-token; then
    cat "$dir/stdout" "$dir/stderr" >&2
    fail "already-assumed identity login failed"
  fi

  assert_not_contains "$dir/aws.log" "sts assume-role"
  assert_contains "$dir/aws.log" "ecr get-login-password --region us-east-1"
  assert_contains "$dir/stdout" "Using already-assumed navigator-onprem-pull credentials."
  echo "ok - already-assumed identity is reused"
}

test_assume_role_failure_is_fail_closed() {
  local dir
  dir="$(make_fixture assume_failure)"
  if run_login "$dir" assume_failure AWS_PROFILE=restricted-source; then
    fail "login unexpectedly succeeded when sts:AssumeRole failed"
  fi

  assert_contains "$dir/stderr" "simulated AccessDenied"
  assert_contains "$dir/stderr" "Could not assume arn:aws:iam::815935788477:role/navigator-onprem-pull."
  [ ! -s "$dir/docker.log" ] || fail "docker login ran after sts:AssumeRole failure"
  assert_not_contains "$dir/stdout" "fake-session-token"
  assert_not_contains "$dir/stderr" "fake-session-token"
  echo "ok - assume-role failure stops before Docker login"
}

test_restricted_source_identity
test_already_assumed_identity
test_assume_role_failure_is_fail_closed
