# Smart Build Versioning for TestFlight

## Problem

When deploying from different Git branches, local build numbers can get out of sync with what's already uploaded to App Store Connect. This causes "duplicate build number" errors during upload, requiring manual intervention.

**Example scenario:**
- Branch A: local build 35 → deploy → TestFlight build 35
- Branch B: local build 33 → try to deploy → bump to 34 → upload fails (35 already exists)
- Manual fix: bump again to 36

## Solution

The `smart-bump-build.sh` script queries App Store Connect's API to find the latest build number already in TestFlight, then sets the local build to `latest + 1`.

## Usage

### Automatic (Recommended)

```bash
make deploy-testflight
```

This now uses smart bumping by default.

### Manual Build Number Management

```bash
# Smart bump (queries TestFlight)
make bump-build

# Simple increment (legacy, may conflict)
make bump-build-simple
```

## How It Works

1. **Query Remote**: Uses `xcrun altool --list-builds` to get all builds from TestFlight
2. **Find Latest**: Sorts builds numerically and takes the highest
3. **Calculate Next**: Sets local to `max(remote_latest + 1, local + 1)`
4. **Fallback**: If API query fails, falls back to simple increment

## Requirements

**Python Dependencies:**
```bash
pip3 install --break-system-packages PyJWT cryptography
```

**App Store Connect API Keys** (in `.envrc`):
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_PATH` (defaults to `~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8`)

If keys are not configured, falls back to simple increment with a warning.

## Benefits

- **No conflicts**: Always uses the next available build number
- **Branch-safe**: Works correctly regardless of which branch you deploy from
- **Idempotent**: Can run multiple times safely
- **Fallback**: Still works (with warnings) if API is unavailable

## Limitations

- Requires API credentials
- Adds ~2-3 seconds to deployment (API query time)
- If two developers deploy simultaneously, there's a tiny race window (extremely rare)

## Testing

Test the smart bump without deploying:

```bash
make bump-build
```

Check the new build number:

```bash
cd ios && xcrun agvtool what-version
```

### Example Output

```
[INFO] Starting smart build number bump...
[INFO] Local version:  (39)
[INFO] Querying App Store Connect for latest build number...
[INFO] Latest build in TestFlight: 36
[INFO] Next build number will be: 37
[WARN] Local build (39) is already >= next required (37)
[INFO] Using local build + 1: 40
[INFO] Setting build number to 40...
[INFO] Final version:
Current version of project VoiceCode is:
    40
```

This shows the script:
1. Found TestFlight has build 36
2. Local was already at 39 (from a different branch)
3. Used local + 1 = 40 to avoid conflicts
