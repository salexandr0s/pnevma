import { DragOverlay as DndDragOverlay } from "@dnd-kit/core";
import type { Task } from "../../lib/types";
import { TaskCard } from "./TaskCard";

type Props = {
  task: Task | null;
};

export function DragOverlayCard({ task }: Props) {
  if (!task) return null;
  return (
    <DndDragOverlay>
      <TaskCard task={task} status={task.status} onDispatch={() => Promise.resolve()} overlay />
    </DndDragOverlay>
  );
}
