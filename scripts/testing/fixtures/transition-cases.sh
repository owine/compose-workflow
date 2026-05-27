#!/usr/bin/env bash
# Transition table scenarios for detect-stack-changes.sh tests.
# Each function: builds scenario, runs script, asserts expected classification.

case_normal_add() {
  local wd; wd=$(mktemp -d -p "$TMPROOT")
  local shas; shas=$(build_scenario "$wd" _setup_empty _add_foo_enabled)
  local current target
  read -r current target <<<"$shas"
  local out; out=$(run_detect "$wd" "$current" "$target" '["foo"]' '[]' '["foo/compose.yaml"]')
  assert_classifications "normal_add" '[]' '[]' '["foo"]' "$out"
}
# shellcheck disable=SC2317  # invoked indirectly via build_scenario
_setup_empty() { :; }
# shellcheck disable=SC2317  # invoked indirectly via build_scenario
_add_foo_enabled() { mkdir -p foo; echo 'services: {a: {image: nginx}}' > foo/compose.yaml; }

case_normal_delete() {
  local wd; wd=$(mktemp -d -p "$TMPROOT")
  local shas; shas=$(build_scenario "$wd" _add_foo_enabled _delete_foo)
  local current target
  read -r current target <<<"$shas"
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '["foo/compose.yaml"]' '[]')
  assert_classifications "normal_delete" '["foo"]' '[]' '[]' "$out"
}
# shellcheck disable=SC2317  # invoked indirectly via build_scenario
_delete_foo() { rm -rf foo; }

case_normal_update() {
  local wd; wd=$(mktemp -d -p "$TMPROOT")
  local shas; shas=$(build_scenario "$wd" _add_foo_enabled _modify_foo)
  local current target
  read -r current target <<<"$shas"
  local out; out=$(run_detect "$wd" "$current" "$target" '["foo"]' '[]' '[]')
  assert_classifications "normal_update" '[]' '["foo"]' '[]' "$out"
}
# shellcheck disable=SC2317  # invoked indirectly via build_scenario
_modify_foo() { echo 'services: {a: {image: nginx:1.27}}' > foo/compose.yaml; }

case_disable() {
  local wd; wd=$(mktemp -d -p "$TMPROOT")
  local shas; shas=$(build_scenario "$wd" _add_foo_enabled _disable_foo)
  local current target
  read -r current target <<<"$shas"
  # Input stacks excludes foo because the discover step (workflow-side) filters
  # .disabled-bearing dirs. Simulate that here.
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '[]' '["foo/.disabled"]')
  assert_classifications "disable" '["foo"]' '[]' '[]' "$out"
}
# shellcheck disable=SC2317  # invoked indirectly via build_scenario
_disable_foo() { touch foo/.disabled; }

case_re_enable() {
  local wd; wd=$(mktemp -d -p "$TMPROOT")
  local shas; shas=$(build_scenario "$wd" _add_foo_disabled _enable_foo)
  local current target
  read -r current target <<<"$shas"
  local out; out=$(run_detect "$wd" "$current" "$target" '["foo"]' '["foo/.disabled"]' '[]')
  assert_classifications "re_enable" '[]' '[]' '["foo"]' "$out"
}
# shellcheck disable=SC2317  # invoked indirectly via build_scenario
_add_foo_disabled() {
  mkdir -p foo; echo 'services: {a: {image: nginx}}' > foo/compose.yaml; touch foo/.disabled;
}
# shellcheck disable=SC2317  # invoked indirectly via build_scenario
_enable_foo() { rm foo/.disabled; }

case_stay_disabled() {
  local wd; wd=$(mktemp -d -p "$TMPROOT")
  local shas; shas=$(build_scenario "$wd" _add_foo_disabled _noop)
  local current target
  read -r current target <<<"$shas"
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '[]' '[]')
  assert_classifications "stay_disabled" '[]' '[]' '[]' "$out"
}
# shellcheck disable=SC2317  # invoked indirectly via build_scenario
_noop() { :; }

case_born_disabled() {
  local wd; wd=$(mktemp -d -p "$TMPROOT")
  local shas; shas=$(build_scenario "$wd" _setup_empty _add_foo_disabled)
  local current target
  read -r current target <<<"$shas"
  # Both files appear as added; this is the regression case for the guard.
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '[]' '["foo/compose.yaml","foo/.disabled"]')
  assert_classifications "born_disabled" '[]' '[]' '[]' "$out"
}

case_delete_while_disabled() {
  local wd; wd=$(mktemp -d -p "$TMPROOT")
  local shas; shas=$(build_scenario "$wd" _add_foo_disabled _delete_foo)
  local current target
  read -r current target <<<"$shas"
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '["foo/compose.yaml","foo/.disabled"]' '[]')
  assert_classifications "delete_while_disabled" '[]' '[]' '[]' "$out"
}

run_all_cases() {
  case_normal_add
  case_normal_delete
  case_normal_update
  case_disable
  case_re_enable
  case_stay_disabled
  case_born_disabled
  case_delete_while_disabled
}
