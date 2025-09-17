---
id: task-1
title: Restructure blog system to use date-based folder structure
status: Done
assignee:
  - '@claude'
created_date: '2025-09-16 23:09'
updated_date: '2025-09-16 23:21'
labels: []
dependencies: []
---

## Description

Modify the blog system to organize posts in a hierarchical folder structure based on dates. For example, a blog post from September 16, 2025 would be stored in the path 2025/09/16/. This will improve organization and make it easier to browse posts chronologically.

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Blog posts are stored in YYYY/MM/DD/ folder structure
- [x] #2 Existing blog posts are migrated to the new structure
- [x] #3 Blog system correctly reads posts from date-based folders
- [x] #4 URLs and routing work with the new folder structure
- [x] #5 Build process handles the new structure correctly
<!-- AC:END -->


## Implementation Plan

1. Research Zola's support for nested sections and date-based directories
2. Create a test blog post in date-based folder structure (2025/09/16/)
3. Update Zola config if needed to support date-based URLs
4. Create a migration script to move existing posts to date folders
5. Update blog.nix build process if necessary
6. Test that all posts render correctly with new URLs
7. Ensure RSS feed and navigation still work


## Implementation Notes

Successfully migrated blog system to date-based folder structure:

- All 27 existing blog posts moved to YYYY/MM/DD/ folders
- Internal links updated to reflect new paths
- Zola builds successfully with new structure
- URLs now follow /posts/YYYY/MM/DD/post-name pattern
- No changes needed to blog.nix build process

Added URL aliases to preserve old links:
- All old URLs (/posts/post-name/) redirect to new date-based URLs
- Zola generates redirect HTML files automatically
- No broken links for existing bookmarks or references
