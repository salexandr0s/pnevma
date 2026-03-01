import { create } from "zustand";
import type { Pane, Task, Session } from "../lib/types";

type AppStore = {
  projectId?: string;
  projectName?: string;
  panes: Pane[];
  activePaneId?: string;
  tasks: Task[];
  sessions: Session[];
  projectCost: number;
  setProjectId: (id: string) => void;
  setProjectName: (name?: string) => void;
  setPanes: (panes: Pane[]) => void;
  removePane: (paneId: string) => void;
  setTasks: (tasks: Task[]) => void;
  setSessions: (sessions: Session[]) => void;
  setProjectCost: (cost: number) => void;
  addPane: (pane: Pane) => void;
  focusPane: (paneId: string) => void;
};

export const useAppStore = create<AppStore>((set) => ({
  panes: [{ id: "pane-board", type: "task-board", label: "Task Board", position: "root" }],
  activePaneId: "pane-board",
  tasks: [],
  sessions: [],
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
  setProjectCost: (projectCost) => set({ projectCost }),
  addPane: (pane) =>
    set((state) => ({
      panes: [...state.panes, pane],
      activePaneId: pane.id,
    })),
  focusPane: (activePaneId) => set({ activePaneId }),
}));
