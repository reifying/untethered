# Homebrew Tap for Untethered

This directory contains Homebrew cask formulas for Untethered.

## Setup

To use this tap, you have two options:

### Option 1: Separate Repository (Recommended)

Create a new repo named `homebrew-untethered` and copy the `Casks/` directory there.

Users install with:
```bash
brew tap reifying/untethered
brew install --cask untethered
```

### Option 2: From Main Repository

Users can tap directly from subdirectory:
```bash
brew tap reifying/untethered https://github.com/reifying/untethered
brew install --cask untethered
```

## Updating the Cask

After creating a new release:

1. Build, notarize, and package:
   ```bash
   ./scripts/publish-mac.sh release
   ```

2. Upload `build/Untethered-X.Y-mac.zip` to GitHub Release

3. Update `Casks/untethered.rb`:
   - Update `version`
   - Update `sha256` (printed by publish-mac.sh)

4. Commit and push

## Manual Installation

Without Homebrew:
1. Download `Untethered-X.Y-mac.zip` from GitHub Releases
2. Unzip and drag `Untethered.app` to `/Applications`
