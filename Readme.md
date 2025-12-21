# IBM API Connect Automation Script

A powerful bash automation script for managing IBM API Connect deployments with intelligent incremental builds, schema injection, and product lifecycle management.

## 🎯 Overview

This script automates the complete lifecycle of API management in IBM API Connect, from creating/updating individual APIs to publishing complete product catalogs. It features git-based incremental builds that dramatically reduce deployment time by processing only changed services.

## ✨ Key Features

### 🚀 Smart Build Modes
- **Full Build** - Complete deployment of all APIs and products
- **Incremental Build** - Git-based change detection that only processes modified services
- **Automatic fallback** to full build when critical configuration files change

### 🔄 Intelligent API Management
- **Auto-detection** of existing APIs with smart create/update logic
- **Schema injection** from JSON files with automatic YAML conversion
- **Template-based** API generation with dynamic placeholder replacement
- **Target URL synchronization** to keep endpoints current
- **Operation name detection** from existing APIs for case-insensitive matching

### 📦 Product Lifecycle Automation
- **Automatic product merging** - Combines new and existing APIs without data loss
- **One-click publishing** from draft to catalog
- **Backup & rollback** capability for safe deployments
- **Missing API recovery** from backup files

### 🛡️ Enterprise-Ready
- **SSO authentication** with Keycloak integration
- **Validation at every step** - YAML, JSON, and API Connect validation
- **Success/failure tracking** with detailed reporting
- **State management** for reliable incremental builds
- **Comprehensive error handling** with graceful degradation

### ⚡ Performance & Efficiency
- **Skip unchanged services** in incremental mode (up to 80% faster)
- **Batch processing** of multiple APIs
- **Smart change detection** via git diff
- **Optimized schema loading** (single load per service)

### 🔧 Developer Experience
- **External configuration** via `config.env`
- **Cross-platform support** (Linux, Windows/WSL, macOS)
- **Detailed logging** with progress indicators
- **Automatic cleanup** of temporary files
- **Comment support** in service definitions

## 📋 Prerequisites

### Required
- **Bash 4.0+** - Shell environment
- **IBM API Connect Toolkit** - `apic` CLI tool
- **Python 3.6+** - For schema conversion and YAML processing
- **Git** - Required for incremental mode

### Helper Scripts (Required)
- `convert_json_to_yaml.py` - JSON to YAML converter
- `update_target_url.py` - Target URL updater
- `merge_apis.py` - API list merger

### API Connect Access
- API Connect management server URL
- Organization name
- Valid credentials for SSO login
- Catalog name for publishing

## 🚀 Installation

### 1. Clone or Download the Repository
```bash
git clone <repository-url>
cd apic-automation
```

### 2. Install IBM API Connect Toolkit

**Linux/macOS:**
```bash
# Download from IBM Fix Central
# Or use package manager
npm install -g @ibm/apiconnect-toolkit
```

**Windows:**
```powershell
# Download installer from IBM
# Install to: C:\Program Files\IBM\APIC-Toolkit\
```

### 3. Verify Prerequisites
```bash
# Check bash version
bash --version

# Check Python
python3 --version

# Check apic CLI
apic --version

# Check git (for incremental mode)
git --version
```

### 4. Make Script Executable
```bash
chmod +x yamlBuilderEnh.sh
```

## ⚙️ Configuration

### Create `config.env`

Copy the template and customize for your environment:

```bash
# ======================================
# APIC Script Configuration
# ======================================

# ------------------------------
# APIC Connection Settings
# ------------------------------
APIC_ORG="your-organization"
APIC_SERVER="https://your-apic-server.com"

# ------------------------------
# File Paths
# ------------------------------
INPUT_FILE="services.txt"
TEMPLATE_FILE="template.yaml"
OUTPUT_DIRECTORY="API-yamls"
SCHEMAS_DIRECTORY="schemas"

# ------------------------------
# Product Configuration
# ------------------------------
PRODUCT_NAME="my-product"
PRODUCT_VERSION="1.0.0"
PRODUCT_TITLE="My API Product"
CATALOG_NAME="sandbox"

# ------------------------------
# Build Tracking
# ------------------------------
LAST_COMMIT_FILE="API-yamls/.last_successful_commit"
```

### Create `services.txt`

Define your services in pipe-delimited format:

```
# ServiceName|ESBUrl|SchemaPath
Customer Service|https://api.example.com/customers|schemas/customer-request.json
Order Service|https://api.example.com/orders|schemas/order-request.json
Payment Service|https://api.example.com/payments|
# Comments and blank lines are ignored
```

**Format:**
- **ServiceName** - Display name for the API
- **ESBUrl** - Target backend URL
- **SchemaPath** - (Optional) Path to JSON schema file

### Create `template.yaml`

Your API template with placeholders:

```yaml
swagger: "2.0"
info:
  title: {{ServiceName}}
  x-ibm-name: {{x_ibm_name}}
  version: 1.0.0
basePath: /{{x_ibm_name}}
paths:
  /{{OperationName}}:
    post:
      operationId: {{OperationName}}
      parameters:
        - name: body
          in: body
          required: true
          schema:
            $ref: '#/definitions/{{OperationName}}Request'
definitions:
  {{OperationName}}Request:
    {{SCHEMA_PLACEHOLDER}}
x-ibm-configuration:
  gateway: datapower-api-gateway
  assembly:
    execute:
      - invoke:
          target-url: {{ESBUrl}}
```

**Available Placeholders:**
- `{{ServiceName}}` - Original service name
- `{{x_ibm_name}}` - Lowercase, hyphenated name
- `{{OperationName}}` - No-space version
- `{{ESBUrl}}` - Backend URL
- `{{SCHEMA_PLACEHOLDER}}` - Replaced with schema content

## 📖 Usage

### Full Build Mode (Default)

Process all services in `services.txt`:

```bash
./yamlBuilderEnh.sh
```

**Use when:**
- First-time deployment
- Major configuration changes
- Complete refresh needed

### Incremental Build Mode

Process only services with changed schemas:

```bash
./yamlBuilderEnh.sh --incremental
```

**Benefits:**
- 🚀 Up to 80% faster execution
- 🎯 Processes only modified schemas
- 🔄 Automatic full build if critical files changed
- 💾 Tracks last successful commit

**Automatic Full Build Triggers:**
- `services.txt` modified
- `template.yaml` modified
- `config.env` modified
- No previous successful run

### Environment Variable Override

Override configuration without editing `config.env`:

```bash
APIC_ORG="prod-org" \
CATALOG_NAME="production" \
./yamlBuilderEnh.sh
```

### Custom Configuration File

```bash
CONFIG_FILE="prod-config.env" ./yamlBuilderEnh.sh
```

## 📁 Project Structure

```
apic-automation/
├── yamlBuilderEnh.sh           # Main script
├── config.env                  # Configuration file
├── services.txt                # Service definitions
├── template.yaml               # API template
├── convert_json_to_yaml.py     # Schema converter
├── update_target_url.py        # URL updater
├── merge_apis.py               # API merger
├── schemas/                    # JSON schema files
│   ├── customer-request.json
│   ├── order-request.json
│   └── payment-request.json
└── API-yamls/                  # Output directory
    ├── .backup/                # Backups
    ├── .last_successful_commit # Git tracking
    ├── customer-service_1.0.0.yaml
    ├── order-service_1.0.0.yaml
    └── my-product_1.0.0.yaml
```

## 🔄 How It Works

### Workflow Overview

```
┌─────────────────────────────────────────────────┐
│ 1. Initialization                               │
│    - Load config.env                            │
│    - Parse arguments                            │
│    - Determine build mode                       │
└─────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────┐
│ 2. Incremental Logic (if --incremental)        │
│    - Get changed files via git diff             │
│    - Check for critical file changes            │
│    - Force full build if needed                 │
└─────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────┐
│ 3. Authentication                               │
│    - Login to API Connect via SSO               │
└─────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────┐
│ 4. Process Each Service                         │
│    FOR EACH line in services.txt:               │
│    ├─ Skip if unchanged (incremental mode)      │
│    ├─ Check if API exists                       │
│    ├─ CREATE PATH (new API)                     │
│    │  ├─ Generate from template                 │
│    │  ├─ Inject schema                          │
│    │  ├─ Validate YAML                          │
│    │  └─ Create draft API                       │
│    └─ UPDATE PATH (existing API)                │
│       ├─ Get existing API                       │
│       ├─ Replace schema section                 │
│       ├─ Update target URL                      │
│       ├─ Validate YAML                          │
│       └─ Update draft API                       │
└─────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────┐
│ 5. Product Management                           │
│    - Collect all API references                 │
│    - Backup existing product                    │
│    - Merge new + existing APIs                  │
│    - Generate product YAML                      │
│    - Create/Update draft product                │
│    - Publish to catalog                         │
└─────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────┐
│ 6. Finalization                                 │
│    - Finalize backups                           │
│    - Display summary                            │
│    - Save git commit hash (if successful)       │
└─────────────────────────────────────────────────┘
```

### Decision Points

#### 1. Build Mode Selection
```
--incremental flag?
  ├─ YES → Check git changes
  │         ├─ Critical files changed? → FULL BUILD
  │         └─ Only schemas changed? → INCREMENTAL
  └─ NO → FULL BUILD
```

#### 2. Per-Service Processing
```
For each service:
  ├─ Incremental mode AND schema unchanged?
  │  └─ YES → SKIP this service
  └─ NO → Check if API exists
      ├─ NO → CREATE PATH
      └─ YES → UPDATE PATH
```

#### 3. Product Update Decision
```
Should update product?
  ├─ Incremental mode AND no APIs updated?
  │  └─ YES → SKIP product update
  └─ NO → Proceed with product update
```

#### 4. State Saving
```
Save commit hash?
  ├─ All operations successful (FAILURE_COUNT=0)?
  │  └─ YES → Save current commit hash
  └─ NO → Keep previous commit hash
```

## 🔍 Monitoring & Logging

### Real-time Progress

The script provides detailed progress with visual indicators:

```
======================================
Processing: 'Customer Service'
  ESB URL: https://api.example.com/customers
  Schema:  schemas/customer-request.json
======================================
2) Checking if API exists...
  ✓ API exists, will update
3) Loading schema from: schemas/customer-request.json
  ✓ Schema loaded and converted to YAML
4) Updating existing API with new schema...
  ℹ Detected operation name from existing API: CustomerService
  ✓ Schema section replaced
  ✓ Target URL updated
5) Validating updated YAML...
  ✓ Validation passed
6) Updating draft API in API Connect...
  ✓ Draft API updated successfully
```

### Success Summary

```
========================================
✓ COMPLETE: All operations finished successfully
========================================
  APIs created/updated: 5
  Product: my-product v1.0.0
  Published to catalog: sandbox
========================================
```

### Error Tracking

```
========================================
⚠ Completed with 4 successes and 1 failures
========================================
```

## 🐛 Troubleshooting

### Common Issues

#### 1. Login Failed
```
Error: Login failed
```
**Solution:**
- Verify `APIC_SERVER` URL is correct
- Check network connectivity
- Ensure SSO credentials are valid
- Verify organization name in `APIC_ORG`

#### 2. API Validation Failed
```
✗ Validation failed: YAML file is invalid
```
**Solution:**
- Check template.yaml syntax
- Verify all placeholders are replaced
- Validate schema JSON format
- Review generated YAML in `API-yamls/` directory

#### 3. Schema Not Found
```
Error: Schema file not found: schemas/customer.json
```
**Solution:**
- Verify file path in `services.txt`
- Check file exists in schemas directory
- Ensure correct file permissions

#### 4. Product Publish Failed
```
✗ Failed to publish product to catalog
```
**Solution:**
- Verify catalog name is correct
- Check all referenced API YAMLs exist
- Ensure APIs are valid and not conflicting
- Review API Connect logs

#### 5. Incremental Mode Issues
```
⚠ Invalid hash format
```
**Solution:**
- Delete `.last_successful_commit` file
- Run full build once: `./yamlBuilderEnh.sh`
- Verify git repository is initialized

#### 6. Python Script Errors
```
Error: python3 is required but not found
```
**Solution:**
```bash
# Install Python 3
sudo apt-get install python3  # Ubuntu/Debian
brew install python3          # macOS
```

#### 7. Permission Denied
```
bash: ./yamlBuilderEnh.sh: Permission denied
```
**Solution:**
```bash
chmod +x yamlBuilderEnh.sh
```

### Debug Mode

Enable verbose output by adding debug statements:

```bash
set -x  # Add to top of script
./yamlBuilderEnh.sh
```

### Manual Cleanup

If script fails mid-execution:

```bash
# Clean temporary files
rm -rf API-yamls/.temp_*
rm -rf API-yamls/.backup_temp_*

# Reset incremental state
rm API-yamls/.last_successful_commit

# Logout from API Connect
apic logout --server "$APIC_SERVER"
```

## 📊 Performance Optimization

### Incremental Mode Performance

| Scenario | Services | Full Build | Incremental | Time Saved |
|----------|----------|------------|-------------|------------|
| No changes | 50 | 15 min | 30 sec | 97% |
| 5 schemas changed | 50 | 15 min | 2 min | 87% |
| 25 schemas changed | 50 | 15 min | 8 min | 47% |
| Config changed | 50 | 15 min | 15 min | 0% (auto full) |

### Best Practices

1. **Use Incremental Mode in CI/CD**
   ```yaml
   # GitLab CI example
   deploy:
     script:
       - ./yamlBuilderEnh.sh --incremental
   ```

2. **Organize Schemas by Service**
   ```
   schemas/
   ├── customer/
   │   ├── create-request.json
   │   └── update-request.json
   └── order/
       ├── create-request.json
       └── cancel-request.json
   ```

3. **Use Meaningful Service Names**
   ```
   # Good
   Customer Management Service|url|schema.json
   
   # Avoid special characters
   Cust.Mgmt#Service|url|schema.json
   ```

4. **Comment Disabled Services**
   ```
   Active Service|url|schema.json
   # Temporarily disabled
   # Legacy Service|url|schema.json
   ```

## 🔐 Security Considerations

### Credential Management

**❌ Never commit:**
- API Connect passwords
- API keys
- Production server URLs

**✅ Use instead:**
- Environment variables
- Separate config files per environment
- Secret management tools (Vault, AWS Secrets Manager)

### Example Setup

```bash
# .gitignore
config.env
prod-config.env
*.secret

# Template: config.env.template
APIC_ORG="<YOUR_ORG>"
APIC_SERVER="<YOUR_SERVER>"
```

### SSO Login

The script uses SSO authentication which:
- ✅ Avoids storing passwords
- ✅ Supports multi-factor authentication
- ✅ Uses temporary session tokens
- ✅ Integrates with enterprise identity providers