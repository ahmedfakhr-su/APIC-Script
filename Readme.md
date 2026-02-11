# APIC Deployment Script - Complete Algorithm Flow

Interactive breakdown showing the full execution path with integrated utility functions

## How to Use

This automation tool synchronizes your API definitions with IBM API Connect, handling creation, updates, and product publishing in a single workflow.

### Prerequisites

Before running the script, ensure your environment meets the following requirements:

*   **IBM API Connect CLI (`apic`)**: Must be installed and available in your PATH.
*   **Python 3**: Required for schema processing and backend URL updates.
*   **yq**: Required for advanced YAML manipulation (https://github.com/mikefarah/yq).
*   **jq**: Required for parsing the JSON API catalog.
*   **Git**: Required if you intend to use the `--incremental` build mode.

### Configuration

The script is driven by the `Data-Config/config.env` file. Update it with your specific environment details. Below is the structure of the configuration file:

```bash
# APIC Connection Settings
APIC_ORG="apic-sit"
APIC_SERVER="https://apic-sit-mgmt-api-manager.example.com"

# File Paths
INPUT_FILE="Data-Config/api_catalog.json"
TEMPLATE_FILE="Data-Config/template.yaml"
OUTPUT_DIRECTORY="API-yamls"
SCHEMAS_DIRECTORY="schemas"

# Product Configuration
PRODUCT_NAME="internal-services"
PRODUCT_VERSION="1.0.0"
PRODUCT_TITLE="Internal Services"
CATALOG_NAME="internal"

# Build Tracking
LAST_COMMIT_FILE="API-yamls/.last_successful_commit"
```

### Basic Usage

1.  **Run the script**: Choose between full or incremental mode.
    *   **Full Deployment**: `./APIC_Agent.sh`
    *   **Incremental Update**: `./APIC_Agent.sh --incremental`

2.  **Browser Authentication**: 
    Since the script utilizes `--sso` (Single Sign-On) for authentication, running the script will automatically trigger a browser window (or provide a URL) where you **must sign in with your corporate credentials** to authorize the APIC CLI session.

3.  **Monitor Progress**: The script will validate your APIs, sync them to the draft pool, and publish the product once authenticated.

### Example

To deploy a set of services:
1.  Define your services in `Data-Config/api_catalog.json`.
2.  Run `./APIC_Agent.sh`.
3.  **Authenticate in the browser when prompted.**
4.  The script will finalize the product bundle and publish it to the target catalog.

---

## Table of Contents

- [How to Use](#how-to-use)
- [Overview](#overview)
- [Phase 1: Initialization & Configuration](#phase-1-initialization--configuration)
- [Phase 2: API Processing Loop](#phase-2-api-processing-loop)
- [Phase 3: Product Update & Publish](#phase-3-product-update--publish)
- [Phase 4: Finalization & Cleanup](#phase-4-finalization--cleanup)

---

## Overview

This document provides a complete walkthrough of the APIC deployment script's execution flow, including all decision points, function calls, and branching logic.

---

## PHASE 1: Initialization & Configuration

### Step 1: Load Configuration

**Description:** Load environment variables from config file or use defaults

**Process:**

1. **Check for CONFIG_FILE environment variable** (default: `Data-Config/config.env`)
2. **Source config file if it exists**
3. **Set all configuration variables with defaults:**
   ```
   InputFile, TemplateFile, OutputDirectory, SchemasDirectory
   APIC_ORG, APIC_SERVER, PRODUCT_NAME, PRODUCT_VERSION, CATALOG_NAME
   ```

**Key Variables Initialized:**

- **InputFile:** JSON catalog with API definitions
- **TemplateFile:** YAML template for new APIs
- **OutputDirectory:** Where generated YAMLs are stored
- **PRODUCT_NAME:** Product bundle name in API Connect

---

### Step 2: Prerequisite Checks

**Description:** Verify required tools are installed (apic, python3, yq)

**Process:**

1. Check if `apic` CLI is installed
2. Check if `python3` is available (required for schema processing)
3. Check if `yq` is available (required for YAML manipulation)

⚠️ **Exit on Failure:** Script exits with error if any required tool is missing

---

### Step 3: Parse Arguments & Determine Build Mode

**Description:** Check for `--incremental` flag and determine if full or partial build

**Process:**

1. Parse command line arguments looking for `--incremental` flag

**Decision Point:**

#### ✓ Incremental Mode

**Functions Called:**

- **`check_prerequisites()`**
  - Verifies git is installed for incremental builds

- **`get_changed_files()`**
  - Gets list of files changed since last successful run
  - **How it works:**
    1. Read last commit hash from file
    2. Get current commit hash
    3. Run `git diff --name-only` between them
    4. Return list of changed filenames

If critical files changed (`services.json`, `template.yaml`, `config.env`), set `FORCE_ALL=true`

#### ✗ Full Build Mode (Default)

Set `FORCE_ALL=true`  
Process all APIs regardless of changes

---

### Step 4: Detect APIC Command & Login

**Description:** Find APIC CLI executable and authenticate to API Connect

**Function Called:**

- **`detect_apic_cmd()`**
  - Locates APIC CLI across different platforms (WSL, Windows, Unix)
  - **Search Order:**
    1. WSL: `/mnt/c/Program Files/IBM/APIC-Toolkit/apic.exe`
    2. Windows: `C:/Program Files/IBM/APIC-Toolkit/apic.exe`
    3. System PATH: `apic` command

**Login Process:**

```bash
$APIC_CMD login --server $APIC_SERVER \
  --realm "provider/integration-keycloak" \
  --context "provider" --sso --accept-license
```

⚠️ **Exit on Login Failure:** Script exits if login fails - cannot proceed without authentication

---

### Step 5: Validate API Names Uniqueness

**Description:** Ensure no duplicate API names exist in catalog

**Function Called:**

- **`validate_unique_api_names($InputFile)`**
  - Prevents deployment conflicts by detecting duplicate API identifiers
  - **Process:**
    1. Parse all APIs from REST and SOAP sections
    2. Normalize each name (lowercase, hyphens)
    3. Track names in associative array
    4. Report all duplicates with original names
    5. Exit with error if duplicates found

**Why This Matters:**

API Connect uses normalized names as unique identifiers. Duplicates would cause overwrites and deployment failures. This validation happens early to fail fast.

---

## PHASE 2: API Processing Loop

### Step 6: FOR EACH API in Catalog (REST + SOAP)

**Description:** Iterate through all services in hierarchical JSON catalog

**Code:**

```bash
# Flatten REST and SOAP sections into single stream
jq -c '(.REST, .SOAP) | .[][]' "$InputFile"
```

**Process:**

1. **Extract fields from each API:**
   ```
   ServiceName = API Name
   ESBUrl = Backend URL
   SchemaPath = JSON schema file location (optional)
   ```

2. **Skip blank lines and comments** (lines starting with #)

3. **Generate derived names:**
   ```
   x_ibm_name = lowercase-with-hyphens
   OperationName = CamelCaseNoSpaces
   OUTPUT_FILE = API-yamls/{x_ibm_name}_1.0.0.yaml
   ```

4. **Add API to API_REFS array** (used later for product)

**📌 Catalog Structure:**

- JSON has two top-level objects: REST and SOAP
- Each contains service categories as keys
- Values are arrays of API objects with "API Name", "Url", "Schema Location"

---

### Step 7: Incremental Mode Check

**Description:** Skip API if unchanged (incremental mode only)

**Decision Point:**

#### ✓ Incremental + Schema Has Changed

**Check:** Is SchemaPath in CHANGED_FILES list?

If YES:
- Continue processing this API
- Set `NEED_API_SYNC=true`

#### ✗ Incremental + No Changes

**Skip this API:**
- Schema file hasn't changed
- No need to sync to API Connect
- Continue to next API in loop

⚠️ **Force All Override:** If `FORCE_ALL=true` (critical files changed or full build), this check is skipped and ALL APIs are processed regardless of individual changes

---

### Step 8: Escape Special Characters

**Description:** Prepare strings for sed replacement (prevent injection)

**Function Called:**

- **`escape_sed_replacement($string)`**
  - Escapes `/`, `|`, `&` characters to prevent sed injection attacks
  - **Applied to:**
    - `escService = ServiceName`
    - `escName = x_ibm_name`
    - `escOp = OperationName`
    - `escUrl = ESBUrl`

🔒 **Security Note:** Without escaping, user-provided strings containing `/`, `|`, or `&` could break sed commands or inject malicious patterns

---

### Step 9: Check if API Exists in API Connect

**Description:** Query API Connect to determine create vs update path

**Process:**

1. Create temporary directory for API retrieval
2. Attempt to get existing API:
   ```bash
   $APIC_CMD draft-apis:get "${x_ibm_name}:1.0.0" \
     --server "$APIC_SERVER" --org "$APIC_ORG" \
     --output "$TEMP_API_DIR"
   ```
3. Set `API_EXISTS` flag based on command success

**🔀 Branching Point:**

- **API_EXISTS = false:** Go to PATH A (Create New API)
- **API_EXISTS = true:** Go to PATH B (Update Existing API)

---

### Step 10: Load Schema (if provided)

**Description:** Convert JSON schema to YAML format for OpenAPI

**Decision Point:**

#### ✓ Schema Provided

**Function Called:**

- **`load_json_schema($SchemaPath)`**
  - Converts JSON schema to YAML and outputs to temp file
  - **Steps:**
    1. Verify schema file exists
    2. Validate JSON with Python
    3. Convert to YAML via Python script
    4. Save to `$TEMP_SCHEMA_FILE`

Set `SCHEMA_PROVIDED=true`

#### ✗ No Schema

Set `SCHEMA_PROVIDED=false`  
Will use empty/minimal schema later

---

## PATH A: Create New API

### Step A1: Generate Complete YAML from Template

**Description:** Replace placeholders and inject schema

**Process:**

1. **Parse x_ibm_name to extract service name and function ID:**
   ```bash
   # Example: "authenticate-user-181010"
   service_name = "authenticate-user"  # everything before last hyphen
   function_id = "/181010"             # last numeric part with /
   ```

2. **Use sed to replace placeholders in template:**
   ```
   {{ServiceName}} → ServiceName
   {{x_ibm_name}} → service_name
   {{api_full_name}} → x_ibm_name
   {{function_id}} → function_id
   {{OperationName}} → OperationName
   {{ESBUrl}} → ESBUrl
   ```

3. **Save to temporary YAML file**

4. **Replace {{SCHEMA_PLACEHOLDER}}**

#### ✓ Schema Provided

Use awk to:
1. Find `{{SCHEMA_PLACEHOLDER}}` line
2. Read entire `$TEMP_SCHEMA_FILE`
3. Insert schema content at that location
4. Write to `$OUTPUT_FILE`

**Result:** Full schema under `components/schemas/{OperationName}Request`

#### ✗ No Schema

Generate minimal valid OpenAPI schema:
```yaml
type: object
properties: {}
```

Use awk to:
1. Capture indentation of placeholder line
2. Insert minimal schema with proper indentation
3. Write to `$OUTPUT_FILE`

**📌 Why Minimal Schema?**

OpenAPI spec requires a schema definition. Empty schema allows API to accept any JSON, which is needed when formal schema isn't available.

---

### Step A2: Validate Generated YAML

**Description:** Use APIC CLI to validate OpenAPI structure

```bash
$APIC_CMD validate "$OUTPUT_FILE"
```

**Decision Point:**

#### ✗ Validation Failed
- Log error
- Clean up temp files
- Increment FAILURE_COUNT
- Continue to next API (skip create)

#### ✓ Validation Passed
Proceed to A3 (Create Draft API)

---

### Step A3: Create Draft API in API Connect

**Description:** Upload new API definition to platform

```bash
$APIC_CMD draft-apis:create \
  --org "$APIC_ORG" \
  --server "$APIC_SERVER" \
  "$OUTPUT_FILE"
```

**Decision Point:**

#### ✓ Success
- Increment SUCCESS_COUNT
- Increment CREATED_COUNT
- Log success message
- Continue to next API

#### ✗ Failure
- Log error
- Increment FAILURE_COUNT
- Continue to next API

---

## PATH B: Update Existing API

### Step B1: Detect Existing Operation Name

**Description:** Find actual schema key in existing API YAML

**Process:**

1. Parse existing API file from temp directory
2. Use awk to extract operation name from `components/schemas` section:
   ```bash
   awk '/^  schemas:/,/^[^ ]/ {
     if (/^    [A-Za-z0-9]*Request:/) print
   }' | sed 's/Request:.*//'
   ```
3. Set `ACTUAL_OPERATION_NAME` (or use new OperationName if none found)
4. Set `SCHEMA_EXISTS` flag (true if operation found, false if not)

**📌 Why Detect Actual Name?**

Operation names may have changed over time. We need to find the ACTUAL key name currently in the API to properly replace/remove it.

---

### Step B2: Schema Update Decision Tree

**Description:** 4 possible paths based on schema provision and existence

**🌳 Decision Matrix:**

- **Path 1:** Schema Provided + Schema Exists → Replace
- **Path 2:** Schema Provided + No Schema → Insert
- **Path 3:** No Schema + Schema Exists → Replace with Empty
- **Path 4:** No Schema + No Schema → Insert Empty

#### Path 1: Schema Provided + Schema Exists

**Function Called:**

- **`replace_schema_section()`**
  - **Parameters:**
    - `$1 = EXISTING_API_FILE`
    - `$2 = ACTUAL_OPERATION_NAME`
    - `$3 = TEMP_SCHEMA_FILE` (new schema)
    - `$4 = UPDATED_API_FILE` (output)
  - **Process:**
    1. Verify new schema file exists
    2. Confirm key exists at `components.schemas`
    3. Create wrapper YAML with new schema
    4. Merge using yq (overwrites existing key)
    5. Verify replacement succeeded

#### Path 2: Schema Provided + No Existing Schema

**Function Called:**

- **`insert_schema_section()`**
  - **Parameters:**
    - `$1 = EXISTING_API_FILE`
    - `$2 = ACTUAL_OPERATION_NAME`
    - `$3 = TEMP_SCHEMA_FILE`
    - `$4 = UPDATED_API_FILE` (output)
  - **Process:**
    1. Check if `components/schemas` exists
    2. Create wrapper with proper structure
    3. Merge wrapper with existing file using yq
    4. Verify insertion succeeded

#### Path 3: No Schema Provided + Schema Exists

**Step 3.1: Backup Existing Schema**

**Function Called:**

- **`remove_schema_section()`**
  - **Parameters:**
    - `$1 = EXISTING_API_FILE`
    - `$2 = ACTUAL_OPERATION_NAME`
    - `$3 = SCHEMA_BACKUP_FILE` (timestamped)
    - `$4 = TEMP_REMOVED` (output)
  - **Process:**
    1. Check if key exists at `components.schemas`
    2. Extract schema to backup file using yq
    3. Delete schema using `yq del()`
    4. Verify deletion

**Step 3.2: Insert Empty Schema**

**Function Called:**

- **`insert_schema_section()`**
  - **Parameters:**
    - `$1 = TEMP_REMOVED` (from step 3.1)
    - `$2 = ACTUAL_OPERATION_NAME`
    - `$3 = EMPTY_SCHEMA_FILE` (type: object, properties: {})
    - `$4 = UPDATED_API_FILE` (final output)

#### Path 4: No Schema Provided + No Existing Schema

**Function Called:**

- **`insert_schema_section()`**
  - **Parameters:**
    - `$1 = EXISTING_API_FILE`
    - `$2 = ACTUAL_OPERATION_NAME`
    - `$3 = EMPTY_SCHEMA_FILE`
    - `$4 = UPDATED_API_FILE` (output)
  - **Result:** Creates minimal schema in previously schema-less API

---

### Step B3: Update Target URL

**Description:** Update backend endpoint in API YAML

**Function Called:**

- **`update_target_url($UPDATED_API_FILE, $ESBUrl)`**
  - Updates target-url field in API assembly using Python
  - **Process:**
    1. Check if python3 is available
    2. Call `update_target_url.py` Python script
    3. Python parses YAML and updates target-url
    4. Saves modified YAML back to file

**📌 Why Always Update URL?**

Backend URLs may change independently of schemas. This ensures the API points to the correct endpoint even if schema hasn't changed.

---

### Step B4: Validate Updated YAML

**Description:** Ensure modifications didn't break YAML structure

```bash
$APIC_CMD validate "$UPDATED_API_FILE"
```

**Decision Point:**

#### ✗ Validation Failed
- Log error
- Clean up temp files
- Increment FAILURE_COUNT
- Continue to next API (skip update)

#### ✓ Validation Passed
Proceed to B5 (Update Draft API)

---

### Step B5: Update Draft API in API Connect

**Description:** Push modified API definition to platform

```bash
$APIC_CMD draft-apis:update "${x_ibm_name}:1.0.0" \
  --server "$APIC_SERVER" \
  --org "$APIC_ORG" \
  "$UPDATED_API_FILE"
```

**Decision Point:**

#### ✓ Success
- Increment SUCCESS_COUNT
- Increment UPDATED_COUNT
- Copy updated file to OUTPUT_FILE
- Log success message
- Continue to next API

#### ✗ Failure
- Log error
- Increment FAILURE_COUNT
- Continue to next API

---

### Step 11: End of API Processing Loop

**Description:** Return to step 6 for next API, or continue if done

**📊 Summary Statistics Collected:**

- **SUCCESS_COUNT:** Total APIs successfully processed
- **CREATED_COUNT:** New APIs created
- **UPDATED_COUNT:** Existing APIs updated
- **FAILURE_COUNT:** APIs that failed validation or sync
- **API_REFS[]:** Array of all processed API names for product

---

## PHASE 3: Product Update & Publish

### Step 12: Should We Update Product?

**Description:** Check if product update is needed

**Checks:**

1. **Check 1:** If `FAILURE_COUNT > 0`: Skip product update (incomplete)
2. **Check 2:** If Incremental Mode + `FORCE_ALL=false` + `SUCCESS_COUNT=0`: Skip (no changes)

**Decision Point:**

#### ✗ Skip Product Update
Either failures occurred or no changes in incremental mode  
Jump to Step 17 (Final Summary)

#### ✓ Proceed with Product Update
All APIs processed successfully and changes exist  
Continue to Step 13

---

### Step 13: Backup Existing Product

**Description:** Create temporary backup for rollback capability

**Process:**

1. Create `$TEMP_BACKUP_DIR` (timestamped)
2. Try to retrieve existing product:
   ```bash
   $APIC_CMD draft-products:get \
     "${PRODUCT_NAME}:${PRODUCT_VERSION}" \
     --server "$APIC_SERVER" --org "$APIC_ORG" \
     --output "$TEMP_BACKUP_DIR"
   ```
3. If product exists:
   - Rename to EXISTING_PRODUCT_FILE for merging
   - Create BACKUP_FILE copy
   - Set `PRODUCT_EXISTS=true`
4. If product doesn't exist: Set `PRODUCT_EXISTS=false`

**🔄 Backup Strategy:**

Temporary backup is created in `$TEMP_BACKUP_DIR` with process ID suffix. On success, moved to `$BACKUP_DIR`. On failure, cleaned up by EXIT trap.

---

### Step 14: Build API References Section

**Description:** Merge new and existing APIs into product definition

**Process:**

1. **Build NEW_APIS_SECTION from API_REFS[] array:**
   ```bash
   for api_name in "${API_REFS[@]}"; do
     NEW_APIS_SECTION+="  ${api_name}:
       \$ref: ${api_name}_1.0.0.yaml
   "
   done
   ```

**Decision Point:**

#### ✓ Product Exists

**Merge Strategy:**

1. Parse existing product's apis section
2. Add all existing APIs to MERGED_APIS_SECTION (preserving order)
3. Add NEW APIs that aren't already in product
4. Use associative array to track seen APIs (prevent duplicates)

Set `FINAL_APIS_SECTION = MERGED_APIS_SECTION`

#### ✗ New Product

Set `FINAL_APIS_SECTION = NEW_APIS_SECTION`  
(Only includes APIs from this run)

---

### Step 15: Verify API YAML Files Exist

**Description:** Ensure all referenced APIs have local YAML files

**Process:**

1. Parse FINAL_APIS_SECTION to extract all API names
2. For each API name:
   ```bash
   api_file="${OutputDirectory}/${api_name}_1.0.0.yaml"
   ```
3. If file doesn't exist locally:
   - Check if backup exists in TEMP_BACKUP_DIR
   - Copy from backup if found
   - Log warning if not in backup either

⚠️ **Why This Check?**

When merging with existing product, some APIs may not have been processed this run. We need their YAML files locally to create the product bundle.

---

### Step 16: Generate & Publish Product

**Description:** Create product YAML and deploy to catalog

**Process:**

1. **Generate complete product YAML:**
   ```yaml
   product: 1.0.0
   info:
     name: ${PRODUCT_NAME}
     title: ${PRODUCT_TITLE}
     version: ${PRODUCT_VERSION}
   
   apis:
   ${FINAL_APIS_SECTION}
   
   visibility:
     view: {type: public}
     subscribe: {type: authenticated}
   
   plans:
     default-plan:
       title: Default Plan
       rate-limits:
         default: {value: 100/1hour}
   ```

2. **Try to update existing product:**
   ```bash
   $APIC_CMD draft-products:update \
     "${PRODUCT_NAME}:${PRODUCT_VERSION}" \
     --server "$APIC_SERVER" --org "$APIC_ORG" \
     "$PRODUCT_FILE"
   ```

3. **If update fails (product doesn't exist), create new:**
   ```bash
   $APIC_CMD draft-products:create \
     --server "$APIC_SERVER" --org "$APIC_ORG" \
     "$PRODUCT_FILE"
   ```

4. **Publish product to catalog:**
   ```bash
   $APIC_CMD products:publish \
     --server "$APIC_SERVER" --org "$APIC_ORG" \
     --catalog "$CATALOG_NAME" "$PRODUCT_FILE"
   ```

**📦 Product Bundle:**

The product acts as a container for all APIs. Publishing to catalog makes them available to consumers through the developer portal.

---

## PHASE 4: Finalization & Cleanup

### Step 17: Finalize Backup

**Description:** Move temporary backup to permanent location

**Function Called:**

- **`finalize_backup()`**
  - Promotes temporary backup to permanent backup directory
  - **Process:**
    1. Check if TEMP_BACKUP_DIR exists
    2. Remove old BACKUP_DIR if present
    3. Move TEMP_BACKUP_DIR to BACKUP_DIR
    4. Disable EXIT trap (backup preserved)

**🔄 Rollback Capability:**

This backup can be used to restore the previous product state if issues are discovered post-deployment.

---

### Step 18: Save Incremental State

**Description:** Record current commit for future incremental builds

**Decision Point:**

#### ✓ Success (FAILURE_COUNT = 0)

```bash
current_hash=$(git rev-parse HEAD)
echo "$current_hash" > "$LAST_COMMIT_FILE"
```

This commit hash will be used as baseline for next incremental build

#### ✗ Failures Occurred

Do NOT save state  
Next incremental build will re-process from last successful run

---

### Step 19: Display Final Summary

**Description:** Show deployment results and statistics

```
========================================
✓ COMPLETE: All operations finished successfully
========================================

API Statistics:
  - APIs Created: $CREATED_COUNT
  - APIs Updated: $UPDATED_COUNT
  - Total Processed: $SUCCESS_COUNT
  - Failed: $FAILURE_COUNT

Product:
  - Name: $PRODUCT_NAME v$PRODUCT_VERSION
  - Total APIs in Product: ${#API_REFS[@]}
  - Published to catalog: $CATALOG_NAME
========================================

📦 Final backup location: ${BACKUP_DIR}/...
```

---

## ✓ Deployment Complete!

All APIs synced and product published to catalog

---

## Key Functions Reference

### Utility Functions

| Function | Purpose |
|----------|---------|
| `detect_apic_cmd()` | Locates APIC CLI across different platforms |
| `check_prerequisites()` | Verifies required tools are installed |
| `get_changed_files()` | Gets list of files changed since last run |
| `escape_sed_replacement()` | Escapes special characters for sed |
| `validate_unique_api_names()` | Checks for duplicate API identifiers |
| `load_json_schema()` | Converts JSON schema to YAML |
| `replace_schema_section()` | Replaces existing schema in API YAML |
| `insert_schema_section()` | Inserts new schema into API YAML |
| `remove_schema_section()` | Backs up and removes schema from API |
| `update_target_url()` | Updates backend endpoint URL |
| `finalize_backup()` | Moves temporary backup to permanent location |

---

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CONFIG_FILE` | Path to configuration file | `Data-Config/config.env` |
| `InputFile` | JSON catalog with API definitions | - |
| `TemplateFile` | YAML template for new APIs | - |
| `OutputDirectory` | Where generated YAMLs are stored | `API-yamls` |
| `SchemasDirectory` | Location of JSON schemas | - |
| `APIC_ORG` | API Connect organization | - |
| `APIC_SERVER` | API Connect server URL | - |
| `PRODUCT_NAME` | Product bundle name | - |
| `PRODUCT_VERSION` | Product version | `1.0.0` |
| `CATALOG_NAME` | Target catalog for publishing | - |

---

## Build Modes

### Full Build Mode (Default)

- Processes ALL APIs regardless of changes
- Set when no `--incremental` flag is provided
- Set when critical files have changed

### Incremental Build Mode

- Only processes APIs whose schema files have changed
- Activated with `--incremental` flag
- Requires git for file change detection
- Tracks last successful commit for comparison

---

## Error Handling

The script implements comprehensive error handling:

- **Early Exit:** Prerequisites and login failures stop execution immediately
- **Per-API Handling:** Individual API failures don't stop the batch process
- **Product Safety:** Product update skipped if any API failures occurred
- **State Preservation:** Incremental state only saved on complete success
- **Backup Protection:** Temporary backups cleaned up on failure via EXIT trap

---

## Notes

- All temporary files are cleaned up automatically via EXIT trap
- Backups include timestamps for version tracking
- Schema backups are preserved when schemas are removed
- Product merging preserves existing API order
- Validation happens at multiple stages to fail fast