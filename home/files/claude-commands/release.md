# Create a New Release

Create a new release following the current project's standards and conventions.

**Arguments:** $ARGUMENTS (optional: version bump type or specific version)

## Instructions

### Step 1: Discover Project Standards

Investigate the current project to understand its release process:

1. **Check for GitHub workflows:**
   ```bash
   ls -la .github/workflows/
   ```
   Read any release-related workflows (release.yml, publish.yml, deploy.yml, etc.) to understand:
   - What triggers releases (tag push, release publish, manual dispatch)
   - What automation exists (Docker builds, npm publish, etc.)
   - What you need to do manually vs what's automated

2. **Analyze existing tags:**
   ```bash
   git fetch --tags
   git tag --sort=-version:refname | head -10
   ```
   Determine the versioning pattern:
   - Semver with `v` prefix? (v1.2.3)
   - Semver without prefix? (1.2.3)
   - Calendar versioning? (2024.01.15)
   - Other patterns?

3. **Check for existing releases:**
   ```bash
   gh release list --limit 5
   gh release view <latest-tag> 2>/dev/null
   ```
   Understand:
   - Are GitHub releases used, or just tags?
   - What format are release notes in?
   - Are releases auto-generated or manual?

4. **Check for version files:**
   Look for version definitions in:
   - `package.json` (Node.js)
   - `mix.exs` (Elixir)
   - `Cargo.toml` (Rust)
   - `pyproject.toml` / `setup.py` (Python)
   - `VERSION` file
   - Other project-specific locations

5. **Check for release documentation:**
   Look for `RELEASING.md`, `CHANGELOG.md`, or release instructions in `README.md` or `CONTRIBUTING.md`

### Step 2: Validate Pre-conditions

1. **Check git remote:**
   ```bash
   git remote -v
   ```
   Identify the repository for `gh` commands.

2. **Check working directory:**
   ```bash
   git status --porcelain
   ```
   If uncommitted changes exist, ask user how to proceed.

3. **Check current branch:**
   ```bash
   git branch --show-current
   ```
   Warn if not on the default branch (main/master).

4. **Check commits since last tag:**
   ```bash
   git log --oneline $(git describe --tags --abbrev=0 2>/dev/null)..HEAD
   ```
   If no commits, warn the user.

### Step 3: Determine New Version

Parse `$ARGUMENTS`:

- **Empty or `patch`**: Increment patch version
- **`minor`**: Increment minor version
- **`major`**: Increment major version
- **Specific version**: Use as provided (normalize to match project's pattern)

Apply the project's versioning pattern (with/without `v` prefix, etc.).

If the project has a version file, note that it may need updating.

### Step 4: Generate Release Notes

Based on what you discovered about the project:

1. **If CHANGELOG.md exists and follows keep-a-changelog format:**
   - Check if there's an "Unreleased" section
   - Suggest using that content for release notes

2. **If auto-generated releases are used:**
   - Note that GitHub will auto-generate notes

3. **Otherwise, generate from commits:**
   ```bash
   git log --oneline <last-tag>..HEAD
   ```
   Create concise notes summarizing the changes:
   - Group by type if conventional commits are used
   - Otherwise, list key changes briefly

### Step 5: Present Plan and Confirm

Show the user exactly what will happen:

```
## Release Plan

**Project:** <detected from git remote>
**Current version:** <last tag>
**New version:** <calculated version>
**Versioning pattern:** <detected pattern>

## What was discovered:
- GitHub workflow: <what it does / none found>
- Release format: <GitHub releases / tags only>
- Version file: <path if found / none>

## Release Notes:
<generated or sourced notes>

## Actions to perform:
1. <list each action based on what's NOT automated>
   - Create tag? Push tag?
   - Create GitHub release?
   - Update version file?
   - Update CHANGELOG?

## What will happen automatically:
<list what the workflow handles>

Proceed? [y/n]
```

Wait for explicit user confirmation.

### Step 6: Execute Release

Perform only the manual steps needed (what's not handled by automation):

1. **If version file needs updating:**
   - Update the file
   - Commit the change: `chore: bump version to <version>`

2. **Create and push tag:**
   ```bash
   git tag -a <version> -m "<release summary>"
   git push origin <version>
   ```

3. **Create GitHub release (if not auto-created by workflow):**
   ```bash
   gh release create <version> --title "<version>" --notes "<notes>"
   ```
   Or if the workflow creates releases on tag push, skip this.

4. **If CHANGELOG needs updating:**
   - Move "Unreleased" to new version section
   - Commit the change

### Step 7: Verify and Report

1. **Verify tag exists remotely:**
   ```bash
   git ls-remote --tags origin | grep <version>
   ```

2. **Check release (if applicable):**
   ```bash
   gh release view <version>
   ```

3. **Check workflow status (if applicable):**
   ```bash
   gh run list --limit 1
   ```

4. **Report results:**
   - Release URL
   - What automation was triggered
   - Any follow-up actions needed

## Error Handling

- **No tags exist:** Ask user for initial version (suggest v0.1.0 or 1.0.0)
- **Tag already exists:** Abort and suggest different version
- **Push fails:** Check permissions, suggest `gh auth status`
- **No git remote:** Cannot proceed, inform user
- **Workflow not found:** Proceed with manual release only

## Notes

- Always discover project conventions first - never assume
- Ask for confirmation before any destructive or publishing action
- If unsure about project standards, ask the user
- Adapt to whatever versioning scheme the project uses
