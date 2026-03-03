import { useCallback, useEffect, useMemo, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import { CommandPalette } from "./components/CommandPalette";
import {
  DialogProvider,
  alert as nativeAlert,
  confirm as nativeConfirm,
  prompt as nativePrompt,
} from "./components/Dialog";
import { FirstLaunchPanel } from "./components/FirstLaunchPanel";
import {
  type KnowledgeCaptureRequest,
  KnowledgeCaptureDialog,
} from "./components/KnowledgeCaptureDialog";
import { OnboardingOverlay } from "./components/OnboardingOverlay";
import {
  advanceOnboardingStep,
  applyPaneLayoutTemplate,
  approveReview,
  captureKnowledge,
  clearNotifications,
  createTask,
  dispatchTask,
  draftTaskContract,
  executeRegisteredCommand,
  executeMergeQueue,
  getEnvironmentReadiness,
  getDailyBrief,
  initializeGlobalConfig,
  initializeProjectScaffold,
  getOnboardingState,
  getProjectCost,
  listKeybindings,
  listMergeQueue,
  listNotifications,
  listPaneLayoutTemplates,
  listPanes,
  listRecentProjects,
  listRegisteredCommands,
  listSessions,
  listTasks,
  markNotificationRead,
  moveMergeQueueItem,
  openProject,
  projectStatus,
  rejectReview,
  savePaneLayoutTemplate,
  trustWorkspace,
} from "./hooks/useTauri";
import { matchesShortcut } from "./lib/keybinding";
import type {
  DailyBrief,
  EnvironmentReadiness,
  Keybinding,
  MergeQueueItem,
  Notification,
  OnboardingState,
  Pane,
  RecentProject,
  RegisteredCommand,
  Session,
  Task,
} from "./lib/types";
import { AnalyticsPane } from "./panes/analytics/AnalyticsPane";
import { DailyBriefPane } from "./panes/brief/DailyBriefPane";
import { DiffPane } from "./panes/diff/DiffPane";
import { FileBrowserPane } from "./panes/files/FileBrowserPane";
import { NotificationsPane } from "./panes/notifications/NotificationsPane";
import { ReplayPane } from "./panes/replay/ReplayPane";
import { MergeQueuePane } from "./panes/review/MergeQueuePane";
import { ReviewPane } from "./panes/review/ReviewPane";
import { SearchPane } from "./panes/search/SearchPane";
import { RulesManagerPane } from "./panes/settings/RulesManagerPane";
import { SettingsPane } from "./panes/settings/SettingsPane";
import { SshManagerPane } from "./panes/ssh/SshManagerPane";
import { TaskBoardPane } from "./panes/task-board/TaskBoardPane";
import { WorkflowPane } from "./panes/workflow/WorkflowPane";
import { TerminalPane } from "./panes/terminal/TerminalPane";
import { useAppStore } from "./stores/appStore";

const ONBOARDING_ORDER = ["open_project", "create_task", "dispatch_task", "review_task", "merge_task"];

function toShortcutMap(rows: Keybinding[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const row of rows) {
    out[row.action] = row.shortcut;
  }
  return out;
}

function onboardingRank(step: string): number {
  const index = ONBOARDING_ORDER.indexOf(step);
  return index >= 0 ? index : 0;
}

function inferOnboardingStep(projectName: string | undefined, tasks: Task[]): string {
  if (!projectName) {
    return "open_project";
  }
  if (tasks.length === 0) {
    return "create_task";
  }
  const hasDispatched = tasks.some((task) =>
    ["InProgress", "Review", "Done", "Failed"].includes(task.status)
  );
  if (!hasDispatched) {
    return "dispatch_task";
  }
  const hasReview = tasks.some((task) => ["Review", "Done"].includes(task.status));
  if (!hasReview) {
    return "review_task";
  }
  return "merge_task";
}

function paneGridClass(count: number): string {
  if (count <= 1) return "lg:grid-cols-1";
  if (count <= 4) return "lg:grid-cols-2";
  return "lg:grid-cols-3";
}

function paneSpanClass(position?: string): string {
  return position?.endsWith(":v") ? "lg:col-span-full" : "";
}

function renderPane(
  pane: Pane,
  sessions: Session[],
  onDispatch: (taskId: string) => Promise<void>,
  tasks: Task[],
  onApproveReview: (taskId: string, note?: string) => Promise<void>,
  onRejectReview: (taskId: string, note?: string) => Promise<void>,
  onExecuteMerge: (taskId: string) => Promise<void>,
  onMoveMergeQueueItem: (taskId: string, direction: "up" | "down") => Promise<void>,
  mergeQueue: MergeQueueItem[],
  dailyBrief: DailyBrief | undefined,
  onRefreshBrief: () => Promise<void>,
  notifications: Notification[],
  onMarkNotificationRead: (notificationId: string) => Promise<void>,
  onClearNotifications: () => Promise<void>,
  onUpsertTask: (task: Task) => void
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
    return (
      <TaskBoardPane
        tasks={tasks}
        onDispatch={onDispatch}
        onOptimisticStatusChange={(taskId, newStatus) => {
          const task = tasks.find((t) => t.id === taskId);
          if (task) onUpsertTask({ ...task, status: newStatus });
        }}
      />
    );
  }
  if (pane.type === "review") {
    return (
      <ReviewPane
        tasks={tasks}
        onApproveReview={onApproveReview}
        onRejectReview={onRejectReview}
        onExecuteMerge={onExecuteMerge}
      />
    );
  }
  if (pane.type === "merge-queue") {
    return (
      <MergeQueuePane
        mergeQueue={mergeQueue}
        onMove={onMoveMergeQueueItem}
        onExecuteMerge={onExecuteMerge}
      />
    );
  }
  if (pane.type === "notifications") {
    return (
      <NotificationsPane
        notifications={notifications}
        onMarkRead={onMarkNotificationRead}
        onClearAll={onClearNotifications}
      />
    );
  }
  if (pane.type === "replay") {
    return <ReplayPane sessions={sessions} />;
  }
  if (pane.type === "daily-brief") {
    return <DailyBriefPane brief={dailyBrief} onRefresh={onRefreshBrief} />;
  }
  if (pane.type === "diff") {
    return <DiffPane tasks={tasks} />;
  }
  if (pane.type === "search") {
    return <SearchPane />;
  }
  if (pane.type === "file-browser") {
    return <FileBrowserPane />;
  }
  if (pane.type === "rules-manager") {
    return <RulesManagerPane />;
  }
  if (pane.type === "settings") {
    return <SettingsPane />;
  }
  if (pane.type === "ssh-manager") {
    return <SshManagerPane />;
  }
  if (pane.type === "workflow") {
    return <WorkflowPane />;
  }
  if (pane.type === "analytics") {
    return <AnalyticsPane />;
  }
  return null;
}

export function App() {
  const [registeredCommands, setRegisteredCommands] = useState<RegisteredCommand[]>([]);
  const [keybindings, setKeybindings] = useState<Record<string, string>>({});
  const [onboarding, setOnboarding] = useState<OnboardingState | null>(null);
  const [knowledgeRequest, setKnowledgeRequest] = useState<KnowledgeCaptureRequest | null>(null);
  const [knowledgeBusy, setKnowledgeBusy] = useState(false);
  const [bootstrapPath, setBootstrapPath] = useState(".");
  const [readiness, setReadiness] = useState<EnvironmentReadiness | null>(null);
  const [bootstrapBusy, setBootstrapBusy] = useState(false);
  const [bootstrapNotice, setBootstrapNotice] = useState<string | undefined>();
  const [recentProjects, setRecentProjects] = useState<RecentProject[]>([]);

  const {
    panes,
    activePaneId,
    tasks,
    sessions,
    notifications,
    mergeQueue,
    layoutTemplates,
    dailyBrief,
    projectName,
    projectCost,
    setProjectId,
    setProjectName,
    setPanes,
    setTasks,
    upsertTask,
    removeTask,
    setSessions,
    upsertSession,
    removeSession,
    setNotifications,
    upsertNotification,
    setMergeQueue,
    upsertMergeQueueItem,
    setLayoutTemplates,
    setDailyBrief,
    setProjectCost,
    focusPane,
    removePane,
    upsertPane: upsertPaneInStore,
  } = useAppStore();

  const refreshProjectData = useCallback(async () => {
    try {
      const [status, taskRows, sessionRows, cost, paneRows, queueRows, notificationRows, templates, brief] =
        await Promise.all([
          projectStatus(),
          listTasks(),
          listSessions(),
          getProjectCost(""),
          listPanes(),
          listMergeQueue(),
          listNotifications(false),
          listPaneLayoutTemplates(),
          getDailyBrief(),
        ]);
      setProjectId(status.project_id);
      setProjectName(status.project_name);
      setTasks(taskRows);
      setSessions(sessionRows);
      setProjectCost(cost);
      setMergeQueue(queueRows);
      setNotifications(notificationRows);
      setLayoutTemplates(templates);
      setDailyBrief(brief);
      if (paneRows.length > 0) {
        setPanes(paneRows);
      }
    } catch {
      setProjectName(undefined);
      setLayoutTemplates([]);
      setDailyBrief(undefined);
    }
  }, [
    setDailyBrief,
    setMergeQueue,
    setLayoutTemplates,
    setNotifications,
    setPanes,
    setProjectCost,
    setProjectId,
    setProjectName,
    setSessions,
    setTasks,
  ]);

  const refreshCommandRegistry = useCallback(async () => {
    const commands = await listRegisteredCommands();
    setRegisteredCommands(commands);
  }, []);

  const refreshKeybindings = useCallback(async () => {
    try {
      const rows = await listKeybindings();
      setKeybindings(toShortcutMap(rows));
    } catch {
      setKeybindings({});
    }
  }, []);

  const refreshOnboarding = useCallback(async () => {
    try {
      const state = await getOnboardingState();
      setOnboarding(state);
    } catch {
      setOnboarding(null);
    }
  }, []);

  const refreshEnvironment = useCallback(
    async (path = bootstrapPath) => {
      try {
        const next = await getEnvironmentReadiness(path);
        setReadiness(next);
      } catch {
        setReadiness(null);
      }
    },
    [bootstrapPath]
  );

  const initializeGlobalFromPanel = useCallback(async () => {
    setBootstrapBusy(true);
    try {
      const result = await initializeGlobalConfig();
      setBootstrapNotice(
        result.created
          ? `Global config created at ${result.path}`
          : `Global config already exists at ${result.path}`
      );
      await refreshEnvironment();
    } finally {
      setBootstrapBusy(false);
    }
  }, [refreshEnvironment]);

  const initializeProjectFromPanel = useCallback(async () => {
    if (!bootstrapPath.trim()) {
      return;
    }
    setBootstrapBusy(true);
    try {
      const result = await initializeProjectScaffold({ path: bootstrapPath.trim() });
      if (result.already_initialized) {
        setBootstrapNotice("Project scaffold already initialized.");
      } else {
        setBootstrapNotice(`Created ${result.created_paths.length} scaffold paths.`);
      }
      await refreshEnvironment(bootstrapPath.trim());
    } finally {
      setBootstrapBusy(false);
    }
  }, [bootstrapPath, refreshEnvironment]);

  const openProjectByPath = useCallback(async (targetPath: string) => {
    if (!targetPath.trim()) {
      return;
    }
    const trimmed = targetPath.trim();
    setBootstrapBusy(true);
    try {
      await openProject(trimmed);
      setBootstrapNotice(undefined);
      await refreshProjectData();
      await refreshKeybindings();
      await refreshOnboarding();
      void listRecentProjects().then(setRecentProjects).catch(() => {});
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (message.includes("workspace_not_trusted")) {
        const confirmed = await nativeConfirm(
          "This workspace has not been trusted yet. Trust and open?"
        );
        if (confirmed) {
          await trustWorkspace(trimmed);
          try {
            await openProject(trimmed);
            setBootstrapNotice(undefined);
            await refreshProjectData();
            await refreshKeybindings();
            await refreshOnboarding();
            void listRecentProjects().then(setRecentProjects).catch(() => {});
          } catch (retryErr: unknown) {
            const retryMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
            await nativeAlert(`Failed to open project: ${retryMsg}`);
          }
        }
      } else if (message.includes("workspace_config_changed")) {
        const confirmed = await nativeConfirm(
          "Workspace configuration has changed since it was last trusted. Re-trust and open?"
        );
        if (confirmed) {
          await trustWorkspace(trimmed);
          try {
            await openProject(trimmed);
            setBootstrapNotice(undefined);
            await refreshProjectData();
            await refreshKeybindings();
            await refreshOnboarding();
            void listRecentProjects().then(setRecentProjects).catch(() => {});
          } catch (retryErr: unknown) {
            const retryMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
            await nativeAlert(`Failed to open project: ${retryMsg}`);
          }
        }
      } else {
        await nativeAlert(`Failed to open project: ${message}`);
      }
    } finally {
      setBootstrapBusy(false);
    }
  }, [
    refreshKeybindings,
    refreshOnboarding,
    refreshProjectData,
  ]);

  const openProjectFromPanel = useCallback(async () => {
    await openProjectByPath(bootstrapPath);
  }, [bootstrapPath, openProjectByPath]);

  const selectRecentProject = useCallback(async (recentPath: string) => {
    setBootstrapPath(recentPath);
    await openProjectByPath(recentPath);
  }, [openProjectByPath]);

  const browseForProject = useCallback(async () => {
    const selected = await open({ directory: true, multiple: false, title: "Select Project Folder" });
    if (selected && typeof selected === "string") {
      setBootstrapPath(selected);
      setBootstrapNotice(undefined);
      void refreshEnvironment(selected);
    }
  }, [refreshEnvironment]);

  const updateOnboarding = useCallback(async (step: string, completed?: boolean, dismissed?: boolean) => {
    const next = await advanceOnboardingStep({ step, completed, dismissed });
    setOnboarding(next);
  }, []);

  const dispatchFromBoard = useCallback(
    async (taskId: string) => {
      await dispatchTask(taskId);
      await refreshProjectData();
    },
    [refreshProjectData]
  );

  const approveFromReview = useCallback(
    async (taskId: string, note?: string) => {
      await approveReview(taskId, note);
      await refreshProjectData();
    },
    [refreshProjectData]
  );

  const rejectFromReview = useCallback(
    async (taskId: string, note?: string) => {
      await rejectReview(taskId, note);
      await refreshProjectData();
    },
    [refreshProjectData]
  );

  const executeMergeFromReview = useCallback(
    async (taskId: string) => {
      await executeMergeQueue(taskId);
      await refreshProjectData();
    },
    [refreshProjectData]
  );

  const moveInMergeQueue = useCallback(
    async (taskId: string, direction: "up" | "down") => {
      await moveMergeQueueItem(taskId, direction);
      await refreshProjectData();
    },
    [refreshProjectData]
  );

  const markNotificationAsRead = useCallback(
    async (notificationId: string) => {
      await markNotificationRead(notificationId);
      await refreshProjectData();
    },
    [refreshProjectData]
  );

  const clearAllNotifications = useCallback(async () => {
    await clearNotifications();
    await refreshProjectData();
  }, [refreshProjectData]);

  const applyLayoutTemplateFromPalette = useCallback(
    async (templateName: string) => {
      const preview = await applyPaneLayoutTemplate(templateName, false);
      if (!preview.applied && preview.unsaved_replacements.length > 0) {
        const detail = preview.unsaved_replacements
          .map((item) => `- ${item.pane_label} (${item.pane_type}): ${item.reason}`)
          .join("\n");
        const confirmed = await nativeConfirm(
          `Applying "${templateName}" will replace panes with unsaved state:\n${detail}\n\nApply anyway?`
        );
        if (!confirmed) {
          return;
        }
        await applyPaneLayoutTemplate(templateName, true);
      }
      await refreshProjectData();
    },
    [refreshProjectData]
  );

  const saveCurrentLayoutTemplateFromPalette = useCallback(async () => {
    const name = ((await nativePrompt("Template name (slug)", "")) ?? "").trim();
    if (!name) {
      return;
    }
    const displayName = ((await nativePrompt("Template label", "")) ?? "").trim();
    await savePaneLayoutTemplate(name, displayName || undefined);
    await refreshProjectData();
  }, [refreshProjectData]);

  const handleKnowledgeCapture = useCallback(
    async (kind: string, title: string, content: string) => {
      const current = knowledgeRequest;
      if (!current || !content.trim()) {
        return;
      }
      const normalizedKind =
        kind === "changelog" || kind === "convention-update" ? kind : "adr";
      setKnowledgeBusy(true);
      try {
        await captureKnowledge({
          task_id: current.taskId,
          kind: normalizedKind,
          title: title.trim() || undefined,
          content: content.trim(),
        });
        setKnowledgeRequest((prior) => {
          if (!prior) {
            return null;
          }
          const remaining = prior.kinds.filter((entry) => entry !== kind);
          if (remaining.length === 0) {
            return null;
          }
          return {
            ...prior,
            kinds: remaining,
          };
        });
        await refreshProjectData();
      } finally {
        setKnowledgeBusy(false);
      }
    },
    [knowledgeRequest, refreshProjectData]
  );

  useEffect(() => {
    void refreshCommandRegistry();
  }, [refreshCommandRegistry]);

  useEffect(() => {
    void refreshProjectData();
    void refreshKeybindings();
    void refreshOnboarding();
    void refreshEnvironment();
    void listRecentProjects().then(setRecentProjects).catch(() => setRecentProjects([]));
  }, [refreshEnvironment, refreshKeybindings, refreshOnboarding, refreshProjectData]);

  useEffect(() => {
    if (!projectName) {
      return;
    }
    void refreshKeybindings();
    void refreshOnboarding();
  }, [projectName, refreshKeybindings, refreshOnboarding]);

  useEffect(() => {
    if (projectName) {
      return;
    }
    void refreshEnvironment(bootstrapPath);
  }, [bootstrapPath, projectName, refreshEnvironment]);

  useEffect(() => {
    const unlisteners: (() => void)[] = [];
    const onKeybindingsUpdated = () => void refreshKeybindings();
    const onOnboardingReset = () => void refreshOnboarding();

    window.addEventListener("pnevma:keybindings-updated", onKeybindingsUpdated as EventListener);
    window.addEventListener("pnevma:onboarding-reset", onOnboardingReset as EventListener);

    const refreshCost = async () => {
      try { setProjectCost(await getProjectCost("")); } catch { /* noop */ }
    };
    const refreshBrief = async () => {
      try { setDailyBrief(await getDailyBrief()); } catch { /* noop */ }
    };

    const setup = async () => {
      // Task events: use delta payloads when available, fall back to full refresh
      unlisteners.push(
        await listen<Record<string, unknown>>("task_updated", (event) => {
          const p = event.payload ?? {};
          if (p.deleted === true && typeof p.task_id === "string") {
            removeTask(p.task_id);
          } else if (p.task && typeof p.task === "object") {
            upsertTask(p.task as Task);
          } else {
            // Fallback: full refresh (e.g. workflow batch creates)
            void listTasks().then(setTasks).catch(() => undefined);
          }
          void refreshCost();
        })
      );

      unlisteners.push(
        await listen("cost_updated", () => void refreshCost())
      );

      // Session events: use delta payloads when available
      unlisteners.push(
        await listen<Record<string, unknown>>("session_spawned", (event) => {
          const p = event.payload ?? {};
          if (p.session && typeof p.session === "object") {
            upsertSession(p.session as Session);
          } else {
            void listSessions().then(setSessions).catch(() => undefined);
          }
        })
      );
      unlisteners.push(
        await listen<Record<string, unknown>>("session_heartbeat", (event) => {
          const p = event.payload ?? {};
          if (p.session && typeof p.session === "object") {
            upsertSession(p.session as Session);
          } else {
            void listSessions().then(setSessions).catch(() => undefined);
          }
        })
      );
      unlisteners.push(
        await listen<Record<string, unknown>>("session_exited", (event) => {
          const p = event.payload ?? {};
          if (p.session && typeof p.session === "object") {
            upsertSession(p.session as Session);
          } else if (typeof p.session_id === "string") {
            removeSession(p.session_id);
          } else {
            void listSessions().then(setSessions).catch(() => undefined);
          }
        })
      );

      // Notification events
      unlisteners.push(
        await listen<Record<string, unknown>>("notification_created", (event) => {
          const p = event.payload ?? {};
          if (p.id && typeof p.id === "string") {
            upsertNotification(p as unknown as Notification);
          } else {
            void listNotifications(false).then(setNotifications).catch(() => undefined);
          }
        })
      );
      unlisteners.push(
        await listen<Record<string, unknown>>("notification_updated", (event) => {
          const p = event.payload ?? {};
          if (p.id && typeof p.id === "string") {
            // Partial update: merge with existing notification in store
            const store = useAppStore.getState();
            const existing = store.notifications.find((n) => n.id === p.id);
            if (existing) {
              upsertNotification({ ...existing, ...p } as Notification);
            } else {
              void listNotifications(false).then(setNotifications).catch(() => undefined);
            }
          } else {
            void listNotifications(false).then(setNotifications).catch(() => undefined);
          }
        })
      );
      unlisteners.push(
        await listen("notification_cleared", () => {
          setNotifications([]);
        })
      );

      // Merge queue events
      unlisteners.push(
        await listen<Record<string, unknown>>("merge_queue_updated", (event) => {
          const p = event.payload ?? {};
          if (p.item && typeof p.item === "object") {
            upsertMergeQueueItem(p.item as MergeQueueItem);
          } else {
            void listMergeQueue().then(setMergeQueue).catch(() => undefined);
          }
        })
      );

      // Pane events
      unlisteners.push(
        await listen<Record<string, unknown>>("pane_updated", (event) => {
          const p = event.payload ?? {};
          if (p.action === "removed" && typeof p.pane_id === "string") {
            removePane(p.pane_id);
          } else if (p.pane && typeof p.pane === "object") {
            upsertPaneInStore(p.pane as Pane);
          } else {
            void listPanes().then((rows) => { if (rows.length > 0) setPanes(rows); }).catch(() => undefined);
          }
        })
      );

      unlisteners.push(
        await listen("knowledge_captured", () => void refreshBrief())
      );

      // Full refresh fallback for bulk operations
      unlisteners.push(
        await listen("project_refreshed", () => void refreshProjectData())
      );
      unlisteners.push(
        await listen<Record<string, unknown>>("knowledge_capture_requested", (event) => {
          const payload = event.payload ?? {};
          const taskId =
            typeof payload.task_id === "string" && payload.task_id.trim().length > 0
              ? payload.task_id
              : undefined;
          const kinds = Array.isArray(payload.kinds)
            ? payload.kinds
                .filter((entry): entry is string => typeof entry === "string")
                .map((entry) => entry.trim())
                .filter(Boolean)
            : [];
          setKnowledgeRequest({
            taskId,
            kinds: kinds.length > 0 ? kinds : ["adr", "changelog", "convention-update"],
          });
        })
      );
    };

    void setup();

    return () => {
      for (const fn of unlisteners) fn();
      window.removeEventListener("pnevma:keybindings-updated", onKeybindingsUpdated as EventListener);
      window.removeEventListener("pnevma:onboarding-reset", onOnboardingReset as EventListener);
    };
  }, [
    refreshKeybindings,
    refreshOnboarding,
    refreshProjectData,
    removePane,
    removeSession,
    removeTask,
    setDailyBrief,
    setMergeQueue,
    setNotifications,
    setPanes,
    setProjectCost,
    setSessions,
    setTasks,
    upsertMergeQueueItem,
    upsertNotification,
    upsertPaneInStore,
    upsertSession,
    upsertTask,
  ]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.tagName === "SELECT" ||
          target.isContentEditable)
      ) {
        return;
      }

      const nextShortcut = keybindings["pane.focus_next"] ?? "Mod+]";
      const prevShortcut = keybindings["pane.focus_prev"] ?? "Mod+[";
      const newTaskShortcut = keybindings["task.new"] ?? "Mod+Shift+N";
      const dispatchNextShortcut = keybindings["task.dispatch_next_ready"] ?? "Mod+Shift+D";
      const approveNextShortcut = keybindings["review.approve_next"] ?? "Mod+Shift+A";

      const runQuickCommand = (id: string) => {
        void executeRegisteredCommand(id, {})
          .then(() => refreshProjectData())
          .catch(() => undefined);
      };

      if (matchesShortcut(event, nextShortcut) || matchesShortcut(event, prevShortcut)) {
        if (panes.length === 0) {
          return;
        }
        event.preventDefault();
        const activeIndex = panes.findIndex((pane) => pane.id === activePaneId);
        const currentIndex = activeIndex >= 0 ? activeIndex : 0;
        if (matchesShortcut(event, nextShortcut)) {
          const nextIndex = currentIndex + 1 >= panes.length ? 0 : currentIndex + 1;
          focusPane(panes[nextIndex].id);
        } else {
          const nextIndex = currentIndex <= 0 ? panes.length - 1 : currentIndex - 1;
          focusPane(panes[nextIndex].id);
        }
        return;
      }

      if (matchesShortcut(event, newTaskShortcut)) {
        event.preventDefault();
        runQuickCommand("task.new");
        return;
      }

      if (matchesShortcut(event, dispatchNextShortcut)) {
        event.preventDefault();
        runQuickCommand("task.dispatch_next_ready");
        return;
      }

      if (matchesShortcut(event, approveNextShortcut)) {
        event.preventDefault();
        runQuickCommand("review.approve_next");
      }
    };

    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [activePaneId, focusPane, keybindings, panes, refreshProjectData]);

  useEffect(() => {
    if (!onboarding || onboarding.dismissed || onboarding.completed) {
      return;
    }
    const targetStep = inferOnboardingStep(projectName, tasks);
    const shouldComplete = targetStep === "merge_task" && tasks.some((task) => task.status === "Done");
    if (
      onboardingRank(targetStep) > onboardingRank(onboarding.step) ||
      (shouldComplete && !onboarding.completed)
    ) {
      void updateOnboarding(targetStep, shouldComplete, false);
    }
  }, [onboarding, projectName, tasks, updateOnboarding]);

  const resolveCommandArgs = useCallback(
    async (command: RegisteredCommand): Promise<Record<string, string> | null> => {
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
          const prompted = (await nativePrompt(arg.label, arg.default_value ?? "")) ?? "";
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
    () => {
      const remoteCommands = registeredCommands.map((command) => ({
        id: command.id,
        label: command.label,
        run: async () => {
          const args = await resolveCommandArgs(command);
          if (!args) {
            return;
          }
          await executeRegisteredCommand(command.id, args);
          await refreshProjectData();
        },
      }));
      const localDraftCommand = {
        id: "task.draft_from_text",
        label: "Draft Task From Text",
        run: async () => {
          const text = await nativePrompt("Describe the task to draft", "");
          if (!text || !text.trim()) {
            return;
          }
          const draft = await draftTaskContract(text.trim());
          if (draft.warnings.length > 0) {
            await nativeAlert(`Draft warning: ${draft.warnings.join(" | ")}`);
          }
          const title = ((await nativePrompt("Title", draft.title)) ?? draft.title).trim();
          const goal = ((await nativePrompt("Goal", draft.goal)) ?? draft.goal).trim();
          const scope = ((await nativePrompt("Scope (comma-separated)", draft.scope.join(", "))) ?? "")
            .split(",")
            .map((item) => item.trim())
            .filter(Boolean);
          const acceptanceCriteria = (
            (await nativePrompt(
              "Acceptance criteria (one per line)",
              draft.acceptance_criteria.join("\n")
            )) ?? ""
          )
            .split("\n")
            .map((item) => item.trim())
            .filter(Boolean);
          const constraints = (
            (await nativePrompt("Constraints (one per line)", draft.constraints.join("\n"))) ?? ""
          )
            .split("\n")
            .map((item) => item.trim())
            .filter(Boolean);
          const priority = ((await nativePrompt("Priority (P0/P1/P2/P3)", draft.priority)) ?? "P1").trim();
          if (!title || !goal || acceptanceCriteria.length === 0) {
            return;
          }
          await createTask({
            title,
            goal,
            scope,
            acceptance_criteria: acceptanceCriteria,
            constraints,
            dependencies: draft.dependencies,
            priority,
          });
          await refreshProjectData();
        },
      };
      const localSaveLayoutCommand = {
        id: "layout.save_current",
        label: "Save Current Layout as Template",
        run: async () => {
          try {
            await saveCurrentLayoutTemplateFromPalette();
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            await nativeAlert(`Failed to save layout template: ${message}`);
          }
        },
      };
      const localApplyLayoutCommands = layoutTemplates.map((template) => ({
        id: `layout.apply.${template.name}`,
        label: `Apply Layout: ${template.display_name}`,
        run: async () => {
          try {
            await applyLayoutTemplateFromPalette(template.name);
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            await nativeAlert(`Failed to apply layout template: ${message}`);
          }
        },
      }));

      return [
        ...remoteCommands,
        localDraftCommand,
        localSaveLayoutCommand,
        ...localApplyLayoutCommands,
      ];
    },
    [
      applyLayoutTemplateFromPalette,
      layoutTemplates,
      refreshProjectData,
      registeredCommands,
      resolveCommandArgs,
      saveCurrentLayoutTemplateFromPalette,
    ]
  );

  const activePane = panes.find((pane) => pane.id === activePaneId) ?? panes[0];
  const paletteShortcut = keybindings["command_palette.toggle"] ?? "Mod+K";

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
          <span>Merge Queue: {mergeQueue.length}</span>
          <span>
            Alerts: {notifications.filter((notification) => notification.unread).length}
          </span>
        </div>
      </header>

      {!projectName ? (
        <div className="flex flex-1 items-center justify-center">
          <FirstLaunchPanel
            path={bootstrapPath}
            readiness={readiness}
            busy={bootstrapBusy}
            notice={bootstrapNotice}
            recentProjects={recentProjects}
            onPathChange={(value) => {
              setBootstrapPath(value);
              setBootstrapNotice(undefined);
            }}
            onRefresh={async () => {
              await refreshEnvironment(bootstrapPath);
            }}
            onInitGlobalConfig={initializeGlobalFromPanel}
            onInitProject={initializeProjectFromPanel}
            onOpenProject={openProjectFromPanel}
            onBrowse={browseForProject}
            onSelectRecent={selectRecentProject}
          />
        </div>
      ) : null}

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
            className={`grid h-full grid-cols-1 auto-rows-[minmax(260px,1fr)] gap-3 ${paneGridClass(
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
                  {renderPane(
                    pane,
                    sessions,
                    dispatchFromBoard,
                    tasks,
                    approveFromReview,
                    rejectFromReview,
                    executeMergeFromReview,
                    moveInMergeQueue,
                    mergeQueue,
                    dailyBrief,
                    refreshProjectData,
                    notifications,
                    markNotificationAsRead,
                    clearAllNotifications,
                    upsertTask
                  )}
                </div>
              </article>
            ))}
          </div>
        </section>
      </main>

      <footer className="border-t border-white/10 px-4 py-2 text-xs text-slate-500">
        {paletteShortcut} command palette • Simultaneous multi-pane shell
      </footer>

      <CommandPalette
        commands={commands}
        toggleShortcut={paletteShortcut}
        nextShortcut={keybindings["command_palette.next"] ?? "ArrowDown"}
        prevShortcut={keybindings["command_palette.prev"] ?? "ArrowUp"}
        executeShortcut={keybindings["command_palette.execute"] ?? "Enter"}
      />
      <OnboardingOverlay state={onboarding} onAdvance={updateOnboarding} />
      <KnowledgeCaptureDialog
        request={knowledgeRequest}
        busy={knowledgeBusy}
        onCapture={handleKnowledgeCapture}
        onClose={() => setKnowledgeRequest(null)}
      />
      <DialogProvider />
    </div>
  );
}
