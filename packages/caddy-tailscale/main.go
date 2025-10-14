// Caddy with Tailscale plugin
// This is the main entry point for building Caddy with the Tailscale plugin

package main

import (
	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	// Include standard Caddy modules
	_ "github.com/caddyserver/caddy/v2/modules/standard"

	// Include Tailscale plugin
	_ "github.com/tailscale/caddy-tailscale"
)

func main() {
	caddycmd.Main()
}
