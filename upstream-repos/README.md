# Upstream Reference Repositories

This directory contains clones of the upstream OpenShift repositories that are used to build the confidential containers ecosystem.

## Repository Structure

According to Red Hat developers, these are the main repositories they build from:

1. **sandboxed-containers-operator** - https://github.com/openshift/sandboxed-containers-operator.git
   - Operator
   - Must-gather
   - PodVM builder
   - Bundle

2. **cloud-api-adaptor** - https://github.com/openshift/cloud-api-adaptor.git
   - Cloud API Adaptor (CAA)
   - Webhook
   - **PodVM payload** (agent-protocol-forwarder, kata-agent, etc.)

3. **kata-containers** - https://github.com/openshift/kata-containers.git
   - Monitor

4. **confidential-compute-artifacts** - https://github.com/openshift/confidential-compute-artifacts.git
   - Storage helper
   - TDX QGS
   - PCCS

5. **coco-podvm-scripts** - https://github.com/confidential-devhub/coco-podvm-scripts
   - DM-verity image building scripts
   - **This is what ibm_cloud_rhel9 is forked from**

## Key Findings

### agent-config.toml History
The `/etc/agent-config.toml` file in peer pods comes from the **cloud-api-adaptor** repository:

- **First Added**: March 7, 2024 (commit 3aeb1c9d)
  - Part of "build: local builds" restructuring
  - Located at: `src/cloud-api-adaptor/podvm/files/etc/agent-config.toml`

- **Signature Verification Removed**: June 12, 2024 (commit 8e73469a)
  - Upstream removed `enable_signature_verification` and `image_policy_file` settings
  - **Important**: Our fork re-added these settings for IBM Cloud security requirements

- **Registry Auth Updated**: June 27, 2025 (commit a4d0ab69)
  - Updated authenticated registry credentials configuration

### Payload Updates
The 44 "osc-podvm-payload" dependency updates in coco-podvm-scripts point to new builds of cloud-api-adaptor. These updates may include:
- Bug fixes in agent-protocol-forwarder
- Kata-agent improvements
- Configuration file changes (like agent-config.toml)
- Security updates

## Maintenance Strategy

1. **Monitor cloud-api-adaptor** for changes to:
   - `src/cloud-api-adaptor/podvm/files/etc/agent-config.toml`
   - Agent binaries (agent-protocol-forwarder, kata-agent)
   - Configuration files in `src/cloud-api-adaptor/podvm/files/etc/`

2. **Review payload updates** in coco-podvm-scripts:
   - Each `chore(deps): update osc-podvm-payload to *` commit
   - Check the referenced cloud-api-adaptor commit for changes

3. **Track critical files**:
   - `/etc/agent-config.toml`
   - `/etc/containers/policy.json`
   - `/etc/kata-opa/*.rego` (OPA policies)

## Update Commands

To update these reference repositories:

```bash
cd ibm_cloud_rhel9/upstream-repos
for repo in */; do
  echo "Updating $repo"
  cd "$repo"
  git fetch --all
  git pull
  cd ..
done
```

## Notes

- These repositories are for **reference only**
- Do not modify these clones
- Use them to understand upstream changes before adopting into ibm_cloud_rhel9
- The actual build uses ibm_cloud_rhel9 scripts, not these upstream repos directly