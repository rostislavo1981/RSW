import Foundation

public final class WordDictionary {
    public static let shared = WordDictionary()

    private var englishWords: Set<String>
    private var russianWords: Set<String>
    private let fileName = "words.json"

    public var englishCount: Int { englishWords.count }
    public var russianCount: Int { russianWords.count }

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RSwitcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    public init() {
        let builtInEnglish: Set<String> = [
            "the", "is", "it", "in", "on", "at", "to", "of", "and", "an",
            "he", "we", "my", "do", "no", "so", "if", "me", "up", "us",
            "be", "as", "am", "or", "by", "go", "ok", "hi"
        ]
        let builtInRussian: Set<String> = [
            "и", "в", "не", "на", "я", "что", "он", "с", "а", "это",
            "как", "все", "она", "так", "его", "но", "да", "ты", "к",
            "у", "же", "вы", "за", "по", "из", "о", "от", "до", "ли",
            "нет", "вот", "ну", "уж", "бы", "ей", "их", "сам", "уже",
            "или", "ни", "если", "там", "где", "тут", "при", "над",
            "тоже", "тут", "ему", "ей", "вас", "им", "нам", "ним"
        ]

        let loaded = Self.loadFromDisk()
        englishWords = builtInEnglish.union(loaded.english)
        russianWords = builtInRussian.union(loaded.russian)
    }

    public func isKnown(_ word: String, language: KeyboardLanguage) -> Bool {
        let lower = word.lowercased()
        switch language {
        case .english: return englishWords.contains(lower)
        case .russian: return russianWords.contains(lower)
        }
    }

    public func add(_ word: String, language: KeyboardLanguage) {
        let lower = word.lowercased()
        switch language {
        case .english: englishWords.insert(lower)
        case .russian: russianWords.insert(lower)
        }
        saveToDisk()
    }

    public func remove(_ word: String, language: KeyboardLanguage) {
        let lower = word.lowercased()
        switch language {
        case .english: englishWords.remove(lower)
        case .russian: russianWords.remove(lower)
        }
        saveToDisk()
    }

    private func saveToDisk() {
        let data: [String: [String]] = [
            "english": Array(englishWords),
            "russian": Array(russianWords)
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) else { return }
        try? jsonData.write(to: fileURL, options: .atomic)
    }

    private static func loadFromDisk() -> (english: Set<String>, russian: Set<String>) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("RSwitcher").appendingPathComponent("words.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return (english: [], russian: [])
        }
        return (
            english: Set(json["english"] ?? []),
            russian: Set(json["russian"] ?? [])
        )
    }
}
