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

        let builtInEnglish: Set<String> = [
            "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
            "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
            "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
            "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
            "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
            "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
            "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
            "than", "then", "now", "look", "only", "come", "its", "over", "think", "also",
            "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
            "even", "new", "want", "because", "any", "these", "give", "day", "most", "us",
            "is", "was", "are", "were", "been", "has", "had", "did", "does", "doing",
            "hello", "world", "test", "mac", "switch", "keyboard", "buffer", "app", "computer",
            "always", "never", "sometimes", "works", "why", "where", "every", "problem"
        ]
        let builtInRussian: Set<String> = [
            "и", "в", "не", "на", "я", "быть", "он", "с", "что", "а",
            "по", "это", "она", "к", "но", "мы", "за", "его", "то", "всё",
            "из", "у", "они", "так", "ее", "сколько", "зачем", "уже", "вот", "когда",
            "даже", "если", "нет", "можно", "надо", "тут", "там", "тоже", "очень", "сейчас",
            "потом", "просто", "нужно", "потому", "почему", "снова", "дела", "работает", "переключает",
            "всегда", "никогда", "иногда", "кажется", "приложение", "компьютер", "клавиатура", "мышь",
            "экран", "окно", "текст", "файл", "папка", "система", "программа", "язык", "раскладка",
            "ошибка", "вопрос", "ответ", "место", "время", "сегодня", "завтра", "вчера", "человек",
            "друг", "дом", "работа", "часть", "жизнь", "год", "день", "рука", "раз", "город",
            "слово", "лицо", "дверь", "вода", "огонь", "земля", "воздух", "машина", "дорога", "свет",
            "мир", "сила", "ночь", "утро", "вечер", "деньги", "домой"
        ]

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
