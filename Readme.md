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

## Quick Steps
1. Populate `services.txt`.
2. Ensure `template.yaml` contains `{{SCHEMA_PLACEHOLDER}}`.
3. Place JSON schemas in `schemas/` (optional).
4. Run `yamlBuilderEnh.sh`.