#!/usr/bin/env bash
# Sourced by the portable and native builders.
PATCH_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../patches" && pwd -P)

select_patch()
{
    local version=$1 name=$2 fallback=$3 candidate
    [[ "$version" =~ ^[0-9]+([.][0-9]+)+$ ]] || return 1
    [[ ! -L "$PATCH_ROOT/$version" ]] || return 1
    candidate="$PATCH_ROOT/$version/$name"
    if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
        candidate="$PATCH_ROOT/$fallback"
    fi
    [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
}
