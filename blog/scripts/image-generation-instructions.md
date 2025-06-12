# Image Generation Instructions

To generate AI images for the blog posts, you'll need to:

## 1. Authenticate with Google Cloud

```bash
nix run "nixpkgs#google-cloud-sdk" -- auth login
```

Follow the prompts to authenticate with your Google account that has access to the Imagen API.

## 2. Generate Images for Blog Posts

### For "Managing Homelab with NixOS" post:

```bash
cd /home/arosenfeld/Projects/nixos/blog/scripts

# Hero image showing transformation from chaos to order
./generate-image.sh -o "ubuntu-chaos-to-nixos" -a "16:9" -n 2 \
  "Split screen comparison showing chaotic Ubuntu server room with tangled cables and error messages on left side transitioning to clean organized NixOS infrastructure with geometric patterns and snowflake logos on right side, modern tech illustration style, blue and orange color scheme"

# Infrastructure overview image
./generate-image.sh -o "nixos-homelab-overview" -a "16:9" -n 2 \
  "Isometric illustration of a modern home server rack with multiple machines labeled storage and cloud, connected by glowing network cables, NixOS snowflake logo subtly integrated, clean minimal tech aesthetic, blue and white color scheme"

# GitHub Actions deployment workflow
./generate-image.sh -o "nixos-cicd-workflow" -a "16:9" -n 2 \
  "Abstract visualization of automated deployment pipeline, showing code flowing from GitHub through build servers to multiple NixOS machines, geometric flow diagram style, professional tech illustration"
```

### For "Constellation Pattern" post:

```bash
# Main constellation pattern hero image
./generate-image.sh -o "constellation-pattern-hero" -a "16:9" -n 2 \
  "Abstract network constellation of interconnected nodes glowing in dark space, each node representing a different server or service, geometric lines connecting them forming constellation patterns, tech-inspired with blue and purple accents"

# Architecture diagram
./generate-image.sh -o "constellation-architecture" -a "16:9" -n 2 \
  "Technical architecture diagram showing modular boxes stacking and connecting together like building blocks, clean isometric view representing composable infrastructure modules, minimal color palette with blue accents"

# Problems illustration
./generate-image.sh -o "nixos-problems" -a "16:9" -n 2 \
  "Visual representation of configuration drift problem, multiple servers slowly diverging from each other over time showing inconsistency and chaos, technical illustration style, warning colors"
```

## 3. Move Selected Images

After generation, review the images in `../static/images/generated/` and move the best ones to `../static/images/` with the correct names expected by the blog posts.

## 4. Update Blog Posts

The blog posts are already configured to reference these image names:
- `/images/ubuntu-chaos-to-nixos.png`
- `/images/nixos-homelab-overview.png`
- `/images/constellation-pattern-hero.png`
- `/images/constellation-architecture.png`
- `/images/nixos-problems.png`

Make sure the final image names match these references.