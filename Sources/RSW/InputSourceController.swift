import Carbon
import Foundation
import SwitcherCore

final class InputSourceController {
    func select(_ language: KeyboardLanguage) {
        let desiredCode = language == .russian ? "ru" : "en"
        let properties: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true
        ]

        guard let sources = TISCreateInputSourceList(properties as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else {
            return
        }

        for source in sources {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
            else { continue }
            let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
            if languages?.contains(where: { $0.hasPrefix(desiredCode) }) == true {
                TISSelectInputSource(source)
                return
            }
        }
    }
}
