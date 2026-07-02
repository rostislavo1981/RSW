import Foundation
import SwitcherCore

/**
A small, pure struct that holds the currently typed word and provides helpers.
It does **not** depend on any UIKit/AppKit APIs – it can be unit‑tested
outside of the KeyboardMonitor.
*/
public struct WordBuffer {
    /// The characters that have been typed but not yet submitted.
    private var characters: String = ""
    
    /// The word that finished after the most recent space/ punctuation.
    ///
    /// This is the value used to attempt conversion. It is reset after we
    /// attempt replacement.
    public var submittedWord: String {
        // Return a copy to keep internal state immutable from outside.
        return characters
    }
    
    /// Appends a character to the current buffered word.
    ///
    /// The method is deliberately small and self‑contained – it can be
    /// called from anywhere without side effects.
    mutating func append(_ newChar: Character) {
        characters.append(newChar)
    }
    
    /// Resets the stored buffer. Call this when:
    ///   * a word has been submitted,
    ///   * the user typed a back‑space,
    ///   * a terminator (space, punctuation, etc.) arrives,
    ///   * the user switches to a different app.
    mutating func reset() {
        characters.removeAll()
    }
    
    /// Returns the current buffered word.
    public var currentWord: String {
        return characters
    }
}