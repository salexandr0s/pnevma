import { create } from "zustand";
import type {
  DailyBrief,
  MergeQueueItem,
  Notification,
  Pane,
  PaneLayoutTemplate,
  Session,
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
  setSessions: (sessions: Session[]) => void;
  setNotifications: (notifications: Notification[]) => void;
  setMergeQueue: (mergeQueue: MergeQueueItem[]) => void;
  setLayoutTemplates: (templates: PaneLayoutTemplate[]) => void;
  setDailyBrief: (brief?: DailyBrief) => void;
  setProjectCost: (cost: number) => void;
  addPane: (pane: Pane) => void;
  focusPane: (paneId: string) => void;
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
  setSessions: (sessions) => set({ sessions }),
  setNotifications: (notifications) => set({ notifications }),
  setMergeQueue: (mergeQueue) => set({ mergeQueue }),
  setLayoutTemplates: (layoutTemplates) => set({ layoutTemplates }),
  setDailyBrief: (dailyBrief) => set({ dailyBrief }),
  setProjectCost: (projectCost) => set({ projectCost }),
  addPane: (pane) =>
    set((state) => ({
      panes: [...state.panes, pane],
      activePaneId: pane.id,
    })),
  focusPane: (activePaneId) => set({ activePaneId }),
}));
