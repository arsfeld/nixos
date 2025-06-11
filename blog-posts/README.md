# NixOS Blog Posts Publishing

This directory contains blog posts about NixOS self-hosting and tools for publishing them to Ghost CMS.

## Setup

1. **Get Ghost Admin API Key**:
   - Go to your Ghost admin panel: https://blog.arsfeld.dev/ghost/
   - Navigate to Settings → Integrations
   - Create a new Custom Integration
   - Copy the Admin API Key (format: `id:secret`)

2. **Install Dependencies**:
   ```bash
   cd blog-posts
   npm install
   ```

3. **Set Environment Variable**:
   ```bash
   export GHOST_ADMIN_API_KEY="your_admin_api_key_here"
   ```

## Publishing Posts

### Option 1: Node.js Script (Recommended)
```bash
# Publish all markdown files to Ghost
npm run publish
```

### Option 2: Manual Upload
- Use Ghost admin interface to copy/paste content
- Upload images separately through Ghost media library

## Adding New Posts

1. Create a new markdown file in this directory
2. Use frontmatter for metadata (optional):
   ```markdown
   ---
   title: "Your Post Title"
   tags: "NixOS, Self-Hosting, Tutorial"
   ---
   
   # Your Post Title
   Content here...
   ```

3. Add images to the same directory and reference them:
   ```markdown
   ![Alt text](image-name.png)
   ```

4. Run the publish script to upload to Ghost

## NixOS Integration

To automate publishing from your NixOS configuration, add this to your cloud host:

```nix
# In your cloud configuration
environment.systemPackages = with pkgs; [ nodejs ];

systemd.services.ghost-publisher = {
  description = "Publish blog posts to Ghost";
  serviceConfig = {
    Type = "oneshot";
    WorkingDirectory = "/path/to/blog-posts";
    ExecStart = "${pkgs.nodejs}/bin/node publish-to-ghost.js";
    EnvironmentFile = "/run/secrets/ghost-env";
  };
};
```

## Files

- `01-constellation-pattern.md` - First blog post about constellation modules
- `outline.md` - Complete series outline
- `image-prompts.md` - AI image generation prompts
- `publish-to-ghost.js` - Publishing script
- `package.json` - Node.js dependencies