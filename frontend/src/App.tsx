import { useCallback, useEffect, useMemo, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { CommandPalette } from "./components/CommandPalette";
import {
  dispatchTask,
  executeRegisteredCommand,
  getProjectCost,
  listRegisteredCommands,
  listPanes,
  listSessions,
  listTasks,
  projectStatus,
} from "./hooks/useTauri";
import type { Pane, RegisteredCommand, Session, Task } from "./lib/types";
import { TerminalPane } from "./panes/terminal/TerminalPane";
import { TaskBoardPane } from "./panes/task-board/TaskBoardPane";
import { ReviewPane } from "./panes/review/ReviewPane";
import { DiffPane } from "./panes/diff/DiffPane";
import { SearchPane } from "./panes/search/SearchPane";
import { SettingsPane } from "./panes/settings/SettingsPane";
import { useAppStore } from "./stores/appStore";

function paneGridClass(count: number): string {
  if (count <= 1) {
    return "lg:grid-cols-1";
  }
  if (count <= 2) {
    return "lg:grid-cols-2";
  }
  if (count <= 4) {
    return "lg:grid-cols-2";
  }
  return "lg:grid-cols-3";
}

function paneSpanClass(position?: string): string {
  if (!position) {
    return "";
  }
  if (position.endsWith(":v")) {
    return "lg:col-span-full";
  }
  return "";
}

function renderPane(
  pane: Pane,
  sessions: Session[],
  onDispatch: (taskId: string) => Promise<void>,
  tasks: Task[]
) {
  if (pane.type === "terminal") {
    const session = sessions.find((item) => item.id === pane.session_id);
    return (
      <TerminalPane
        title={pane.label}
        sessionId={pane.session_id}
        sessionStatus={session?.status}
      />
    );
  }
  if (pane.type === "task-board") {
    return <TaskBoardPane tasks={tasks} onDispatch={onDispatch} />;
  }
  if (pane.type === "review") {
    return <ReviewPane />;
  }
  if (pane.type === "diff") {
    return <DiffPane />;
  }
  if (pane.type === "search") {
    return <SearchPane />;
  }
  if (pane.type === "settings") {
    return <SettingsPane />;
  }
  return null;
}

export function App() {
  const [registeredCommands, setRegisteredCommands] = useState<RegisteredCommand[]>([]);
  const {
    panes,
    activePaneId,
    tasks,
    sessions,
    projectName,
    projectCost,
    setProjectId,
    setProjectName,
    setPanes,
    setTasks,
    setSessions,
    setProjectCost,
    focusPane,
  } = useAppStore();

  const refreshProjectData = useCallback(async () => {
    try {
      const [status, taskRows, sessionRows, cost, paneRows] = await Promise.all([
        projectStatus(),
        listTasks(),
        listSessions(),
        getProjectCost(""),
        listPanes(),
      ]);
      setProjectId(status.project_id);
      setProjectName(status.project_name);
      setTasks(taskRows);
      setSessions(sessionRows);
      setProjectCost(cost);
      if (paneRows.length > 0) {
        setPanes(paneRows);
      }
    } catch {
      setProjectName(undefined);
    }
  }, [setPanes, setProjectCost, setProjectId, setProjectName, setSessions, setTasks]);

  const refreshCommandRegistry = useCallback(async () => {
    const commands = await listRegisteredCommands();
    setRegisteredCommands(commands);
  }, []);

  const dispatchFromBoard = useCallback(
    async (taskId: string) => {
      await dispatchTask(taskId);
      await refreshProjectData();
    },
    [refreshProjectData]
  );

  useEffect(() => {
    void refreshCommandRegistry();
  }, [refreshCommandRegistry]);

  useEffect(() => {
    let unlistenTask: (() => void) | undefined;
    let unlistenCost: (() => void) | undefined;
    let unlistenSession: (() => void) | undefined;
    const setup = async () => {
      unlistenTask = await listen("task_updated", () => {
        void refreshProjectData();
      });
      unlistenCost = await listen("cost_updated", () => {
        void refreshProjectData();
      });
      unlistenSession = await listen("session_spawned", () => {
        void refreshProjectData();
      });
    };
    void setup();
    return () => {
      if (unlistenTask) {
        unlistenTask();
      }
      if (unlistenCost) {
        unlistenCost();
      }
      if (unlistenSession) {
        unlistenSession();
      }
    };
  }, [refreshProjectData]);

  const resolveCommandArgs = useCallback(
    (command: RegisteredCommand): Record<string, string> | null => {
      const args: Record<string, string> = {};
      const activePane = panes.find((pane) => pane.id === activePaneId) ?? panes[0];
      const activeSessionId = activePane?.session_id ?? undefined;

      for (const arg of command.args) {
        let value = "";
        if (arg.source === "active_pane_id") {
          value = activePane?.id ?? "";
        } else if (arg.source === "active_session_id") {
          value = activeSessionId ?? "";
        } else {
          const prompted = prompt(arg.label, arg.default_value ?? "") ?? "";
          value = prompted.trim();
        }

        if (!value && arg.required) {
          return null;
        }
        if (value) {
          args[arg.name] = value;
        }
      }
      return args;
    },
    [activePaneId, panes]
  );

  const commands = useMemo(
    () =>
      registeredCommands.map((command) => ({
        id: command.id,
        label: command.label,
        run: async () => {
          const args = resolveCommandArgs(command);
          if (!args) {
            return;
          }
          await executeRegisteredCommand(command.id, args);
          await refreshProjectData();
        },
      })),
    [refreshProjectData, registeredCommands, resolveCommandArgs]
  );

  const activePane = panes.find((pane) => pane.id === activePaneId) ?? panes[0];

  return (
    <div className="flex min-h-screen flex-col">
      <header className="flex items-center justify-between border-b border-white/10 px-4 py-2 backdrop-blur">
        <div>
          <h1 className="text-sm font-semibold tracking-wide text-slate-100">Pnevma</h1>
          <p className="text-xs text-slate-400">
            {projectName ? `Project: ${projectName}` : "Terminal-first execution workspace"}
          </p>
        </div>
        <div className="flex gap-4 text-xs text-slate-300">
          <span>Sessions: {sessions.length}</span>
          <span>Project Cost: ${projectCost.toFixed(2)}</span>
        </div>
      </header>

      <main className="grid flex-1 grid-cols-12 gap-3 p-3">
        <aside className="col-span-12 rounded-lg border border-white/10 bg-slate-900/60 p-2 lg:col-span-2">
          <div className="space-y-2">
            {panes.map((pane) => (
              <button
                key={pane.id}
                onClick={() => focusPane(pane.id)}
                className={`w-full rounded-md px-2 py-2 text-left text-sm ${
                  pane.id === activePane?.id ? "bg-mint-500/20 text-mint-300" : "hover:bg-white/10"
                }`}
              >
                {pane.label}
              </button>
            ))}
          </div>
        </aside>

        <section className="col-span-12 overflow-auto rounded-lg border border-white/10 bg-slate-900/50 p-3 lg:col-span-10">
          <div
            className={`grid h-full grid-cols-1 gap-3 auto-rows-[minmax(260px,1fr)] ${paneGridClass(
              panes.length
            )}`}
          >
            {panes.map((pane) => (
              <article
                key={pane.id}
                onClick={() => focusPane(pane.id)}
                className={`flex min-h-[260px] cursor-pointer flex-col overflow-hidden rounded-md border ${
                  pane.id === activePane?.id ? "border-mint-400/70" : "border-white/10"
                } ${paneSpanClass(pane.position)} bg-slate-950/70`}
              >
                <header className="flex items-center justify-between border-b border-white/10 px-3 py-2 text-xs text-slate-400">
                  <span>{pane.label}</span>
                  <span className="uppercase tracking-wide">{pane.type}</span>
                </header>
                <div className="flex-1 overflow-hidden p-2">
                  {renderPane(pane, sessions, dispatchFromBoard, tasks)}
                </div>
              </article>
            ))}
          </div>
        </section>
      </main>

      <footer className="border-t border-white/10 px-4 py-2 text-xs text-slate-500">
        Cmd/Ctrl+K command palette • Simultaneous multi-pane shell
      </footer>

      <CommandPalette commands={commands} />
    </div>
  );
}
