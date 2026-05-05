# Build System Consolidation Plan

## Current State (Fragmented)

### Mac Laptop (~/Bob-Work/EDR)
- **Main repo**: EDR project with scripts/
- **Submodule**: ibm_cloud_rhel9 (our fork with modifications)
- **Submodule**: cloud-api-adaptor (for reference, not actively used)
- **Scripts**: scripts/remote-build.sh orchestrates everything
- **Credentials**: .env file (gitignored)

### Remote Host (gcoon@192.168.1.196)
- **Home directory**: ~/build-podvm.sh (deployed from Mac)
- **Git repos**: 
  - ~/gits/openshift/cloud-api-adaptor (payload binaries build)
  - ~/gits/coco-podvm-scripts (UPSTREAM - original source we forked from)
- **Build artifacts**: ~/.local/share/libvirt/images/
- **Credentials**: ~/.env (deployed from Mac)

### Issues
1. Scripts scattered across multiple locations
2. Two copies of similar code (ibm_cloud_rhel9 vs coco-podvm-scripts)
3. cloud-api-adaptor exists in two places (EDR submodule + remote host)
4. Manual file deployment via scp in remote-build.sh
5. Not Jenkins-ready (hardcoded paths, manual steps)
6. Fragile - easy to get out of sync

## Target State (Consolidated)

### Single Source of Truth: ibm_cloud_rhel9 Repository

**Philosophy**: ibm_cloud_rhel9 becomes the complete, self-contained build system with everything needed to build PodVM images.

```
ibm_cloud_rhel9/                    # Main repository (single source of truth)
├── .env.example                    # Template for credentials
├── .gitignore                      # Excludes .env, build artifacts
├── .gitmodules                     # Submodule configuration
├── README.md                       # Main documentation
├── Jenkinsfile                     # Jenkins pipeline definition
│
├── cloud-api-adaptor/              # SUBMODULE: Payload binaries source
│   └── (https://github.com/openshift/cloud-api-adaptor.git - upstream Red Hat repo)
│
├── build/                          # Build orchestration scripts
│   ├── build-podvm.sh             # Main build orchestrator (runs on remote)
│   ├── build-binaries.sh          # Payload binaries build
│   ├── build-qcow2.sh             # QCOW2 image build
│   ├── deploy-and-build.sh        # Deploy to remote + trigger (runs on Mac/Jenkins)
│   └── lib/                        # Shared functions
│       ├── logging.sh             # Color logging functions
│       └── validation.sh          # Credential validation
│
├── scripts/                        # PodVM customization scripts
│   ├── coco/
│   │   ├── coco-components.sh     # Component installation
│   │   └── podvm/
│   │       ├── podvm_maker.sh     # Main customization script
│   │       ├── install-uptycs.sh  # Uptycs EDR installation
│   │       └── provision-uptycs.sh # Uptycs provisioning
│   ├── verity/
│   │   └── verity.sh              # dm-verity setup (optional)
│   └── create-verity-podvm.sh     # dm-verity wrapper
│
├── services/                       # Systemd service files
│   ├── uptycs-osquery.service     # Uptycs EDR service
│   └── dmverity-configure.service # dm-verity service (optional)
│
├── edr/                            # Uptycs EDR files
│   └── uptycs-complete.tar.gz     # Complete Uptycs package
│
├── helpers/                        # Helper scripts
│   ├── create-certs.sh            # Certificate generation
│   └── measure-image.sh           # Image measurement
│
├── example_run.sh                  # Build wrapper (calls scripts/)
│
├── ibmcloud/                       # IBM Cloud integration
│   ├── create-vsi-image.sh        # VSI image creation
│   ├── upload-to-cos.sh           # COS upload
│   └── configure-openshift.sh     # OpenShift configuration
│
├── configs/                        # OpenShift test configurations
│   └── test-podvm-image.yaml      # Test pod definition
│
└── docs/                           # Documentation
    ├── BUILDING_IMAGES.md
    ├── CONSOLIDATION_PLAN.md      # This file
    ├── JENKINS_SETUP.md           # Jenkins configuration guide
    └── WORKFLOW.md                # Complete workflow documentation
```

### EDR Repository (Simplified)

```
EDR/                                # Wrapper/orchestration repo
├── .gitmodules                     # Points to ibm_cloud_rhel9
├── ibm_cloud_rhel9/               # SUBMODULE: Complete build system
├── .env                            # Local credentials (gitignored)
├── README.md                       # Points to ibm_cloud_rhel9 docs
└── scripts/
    └── quick-build.sh             # Convenience wrapper for ibm_cloud_rhel9/build/
```

### Remote Host Changes (Non-Destructive)

```bash
# Backup existing directories (PRESERVE, don't delete)
~/gits/coco-podvm-scripts → ~/gits/coco-podvm-scripts.upstream.backup
~/gits/openshift/cloud-api-adaptor → ~/gits/openshift/cloud-api-adaptor.backup
~/build-podvm.sh → ~/build-podvm.sh.backup

# New structure (single git clone)
~/gits/ibm_cloud_rhel9/             # Clone of our consolidated repo
├── cloud-api-adaptor/              # Submodule (replaces ~/gits/openshift/cloud-api-adaptor)
├── build/                          # Build scripts
├── scripts/                        # PodVM customization
├── edr/                            # EDR files
└── .env                            # Credentials (gitignored)

# Existing directories (unchanged)
~/.local/share/libvirt/images/      # Still used for build artifacts
```

## Migration Steps

### Phase 1: Consolidate ibm_cloud_rhel9 Repository
1. ✅ Already have ibm_cloud_rhel9 as submodule in EDR
2. Add cloud-api-adaptor as submodule to ibm_cloud_rhel9
3. Move build-podvm.sh into ibm_cloud_rhel9/build/
4. Create modular build scripts (build-binaries.sh, build-qcow2.sh)
5. Add IBM Cloud integration scripts (ibmcloud/)
6. Update .gitignore for consolidated structure
7. Test locally before deploying

### Phase 2: Update Remote Host (Non-Destructive)
1. Backup existing directories with .backup suffix
2. Clone ibm_cloud_rhel9 to ~/gits/ibm_cloud_rhel9
3. Initialize submodules (cloud-api-adaptor)
4. Deploy .env file
5. Test build from new location
6. Validate all functionality works
7. Keep backups until confirmed working

### Phase 3: Update EDR Repository
1. Update EDR to use ibm_cloud_rhel9 submodule for all operations
2. Create convenience wrapper scripts in EDR/scripts/
3. Update EDR README to point to ibm_cloud_rhel9 docs
4. Archive old EDR scripts (don't delete)

### Phase 4: Jenkins Integration
1. Jenkins clones ibm_cloud_rhel9 (with submodules)
2. Create Jenkinsfile in ibm_cloud_rhel9
3. Add Jenkins credentials management
4. Add build parameters (tag, SSH enable, dm-verity)
5. Add test stage with validation
6. Add artifact publishing

### Phase 5: Documentation & Cleanup
1. Update all documentation in ibm_cloud_rhel9
2. Create Jenkins setup guide
3. Document migration from old structure
4. Update README with new workflow
5. Archive (don't delete) old remote host directories

## Benefits

### Single Source of Truth
- **Everything in one repo**: ibm_cloud_rhel9 contains all code
- **Submodules for dependencies**: cloud-api-adaptor tracked properly
- **Version controlled together**: Scripts + configs + docs in sync
- **Easy to clone**: `git clone --recursive` gets everything

### For Development
- Clear directory structure
- No manual file copying
- Easy to test locally
- Easy to understand

### For Jenkins
- Self-contained repository
- Submodules handled automatically
- Parameterized builds
- Automated testing
- Artifact management

### For Maintenance
- Single repo to update
- Clear ownership (ibm_cloud_rhel9 is ours)
- Upstream tracking (cloud-api-adaptor submodule)
- Easy to onboard new developers

## Rollback Plan

If consolidation causes issues:
1. Remote host backups preserved (.backup suffix)
2. Git history allows reverting all changes
3. Old EDR scripts remain in place
4. Can switch back to old workflow immediately
5. No data loss (backups, not deletions)

## Key Decisions

### Why ibm_cloud_rhel9 as main repo (not EDR)?
- ibm_cloud_rhel9 is our fork, we control it
- EDR is more of a workspace/orchestration repo
- ibm_cloud_rhel9 already has the core build logic
- Makes it reusable outside of EDR context

### Why cloud-api-adaptor as submodule?
- Tracks upstream Red Hat changes
- Clear separation: upstream vs our code
- Easy to update to new versions
- Proper git history tracking

### Why keep EDR repo?
- Workspace for development
- Can have multiple projects using ibm_cloud_rhel9
- Convenience wrappers for common tasks
- Local .env and configs

## Next Steps

1. ✅ Review this plan
2. Create feature branch in ibm_cloud_rhel9
3. Add cloud-api-adaptor as submodule
4. Implement Phase 1 (consolidate repo)
5. Test locally before remote deployment
6. Implement Phase 2 (update remote host)
7. Validate everything works
8. Implement remaining phases