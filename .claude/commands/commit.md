---
description: Analyze git changes and create organized commits with proper grouping
---

# Group Commits Command

Analyze the current git changes and create well-organized commits by grouping related changes together.

## Instructions

1. **Analyze the repository state:**
   - Run `git status` to see all changed and untracked files
   - Run `git diff` to see staged changes
   - Run `git diff HEAD` to see all changes (staged + unstaged)

2. **Group changes logically by:**
   - Related functionality (e.g., all changes for adding a new service)
   - Affected host/module (e.g., all storage host changes, all cloud changes)
   - Change type (e.g., configuration changes vs secret updates vs documentation)
   - Dependencies (e.g., service config + secrets + backlog task)

3. **Present the commit plan for approval:**
   - Display a summary of proposed commits showing:
     - Commit message for each group
     - Files to be included in each commit
   - **Ask the user for approval before proceeding** using AskUserQuestion
   - Only continue to step 4 if the user approves

4. **For each approved commit group:**
   - Stage only the files for that group using `git add <files>`
   - Create a commit with proper conventional commit format:
     - `type(scope): subject`
     - Types: feat, fix, chore, docs, refactor
     - Scope: hostname (storage, cloud), module name, or component
   - Verify the commit with `git log -1 --stat`

5. **Verification:**
   - After all commits, run `git status` to ensure working tree is clean
   - Run `git log --oneline -n <num_commits>` to show the created commits
   - Provide a summary of what was committed

## Important Notes

- Follow conventional commit format strictly (see CLAUDE.md)
- Each commit should be atomic and focused on one logical change
- All commits must compile and work independently
- Use meaningful commit messages that explain WHY, not just WHAT
- Never use `--no-verify` to bypass commit hooks
- If there are backlog task files, include them with their related changes
