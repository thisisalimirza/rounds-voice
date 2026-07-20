import Foundation

/// Helpers for authoring Anki-style cloze deletions in the card editor.
enum ClozeEditorSupport {
    /// Next cloze number to use when wrapping a selection (`c1`, `c2`, …).
    static func nextClozeNumber(in text: String) -> Int {
        (ClozeParser.clozeNumbers(in: text).max() ?? 0) + 1
    }

    /// Wraps `selected` as `{{cN::selected}}`. If `selected` is empty, returns text unchanged.
    static func wrapSelection(
        in text: String,
        selection: Range<String.Index>,
        clozeNumber: Int? = nil
    ) -> (text: String, newSelection: Range<String.Index>?) {
        guard selection.lowerBound < selection.upperBound else {
            return (text, selection)
        }
        let selected = String(text[selection])
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (text, selection)
        }
        // Don't double-wrap an already-complete cloze token.
        if trimmed.hasPrefix("{{c"), trimmed.hasSuffix("}}"), ClozeParser.containsCloze(trimmed) {
            return (text, selection)
        }

        let n = clozeNumber ?? nextClozeNumber(in: text)
        let wrapped = "{{c\(n)::\(selected)}}"
        var result = text
        result.replaceSubrange(selection, with: wrapped)
        if let start = result.range(of: wrapped)?.lowerBound {
            let end = result.index(start, offsetBy: wrapped.count)
            return (result, start..<end)
        }
        return (result, nil)
    }

    /// Convenience for UTF-16 / UITextView NSRange.
    static func wrapSelection(
        in text: String,
        utf16Range: NSRange,
        clozeNumber: Int? = nil
    ) -> (text: String, newUTF16Range: NSRange?) {
        guard let range = Range(utf16Range, in: text) else {
            return (text, utf16Range)
        }
        let result = wrapSelection(in: text, selection: range, clozeNumber: clozeNumber)
        guard let newSel = result.newSelection else {
            return (result.text, nil)
        }
        let lower = result.text.utf16.distance(from: result.text.utf16.startIndex, to: newSel.lowerBound)
        let len = result.text.utf16.distance(from: newSel.lowerBound, to: newSel.upperBound)
        return (result.text, NSRange(location: lower, length: len))
    }
}
