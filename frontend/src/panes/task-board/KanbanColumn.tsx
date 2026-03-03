import { useDroppable } from "@dnd-kit/core";
import { SortableContext, verticalListSortingStrategy } from "@dnd-kit/sortable";
import type { Task } from "../../lib/types";
import { TaskCard } from "./TaskCard";

type Props = {
  status: string;
  tasks: Task[];
  onDispatch: (taskId: string) => Promise<void>;
  isValidTarget: boolean;
  isDragActive: boolean;
};

export function KanbanColumn({ status, tasks, onDispatch, isValidTarget, isDragActive }: Props) {
  const { setNodeRef, isOver } = useDroppable({ id: status });

  const borderClass = isDragActive
    ? isValidTarget
      ? isOver
        ? "border-mint-400/70 bg-mint-400/5"
        : "border-mint-400/30"
      : "border-red-500/40 bg-red-500/5"
    : "border-white/10";

  return (
    <section
      ref={setNodeRef}
      aria-label={`${status} column, ${tasks.length} tasks`}
      className={[
        "rounded-lg border bg-slate-900/70 p-3 transition-colors duration-150",
        borderClass,
      ].join(" ")}
    >
      <header className="mb-3 text-xs font-semibold uppercase tracking-wide text-slate-300">
        {status} ({tasks.length})
      </header>
      <SortableContext items={tasks.map((t) => t.id)} strategy={verticalListSortingStrategy}>
        <div className="space-y-2">
          {tasks.map((task) => (
            <TaskCard key={task.id} task={task} status={status} onDispatch={onDispatch} />
          ))}
        </div>
      </SortableContext>
    </section>
  );
}
