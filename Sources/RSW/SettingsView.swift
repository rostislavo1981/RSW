import SwiftUI
import SwitcherCore
import Carbon.HIToolbox

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var recordingKey = false
    @State private var showKeyPicker = false

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("Основные", systemImage: "gear") }

            HotkeyTab(settings: settings, recordingKey: $recordingKey)
                .tabItem { Label("Горячие клавиши", systemImage: "keyboard") }

            ExcludedKeysTab(settings: settings, showKeyPicker: $showKeyPicker)
                .tabItem { Label("Исключения", systemImage: "xmark.circle") }

            DictionaryTab()
                .tabItem { Label("Словарь", systemImage: "book") }
        }
        .frame(width: 480, height: 360)
    }
}

struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Автопереключение", isOn: $settings.autoSwitchEnabled)

            Stepper(
                "Минимальная длина слова: \(settings.minWordLength)",
                value: $settings.minWordLength,
                in: 2...10
            )

            Toggle("Показывать подсказку при исправлении", isOn: $settings.showTooltip)

            Toggle("Запуск при входе в систему", isOn: $settings.launchAtLogin)
        }
        .padding()
    }
}

struct HotkeyTab: View {
    @ObservedObject var settings: AppSettings
    @Binding var recordingKey: Bool

    var body: some View {
        Form {
            Section("Ручное переключение выделенного текста") {
                Picker("Способ вызова", selection: $settings.manualSwitchTrigger) {
                    ForEach(ManualSwitchTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                .pickerStyle(.radioGroup)

                if settings.manualSwitchTrigger == .doubleModifier {
                    Picker("Модификатор", selection: $settings.manualSwitchModifierKey) {
                        ForEach(ManualSwitchModifier.allCases) { mod in
                            Text(mod.title).tag(mod.rawValue)
                        }
                    }
                    Text("Дважды быстро нажмите выбранный модификатор, чтобы переключить выделенный текст (или последнее слово).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    HStack {
                        Text("Клавиша:")
                        Spacer()
                        Button(action: { recordingKey = true }) {
                            Text(keyName(settings.manualSwitchKeyCode, modifiers: settings.manualSwitchModifiers))
                                .frame(minWidth: 120)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        if recordingKey {
                            Text("Нажмите клавишу...")
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("Нажмите комбинацию с модификатором (например ⌃⇧S) для переключения выделенного текста.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyRecorded)) { notification in
            guard recordingKey else { return }
            if let info = notification.userInfo as? [String: Any],
               let code = info["keyCode"] as? Int,
               let mods = info["modifiers"] as? Int {
                settings.manualSwitchKeyCode = code
                settings.manualSwitchModifiers = mods
                recordingKey = false
            }
        }
        .overlay(
            recordingKey ? KeyRecorderOverlay() : nil
        )
    }
}

struct KeyRecorderOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = KeyRecorderView()
        DispatchQueue.main.async { view.makeKey() }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            (nsView as? KeyRecorderView)?.makeKey()
        }
    }
}

class KeyRecorderView: NSView {
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
        guard monitor == nil else { return true }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let mods = Int(event.modifierFlags.rawValue & UInt(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue))
            NotificationCenter.default.post(
                name: .keyRecorded,
                object: nil,
                userInfo: ["keyCode": code, "modifiers": mods]
            )
            if let m = self.monitor {
                NSEvent.removeMonitor(m)
                self.monitor = nil
            }
            return nil
        }
        return true
    }

    func makeKey() {
        window?.makeFirstResponder(self)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

extension Notification.Name {
    static let keyRecorded = Notification.Name("keyRecorded")
}

struct ExcludedKeysTab: View {
    @ObservedObject var settings: AppSettings
    @Binding var showKeyPicker: Bool

    var body: some View {
        Form {
            Section("Клавиши, не сбрасывающие текущее слово") {
                ForEach(settings.excludedKeys, id: \.self) { code in
                    HStack {
                        Text(keyName(code, modifiers: 0))
                            .frame(width: 120)
                        Spacer()
                        Button(action: { removeKey(code) }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button(action: { showKeyPicker = true }) {
                    Label("Добавить клавишу", systemImage: "plus")
                }
            }

            Section {
                Text("Если клавиша в списке — нажатие не прерывает текущее слово. Например: Shift, Caps Lock.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .sheet(isPresented: $showKeyPicker) {
            KeyPickerSheet(selectedKeys: $settings.excludedKeys, isPresented: $showKeyPicker)
        }
    }

    private func removeKey(_ code: Int) {
        settings.excludedKeys.removeAll { $0 == code }
    }
}

struct KeyPickerSheet: View {
    @Binding var selectedKeys: [Int]
    @Binding var isPresented: Bool
    @State private var recording = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Нажмите клавишу для добавления")
                .font(.headline)

            if recording {
                Text("Ожидание нажатия...")
                    .foregroundColor(.secondary)
            } else {
                Button("Начать запись") { recording = true }
                    .buttonStyle(.borderedProminent)
            }

            Button("Готово") { isPresented = false }
                .padding(.top)
        }
        .frame(width: 300, height: 150)
        .overlay(
            recording ? KeyRecorderOverlay() : nil
        )
        .onReceive(NotificationCenter.default.publisher(for: .keyRecorded)) { notification in
            guard recording else { return }
            if let info = notification.userInfo as? [String: Any],
               let code = info["keyCode"] as? Int,
               !selectedKeys.contains(code) {
                selectedKeys.append(code)
            }
            recording = false
            isPresented = false
        }
    }
}

struct DictionaryTab: View {
    @State private var newWord = ""
    @State private var selectedLanguage: KeyboardLanguage = .russian

    var body: some View {
        Form {
            Section("Добавить слово") {
                HStack {
                    TextField("Слово", text: $newWord)
                        .textFieldStyle(.roundedBorder)

                    Picker("", selection: $selectedLanguage) {
                        Text("RU").tag(KeyboardLanguage.russian)
                        Text("EN").tag(KeyboardLanguage.english)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)

                    Button("Добавить") {
                        guard !newWord.isEmpty else { return }
                        WordDictionary.shared.add(newWord.lowercased(), language: selectedLanguage)
                        newWord = ""
                    }
                    .disabled(newWord.isEmpty)
                }
            }

            Section("Статистика") {
                HStack {
                    Text("Русских слов:")
                    Spacer()
                    Text("\(WordDictionary.shared.russianCount)")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Английских слов:")
                    Spacer()
                    Text("\(WordDictionary.shared.englishCount)")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

func keyName(_ code: Int, modifiers: Int) -> String {
    let modFlags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
    var name = ""

    if modFlags.contains(.control) { name += "⌃" }
    if modFlags.contains(.option) { name += "⌥" }
    if modFlags.contains(.command) { name += "⌘" }
    if modFlags.contains(.shift) { name += "⇧" }

    let commonKeys: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
        6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        50: "`"
    ]
    let specialKeys: [Int: String] = [
        36: "Return", 49: "Space", 51: "Delete", 53: "Esc",
        48: "Tab", 123: "←", 124: "→", 125: "↓", 126: "↑",
        56: "Shift", 59: "Ctrl", 58: "⌥", 55: "⌘",
        60: "⇧R", 61: "⌥R", 63: "⌘R",
        96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 109: "F10",
        111: "F12", 113: "F14", 115: "Home", 116: "PageUp",
        117: "Forward", 119: "End", 120: "F2", 121: "PageDown",
        122: "F1", 127: "F4"
    ]

    name += specialKeys[code] ?? commonKeys[code] ?? "#\(code)"
    return name
}
