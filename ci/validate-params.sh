#!/bin/sh
#
# ci/validate-params.sh — check the parameters of the pipeline.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The Jenkinsfile calls this script in its Validate stage. Every
# free-text parameter is checked against ^[A-Za-z0-9._/-]+$: a parameter
# ends up in a file name, in a directory name, in a VM name or in a
# command line, so it may not hold whitespace, a shell metacharacter or
# any other character that would have to be escaped. A parameter that
# does not match is refused, the pipeline stops before it builds
# anything.
#
# The parameters are read from the environment: Jenkins exports the
# parameters of a build as environment variables.
#
#   AGENT_LABEL      the label of the agent (required)
#   VM_PROVIDER      the name of the VM provider (required)
#   BUILD_VM_NAME    the name of the build VM (required)
#   BUILD_VM_IMAGE   the image the build VM boots (required unless the
#                    build runs on the agent)
#   BUILD_VM_WORKDIR the directory of this repository in the build VM
#                    (required)
#   BUILD_ON_AGENT   "true" when the build runs on the agent itself
#   PRODUCT_CONF     the product configuration in the workspace

set -eu

PROG=$(basename -- "$0")

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

AGENT_LABEL=${AGENT_LABEL:-}
VM_PROVIDER=${VM_PROVIDER:-}
BUILD_VM_NAME=${BUILD_VM_NAME:-}
BUILD_VM_IMAGE=${BUILD_VM_IMAGE:-}
BUILD_VM_WORKDIR=${BUILD_VM_WORKDIR:-}
BUILD_ON_AGENT=${BUILD_ON_AGENT:-false}
PRODUCT_CONF=${PRODUCT_CONF:-product.conf}

# ok_value <name> <value> <required: yes|no>
ok_value() {
	_name=$1 _value=$2 _need=$3
	if [ -z "$_value" ]; then
		[ "$_need" = yes ] && die "$_name must not be empty"
		return 0
	fi
	case $_value in
	*[!A-Za-z0-9._/-]*)
		die "$_name may only hold letters, digits, '.', '_', '-' and '/' (got: $_value)"
		;;
	esac
	case $_value in
	*/)
		die "$_name may not end with '/' (got: $_value)"
		;;
	esac
}

ok_value AGENT_LABEL "$AGENT_LABEL" yes
ok_value VM_PROVIDER "$VM_PROVIDER" yes
ok_value BUILD_VM_NAME "$BUILD_VM_NAME" yes
ok_value BUILD_VM_WORKDIR "$BUILD_VM_WORKDIR" yes
ok_value PRODUCT_CONF "$PRODUCT_CONF" yes

case $BUILD_ON_AGENT in
true | false) ;;
*) die "BUILD_ON_AGENT must be true or false (got: $BUILD_ON_AGENT)" ;;
esac

if [ "$BUILD_ON_AGENT" != true ]; then
	ok_value BUILD_VM_IMAGE "$BUILD_VM_IMAGE" yes
fi

printf '%s: the parameters are valid\n' "$PROG"
exit 0
