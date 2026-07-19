import Testing
@testable import RoundsVoice

struct AnKingNoteMapperTests {
    @Test func mapsAnKingClozeTextAndExtra() {
        let noteType = AnkiCollectionReader.NoteType(
            id: 1,
            name: "AnKing",
            type: 1,
            fieldNames: ["Text", "Extra", "Personal Notes", "Missed Questions", "One by one"]
        )
        let collection = AnkiCollectionReader.Collection(
            noteTypes: [1: noteType],
            decks: [1: .init(id: 1, name: "AnKing Step 1")],
            notes: [
                .init(
                    id: 42,
                    modelID: 1,
                    tags: ["#AK_Step1_v12", "pharmacology"],
                    fields: [
                        "{{c1::Vancomycin}} binds {{c2::D-Ala-D-Ala}}",
                        "Glycopeptide antibiotic.",
                        "",
                        "",
                        ""
                    ]
                )
            ],
            primaryDeckName: "AnKing Step 1"
        )

        let result = AnKingNoteMapper.map(collection: collection)
        #expect(result.notes.count == 1)
        #expect(result.notes[0].cardType == .cloze)
        #expect(result.notes[0].front.contains("{{c1::Vancomycin}}"))
        #expect(result.notes[0].back.contains("Glycopeptide"))
        #expect(result.skippedImageOcclusion == 0)
    }

    @Test func skipsImageOcclusionNotes() {
        let ioType = AnkiCollectionReader.NoteType(
            id: 2,
            name: "Image Occlusion Enhanced",
            type: 0,
            fieldNames: ["Image", "Occlusion", "Header", "Back Extra"]
        )
        let anking = AnkiCollectionReader.NoteType(
            id: 1,
            name: "AnKing",
            type: 1,
            fieldNames: ["Text", "Extra"]
        )
        let collection = AnkiCollectionReader.Collection(
            noteTypes: [1: anking, 2: ioType],
            decks: [1: .init(id: 1, name: "Mixed")],
            notes: [
                .init(id: 1, modelID: 2, tags: [], fields: ["img", "mask", "header", "extra"]),
                .init(
                    id: 2,
                    modelID: 1,
                    tags: [],
                    fields: ["Metformin activates {{c1::AMPK}}", ""]
                )
            ],
            primaryDeckName: "Mixed"
        )

        let result = AnKingNoteMapper.map(collection: collection)
        #expect(result.skippedImageOcclusion == 1)
        #expect(result.notes.count == 1)
        #expect(result.notes[0].cardType == .cloze)
    }

    @Test func mapsBasicFrontBack() {
        let basic = AnkiCollectionReader.NoteType(
            id: 3,
            name: "Basic",
            type: 0,
            fieldNames: ["Front", "Back"]
        )
        let collection = AnkiCollectionReader.Collection(
            noteTypes: [3: basic],
            decks: [1: .init(id: 1, name: "Basics")],
            notes: [
                .init(
                    id: 9,
                    modelID: 3,
                    tags: [],
                    fields: ["What enzyme does allopurinol inhibit?", "Xanthine oxidase"]
                )
            ],
            primaryDeckName: "Basics"
        )

        let result = AnKingNoteMapper.map(collection: collection)
        #expect(result.notes.count == 1)
        #expect(result.notes[0].cardType == .basic)
        #expect(result.notes[0].front.contains("allopurinol"))
        #expect(result.notes[0].back.contains("Xanthine"))
    }

    @Test func stripsHTMLButKeepsCloze() {
        let html = #"<div>{{c1::Isoniazid}} causes vitamin {{c2::B6}} deficiency</div>"#
        let plain = AnkiHTMLCleaner.preserveClozePlainText(from: html)
        #expect(plain.contains("{{c1::Isoniazid}}"))
        #expect(plain.contains("{{c2::B6}}"))
        #expect(!plain.contains("<div>"))
    }

    @Test func supportsAnKingOneByOneSequentialExpansion() {
        let text = "Confirm ROM by: {{c1::pooling}}, {{c1::nitrazine}}, {{c1::ferning}}"
        let cards = ClozeParser.expandToCards(
            noteText: text,
            tags: [],
            deckName: "AnKing Step Deck",
            oneByOne: true
        )
        #expect(cards.count == 3)
        #expect(cards[0].clozeOrdinal == 0)
        #expect(cards[0].spokenAnswer.lowercased().contains("pooling"))
        #expect(cards[1].spokenQuestion.contains("pooling"))
        #expect(cards[1].spokenAnswer.lowercased().contains("nitrazine"))
        #expect(cards[2].spokenAnswer.lowercased().contains("ferning"))
    }

    @Test func autoSequencesSharedClozeNumbers() {
        let text = "Layers: {{c1::glomerulosa}}, {{c1::fasciculata}}, {{c1::reticularis}}"
        let cards = ClozeParser.expandToCards(
            noteText: text,
            tags: [],
            deckName: "AnKing"
        )
        #expect(cards.count == 3)
        #expect(cards.allSatisfy { $0.clozeOrdinal != nil })
    }

    @Test func detectsOneByOneFieldValues() {
        #expect(AnKingNoteMapper.isOneByOneEnabled("y"))
        #expect(AnKingNoteMapper.isOneByOneEnabled("y<br>"))
        #expect(AnKingNoteMapper.isOneByOneEnabled("yes"))
        #expect(!AnKingNoteMapper.isOneByOneEnabled(""))
        #expect(!AnKingNoteMapper.isOneByOneEnabled(","))
    }

    @Test func detectsAnKingIONoteType() {
        let io = AnkiCollectionReader.NoteType(
            id: 1,
            name: "IO-one by one (AnKing Step Deck / AnKingMed)",
            type: 0,
            fieldNames: ["Image", "Header", "Extra", "I0"]
        )
        #expect(AnKingNoteMapper.isImageOcclusion(noteType: io))

        let overhaul = AnkiCollectionReader.NoteType(
            id: 2,
            name: "AnKingOverhaul (AnKing Step Deck / AnKingMed)",
            type: 1,
            fieldNames: ["Text", "Extra", "One by one"]
        )
        #expect(!AnKingNoteMapper.isImageOcclusion(noteType: overhaul))
    }
}
