import Foundation

enum BlooperEnv {
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blooper")
    }
    static var mistakesFile: URL { supportDir.appendingPathComponent("mistakes.jsonl") }
    static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    static var binDir: URL { supportDir.appendingPathComponent("bin") }

    // İzleme fd tabanlı: dosyalar izleme kurulmadan ÖNCE var edilmeli
    static func bootstrap(bundle: Bundle? = Bundle.main) {
        let fm = FileManager.default
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: mistakesFile.path) { fm.createFile(atPath: mistakesFile.path, contents: nil) }
        if !fm.fileExists(atPath: configFile.path) {
            try? #"{"model":"claude-haiku-4-5","notifications":true}"#.write(to: configFile, atomically: true, encoding: .utf8)
        }
        syncScripts(from: bundle)
    }

    // App her açılışta script'lerin güncel kopyasını sabit yola yazar; hook app bundle'ına değil buraya bağlıdır
    static func syncScripts(from bundle: Bundle?) {
        let fm = FileManager.default
        for name in ["hook.sh", "checker.sh"] {
            guard let src = bundle?.url(forResource: name, withExtension: nil) else { continue }
            let dst = binDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
    }
}
