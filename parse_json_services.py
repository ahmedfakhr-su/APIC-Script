#!/usr/bin/env python3
"""
Parse services JSON file for bash script consumption.
Provides different output modes for different use cases.
"""

import json
import sys

def parse_services(json_file, mode='full'):
    """
    Parse services JSON and output in bash-friendly format.
    
    Modes:
    - 'full': Output each service as pipe-separated values (for main loop)
    - 'names': Output only API names (for API collection)
    - 'count': Output count of services
    - 'validate': Validate JSON and exit with status code
    """
    try:
        with open(json_file, 'r', encoding='utf-8') as f:
            services = json.load(f)
        
        if not isinstance(services, list):
            print("Error: JSON root must be an array", file=sys.stderr)
            sys.exit(1)
        
        if mode == 'validate':
            # Just validate and return count
            print(len(services))
            sys.exit(0)
        
        elif mode == 'count':
            print(len(services))
            sys.exit(0)
        
        elif mode == 'names':
            # Output only API names (for API_REFS collection)
            for service in services:
                api_name = service.get('API Name', '')
                if api_name and api_name != 'null':
                    print(api_name)
        
        elif mode == 'full':
            # Output full service data as pipe-separated values
            for service in services:
                api_name = service.get('API Name', '')
                url = service.get('Url', '')
                schema = service.get('Schema Location', '')
                tag = service.get('tag', 'rest')
                
                # Skip if required fields are missing
                if not api_name or api_name == 'null':
                    continue
                if not url or url == 'null':
                    continue
                
                # Output as pipe-separated (bash-friendly)
                print(f"{api_name}|{url}|{schema}|{tag}")
        
        else:
            print(f"Error: Unknown mode '{mode}'", file=sys.stderr)
            sys.exit(1)
    
    except FileNotFoundError:
        print(f"Error: File not found: {json_file}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: parse_json_services.py <json_file> [mode]", file=sys.stderr)
        print("Modes: full (default), names, count, validate", file=sys.stderr)
        sys.exit(1)
    
    json_file = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else 'full'
    
    parse_services(json_file, mode)
