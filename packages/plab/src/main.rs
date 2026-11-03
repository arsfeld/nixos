mod albums;
mod api;
mod app;
mod codedb;
mod commands;
mod config;
mod curated;
mod db;
mod events;
mod external;
mod filters;
mod grab;
mod http;
mod identify;
mod images;
mod jobs;
mod labels;
mod llm;
mod monitor;
mod plab;
mod provenance;
mod prowlarr;
mod prune;
mod rqbit;
mod scenes;
mod site;
mod sources;
mod stash;
mod stream;
mod taste;
#[cfg(test)]
mod testlog;
mod tracker;
mod transmission;
mod web;

use std::process::ExitCode;

use clap::{Parser, Subcommand};

use crate::config::Config;

#[derive(Parser)]
#[command(name = "plab")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// The daemon: page, identify watcher, and the periodic jobs.
    Serve {
        #[arg(long, default_value = "127.0.0.1")]
        bind: String,
        #[arg(long, default_value_t = 8577)]
        port: u16,
        /// Comma-separated subset of web,identify,refresh,prune,grab.
        #[arg(
            long,
            value_delimiter = ',',
            default_value = "web,identify,refresh,prune,grab"
        )]
        tasks: Vec<String>,
        /// Also serve GET /stream/<topic>/<file> alone on this port (the tailnet node).
        #[arg(long)]
        stream_port: Option<u16>,
    },
    /// Drain the download queues, then rebuild the video and games lists.
    Refresh,
    /// Search the curated terms (the tracker, and other indexers for terms marked @), then
    /// rebuild the video list.
    Curated,
    /// Take finished Vault and Games torrents out of Transmission.
    Prune {
        #[arg(long)]
        dry_run: bool,
    },
    /// Grab new scenes of the followed studios into Vault.
    Grab {
        #[arg(long)]
        dry_run: bool,
    },
    /// One identify pass. Without paths: the LLM step only (no Stash jobs).
    Identify {
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        limit: Option<usize>,
        #[arg(long = "scene")]
        scenes: Vec<String>,
        #[arg(long)]
        no_jobs: bool,
        paths: Vec<String>,
    },
    /// Seed the tracker session by hand when a login hits a captcha.
    SetCookie { value: String },
}

#[tokio::main]
async fn main() -> anyhow::Result<ExitCode> {
    use tracing_subscriber::prelude::*;
    // The filter is a global layer, so the monitor sees exactly what the journal does.
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with(
            tracing_subscriber::fmt::layer()
                .with_writer(std::io::stderr)
                .with_ansi(false)
                .without_time(), // the journal timestamps lines
        )
        .with(monitor::MonitorLayer::new(monitor::global().clone()))
        .init();
    let cli = Cli::parse();
    let cfg = Config::from_env(|k| std::env::var(k).ok());
    site::init(cfg.site_file.as_deref())?;
    match cli.cmd {
        Cmd::Serve {
            bind,
            port,
            tasks,
            stream_port,
        } => {
            commands::serve(cfg, bind, port, stream_port, tasks).await?;
            // Exit at once: the tasks are mid-run by design, and nothing waits on them.
            std::process::exit(0);
        }
        Cmd::Refresh => commands::refresh(&cfg).await?,
        Cmd::Curated => commands::curated(&cfg).await?,
        Cmd::Prune { dry_run } => {
            commands::prune(&cfg, dry_run).await?;
        }
        Cmd::Grab { dry_run } => return commands::grab(&cfg, dry_run).await,
        Cmd::Identify {
            dry_run,
            limit,
            scenes,
            no_jobs,
            paths,
        } => commands::identify(&cfg, dry_run, limit, scenes, no_jobs, paths).await?,
        Cmd::SetCookie { value } => commands::set_cookie(&cfg, &value)?,
    }
    Ok(ExitCode::SUCCESS)
}
