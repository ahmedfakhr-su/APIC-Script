#!/usr/bin/env python3
"""
Update target URL in YAML file.
Handles both inline and multiline (>-) value formats.
"""

import sys


def update_target_url(file_path, new_url):
    """Update the target-url value in a YAML file."""
    
    with open(file_path, 'r') as f:
        lines = f.readlines()
    
    new_lines = []
    in_target_url = False
    in_value_block = False
    updated = False
    
    for i, line in enumerate(lines):
        stripped = line.strip()
        
        if 'target-url:' in line:
            in_target_url = True
            new_lines.append(line)
            continue
            
        if in_target_url and 'value:' in line:
            # Check if it's "value: >-" (multiline) or "value: http..." (inline)
            if '>-' in line:
                in_value_block = True
                new_lines.append(line)
                continue
            else:
                # Inline value case
                indent = line.split('value:')[0]
                new_lines.append(f"{indent}value: {new_url}\n")
                in_target_url = False  # Done
                updated = True
                continue
        
        if in_value_block:
            # This line is the URL content
            # Detect indentation
            indent = line[:len(line) - len(line.lstrip())]
            new_lines.append(f"{indent}{new_url}\n")
            in_value_block = False
            in_target_url = False
            updated = True
            continue
        
        # Reset if we hit another property at specific indentation
        # For now, simplistic state machine is fine for our controlled template.
        
        new_lines.append(line)
    
    # Write back to file
    with open(file_path, 'w') as f:
        f.writelines(new_lines)
    
    # Return 0 (success) only if we actually updated something
    return 0 if updated else 1


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: update_target_url.py <yaml_file> <new_url>", file=sys.stderr)
        sys.exit(1)
    
    try:
        result = update_target_url(sys.argv[1], sys.argv[2])
        sys.exit(result)
    except Exception as e:
        print(f"Error updating target URL: {e}", file=sys.stderr)
        sys.exit(1)
