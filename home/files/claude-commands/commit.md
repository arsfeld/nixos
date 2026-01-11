# Smart Git Commit

Analyze all uncommitted changes and create logical, well-organized commits.

## Instructions

1. **Gather information** by running these commands in parallel:
   - `git status` to see all changed and untracked files
   - `git diff` to see unstaged changes
   - `git diff --cached` to see staged changes
   - `git log --oneline -10` to understand recent commit message style

2. **Analyze and group** the changes into **at most 3-4 commits**:
   - Aggressively combine related changes - prefer fewer, larger commits over many small ones
   - Group by high-level intent (e.g., "add feature X", "refactor Y", "fix bugs in Z")
   - Only separate changes if they are truly unrelated or would create a confusing commit
   - When in doubt, combine into one commit

3. **Present your proposed commits** using the AskUserQuestion tool:
   - Show each proposed commit with its files and message
   - Use multiSelect to let the user approve/reject individual commits
   - Include an option to "Commit all as proposed"

4. **For approved commits**:
   - Stage only the files for that group: `git add <files>`
   - Write a clear commit message that explains the "why", not just the "what"
   - Use conventional commit style if the project uses it, otherwise match existing style
   - Keep the subject line under 72 characters
   - Add a body if the change needs explanation
   - Do NOT use `--no-verify` flag

5. **Commit message guidelines**:
   - Focus on intent and impact, not implementation details
   - Never mention AI, Claude, or automated tools in the message
   - Use imperative mood ("Add feature" not "Added feature")
   - Reference issue numbers if applicable

6. **After all commits**:
   - Run `git status` to confirm everything is committed
   - Show a summary of all commits created

## Example groupings (keep it to 3-4 max)

- All feature code + tests + related config = one commit
- Refactoring across multiple files = one commit
- Multiple bug fixes = combine into one commit unless completely unrelated
- Documentation + formatting = one commit

Now analyze the current changes and propose how to group them into commits.
