import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import type { Task } from "../../lib/types";

type Props = {
  task: Task;
  status: string;
  onDispatch: (taskId: string) => Promise<void>;
  overlay?: boolean;
};

export function TaskCard({ task, status, onDispatch, overlay = false }: Props) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: task.id,
    data: { task, status },
  });

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.4 : 1,
  };

  return (
    <article
      ref={overlay ? undefined : setNodeRef}
      style={overlay ? undefined : style}
      tabIndex={0}
      aria-label={`Task: ${task.title}, status: ${status}`}
      aria-grabbed={isDragging}
      onKeyDown={(event) => {
        if ((event.key === "d" || event.key === "Enter") && status === "Ready") {
          event.preventDefault();
          void onDispatch(task.id);
        }
      }}
      className={[
        "rounded-md border border-white/10 bg-slate-950/80 p-2 outline-none",
        "focus:border-mint-400/70",
        overlay ? "rotate-1 shadow-xl opacity-90" : "cursor-grab active:cursor-grabbing",
      ].join(" ")}
      {...(overlay ? {} : { ...attributes, ...listeners })}
    >
      <div className="text-sm font-medium">{task.title}</div>
      <div className="mt-1 line-clamp-3 text-xs text-slate-400">{task.goal}</div>
      <div className="mt-2 flex items-center justify-between text-xs text-slate-500">
        <span>{task.priority}</span>
        {status === "Ready" ? (
          <button
            className="rounded bg-mint-500 px-2 py-1 text-[11px] font-semibold text-slate-950"
            onPointerDown={(e) => e.stopPropagation()}
            onClick={(e) => {
              e.stopPropagation();
              void onDispatch(task.id);
            }}
          >
            Dispatch
          </button>
        ) : null}
      </div>
      <div className="mt-2 flex items-center justify-between text-[11px] text-slate-500">
        <span>
          Deps: {task.dependencies.length}
          {task.queued_position ? ` · Queue #${task.queued_position}` : ""}
        </span>
        <span>{typeof task.cost_usd === "number" ? `$${task.cost_usd.toFixed(2)}` : "No cost"}</span>
      </div>
    </article>
  );
}
