import Foundation
import CoreFoundation
import ApplicationServices

/** AXTextReplacement – небольшая оболочка над raw‑AX‑вызовами,
которая знает, как:

1. Вычислить конечную позицию слова перед курсором.
2. Проверить, что длина выделения равна нулю.
3. Сформировать диапазон замены, включая возможный добавочный разделитель.
4. Выполнить `AXUIElementSetAttributeValue` для `kAXValueAttribute`.
5. Сдвинуть caret‑позицию.

Все четыре действия вынесены в три «инъекции», которые можно подменить в
unit‑тестах (фокусирующий элемент, диапазон выделения, функция установки
нового диапазона).*/

public final class AXTextReplacement {
    // MARK: Инъекции (зависимости)
    private let focusedElementProvider: () -> AXUIElement?
    private let selectedRangeProvider: (AXUIElement) -> NSRange?
    private let setSelectedRangeProvider: (AXUIElement, NSRange) -> Bool
    
    // MARK: Делегаты
    public init(
        focusedElementProvider: @escaping () -> AXUIElement?,
        selectedRangeProvider: @escaping (AXUIElement) -> NSRange?,
        setSelectedRangeProvider: @escaping (AXUIElement, NSRange) -> Bool
    ) {
        self.focusedElementProvider = focusedElementProvider
        self.selectedRangeProvider = selectedRangeProvider
        self.setSelectedRangeProvider = setSelectedRangeProvider
    }
    
    // MARK: Public API
    /** \
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
        // `kAXValueAttribute` объявлен в <ApplicationServices/AXEvidence.h>
        var attributeValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &attributeValue)
        guard status == .success, let nsValue = attributeValue as? NSString else { return false }
        let valueLength = nsValue.length
        
        // ---- Определяем позицию начала слова -------------------------------------------------
        guard let selectedRange = selectedRangeProvider(focused), selectedRange.length == 0 else { return false }
        let wordStart = selectedRange.location

        // Если перед словом уже есть delimiter и мы НЕ хотим его вставлять,
        // длина слова остаётся прежней; иначе добавляем пробел в `fullReplacement`
        // и заменяем ровно `wordLength` символов перед курсором. Координаты
        // selectedRange в этом случае не меняются.
        _ = delimiterPresent
        _ = insertDelimiterIfMissing
        
        // ---- Формируем диапазон замены -------------------------------------------------------
        let replaceStart = wordStart - wordLength
        let replaceLength = wordLength
        let replaceRange = NSRange(location: replaceStart, length: replaceLength)
        
        // ---- Формируем окончательный текст замены -------------------------------------------
        let suffix = (insertDelimiterIfMissing && !delimiterPresent) ? " " : ""
        let fullReplacement = replacement + suffix
        
        // ---- Выполняем замену в строке -------------------------------------------------------
        let mutable = NSMutableString(string: (nsValue as String))
        mutable.replaceCharacters(in: replaceRange, with: fullReplacement)

        // ---- Записываем новое значение обратно в AX element ---------------------------------
        let writeStatus = AXUIElementSetAttributeValue(focused,
                                                      kAXValueAttribute as CFString,
                                                      mutable as CFString)
        guard writeStatus == .success else { return false }

        // ---- Устанавливаем новое Selected Text Range -----------------------------------------
        let newCaretLocation = replaceStart + fullReplacement.count
        let newRange = NSRange(location: newCaretLocation, length: 0)
        _ = setSelectedRangeProvider(focused, newRange)
        return true
    }
    
    // MARK: – Helpers used only by unit‑tests
    private func adjustedWordEnd(for focused: AXUIElement,
                                 selectedRange: NSRange,
                                 delimiterPresent: Bool,
                                 insertDelimiterIfMissing: Bool) -> Int {
        // Плохой‑человекская реализация – не используется в основной логике,
        // оставлена лишь для иллюстрации того, как оригинальный алгоритм мог бы
        // выглядеть в вынесённой функции.
        return selectedRange.location
    }
}