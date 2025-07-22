# Router UI

A modern web interface for managing router services, built with Elixir Phoenix, LiveView, and Tailwind CSS.

## Features

- **VPN Client Management** - Assign individual network clients to different VPN providers
- **Real-time Monitoring** - Live status updates for VPN connections and client traffic
- **Traffic Isolation** - Complete network isolation between VPN and non-VPN traffic
- **Web-based Configuration** - Intuitive UI for managing router services
- **Integration** - Seamless integration with existing NixOS router infrastructure

## Architecture

Router UI is built as a Phoenix application with:
- SQLite3 for lightweight persistent storage
- LiveView for real-time UI updates
- Tailwind CSS 4 with DaisyUI 5 for modern styling
- OTP supervision trees for reliability

## Installation

Add Router UI to your NixOS configuration:

```nix
# In your router configuration
{ pkgs, ... }:

{
  imports = [
    ../../packages/router_ui/module.nix
  ];
  
  services.router-ui = {
    enable = true;
    port = 4000;
    environmentFile = "/run/secrets/router-ui-env";
  };
}
```

## Configuration

Create an environment file with your secret key base:

```bash
# /run/secrets/router-ui-env
SECRET_KEY_BASE=your-64-character-secret-key-base
```

Generate a secret key base:
```bash
openssl rand -hex 64
```

## Development

To work on Router UI locally:

```bash
cd packages/router_ui
nix shell "nixpkgs#elixir" "nixpkgs#postgresql" "nixpkgs#nodejs"

# Install dependencies
mix deps.get
npm install --prefix assets

# Create and migrate database
mix ecto.create
mix ecto.migrate

# Start Phoenix server
mix phx.server
```

Visit http://localhost:4000 to see the application.

## Documentation

- [Architecture Overview](docs/router-ui-architecture.md)
- [VPN Manager Implementation](docs/vpn-manager-implementation.md)
- [Task List](TASK.md)

## License

MIT