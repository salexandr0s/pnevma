#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


CI_JOB_NAMES = ("Rust checks", "Native app build")
REHEARSAL_PRECHECK_JOB = "Release package preflight"
REHEARSAL_SIGN_JOB = "Sign and prove candidate DMG"


def run_command(args: list[str]) -> str:
    proc = subprocess.run(args, check=True, capture_output=True, text=True)
    return proc.stdout


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Report consecutive green runs for the required main-branch release "
            "lanes and optionally enforce the signed DMG lane."
        )
    )
    parser.add_argument(
        "--repo",
        default=os.environ.get("CI_GREEN_RUNS_REPO_SLUG"),
        help="GitHub repo slug (owner/name). Defaults to origin remote.",
    )
    parser.add_argument(
        "--branch",
        default=os.environ.get("CI_GREEN_RUNS_BRANCH", "main"),
        help="Branch to inspect. Default: main",
    )
    parser.add_argument(
        "--min-streak",
        type=int,
        default=int(os.environ.get("CI_GREEN_RUNS_MIN_STREAK", "10")),
        help="Minimum consecutive streak required. Default: 10",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=int(os.environ.get("CI_GREEN_RUNS_LIMIT", "40")),
        help="Maximum workflow runs to fetch per workflow. Default: 40",
    )
    parser.add_argument(
        "--require-signed-lane",
        action="store_true",
        default=os.environ.get("CI_GREEN_RUNS_REQUIRE_SIGNED_LANE", "0") == "1",
        help="Require the signed-DMG rehearsal lane to meet the minimum streak too.",
    )
    parser.add_argument(
        "--markdown",
        help="Write the Markdown report to this path.",
    )
    parser.add_argument(
        "--json",
        dest="json_path",
        help="Write the JSON report to this path.",
    )
    return parser.parse_args()


def resolve_repo_slug() -> str:
    try:
        remote = run_command(["git", "remote", "get-url", "origin"]).strip()
    except Exception as exc:  # pragma: no cover - surfaced to caller
        raise SystemExit(f"failed to resolve origin remote: {exc}") from exc

    patterns = (
        r"^https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$",
        r"^git@github\.com:(?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$",
        r"^ssh://git@github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$",
    )
    for pattern in patterns:
        match = re.match(pattern, remote)
        if match:
            return f"{match.group('owner')}/{match.group('repo')}"

    raise SystemExit(f"unsupported GitHub remote URL format: {remote}")


def gh_json(gh_bin: str, args: list[str]) -> Any:
    raw = run_command([gh_bin, *args])
    return json.loads(raw or "null")


def parse_timestamp(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def normalize_status(job: dict[str, Any] | None) -> str:
    if not job:
        return "not-found"
    conclusion = job.get("conclusion")
    status = job.get("status")
    if conclusion:
        return str(conclusion)
    if status:
        return str(status)
    return "unknown"


def workflow_run_status(run: dict[str, Any] | None) -> str:
    if not run:
        return "missing"
    conclusion = run.get("conclusion")
    status = run.get("status")
    if conclusion:
        return str(conclusion)
    if status:
        return str(status)
    return "unknown"


def fetch_workflow_runs(gh_bin: str, repo: str, workflow: str, branch: str, limit: int) -> list[dict[str, Any]]:
    data = gh_json(
        gh_bin,
        [
            "run",
            "list",
            "--repo",
            repo,
            "--workflow",
            workflow,
            "--branch",
            branch,
            "--event",
            "push",
            "--limit",
            str(limit),
            "--json",
            "databaseId,headSha,createdAt,url,status,conclusion,workflowName,displayTitle",
        ],
    )
    if not isinstance(data, list):
        raise SystemExit(f"unexpected response when listing workflow runs for {workflow}")
    return data


def fetch_jobs_for_run(gh_bin: str, repo: str, run_id: int) -> dict[str, dict[str, Any]]:
    data = gh_json(
        gh_bin,
        [
            "run",
            "view",
            str(run_id),
            "--repo",
            repo,
            "--json",
            "jobs",
        ],
    )
    jobs = data.get("jobs", []) if isinstance(data, dict) else []
    result: dict[str, dict[str, Any]] = {}
    for job in jobs:
        name = job.get("name")
        if isinstance(name, str):
            result[name] = job
    return result


def choose_latest_per_sha(runs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    latest: dict[str, dict[str, Any]] = {}
    for run in runs:
        sha = run.get("headSha")
        if not isinstance(sha, str) or not sha:
            continue
        current = latest.get(sha)
        if not current or parse_timestamp(run["createdAt"]) > parse_timestamp(current["createdAt"]):
            latest[sha] = run
    return latest


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    gh_bin = os.environ.get("GH_BIN", "gh")
    if not shutil_which(gh_bin):
        raise SystemExit(f"{gh_bin} is required")

    try:
        ci_runs = fetch_workflow_runs(gh_bin, args.repo, "CI", args.branch, args.limit)
        rehearsal_runs = fetch_workflow_runs(gh_bin, args.repo, "Release Rehearsal", args.branch, args.limit)
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip() if exc.stderr else ""
        raise SystemExit(stderr or str(exc)) from exc

    ci_by_sha = choose_latest_per_sha(ci_runs)
    rehearsal_by_sha = choose_latest_per_sha(rehearsal_runs)
    shared_shas = sorted(
        set(ci_by_sha).intersection(rehearsal_by_sha),
        key=lambda sha: max(
            parse_timestamp(ci_by_sha[sha]["createdAt"]),
            parse_timestamp(rehearsal_by_sha[sha]["createdAt"]),
        ),
        reverse=True,
    )

    records: list[dict[str, Any]] = []
    for sha in shared_shas:
        ci_run = ci_by_sha[sha]
        rehearsal_run = rehearsal_by_sha[sha]

        ci_jobs = fetch_jobs_for_run(gh_bin, args.repo, int(ci_run["databaseId"]))
        rehearsal_jobs = fetch_jobs_for_run(gh_bin, args.repo, int(rehearsal_run["databaseId"]))

        ci_statuses = {name: normalize_status(ci_jobs.get(name)) for name in CI_JOB_NAMES}
        rehearsal_precheck_status = normalize_status(rehearsal_jobs.get(REHEARSAL_PRECHECK_JOB))
        rehearsal_sign_status = normalize_status(rehearsal_jobs.get(REHEARSAL_SIGN_JOB))

        workflow_lane_ok = (
            all(status == "success" for status in ci_statuses.values())
            and rehearsal_precheck_status == "success"
        )
        signed_lane_ok = workflow_lane_ok and rehearsal_sign_status == "success"

        records.append(
            {
                "sha": sha,
                "short_sha": sha[:7],
                "created_at": max(ci_run["createdAt"], rehearsal_run["createdAt"]),
                "ci": {
                    "run_id": ci_run["databaseId"],
                    "url": ci_run["url"],
                    "workflow_status": workflow_run_status(ci_run),
                    "jobs": ci_statuses,
                },
                "release_rehearsal": {
                    "run_id": rehearsal_run["databaseId"],
                    "url": rehearsal_run["url"],
                    "workflow_status": workflow_run_status(rehearsal_run),
                    "jobs": {
                        REHEARSAL_PRECHECK_JOB: rehearsal_precheck_status,
                        REHEARSAL_SIGN_JOB: rehearsal_sign_status,
                    },
                },
                "workflow_lane_ok": workflow_lane_ok,
                "signed_lane_ok": signed_lane_ok,
            }
        )

    workflow_streak = 0
    signed_lane_streak = 0
    for record in records:
        if record["workflow_lane_ok"]:
            workflow_streak += 1
        else:
            break

    for record in records:
        if record["signed_lane_ok"]:
            signed_lane_streak += 1
        else:
            break

    return {
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "repo": args.repo,
        "branch": args.branch,
        "minimum_required_streak": args.min_streak,
        "require_signed_lane": args.require_signed_lane,
        "workflow_streak": workflow_streak,
        "signed_lane_streak": signed_lane_streak,
        "workflow_streak_satisfied": workflow_streak >= args.min_streak,
        "signed_lane_streak_satisfied": signed_lane_streak >= args.min_streak,
        "records": records,
    }


def render_markdown(report: dict[str, Any]) -> str:
    workflow_status = "PASS" if report["workflow_streak_satisfied"] else "FAIL"
    signed_status = "PASS" if report["signed_lane_streak_satisfied"] else "FAIL"
    lines = [
        "# CI green-run report",
        "",
        f"- Repo: `{report['repo']}`",
        f"- Branch: `{report['branch']}`",
        f"- Generated at (UTC): `{report['generated_at_utc']}`",
        f"- Minimum required streak: `{report['minimum_required_streak']}`",
        f"- Workflow streak (`CI / Rust checks`, `CI / Native app build`, `Release Rehearsal / Release package preflight`): `{report['workflow_streak']}` — **{workflow_status}**",
        f"- Signed-lane streak (above + `Release Rehearsal / Sign and prove candidate DMG`): `{report['signed_lane_streak']}` — **{signed_status}**",
        "",
        "Notes:",
        f"- The workflow streak counts only commits where the required CI and release-preflight jobs all succeeded on the same `{report['branch']}` push commit.",
        "- The signed-lane streak additionally requires the signed DMG rehearsal job to succeed.",
        "- A skipped or missing signed DMG rehearsal job does not count toward the signed-lane streak.",
        "",
        "| Commit | Rust checks | Native app build | Release package preflight | Sign and prove candidate DMG | CI run | Release Rehearsal run |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]

    for record in report["records"][: max(report["minimum_required_streak"], 10)]:
        ci_jobs = record["ci"]["jobs"]
        rehearsal_jobs = record["release_rehearsal"]["jobs"]
        lines.append(
            "| "
            f"`{record['short_sha']}` | "
            f"`{ci_jobs['Rust checks']}` | "
            f"`{ci_jobs['Native app build']}` | "
            f"`{rehearsal_jobs[REHEARSAL_PRECHECK_JOB]}` | "
            f"`{rehearsal_jobs[REHEARSAL_SIGN_JOB]}` | "
            f"[CI]({record['ci']['url']}) | "
            f"[Release Rehearsal]({record['release_rehearsal']['url']}) |"
        )

    return "\n".join(lines) + "\n"


def write_if_requested(path: str | None, content: str) -> None:
    if not path:
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def shutil_which(command: str) -> str | None:
    return shutil.which(command)


def main() -> int:
    args = parse_args()
    if not args.repo:
        args.repo = resolve_repo_slug()
    report = build_report(args)

    markdown = render_markdown(report)
    json_payload = json.dumps(report, indent=2) + "\n"

    write_if_requested(args.markdown, markdown)
    write_if_requested(args.json_path, json_payload)

    if not args.markdown and not args.json_path:
        sys.stdout.write(markdown)

    workflow_ok = bool(report["workflow_streak_satisfied"])
    signed_ok = bool(report["signed_lane_streak_satisfied"])
    if workflow_ok and (signed_ok or not args.require_signed_lane):
        return 0
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:  # pragma: no cover - top-level safety net
        print(str(exc), file=sys.stderr)
        raise SystemExit(2) from exc
