#!/bin/bash
# =============================================================================
# cis-batch-run.sh — run cis-dev-loop.sh once per CIS batch IN PARALLEL on the build host, so a regression can be pinned
# to ONE batch of cis-harden.sh changes. Each run: CIS_LEVEL=4, CIS_TENABLE=1, CIS_SKIP_OSCAP=1 (about 3-4 min each).
# DEV ONLY: nothing here is a releasable image.
#
# Usage (on the build host, from the repo root):
#   bash rhel10-experimental/scripts/cis-batch-run.sh <standard-base.qcow2> [batch ...]
#   default batches: none cfg logs tmp fw sha1
# Base MUST be a standard (pre-hardening) image: cis-dev-loop.sh re-applies cis-harden.sh to whatever it is given.
# Output: cis_results/cis-dev-b-<batch>/tenable-eq.txt, logs in cis_results/batch-<batch>.log, summary in cis_results/batch-summary.txt
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="${1:?usage: cis-batch-run.sh <standard-base.qcow2> [batch ...]}"; shift
[[ "$(basename "$BASE")" == rhel10-hardened-* ]] && { echo "ERROR: base is already hardened ($BASE); use a standard image" >&2; exit 1; }
BATCHES=("$@"); [[ ${#BATCHES[@]} -gt 0 ]] || BATCHES=(none cfg logs tmp fw sha1)
cd "$REPO_ROOT"; mkdir -p cis_results
pids=()
for b in "${BATCHES[@]}"; do
    CIS_LEVEL=4 CIS_TAG="b-$b" CIS_BATCHES="$b" CIS_TENABLE=1 CIS_SKIP_OSCAP=1 CIS_MEM=3072 \
        bash rhel10-experimental/scripts/cis-dev-loop.sh "$BASE" > "cis_results/batch-$b.log" 2>&1 &
    pids+=($!)
    sleep 20   # stagger: libguestfs appliance start + subscription-manager register
done
: > cis_results/batch-summary.txt
for i in "${!BATCHES[@]}"; do
    b="${BATCHES[$i]}"; rc=0; wait "${pids[$i]}" || rc=$?
    echo "batch=$b rc=$rc $(grep -a '^TENABLE_EQ' "cis_results/cis-dev-b-$b/tenable-eq.txt" 2>/dev/null || echo 'no-tenable-eq')" | tee -a cis_results/batch-summary.txt
done
echo "BATCH_RUN_DONE" | tee -a cis_results/batch-summary.txt
