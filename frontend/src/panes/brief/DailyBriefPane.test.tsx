import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, cleanup } from "@testing-library/react";
import { DailyBriefPane } from "./DailyBriefPane";
import type { DailyBrief } from "../../lib/types";

// Mock the Avatar component to keep tests isolated from styling internals
vi.mock("../../components/ui/avatar", () => ({
  Avatar: ({ name }: { name: string }) => (
    <span data-testid="avatar">{name}</span>
  ),
}));

describe("DailyBriefPane", () => {
  afterEach(cleanup);

  it("renders placeholder when no brief provided", () => {
    render(<DailyBriefPane onRefresh={async () => {}} />);
    expect(screen.getByText("No brief available yet.")).toBeInTheDocument();
  });

  const minimalBrief: DailyBrief = {
    generated_at: new Date().toISOString(),
    total_tasks: 5,
    ready_tasks: 2,
    review_tasks: 1,
    blocked_tasks: 1,
    failed_tasks: 1,
    total_cost_usd: 1.23,
    recent_events: [
      {
        timestamp: new Date().toISOString(),
        kind: "task_completed",
        summary: "Done",
        payload: {},
      },
    ],
    recommended_actions: ["Review blocked tasks"],
  };

  it("renders with minimal brief (no extended fields)", () => {
    render(<DailyBriefPane brief={minimalBrief} onRefresh={async () => {}} />);
    // Core stats should render
    expect(screen.getByText("5")).toBeInTheDocument();
    // Extended fields show fallback values — multiple zeros appear so use getAllByText
    const zeros = screen.getAllByText("0");
    expect(zeros.length).toBeGreaterThan(0); // active_sessions, completed, failed all fallback to 0
    expect(screen.getByText("$0.00")).toBeInTheDocument(); // cost_last_24h_usd fallback
  });

  it("renders with full brief including extended fields", () => {
    const fullBrief: DailyBrief = {
      ...minimalBrief,
      active_sessions: 3,
      cost_last_24h_usd: 4.56,
      tasks_completed_last_24h: 7,
      tasks_failed_last_24h: 2,
      stale_ready_count: 1,
      longest_running_task: "Deploy pipeline",
      top_cost_tasks: [
        { task_id: "t1", title: "Expensive task", cost_usd: 2.5 },
      ],
    };
    render(<DailyBriefPane brief={fullBrief} onRefresh={async () => {}} />);
    expect(screen.getByText("3")).toBeInTheDocument(); // active_sessions
    expect(screen.getByText("$4.56")).toBeInTheDocument(); // cost_last_24h_usd
    expect(screen.getByText("Deploy pipeline")).toBeInTheDocument();
    expect(screen.getByText("Expensive task")).toBeInTheDocument();
  });
});
