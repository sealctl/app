//! `fake-relay [--bind 127.0.0.1:8787]`: the in-memory relay for app and machine tests.

use clap::Parser;

#[derive(Parser)]
#[command(about = "In-memory sealctl relay with /test/ controls (loopback only)")]
struct Args {
    /// Address to listen on.
    #[arg(long, default_value = "127.0.0.1:8787")]
    bind: String,
}

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let args = Args::parse();
    fake_relay::serve(&args.bind).await
}
