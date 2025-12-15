#!/usr/bin/env python3
"""
Merge existing APIs with new APIs from a product YAML file.
Reads the existing product file and combines APIs.
"""

import sys
import re


def get_existing_apis(existing_product_file):
    """Extract API names from the existing product file."""
    try:
        with open(existing_product_file, 'r') as f:
            existing_content = f.read()
        
        # Extract apis section from existing product
        apis_match = re.search(
            r'^apis:\s*\n((?:^  \S+:.*\n(?:^    .*\n)*)*)',
            existing_content,
            re.MULTILINE
        )
        existing_apis = {}
        if apis_match:
            apis_block = apis_match.group(1)
            # Parse each API entry
            for line in apis_block.split('\n'):
                if line and line.startswith('  ') and ':' in line:
                    api_name = line.split(':')[0].strip()
                    if api_name:
                        existing_apis[api_name] = True
        
        return existing_apis
    except Exception as e:
        print(f"Error reading existing product: {e}", file=sys.stderr)
        return {}


def merge_apis(new_api_list, existing_apis):
    """Merge existing and new APIs, removing duplicates."""
    merged_apis = set(existing_apis.keys())
    for api in new_api_list:
        if api and api.strip():
            merged_apis.add(api.strip())
    
    return sorted(merged_apis)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: merge_apis.py <existing_product_file> <new_api_1> [<new_api_2> ...]", 
              file=sys.stderr)
        sys.exit(1)
    
    try:
        existing_product_file = sys.argv[1]
        new_api_list = sys.argv[2:]
        
        existing_apis = get_existing_apis(existing_product_file)
        merged_apis = merge_apis(new_api_list, existing_apis)
        
        # Output merged APIs
        print(' '.join(merged_apis))
        
    except Exception as e:
        print(f"Error merging APIs: {e}", file=sys.stderr)
        sys.exit(1)
