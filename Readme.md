# YAML Builder — Features

## Overview
Generates IBM API Connect YAML drafts from a template and service list, with optional JSON Schema injection converted to OpenAPI-compatible YAML.

## Key Features
- Reads services from `services.txt` (pipe-delimited).
- Supports an optional JSON schema per service; converts JSON → YAML and injects into template.
- Template placeholder: `{{SCHEMA_PLACEHOLDER}}` for multi-line schema insertion.
- Auto-replaces placeholders: `{{ServiceName}}`, `{{x_ibm_name}}`, `{{OperationName}}`, `{{ESBUrl}}`.
- Validates JSON schema using `python3` before conversion.
- Filters out JSON-Schema-specific properties not suitable for OpenAPI.
- Ensures `type` appears first in generated YAML for API Connect compatibility.
- Detects `apic` CLI executable (Windows paths supported).
- Validate the YAML file before creating the API, If invalid, It will abort the process for the current API and proceed with the rest.
- Logs into API Connect and attempts draft creation (`apic draft-apis:create`).
- Tracks counters: total processed, created, already exists, failed.
- Robust error handling and informative debug output.
- Uses temporary files for multi-line replacements and cleans them up.

## Input Format
services.txt (pipe-delimited):
ServiceName|ESBUrl|SchemaPath
- Example: `Demo Service|http://example.com/api|schemas/demo_schema.json`
- SchemaPath is optional. If empty, defaults to `type: object`.

## Requirements
- bash (Windows WSL or Git Bash)
- python3 (for JSON→YAML conversion)
- IBM APIC Toolkit (`apic` CLI)

## Template Note
In `template.yaml` replace the request schema block with:
  `{{SCHEMA_PLACEHOLDER}}`
so the script can inject the converted schema at the correct indentation.

## Output
- Generated YAML files are saved to `API-yamls/`
- Script exits with code 0 on success; non-zero if failures occurred.

## Configuration
The script loads settings from `config.env` (if exists). You can also set environment variables directly.

| Variable | Default | Description |
|----------|---------|-------------|
| `APIC_ORG` | `apic-sit` | API Connect organization |
| `APIC_SERVER` | `https://...` | APIC Management server URL |
| `INPUT_FILE` | `services.txt` | Services input file |
| `TEMPLATE_FILE` | `template.yaml` | API template file |
| `OUTPUT_DIRECTORY` | `API-yamls` | Generated YAML output |
| `PRODUCT_NAME` | `internal-services` | Product name |
| `PRODUCT_VERSION` | `1.0.0` | Product version |
| `CATALOG_NAME` | `internal` | Target catalog |

## Quick Steps
1. **Configure**: Edit `config.env` with your environment settings.
2. Populate `services.txt`.
3. Ensure `template.yaml` contains `{{SCHEMA_PLACEHOLDER}}`.
4. Place JSON schemas in `schemas/` (optional).
5. Run `yamlBuilderEnh.sh`.

## Product Update & Publish (Step 6)

## Incremental Mode
The script supports an incremental build mode optimized for CI/CD pipelines.

```bash
./yamlBuilderEnh.sh --incremental
```

### How it works
1. Detects changes since the last successful run (stored in `API-yamls/.last_successful_commit`).
2. **Generates** local YAMLs for all APIs (fast).
3. **Skips** expensive server operations (validation, update) for APIs with no schema changes.
4. **Forces full update** if critical files (`services.txt`, `template.yaml`, `config.env`) changed.
5. **Updates Product** only if APIs were modified or config changed.
6. Saves the current commit hash on success.

## API Update Path (Step 5)
When an API already exists in API Connect, the script now:
1. Detects the existing API using `apic draft-apis:get`
2. Pulls the current YAML definition
3. Replaces the `{OperationName}Request` schema section with the new schema from `services.txt`
4. Validates the updated YAML
5. Updates the API using `apic draft-apis:update`

This ensures schema changes are propagated to existing APIs without manual intervention.

## Product Update & Publish (Step 6)
After processing all APIs, the script automatically:
1. Collects all API references from `services.txt`
2. Generates a product YAML (`internal-services_1.0.0.yaml`)
3. Backs up existing product (if any) for reversibility
4. Creates or updates the draft product in API Connect
5. Publishes the product to the `internal` catalog

### Product Configuration
The following values can be modified in the script:
- `PRODUCT_NAME`: Name of the product (default: `internal-services`)
- `PRODUCT_VERSION`: Version of the product (default: `1.0.0`)
- `CATALOG_NAME`: Target catalog for publishing (default: `internal`)

### Rollback
If you need to rollback changes:
1. Backup files are stored in `API-yamls/.backup/`
2. To restore a previous product state:
```bash
apic draft-products:update internal-services:1.0.0 \
    --server $APIC_SERVER --org $APIC_ORG \
    API-yamls/.backup/internal-services_1.0.0_backup.yaml

https://claude.ai/public/artifacts/8f7df6ba-11a5-4549-8bed-cd77bade1ce3
```

