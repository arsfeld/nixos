use clap::{Parser, Subcommand};

use pia::config::Config;
use pia::exits::config::ExitsConfig;

/// PIA WireGuard control plane for galactica's `pia` network namespace.
#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Clone, Copy)]
enum Command {
    /// Authenticate, register a WireGuard key, write the tunnel config (host netns).
    Connect,
    /// Acquire and bind the forwarded port, open it, notify consumers (inside the namespace).
    Portforward,
    /// Restart the namespace when its WireGuard handshake has gone stale.
    Watchdog,
    /// Tailscale exit slots, configured by the JSON file in PIA_EXITS_CONFIG.
    Exits {
        #[command(subcommand)]
        cmd: ExitsCmd,
    },
}

#[derive(Subcommand, Clone, Copy)]
enum ExitsCmd {
    /// Serve the slots' status and choices over loopback HTTP.
    Serve,
    /// Log a slot's tailscaled in and name it for its region.
    Node { slot: u8 },
}

fn main() {
    let cli = Cli::parse();
    let result = match cli.command {
        Command::Exits { cmd } => ExitsConfig::from_env().and_then(|cfg| match cmd {
            ExitsCmd::Serve => pia::exits::run(&cfg),
            ExitsCmd::Node { slot } => pia::exits::node::run(&cfg, slot),
        }),
        command => Config::from_env().and_then(|cfg| match command {
            Command::Connect => pia::connect::run(&cfg),
            Command::Portforward => pia::portforward::run(&cfg),
            Command::Watchdog => pia::watchdog::run(&cfg),
            Command::Exits { .. } => unreachable!("handled above"),
        }),
    };
    if let Err(err) = result {
        let prefix = match cli.command {
            Command::Watchdog => "pia-watchdog",
            Command::Exits { .. } => "pia-exits",
            _ => "pia",
        };
        eprintln!("{prefix}: {err:#}");
        std::process::exit(1);
    }
}
