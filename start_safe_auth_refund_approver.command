#!/bin/zsh
set -e
cd "${0:A:h}"
mkdir -p outputs
clang -fobjc-arc -fno-modules -Wall -framework AppKit -framework ApplicationServices \
  safe_auth_refund_approver.m -o outputs/safe_auth_refund_approver
exec ./outputs/safe_auth_refund_approver --approve --watch
