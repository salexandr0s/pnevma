import { create } from "zustand";
import type {
  DailyBrief,
  MergeQueueItem,
  Notification,
  Pane,
  PaneLayoutTemplate,
  Session,
  SshProfile,
  Task,
} from "../lib/types";

type AppStore = {
  projectId?: string;
  projectName?: string;
  panes: Pane[];
  activePaneId?: string;
  tasks: Task[];
  sessions: Session[];
  notifications: Notification[];
  mergeQueue: MergeQueueItem[];
  layoutTemplates: PaneLayoutTemplate[];
  dailyBrief?: DailyBrief;
  projectCost: number;
  setProjectId: (id: string) => void;
  setProjectName: (name?: string) => void;
  setPanes: (panes: Pane[]) => void;
  removePane: (paneId: string) => void;
  setTasks: (tasks: Task[]) => void;
  upsertTask: (task: Task) => void;
  removeTask: (taskId: string) => void;
  setSessions: (sessions: Session[]) => void;
  upsertSession: (session: Session) => void;
  removeSession: (sessionId: string) => void;
  setNotifications: (notifications: Notification[]) => void;
  upsertNotification: (notification: Notification) => void;
  removeNotification: (notificationId: string) => void;
  setMergeQueue: (mergeQueue: MergeQueueItem[]) => void;
  upsertMergeQueueItem: (item: MergeQueueItem) => void;
  removeMergeQueueItem: (itemId: string) => void;
  setLayoutTemplates: (templates: PaneLayoutTemplate[]) => void;
  setDailyBrief: (brief?: DailyBrief) => void;
  setProjectCost: (cost: number) => void;
  addPane: (pane: Pane) => void;
  upsertPane: (pane: Pane) => void;
  focusPane: (paneId: string) => void;
  sshProfiles: SshProfile[];
  setSshProfiles: (profiles: SshProfile[]) => void;
};

export const useAppStore = create<AppStore>((set) => ({
  panes: [{ id: "pane-board", type: "task-board", label: "Task Board", position: "root" }],
  activePaneId: "pane-board",
  tasks: [],
  sessions: [],
  notifications: [],
  mergeQueue: [],
  layoutTemplates: [],
  dailyBrief: undefined,
  projectCost: 0,
  setProjectId: (id) => set({ projectId: id }),
  setProjectName: (projectName) => set({ projectName }),
  setPanes: (panes) =>
    set((state) => ({
      panes,
      activePaneId: panes.some((pane) => pane.id === state.activePaneId)
        ? state.activePaneId
        : panes[0]?.id,
    })),
  removePane: (paneId) =>
    set((state) => {
      const panes = state.panes.filter((pane) => pane.id !== paneId);
      const fallback = panes[0]?.id;
      return {
        panes,
        activePaneId: state.activePaneId === paneId ? fallback : state.activePaneId,
      };
    }),
  setTasks: (tasks) => set({ tasks }),
  upsertTask: (task) =>
    set((state) => {
      const idx = state.tasks.findIndex((t) => t.id === task.id);
      if (idx >= 0) {
        const next = [...state.tasks];
        next[idx] = task;
        return { tasks: next };
      }
      return { tasks: [...state.tasks, task] };
    }),
  removeTask: (taskId) =>
    set((state) => ({ tasks: state.tasks.filter((t) => t.id !== taskId) })),
  setSessions: (sessions) => set({ sessions }),
  upsertSession: (session) =>
    set((state) => {
      const idx = state.sessions.findIndex((s) => s.id === session.id);
      if (idx >= 0) {
        const next = [...state.sessions];
        next[idx] = session;
        return { sessions: next };
      }
      return { sessions: [...state.sessions, session] };
    }),
  removeSession: (sessionId) =>
    set((state) => ({ sessions: state.sessions.filter((s) => s.id !== sessionId) })),
  setNotifications: (notifications) => set({ notifications }),
  upsertNotification: (notification) =>
    set((state) => {
      const idx = state.notifications.findIndex((n) => n.id === notification.id);
      if (idx >= 0) {
        const next = [...state.notifications];
        next[idx] = notification;
        return { notifications: next };
      }
      return { notifications: [...state.notifications, notification] };
    }),
  removeNotification: (notificationId) =>
    set((state) => ({
      notifications: state.notifications.filter((n) => n.id !== notificationId),
    })),
  setMergeQueue: (mergeQueue) => set({ mergeQueue }),
  upsertMergeQueueItem: (item) =>
    set((state) => {
      const idx = state.mergeQueue.findIndex((m) => m.id === item.id);
      if (idx >= 0) {
        const next = [...state.mergeQueue];
        next[idx] = item;
        return { mergeQueue: next };
      }
      return { mergeQueue: [...state.mergeQueue, item] };
    }),
  removeMergeQueueItem: (itemId) =>
    set((state) => ({
      mergeQueue: state.mergeQueue.filter((m) => m.id !== itemId),
    })),
  setLayoutTemplates: (layoutTemplates) => set({ layoutTemplates }),
  setDailyBrief: (dailyBrief) => set({ dailyBrief }),
  setProjectCost: (projectCost) => set({ projectCost }),
  addPane: (pane) =>
    set((state) => ({
      panes: [...state.panes, pane],
      activePaneId: pane.id,
    })),
  upsertPane: (pane) =>
    set((state) => {
      const idx = state.panes.findIndex((p) => p.id === pane.id);
      if (idx >= 0) {
        const next = [...state.panes];
        next[idx] = pane;
        return { panes: next };
      }
      return { panes: [...state.panes, pane] };
    }),
  focusPane: (activePaneId) => set({ activePaneId }),
  sshProfiles: [],
  setSshProfiles: (sshProfiles) => set({ sshProfiles }),
}));
