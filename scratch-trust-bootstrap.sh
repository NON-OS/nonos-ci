#!/usr/bin/env bash
# Scratch trust-chain bootstrap for CI lanes that need to build a
# signed kernel image but do not hold the upstream trust-anchor seed.
#
# Generates a fresh in-tree Ed25519 + ML-DSA-65 trust anchor, fresh
# per-capsule publisher keypairs, wipes the committed scratch outputs
# (policy, certs, manifests), and re-signs every capsule listed in
# CAPSULE_SLUGS through the production Makefile recipes. The kernel
# image these certs go into is signature-shaped but does NOT chain to
# the upstream trust anchor — the production-ledger never trusts it.
#
# Inputs (env, all optional):
#   CAPSULE_SLUGS           dash-form slug list, default "proof-io ramfs keyring"
#                           (matches the embed set of microkernel-capsules)
#   CAPSULE_KEY_PREFIXES    underscore-form prefix list, default
#                           auto-derived from CAPSULE_SLUGS (s/-/_/g)
#
# Idempotent: calling twice produces a different scratch chain. Safe
# only inside an ephemeral CI workspace.

set -euo pipefail

CAPSULE_SLUGS="${CAPSULE_SLUGS:-proof-io ramfs keyring}"

# Default the prefix list to the slug list with dashes mapped to
# underscores. capsule-sign and Makefile recipes expect the underscored
# form for publisher key filenames.
if [ -z "${CAPSULE_KEY_PREFIXES:-}" ]; then
    CAPSULE_KEY_PREFIXES="$(echo "${CAPSULE_SLUGS}" | tr '-' '_')"
fi

mkdir -p .keys
mkdir -p nonos-data/trust/keys
mkdir -p nonos-data/trust/policy
mkdir -p nonos-data/trust/capsules
mkdir -p target/ci/zk

echo "[scratch-trust-bootstrap] building capsule-sign host tool"
( cd nonos-sign && cargo build --release --bin capsule-sign )

CS="$(pwd)/nonos-sign/target/release/capsule-sign"
[ -x "${CS}" ] || { echo "::error::capsule-sign not built at ${CS}"; exit 1; }

echo "[scratch-trust-bootstrap] generating scratch trust-anchor keypair"
"${CS}" keygen --alg ed25519 --out .keys/nonos_trust_anchor_ed25519
"${CS}" keygen --alg mldsa65 --out .keys/nonos_trust_anchor_mldsa65
chmod 600 .keys/nonos_trust_anchor_ed25519.seed \
          .keys/nonos_trust_anchor_mldsa65.seed
mv .keys/nonos_trust_anchor_ed25519.pub nonos-data/trust/keys/
mv .keys/nonos_trust_anchor_mldsa65.pub nonos-data/trust/keys/

echo "[scratch-trust-bootstrap] generating publisher keypairs: ${CAPSULE_KEY_PREFIXES}"
for prefix in ${CAPSULE_KEY_PREFIXES}; do
    "${CS}" keygen --alg ed25519 --out ".keys/${prefix}_publisher_ed25519"
    "${CS}" keygen --alg mldsa65 --out ".keys/${prefix}_publisher_mldsa65"
    chmod 600 ".keys/${prefix}_publisher_ed25519.seed" \
              ".keys/${prefix}_publisher_mldsa65.seed"
    mv ".keys/${prefix}_publisher_ed25519.pub" nonos-data/trust/keys/
    mv ".keys/${prefix}_publisher_mldsa65.pub" nonos-data/trust/keys/
done

echo "[scratch-trust-bootstrap] wiping stale committed policy + certs + manifests"
# Only the trust-anchor policy is key-dependent and gets re-sealed with the
# scratch keys by the kernel build. The zk capsule policy root is the Merkle
# root over capsule hashes and capability masks, independent of signing keys,
# and the kernel embeds it at compile time; keep the committed one.
rm -f nonos-data/trust/policy/nonos_trust_anchor.policy.bin
rm -f nonos-data/trust/capsules/*.nonos_id_cert.bin
rm -f nonos-data/trust/capsules/*.manifest.bin

echo "[scratch-trust-bootstrap] enrolling scratch boot identity"
printf 'ci-scratch-device\n' > target/ci/zk/device_labels.txt
make ZK_BOOT_LABELS=target/ci/zk/device_labels.txt \
     ZK_BOOT_ROOT=target/ci/zk/device_root.bin \
     ZK_BOOT_COMMITMENTS=target/ci/zk/device_commitments.bin \
     ZK_BOOT_SECRETS=target/ci/zk/device_secrets.txt \
     ZK_BOOT_ENROLL_SEED=nonos-ci-scratch-boot-enroll \
     target/ci/zk/device_root.bin \
     target/ci/zk/device_commitments.bin \
     target/ci/zk/device_secrets.txt

echo "[scratch-trust-bootstrap] building userland libc"
make nonos-mk-libc

echo "[scratch-trust-bootstrap] re-signing capsules: ${CAPSULE_SLUGS}"
for slug in ${CAPSULE_SLUGS}; do
    make ZK_CAPSULE_ENROLL_SEED=nonos-ci-scratch-capsule-enroll \
         ZK_CAPSULE_NONCE_SEED=nonos-ci-scratch-capsule-nonce \
         "nonos-mk-${slug}-sign"
done

echo "[scratch-trust-bootstrap] done"
