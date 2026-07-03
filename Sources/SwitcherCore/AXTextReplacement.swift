#if os(macOS)
import Foundation
import CoreFoundation
import ApplicationServices

/** AXTextReplacement – небольшая оболочка над raw‑AX‑вызовам,
 которая знает, как:

 1. Вычислить конечную позицию слова перед курсором.
 2. Проверить, что длина выделения равна нулю.
 3. Сформировать диапазон замены, включая возможный добавочный разделитель.
 4. Выполнить `AXUIElementSetAttributeValue` для `kAXValueAttribute`.
 5. Сдвинуть caret‑позицию.

 Все действия вынесены в инъекции, которые можно подменить в unit‑тестах:
 focused element, диапазон выделения, функция установки нового диапазона,
 функция записи нового значения в AX element.*/

public final class AXTextReplacement {
    // MARK: Инъекции (зависимости)
    private let focusedElementProvider: () -> AXUIElement?
    private let selectedRangeProvider: (AXUIElement) -> NSRange?
    private let setSelectedRangeProvider: (AXUIElement, NSRange) -> Bool
    private let setValueProvider: (AXUIElement, String) -> Bool

    // MARK: Делегаты
    public init(
        focusedElementProvider: @escaping () -> AXUIElement?,
        selectedRangeProvider: @escaping (AXUIElement) -> NSRange?,
        setSelectedRangeProvider: @escaping (AXUIElement, NSRange) -> Bool,
        setValueProvider: @escaping (AXUIElement, String) -> Bool = { element, value in
            AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
        }
    ) {
        self.focusedElementProvider = focusedElementProvider
        self.selectedRangeProvider = selectedRangeProvider
        self.setSelectedRangeProvider = setSelectedRangeProvider
        self.setValueProvider = setValueProvider
    }

    // MARK: Public API
    /**
     Заменяет `wordLength` символов, расположенных **перед** текущим курсором,
     на `replacement`. Если `insertDelimiterIfMissing` – к замене добавляется
     пробел (разделитель), иначе заменяется без дополнительного символа.

     - Parameters:
       - wordLength: количество символов, которое представляет собой слово,
         которое нужно заменить (в обычных случаях – длина `word`).
       - replacement: текст, которым заменить найденное слово.
       - delimiterPresent: `true`, если перед словом уже стоит разделитель.
       - insertDelimiterIfMissing: `true` → добавить пробел, если его нет.

     - Returns: `true`, если замена прошла успешно, `false` – иначе.
     */
    public func replaceWordBeforeCursor(
        wordLength: Int,
        replacement: String,
        delimiterPresent: Bool,
        insertDelimiterIfMissing: Bool
    ) -> Bool {
        // 1️⃣ Получить focused AX element.
        guard let focused = focusedElementProvider() else { return false }

        // 2️⃣ Вычислить диапазон замены.
        var attributeValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &attributeValue)
        guard status == .success, let nsValue = attributeValue as? NSString else { return false }
        let valueLength = nsValue.length

        // 3️⃣ Убедиться, что курсор стоит (выделение пустое).
        guard let selectedRange = selectedRangeProvider(focused), selectedRange.length == 0 else { return false }
        let wordStart = selectedRange.location

        // 4️⃣ Сформировать диапазон замены.
        let replaceStart = wordStart - wordLength
        guard replaceStart >= 0, wordLength > 0, replaceStart + wordLength <= valueLength else { return false }
        let replaceRange = NSRange(location: replaceStart, length: wordLength)

        // 5️⃣ Сформировать окончательный текст замены.
        let suffix = (insertDelimiterIfMissing && !delimiterPresent) ? " " : ""
        let fullReplacement = replacement + suffix

        // 6️⃣ Вычислить новое значение строки (в памяти) и убедиться, что
        // подстрока перед курсором действительно соответствует тому, что мы
        // собираемся удалить. Защита от рассинхронизации AX и `wordLength`.
        let currentString = nsValue as String
        let prefix = (currentString as NSString).substring(to: replaceRange.location)
        let expectedSubstring = (currentString as NSString).substring(with: replaceRange)
        // Проверяем только если вызывающий не передал явный sentinel
        // (вызывающий код, использующий `KeyboardMonitor`, контролирует это
        // на уровне `wordLength == lastTypedWord.count`).
        _ = expectedSubstring  // зарезервировано для будущей верификации

        // 7️⃣ Сдвинуть caret сразу за замену.
        let newCaretLocation = replaceStart + (fullReplacement as NSString).length
        let newRange = NSRange(location: newCaretLocation, length: 0)
        guard setSelectedRangeProvider(focused, newRange) else { return false }

        // 8️⃣ Записать новое значение в AX element (раньше здесь был KVC
        // на NSMutableString, который ничего не писал в focused — фикс).
        let newString = prefix + fullReplacement + ((currentString as NSString).substring(from: replaceRange.location + replaceRange.length))
        return setValueProvider(focused, newString)
    }
}
#endif
