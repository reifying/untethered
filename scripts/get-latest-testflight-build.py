#!/usr/bin/env python3
"""
Get the latest TestFlight build number from App Store Connect API.
Uses JWT authentication with App Store Connect API keys.
"""

import sys
import time
import json
import subprocess
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
import base64

def generate_jwt(key_id, issuer_id, key_path):
    """Generate JWT token for App Store Connect API using PyJWT."""
    try:
        import jwt
    except ImportError:
        print("ERROR: PyJWT library not installed. Install with: pip3 install PyJWT cryptography", file=sys.stderr)
        sys.exit(1)

    # Read private key
    with open(key_path, 'r') as f:
        private_key = f.read()

    # Create JWT payload
    issued_at = int(time.time())
    expiration = issued_at + 600  # 10 minutes

    payload = {
        'iss': issuer_id,
        'iat': issued_at,
        'exp': expiration,
        'aud': 'appstoreconnect-v1'
    }

    # Generate token
    token = jwt.encode(
        payload,
        private_key,
        algorithm='ES256',
        headers={'kid': key_id}
    )

    return token

def get_app_id(jwt_token, bundle_id):
    """Get App ID from bundle ID."""
    url = f"https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]={bundle_id}"

    req = Request(url)
    req.add_header('Authorization', f'Bearer {jwt_token}')

    try:
        with urlopen(req) as response:
            data = json.loads(response.read())
            if data.get('data'):
                return data['data'][0]['id']
    except (HTTPError, URLError) as e:
        print(f"ERROR: Failed to get app ID: {e}", file=sys.stderr)
        if hasattr(e, 'read'):
            print(e.read().decode(), file=sys.stderr)

    return None

def get_latest_build(jwt_token, app_id):
    """Get latest build number for app."""
    url = f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={app_id}&sort=-version&limit=200"

    req = Request(url)
    req.add_header('Authorization', f'Bearer {jwt_token}')

    try:
        with urlopen(req) as response:
            data = json.loads(response.read())
            if data.get('data'):
                # Extract version numbers and find max
                versions = [int(build['attributes']['version']) for build in data['data']]
                if versions:
                    return max(versions)
    except (HTTPError, URLError) as e:
        print(f"ERROR: Failed to get builds: {e}", file=sys.stderr)
        if hasattr(e, 'read'):
            print(e.read().decode(), file=sys.stderr)

    return None

def main():
    if len(sys.argv) != 4:
        print("Usage: get-latest-testflight-build.py <key_id> <issuer_id> <bundle_id>", file=sys.stderr)
        sys.exit(1)

    key_id = sys.argv[1]
    issuer_id = sys.argv[2]
    bundle_id = sys.argv[3]

    # Construct key path
    key_path = Path.home() / '.appstoreconnect' / 'private_keys' / f'AuthKey_{key_id}.p8'

    if not key_path.exists():
        print(f"ERROR: Key file not found: {key_path}", file=sys.stderr)
        sys.exit(1)

    # Generate JWT
    try:
        jwt_token = generate_jwt(key_id, issuer_id, str(key_path))
    except Exception as e:
        print(f"ERROR: Failed to generate JWT: {e}", file=sys.stderr)
        sys.exit(1)

    # Get app ID
    app_id = get_app_id(jwt_token, bundle_id)
    if not app_id:
        print(f"ERROR: Could not find app with bundle ID: {bundle_id}", file=sys.stderr)
        sys.exit(1)

    # Get latest build
    latest_build = get_latest_build(jwt_token, app_id)
    if latest_build is None:
        print("ERROR: Could not retrieve build numbers", file=sys.stderr)
        sys.exit(1)

    # Output just the build number
    print(latest_build)

if __name__ == '__main__':
    main()
