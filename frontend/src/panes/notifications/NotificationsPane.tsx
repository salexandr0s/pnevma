import type { Notification } from "../../lib/types";

type Props = {
  notifications: Notification[];
  onMarkRead: (notificationId: string) => Promise<void>;
  onClearAll: () => Promise<void>;
};

export function NotificationsPane({ notifications, onMarkRead, onClearAll }: Props) {
  const unread = notifications.filter((item) => item.unread);

  return (
    <div className="flex h-full flex-col overflow-hidden rounded-lg border border-white/10 bg-slate-900/60">
      <header className="flex items-center justify-between border-b border-white/10 px-3 py-2">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-300">
          Notifications ({unread.length} unread)
        </div>
        <button
          className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 hover:bg-slate-600"
          onClick={() => {
            void onClearAll();
          }}
        >
          Mark All Read
        </button>
      </header>
      <div className="flex-1 space-y-2 overflow-auto p-3">
        {notifications.length === 0 ? (
          <div className="rounded border border-dashed border-white/15 p-3 text-sm text-slate-400">
            No notifications yet.
          </div>
        ) : null}
        {notifications.map((notification) => (
          <article
            key={notification.id}
            className={`rounded border p-2 ${
              notification.unread ? "border-amber-400/50 bg-amber-400/10" : "border-white/10 bg-slate-950/70"
            }`}
          >
            <div className="flex items-start justify-between gap-3">
              <div>
                <div className="text-sm font-medium text-slate-100">{notification.title}</div>
                <div className="mt-1 text-xs text-slate-400">{notification.body}</div>
                <div className="mt-1 text-[11px] uppercase tracking-wide text-slate-500">
                  {notification.level} · {new Date(notification.created_at).toLocaleString()}
                </div>
              </div>
              {notification.unread ? (
                <button
                  className="rounded bg-amber-500 px-2 py-1 text-[11px] font-semibold text-slate-950"
                  onClick={() => {
                    void onMarkRead(notification.id);
                  }}
                >
                  Mark Read
                </button>
              ) : null}
            </div>
          </article>
        ))}
      </div>
    </div>
  );
}
