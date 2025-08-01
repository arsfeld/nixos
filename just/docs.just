# Documentation commands

# Serve documentation locally
serve:
    devenv shell -- mkdocs serve --dev-addr 127.0.0.1:8000

# Build documentation
build:
    devenv shell -- mkdocs build

# Deploy documentation to GitHub Pages
deploy:
    devenv shell -- mkdocs gh-deploy --force