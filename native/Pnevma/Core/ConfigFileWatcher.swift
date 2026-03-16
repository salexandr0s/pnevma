import Foundation

/// Watches a file for changes using GCD dispatch sources.
/// Handles atomic-write editors (Vim, etc.) that rename/delete the file.
final class ConfigFileWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let url: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private let debounceInterval: TimeInterval

    private var debounceWorkItem: DispatchWorkItem?

    init(
        url: URL,
        queue: DispatchQueue = .main,
        debounceInterval: TimeInterval = 0.3,
        onChange: @escaping () -> Void
    ) {
        self.url = url
        self.queue = queue
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    func start() {
        stop()
        openAndWatch()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    deinit {
        stop()
    }

    private func openAndWatch() {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []

            if flags.contains(.rename) || flags.contains(.delete) {
                // File was replaced (atomic write) — re-open after a brief delay
                self.source?.cancel()
                self.source = nil
                if self.fileDescriptor >= 0 {
                    Darwin.close(self.fileDescriptor)
                    self.fileDescriptor = -1
                }
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.openAndWatch()
                    self?.scheduleCallback()
                }
            } else {
                self.scheduleCallback()
            }
        }

        src.setCancelHandler { [fd] in
            Darwin.close(fd)
        }

        // Prevent double-close: setCancelHandler owns the fd now
        fileDescriptor = -1
        source = src
        src.resume()
    }

    private func scheduleCallback() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}
