import SwiftUI

struct CardEditView: View {
    @Environment(\.dismiss) private var dismiss
    let card: Card
    var onSave: (_ front: String, _ back: String, _ tags: [String]) -> Void

    @State private var front: String = ""
    @State private var back: String = ""
    @State private var tagsText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Front", text: $front, axis: .vertical)
                        .lineLimit(4...12)
                }
                Section("Answer") {
                    TextField("Back", text: $back, axis: .vertical)
                        .lineLimit(3...10)
                }
                Section("Tags") {
                    TextField("Comma-separated tags", text: $tagsText)
                }
                if card.cardType == .cloze {
                    Section {
                        Text("Cloze markup in the front field is preserved. Use {{c1::…}} style deletions.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
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
                front = card.front
                back = card.back
                tagsText = card.tags.joined(separator: ", ")
            }
        }
    }
}

extension Card: Identifiable {}
