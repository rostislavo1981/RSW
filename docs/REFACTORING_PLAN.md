# RSW Refactoring and Improvement Plan

## Context

Current v0.2.17 prioritizes safety after log analysis showed two damaging classes of behavior:

- fallback paths that touched the shared pasteboard could paste stale clipboard contents;
- blind synthetic backspace replacement could delete or rewrite the wrong word when AX context was unavailable or stale.

The current implementation removed pasteboard replacement and disables automatic correction unless AX confirms and applies the replacement. Manual last-word switching still has a limited synthetic fallback, which should be removed or made fully verifiable.

## Code Review Findings to Address

### P1: Remove the remaining synthetic last-word fallback

`KeyboardMonitor.manualSwitchLastWord()` can still call `replaceWordViaSyntheticEvents()` after `distanceFromCursorToWordStart()` succeeds. That helper computes a distance from AX value/range, but it does not verify that the exact substring before the cursor equals `lastTypedWord`. If the cursor moved, the AX value changed, or `lastTypedWord` is stale, synthetic backspaces can still rewrite unrelated text.

Target fix:

- replace the fallback with an AX-only operation, or
- make the fallback verify the exact substring range before posting backspaces, then re-check focus/app identity immediately before posting.

Preferred direction: remove synthetic text replacement entirely outside tests and diagnostics.

### P2: Delete unreachable terminal buffering code

`handle()` returns early for terminal apps before `focusedAppPrefersBufferedReplacement()` is checked, while `focusedAppPrefersBufferedReplacement()` is currently equivalent to `focusedAppIsTerminal()`. This makes `handleBufferedTerminalInput()` dead code.

Target fix:

- remove `handleBufferedTerminalInput()` and `focusedAppPrefersBufferedReplacement()`, or
- reintroduce terminal buffering deliberately behind a setting with tests and documentation.

Preferred direction: delete it; terminals are intentionally pass-through.

### P2: Split KeyboardMonitor responsibilities

`KeyboardMonitor` owns event tap lifecycle, word buffering, manual switch hotkeys, AX replacement, synthetic event posting, terminal policy, and logging. This makes safety reasoning difficult.

Target split:

- `KeyboardEventTap`: lifecycle and CGEvent callback only.
- `WordBuffer`: current word and last typed word state.
- `ReplacementEngine`: AX-only replacement primitives.
- `ManualSwitchController`: selected-text and last-word switching.
- `AppPolicy`: terminal/excluded-app rules.
- `KeyboardMonitor`: orchestration only.

### P3: Replace ad-hoc scoring with explicit decision diagnostics

`LayoutConverter` now mixes dictionary checks, scoring, and suspicious-character heuristics. This is hard to tune from logs.

Target fix:

- return an internal `Decision` in tests/diagnostics with source language, target language, scores, dictionary hits, and rejection reason;
- keep public `convert()` returning `Conversion?`.

## Implementation Plan

### Phase 1: Safety cleanup

1. Remove `last_word_synthetic` fallback from manual switching.
2. Remove `replaceWordViaSyntheticEvents()`, `postKey()`, and free-form `postText()` if no longer needed.
3. Remove dead terminal buffering code.
4. Update diagnostics so failed manual fallback logs `manual_switch_failed` with an explicit reason.
5. Add regression tests around manual-switch state where possible using extracted pure helpers.

### Phase 2: Architecture split

1. Extract `WordBuffer` with unit tests for letters, delimiters, backspace, modifiers, and app switches.
2. Extract `AppPolicy` with terminal bundle identifiers and excluded app/key decisions.
3. Extract `AXTextReplacement` with range calculation helpers that can be tested without live AX.
4. Keep `KeyboardMonitor` as a small coordinator.

### Phase 3: Converter tuning

1. Add a `ConversionDecision` test-only/debug API.
2. Build a corpus from sanitized diagnostic logs: accepted corrections, skipped words, and known false positives.
3. Add table-driven tests for false positives and false negatives.
4. Move built-in dictionaries to resource files or generated Swift constants with source comments.

### Phase 4: Runtime quality

1. Add app-level allow/deny policy for auto-correction, starting with Electron editors where AX is unreliable.
2. Add a visible diagnostics command/menu item: open current log file and show latest failure reason.
3. Add launch-agent/app-bundle documentation for persistent logging, separate from `swift run`.

## Acceptance Criteria

- No code path uses `NSPasteboard` or menu Paste for replacement.
- No automatic path posts synthetic backspaces or text.
- Manual switching never posts backspaces unless the exact target range is verified immediately before posting; preferably it never posts them at all.
- `swift run TestRunner` passes.
- `swift build -c release` passes.
- README accurately describes disabled fallback behavior and known unsupported apps.
