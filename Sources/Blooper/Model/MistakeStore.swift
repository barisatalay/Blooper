import Foundation

final class MistakeStore: ObservableObject {
    @Published private(set) var mistakes: [Mistake] = []
    var onNewMistakes: (([Mistake]) -> Void)?

    private let fileURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init(fileURL: URL) { self.fileURL = fileURL }
    deinit { stopWatching() }

    func reload() {
        let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let parsed = Mistake.parseLog(content)
        let fresh = Array(parsed.dropFirst(mistakes.count))
        mistakes = parsed
        if !fresh.isEmpty { onNewMistakes?(fresh) }
    }

    func startWatching() {
        stopWatching()
        fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                // Dosya yeniden oluşturulmuş olabilir: izlemeyi tazele.
                // O anda henüz yoksa önce yarat — yoksa open başarısız olur ve izleme sessizce ölür.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                        FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
                    }
                    self.startWatching(); self.reload()
                }
            } else {
                self.reload()
            }
        }
        src.setCancelHandler { [fd = self.fd] in if fd >= 0 { close(fd) } }
        src.resume()
        source = src
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        fd = -1
    }
}
