#!/usr/bin/env python3
"""
Convert JSON Schema to OpenAPI-compatible YAML format.
Filters out JSON Schema-specific properties that aren't valid in OpenAPI 3.0.
Ensures 'type' appears first for better API Connect display.
"""

import json
import sys


def json_to_yaml(obj, indent=0):
    """
    Convert JSON Schema to OpenAPI-compatible YAML format.
    Filters out JSON Schema-specific properties that aren't valid in OpenAPI 3.0.
    Ensures 'type' appears first for better API Connect display.
    """
    lines = []
    spaces = '  ' * indent
    
    # Properties to exclude (JSON Schema specific, not OpenAPI)
    excluded_props = {'$schema', '$id', '$comment', 'definitions', '$defs'}
    
    if isinstance(obj, dict):
        # CRITICAL: We must output 'type' FIRST for API Connect to display correctly
        # Define the exact order - this is the order they will appear in YAML
        property_order = [
            'type',           # MUST BE FIRST
            'format',
            'title', 
            'description',
            'required',
            'enum',
            'default',
            'example',
            'minimum',
            'maximum',
            'exclusiveMinimum',
            'exclusiveMaximum',
            'minLength',
            'maxLength',
            'minItems',
            'maxItems',
            'pattern',
            'properties',
            'items',
            'additionalProperties',
            'allOf',
            'oneOf',
            'anyOf'
        ]
        
        # Build ordered list of keys to process
        all_keys = []
        
        # First pass: add keys in our defined order
        for prop in property_order:
            if prop in obj and prop not in excluded_props:
                all_keys.append(prop)
        
        # Second pass: add any remaining keys alphabetically
        remaining = sorted([k for k in obj.keys() if k not in all_keys and k not in excluded_props])
        all_keys.extend(remaining)
        
        for key in all_keys:
            value = obj[key]
            
            if isinstance(value, dict):
                lines.append(f"{spaces}{key}:")
                lines.extend(json_to_yaml(value, indent + 1))
            elif isinstance(value, list):
                lines.append(f"{spaces}{key}:")
                lines.extend(json_to_yaml(value, indent + 1))
            elif isinstance(value, bool):
                lines.append(f"{spaces}{key}: {str(value).lower()}")
            elif isinstance(value, str):
                # Escape strings that might need quotes
                if ':' in value or '#' in value or value.startswith(('*', '&', '!')) or value == '':
                    lines.append(f"{spaces}{key}: '{value}'")
                else:
                    lines.append(f"{spaces}{key}: {value}")
            elif value is None:
                lines.append(f"{spaces}{key}: null")
            else:
                lines.append(f"{spaces}{key}: {value}")
    
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, (dict, list)):
                lines.append(f"{spaces}-")
                nested = json_to_yaml(item, indent + 1)
                # For nested objects/arrays, don't duplicate the indent
                for i, nested_line in enumerate(nested):
                    if i == 0:
                        # First line goes on same line as dash
                        lines[-1] = f"{spaces}- {nested_line.strip()}"
                    else:
                        lines.append(f"{spaces}  {nested_line.strip()}")
            else:
                # Simple values in array
                if isinstance(item, str):
                    lines.append(f"{spaces}- {item}")
                else:
                    lines.append(f"{spaces}- {item}")
    
    return lines


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: convert_json_to_yaml.py <schema_file>", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(sys.argv[1], 'r') as f:
            schema = json.load(f)
        
        # Check if this is a properly structured request schema
        if 'type' in schema and schema.get('type') == 'object' and 'properties' in schema:
            # This is the complete request schema structure - use it directly
            processed_schema = schema
        else:
            # Fallback - use as provided
            processed_schema = schema
        
        # Generate YAML lines
        yaml_lines = json_to_yaml(processed_schema, indent=0)
        
        # Print with base indentation of 6 spaces (to match the placeholder position)
        for line in yaml_lines:
            print('      ' + line)
        
    except Exception as e:
        print(f"Error processing schema: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
