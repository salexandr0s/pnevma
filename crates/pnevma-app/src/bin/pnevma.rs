use pnevma_app::control::{send_request, ControlAuthEnvelope, ControlRequest};
use serde_json::Value;
use std::path::PathBuf;
use uuid::Uuid;

fn usage() -> &'static str {
    "Usage:
  pnevma ctl <method> [--params-json <json>] [--socket <path>] [--id <id>] [--password <secret>]

Examples:
  pnevma ctl project.status
  pnevma ctl task.dispatch --params-json '{\"task_id\":\"...\"}'
  pnevma ctl notification.create --params-json '{\"title\":\"Build\",\"body\":\"Needs review\"}'"
}

fn take_option(args: &mut Vec<String>, name: &str) -> Option<String> {
    let mut idx = 0;
    while idx < args.len() {
        if args[idx] == name {
            if idx + 1 >= args.len() {
                return None;
            }
            let value = args.remove(idx + 1);
            let _ = args.remove(idx);
            return Some(value);
        }
        idx += 1;
    }
    None
}

#[tokio::main]
async fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("{}", usage());
        std::process::exit(1);
    }
    let sub = args.remove(0);
    if sub != "ctl" {
        eprintln!("{}", usage());
        std::process::exit(1);
    }

    if args.is_empty() {
        eprintln!("{}", usage());
        std::process::exit(1);
    }

    let socket = take_option(&mut args, "--socket")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".pnevma/run/control.sock"));
    let id = take_option(&mut args, "--id").unwrap_or_else(|| Uuid::new_v4().to_string());
    let params_json = take_option(&mut args, "--params-json").unwrap_or_else(|| "{}".to_string());
    let password = take_option(&mut args, "--password");

    let method = args.remove(0);
    if !args.is_empty() {
        eprintln!("unexpected trailing arguments: {}", args.join(" "));
        std::process::exit(1);
    }

    let params: Value = match serde_json::from_str(&params_json) {
        Ok(value) => value,
        Err(err) => {
            eprintln!("invalid --params-json: {err}");
            std::process::exit(1);
        }
    };

    let request = ControlRequest {
        id,
        method,
        params,
        auth: password.map(|password| ControlAuthEnvelope {
            password: Some(password),
        }),
    };

    let response = match send_request(&socket, &request).await {
        Ok(response) => response,
        Err(err) => {
            eprintln!("control request failed: {err}");
            std::process::exit(1);
        }
    };

    if response.ok {
        println!(
            "{}",
            serde_json::to_string_pretty(&response.result.unwrap_or(Value::Null))
                .unwrap_or_else(|_| "{}".to_string())
        );
        return;
    }

    eprintln!(
        "{}",
        serde_json::to_string_pretty(&response.error).unwrap_or_else(|_| "{}".to_string())
    );
    std::process::exit(2);
}
