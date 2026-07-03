import Foundation

public final class WordDictionary {
    public static let shared = WordDictionary(storageURL: defaultStorageURL())

    private var englishWords: Set<String>
    private var russianWords: Set<String>
    private let storageURL: URL?
    private let lock = NSLock()

    public var englishCount: Int { lock.withLock { englishWords.count } }
    public var russianCount: Int { lock.withLock { russianWords.count } }

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL

        let builtInEnglish = Self.loadWords(from: "english_dictionary", bundle: .module)
        let builtInRussian = Self.loadWords(from: "russian_dictionary", bundle: .module)

        let loaded = storageURL.map(Self.loadFromDisk) ?? (english: [], russian: [])
        englishWords = builtInEnglish.union(loaded.english)
        russianWords = builtInRussian.union(loaded.russian)
    }

    public func isKnown(_ word: String, language: KeyboardLanguage) -> Bool {
        let lower = word.lowercased()
        return lock.withLock {
            switch language {
            case .english: return englishWords.contains(lower)
            case .russian: return russianWords.contains(lower)
            }
        }
    }

    public func add(_ word: String, language: KeyboardLanguage) {
        let lower = word.lowercased()
        lock.withLock {
            switch language {
            case .english: englishWords.insert(lower)
            case .russian: russianWords.insert(lower)
            }
            saveToDisk()
        }
    }

    public func remove(_ word: String, language: KeyboardLanguage) {
        let lower = word.lowercased()
        lock.withLock {
            switch language {
            case .english: englishWords.remove(lower)
            case .russian: russianWords.remove(lower)
            }
            saveToDisk()
        }
    }

    private func saveToDisk() {
        guard let storageURL else { return }

        let data: [String: [String]] = [
            "english": Array(englishWords).sorted(),
            "russian": Array(russianWords).sorted()
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? jsonData.write(to: storageURL, options: .atomic)
    }

    private static func loadFromDisk(_ url: URL) -> (english: Set<String>, russian: Set<String>) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return (english: [], russian: [])
        }
        return (
            english: Set(json["english"] ?? []),
            russian: Set(json["russian"] ?? [])
        )
    }

    private static func loadWords(from filename: String, bundle: Bundle) -> Set<String> {
        guard let url = bundle.url(forResource: filename, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]],
              let words = json["words"] else {
            return []
        }
        return Set(words)
    }

    private static func defaultStorageURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("RSwitcher")
            .appendingPathComponent("words.json")
    }
}
