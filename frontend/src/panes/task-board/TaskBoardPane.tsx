import {
  DndContext,
  KeyboardSensor,
  PointerSensor,
  type DragEndEvent,
  type DragStartEvent,
  useSensor,
  useSensors,
} from "@dnd-kit/core";
import { sortableKeyboardCoordinates } from "@dnd-kit/sortable";
import { useState } from "react";
import { updateTask } from "../../hooks/useTauri";
import type { Task } from "../../lib/types";
import { DragOverlayCard } from "./DragOverlayCard";
import { KanbanColumn } from "./KanbanColumn";

type Props = {
  tasks: Task[];
  onDispatch: (taskId: string) => Promise<void>;
  onOptimisticStatusChange?: (taskId: string, newStatus: string) => void;
};

const COLUMNS = ["Planned", "Ready", "InProgress", "Review", "Done", "Failed", "Blocked"] as const;

const VALID_TRANSITIONS: Record<string, readonly string[]> = {
  Planned: ["Ready", "Blocked"],
  Ready: ["InProgress", "Failed", "Blocked"],
  InProgress: ["Review", "Failed"],
  Review: ["Done", "Failed"],
  Blocked: ["Planned"],
};

export function TaskBoardPane({ tasks, onDispatch, onOptimisticStatusChange }: Props) {
  const [activeTask, setActiveTask] = useState<Task | null>(null);

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 8 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates })
  );

  function handleDragStart(event: DragStartEvent) {
    const task = tasks.find((t) => t.id === event.active.id);
    setActiveTask(task ?? null);
  }

  function handleDragEnd(event: DragEndEvent) {
    setActiveTask(null);

    const { active, over } = event;
    if (!over) return;

    const task = tasks.find((t) => t.id === active.id);
    if (!task) return;

    // over.id can be either a column status string or a task id in another column
    // Resolve the target column: if over.id is a task id, look up its status
    let targetStatus: string;
    const overTask = tasks.find((t) => t.id === over.id);
    if (overTask) {
      targetStatus = overTask.status;
    } else {
      // over.id is a droppable column id (the status string)
      targetStatus = over.id as string;
    }

    if (task.status === targetStatus) return;

    const allowed = VALID_TRANSITIONS[task.status] ?? [];
    if (!allowed.includes(targetStatus)) {
      console.warn(
        `[TaskBoard] Invalid transition: ${task.status} → ${targetStatus} for task ${task.id}`
      );
      return;
    }

    onOptimisticStatusChange?.(task.id, targetStatus);
    void updateTask({ id: task.id, status: targetStatus });
  }

  const activeFromStatus = activeTask?.status ?? null;

  return (
    <DndContext sensors={sensors} onDragStart={handleDragStart} onDragEnd={handleDragEnd}>
      <div className="grid h-full grid-cols-2 gap-3 overflow-auto xl:grid-cols-4 2xl:grid-cols-7">
        {COLUMNS.map((status) => {
          const items = tasks.filter((task) => task.status === status);
          const isValidTarget =
            activeFromStatus !== null &&
            (VALID_TRANSITIONS[activeFromStatus] ?? []).includes(status);

          return (
            <KanbanColumn
              key={status}
              status={status}
              tasks={items}
              onDispatch={onDispatch}
              isValidTarget={isValidTarget}
              isDragActive={activeTask !== null}
            />
          );
        })}
      </div>
      <DragOverlayCard task={activeTask} />
    </DndContext>
  );
}
