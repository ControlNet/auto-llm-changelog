#!/usr/bin/env bash

log_group() {
  printf '::group::%s\n' "$1"
}

log_endgroup() {
  printf '::endgroup::\n'
}

log_info() {
  printf '%s\n' "$*"
}

log_debug() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    printf '::debug::%s\n' "$*"
  fi
}

log_warning() {
  printf '::warning::%s\n' "$*"
}

log_error() {
  printf '::error::%s\n' "$*" >&2
}

fail() {
  log_error "$*"
  exit 1
}
