import SwiftUI
import UIKit

struct CardEditView: View {
    @Environment(\.dismiss) private var dismiss
    let card: Card?
    var isNew: Bool = false
    var onSave: (_ front: String, _ back: String, _ tags: [String]) -> Void

    @State private var front: String = ""
    @State private var back: String = ""
    @State private var tagsText: String = ""
    @State private var frontSelection = NSRange(location: 0, length: 0)

    private var spokenPreview: String {
        guard ClozeParser.containsCloze(front) else {
            return AnkiHTMLCleaner.plainText(from: front)
        }
        let n = card?.clozeNumber ?? ClozeParser.clozeNumbers(in: front).first ?? 1
        return ClozeParser.spokenQuestion(from: front, clozeNumber: n)
    }

    private var displayPreview: String {
        guard ClozeParser.containsCloze(front) else {
            return AnkiHTMLCleaner.plainText(from: front)
        }
        let n = card?.clozeNumber ?? ClozeParser.clozeNumbers(in: front).first ?? 1
        return ClozeParser.displayQuestion(from: front, clozeNumber: n)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Highlight a word, then tap Cloze — voice will read it as “blank”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SelectableTextEditor(text: $front, selectedRange: $frontSelection)
                        .frame(minHeight: 140)
                    Button {
                        applyClozeToSelection()
                    } label: {
                        Label("Make Cloze from Selection", systemImage: "rectangle.and.pencil.and.ellipsis")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RVTheme.seafoam)
                    .disabled(frontSelection.length == 0)
                } header: {
                    Text("Question / Front")
                }

                Section("Answer / Back") {
                    TextField("Back (optional for cloze)", text: $back, axis: .vertical)
                        .lineLimit(3...10)
                }

                Section("Tags") {
                    TextField("Comma-separated tags", text: $tagsText)
                }

                if ClozeParser.containsCloze(front) {
                    Section("Voice preview") {
                        LabeledContent("Screen") {
                            Text(displayPreview)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Spoken") {
                            Text(spokenPreview)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(RVTheme.seafoam)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Card" : "Edit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Cloze") { applyClozeToSelection() }
                        .disabled(frontSelection.length == 0)
                    Button("Save") {
                        let tags = tagsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(front, back, tags)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let card {
                    front = card.front
                    back = card.back
                    tagsText = card.tags.joined(separator: ", ")
                }
            }
        }
    }

    private func applyClozeToSelection() {
        let result = ClozeEditorSupport.wrapSelection(in: front, utf16Range: frontSelection)
        front = result.text
        if let range = result.newUTF16Range {
            frontSelection = range
        }
    }
}

// MARK: - Selection-aware text editor

private struct SelectableTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.keyboardDismissMode = .interactive
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.selectedRange != selectedRange,
           selectedRange.location != NSNotFound,
           NSMaxRange(selectedRange) <= (uiView.text as NSString).length {
            uiView.selectedRange = selectedRange
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextEditor

        init(_ parent: SelectableTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }
    }
}
