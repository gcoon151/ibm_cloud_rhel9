# IBM Cloud VSI-Based PodVM Image Builder

This directory contains scripts and documentation for building PodVM images using IBM Cloud Virtual Server Instances (VSI) instead of local containers.

## Architecture Overview

### Traditional Approach (Container-Based)
```
Kickstart → virt-install → QCOW2 → Podman Container → Modified QCOW2
```

### New Approach (VSI-Based)
```
Pre-built QCOW2 (in COS) → IBM Cloud VSI → Modified QCOW2 (back to COS)
```

## Benefits

1. **Separation of Concerns**: Base image creation (rarely changes) is separate from PodVM transformation
2. **Security**: VSI runs in private subnet with no public internet access
3. **Scalability**: Can run multiple builds in parallel
4. **Auditability**: All builds logged and tracked in IBM Cloud
5. **Cost Efficiency**: Only pay for VSI during build time
6. **Versioning**: Automatic versioning with date-based naming

## Prerequisites

### 1. IBM Cloud Account
- Active IBM Cloud account
- Appropriate permissions for VPC, VSI, and COS

### 2. IBM Cloud CLI
```bash
# Install IBM Cloud CLI
curl -fsSL https://clis.cloud.ibm.com/install/linux | sh

# Install required plugins
ibmcloud plugin install vpc-infrastructure
ibmcloud plugin install cloud-object-storage

# Login
ibmcloud login --sso
ibmcloud target -r us-south -g default
```

### 3. IBM Cloud Infrastructure

#### VPC Setup
```bash
# Create VPC
ibmcloud is vpc-create podvm-builder-vpc

# Create subnet (private, no public gateway)
ibmcloud is subnet-create podvm-builder-subnet \
    <VPC_ID> \
    --zone us-south-1 \
    --ipv4-cidr-block 10.240.0.0/24
```

#### Security Group
```bash
# Create security group
ibmcloud is security-group-create podvm-builder-sg <VPC_ID>

# Allow outbound to COS endpoints only
ibmcloud is security-group-rule-add <SG_ID> outbound tcp \
    --remote 0.0.0.0/0 --port-min 443 --port-max 443

# No inbound rules needed (VSI doesn't need SSH access)
```

#### Cloud Object Storage
```bash
# Create COS instance (if not exists)
ibmcloud resource service-instance-create podvm-cos \
    cloud-object-storage standard global

# Create bucket
ibmcloud cos bucket-create \
    --bucket podvm-images \
    --ibm-service-instance-id <COS_INSTANCE_ID> \
    --region us-south

# Upload base image
ibmcloud cos upload \
    --bucket podvm-images \
    --key rhel9-base.qcow2 \
    --file /path/to/rhel9-base.qcow2 \
    --region us-south
```

### 4. Service Authorization
```bash
# Allow VSI to access COS
ibmcloud iam authorization-policy-create \
    is \
    cloud-object-storage \
    Reader,Writer \
    --source-resource-type instance \
    --target-service-instance-id <COS_INSTANCE_ID>
```

## Configuration

### Environment Variables

Create a `.env` file or export these variables:

```bash
# IBM Cloud Configuration
export IBM_CLOUD_REGION="us-south"
export IBM_CLOUD_ZONE="us-south-1"
export IBM_CLOUD_RESOURCE_GROUP="default"
export IBM_CLOUD_VPC_NAME="podvm-builder-vpc"
export IBM_CLOUD_SUBNET_NAME="podvm-builder-subnet"
export IBM_CLOUD_VSI_PROFILE="bx2-2x8"  # 2 vCPU, 8GB RAM
export IBM_CLOUD_VSI_IMAGE="ibm-redhat-9-3-minimal-amd64-1"

# COS Configuration
export COS_BUCKET_NAME="podvm-images"
export COS_BASE_IMAGE_NAME="rhel9-base.qcow2"
export COS_ENDPOINT="s3.us-south.cloud-object-storage.appdomain.cloud"
export COS_INSTANCE_ID="<your-cos-instance-id>"

# Build Configuration
export OUTPUT_IMAGE_PREFIX="podvm-rhel9"
export WORK_DIR="/tmp/podvm-builder"
```

## Usage

### Basic Build

```bash
# Source environment
source .env

# Run builder
./vsi-builder.sh
```

### Custom Configuration

```bash
# Build with custom base image
COS_BASE_IMAGE_NAME="rhel9-custom-base.qcow2" ./vsi-builder.sh

# Build with custom output prefix
OUTPUT_IMAGE_PREFIX="podvm-rhel9-test" ./vsi-builder.sh

# Build in different region
IBM_CLOUD_REGION="eu-de" \
IBM_CLOUD_ZONE="eu-de-1" \
./vsi-builder.sh
```

## Build Process

### Step-by-Step Flow

1. **Initialization**
   - Check prerequisites (IBM Cloud CLI, plugins, login)
   - Set up work directory
   - Copy build scripts

2. **Version Determination**
   - Query COS for existing images with today's date
   - Determine next version number (01, 02, 03, etc.)
   - Example: `podvm-rhel9-2026012601`, `podvm-rhel9-2026012602`

3. **VSI Creation**
   - Create VSI in private subnet
   - Inject cloud-init configuration
   - VSI has no public IP (secure)
   - VSI can only access COS endpoints

4. **Image Transformation** (runs on VSI via cloud-init)
   - Download base QCOW2 from COS
   - Install required packages (libguestfs, qemu-img, etc.)
   - Run `coco-components.sh` to install CoCo components
   - Run `verity.sh` to set up dm-verity
   - Upload result to COS with versioned name

5. **Completion**
   - VSI powers off automatically
   - Orchestration script verifies output in COS
   - VSI is deleted (cleanup)
   - Build log saved

### Cloud-Init Process

The VSI runs this sequence via cloud-init:

```yaml
1. Install packages (qemu-img, libguestfs, etc.)
2. Write build scripts to /root/
3. Execute /root/build-podvm.sh:
   - Copy base image from COS
   - Run transformation scripts
   - Upload result to COS
4. Power off VSI
```

## Output

### Naming Convention

```
podvm-rhel9-YYYYMMDD##.qcow2
```

Where:
- `YYYYMMDD`: Build date
- `##`: Version number (01, 02, 03, etc.)

### Examples

```
podvm-rhel9-2026012601.qcow2  # First build on Jan 26, 2026
podvm-rhel9-2026012602.qcow2  # Second build on Jan 26, 2026
podvm-rhel9-2026012701.qcow2  # First build on Jan 27, 2026
```

### Accessing Output

```bash
# List all images
ibmcloud cos list-objects \
    --bucket podvm-images \
    --prefix podvm-rhel9

# Download specific image
ibmcloud cos download \
    --bucket podvm-images \
    --key podvm-rhel9-2026012601.qcow2 \
    --file ./podvm-rhel9-2026012601.qcow2 \
    --region us-south

# Get image URL
ibmcloud cos get-object-url \
    --bucket podvm-images \
    --key podvm-rhel9-2026012601.qcow2
```

## Security Considerations

### Network Isolation

- VSI has **no public IP address**
- VSI is in **private subnet**
- No public gateway attached to subnet
- Only outbound HTTPS to COS endpoints allowed
- No SSH access needed or configured

### Credentials

- VSI uses **IAM service authorization** to access COS
- No API keys stored on VSI
- No credentials in cloud-init
- Temporary credentials via instance metadata

### Audit Trail

- All VSI creation logged in IBM Cloud Activity Tracker
- All COS access logged in COS Activity Tracker
- Build logs stored in COS
- VSI automatically deleted after build

## Monitoring

### Build Progress

```bash
# Check VSI status
ibmcloud is instance <VSI_ID>

# View VSI console output (if needed)
ibmcloud is instance-console <VSI_ID>

# Check COS for output
ibmcloud cos list-objects --bucket podvm-images --prefix podvm-rhel9-$(date +%Y%m%d)
```

### Logs

Build logs are available:
1. In the orchestration script output
2. In the work directory: `/tmp/podvm-builder-<pid>/build.log`
3. On the VSI: `/var/log/podvm-build.log` (before deletion)

## Troubleshooting

### VSI Doesn't Start

```bash
# Check VPC and subnet
ibmcloud is vpcs
ibmcloud is subnets

# Check security group rules
ibmcloud is security-group <SG_ID>

# Check VSI creation errors
ibmcloud is instances --output json | jq '.[] | select(.name | contains("podvm-builder"))'
```

### Build Fails

```bash
# Check VSI console output
ibmcloud is instance-console <VSI_ID>

# Check COS access
ibmcloud cos head-object --bucket podvm-images --key rhel9-base.qcow2

# Verify IAM authorization
ibmcloud iam authorization-policies
```

### Output Not in COS

```bash
# Check COS bucket
ibmcloud cos list-objects --bucket podvm-images

# Check COS permissions
ibmcloud cos bucket-head --bucket podvm-images

# Verify service authorization
ibmcloud iam authorization-policy <POLICY_ID>
```

### VSI Doesn't Power Off

- Build may still be running (check console output)
- Build may have failed (check logs)
- Manually delete VSI if needed: `ibmcloud is instance-delete <VSI_ID> --force`

## Cost Estimation

### Per Build

- **VSI**: ~$0.10/hour × 1 hour = $0.10
- **COS Storage**: $0.023/GB/month (minimal for temporary storage)
- **COS Bandwidth**: $0.09/GB (download + upload)
- **Total per build**: ~$0.15-0.25

### Monthly (assuming 20 builds)

- **VSI**: $2.00
- **COS Storage**: $0.50 (for stored images)
- **COS Bandwidth**: $1.80
- **Total**: ~$4.30/month

## Comparison with Container-Based Approach

| Aspect | Container-Based | VSI-Based |
|--------|----------------|-----------|
| **Build Time** | 30-45 min | 30-45 min |
| **Security** | Local machine | Isolated VSI |
| **Scalability** | Limited by local resources | Unlimited (parallel VSIs) |
| **Cost** | Free (local) | ~$0.20/build |
| **Auditability** | Local logs only | Full IBM Cloud audit trail |
| **Automation** | Requires local setup | Fully automated |
| **Versioning** | Manual | Automatic |

## Advanced Usage

### Parallel Builds

```bash
# Build multiple versions in parallel
for i in {1..3}; do
    OUTPUT_IMAGE_PREFIX="podvm-rhel9-variant$i" ./vsi-builder.sh &
done
wait
```

### Custom Transformation Scripts

```bash
# Add custom scripts to ibm-cloud/custom-scripts/
# They will be copied to VSI and available in /root/scripts/
```

### Integration with CI/CD

```yaml
# Example GitHub Actions workflow
name: Build PodVM Image
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Install IBM Cloud CLI
        run: curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
      - name: Login to IBM Cloud
        run: ibmcloud login --apikey ${{ secrets.IBM_CLOUD_API_KEY }}
      - name: Build PodVM Image
        run: ./ibm-cloud/vsi-builder.sh
```

## Maintenance

### Updating Base Image

```bash
# Build new base image (separate process)
# Upload to COS
ibmcloud cos upload \
    --bucket podvm-images \
    --key rhel9-base-v2.qcow2 \
    --file /path/to/new-base.qcow2

# Use new base
COS_BASE_IMAGE_NAME="rhel9-base-v2.qcow2" ./vsi-builder.sh
```

### Cleaning Up Old Images

```bash
# List old images
ibmcloud cos list-objects --bucket podvm-images --prefix podvm-rhel9

# Delete images older than 30 days
# (implement retention policy as needed)
```

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review IBM Cloud documentation
3. Check build logs
4. Verify infrastructure setup

## References

- [IBM Cloud VPC Documentation](https://cloud.ibm.com/docs/vpc)
- [IBM Cloud COS Documentation](https://cloud.ibm.com/docs/cloud-object-storage)
- [Cloud-init Documentation](https://cloudinit.readthedocs.io/)
- [Libguestfs Documentation](https://libguestfs.org/)