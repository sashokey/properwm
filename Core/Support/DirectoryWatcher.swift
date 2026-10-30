import Foundation

/// 目录变更监视：`open(path, O_EVTONLY)` + `DispatchSourceFileSystemObject`，
/// ~0.3s 防抖后回主线程回调。封面刷新、废纸篓空/满、弹窗实时刷新共用。
///
/// fd 生命周期：fd 只在 source 的 cancel handler 里 close（绝不先 close 再 cancel，
/// 否则 fd 可能被复用后误关别人的）；`stop()` 幂等，deinit 兜底。
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void

    /// 路径打不开（不存在/无权限）返回 nil，调用方自行降级。回调保证在主线程。
    init?(path: String, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.debounceInterval = debounce
        self.onChange = onChange

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.resume()
        self.source = source
    }

    /// 主队列上防抖：事件风暴（批量拷贝）只触发一次回调。
    private func scheduleChange() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.source != nil else { return }
            self.onChange()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
    }

    deinit {
        debounceWorkItem?.cancel()
        source?.cancel()
    }
}
