use clap::{Parser, Subcommand};

use pia::config::Config;

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
}

fn main() {
    let cli = Cli::parse();
    let result = Config::from_env().and_then(|cfg| match cli.command {
        Command::Connect => pia::connect::run(&cfg),
        Command::Portforward => pia::portforward::run(&cfg),
        Command::Watchdog => pia::watchdog::run(&cfg),
    });
    if let Err(err) = result {
        let prefix = match cli.command {
            Command::Watchdog => "pia-watchdog",
            _ => "pia",
        };
        eprintln!("{prefix}: {err:#}");
        std::process::exit(1);
    }
}
