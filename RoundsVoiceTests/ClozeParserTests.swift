import Testing
@testable import RoundsVoice

struct ClozeParserTests {
    @Test func detectsClozeMarkup() {
        #expect(ClozeParser.containsCloze("{{c1::Vancomycin}} binds {{c2::D-Ala-D-Ala}}"))
        #expect(!ClozeParser.containsCloze("What is metformin?"))
    }

    @Test func extractsClozeNumbers() {
        let numbers = ClozeParser.clozeNumbers(in: "{{c1::Vancomycin}} binds {{c2::D-Ala-D-Ala}}")
        #expect(numbers == [1, 2])
    }

    @Test func buildsSpokenQuestionAndAnswerForC1() {
        let note = "{{c1::Vancomycin}} binds {{c2::D-Ala-D-Ala}}"
        let question = ClozeParser.spokenQuestion(from: note, clozeNumber: 1)
        let display = ClozeParser.displayQuestion(from: note, clozeNumber: 1)
        let answer = ClozeParser.spokenAnswer(from: note, clozeNumber: 1)

        #expect(question.contains("blank"))
        #expect(!display.contains("blank"))
        #expect(display.contains("[...]"))
        #expect(question.contains("D-Ala-D-Ala") || question.contains("binds"))
        #expect(!question.contains("Vancomycin"))
        #expect(answer == "Vancomycin")
    }

    @Test func buildsSpokenQuestionAndAnswerForC2() {
        let note = "{{c1::Vancomycin}} binds {{c2::D-Ala-D-Ala}}"
        let question = ClozeParser.spokenQuestion(from: note, clozeNumber: 2)
        let answer = ClozeParser.spokenAnswer(from: note, clozeNumber: 2)

        #expect(question.contains("Vancomycin"))
        #expect(question.contains("blank"))
        #expect(answer == "D-Ala-D-Ala")
    }

    @Test func expandsMultiBlankIntoOneCardPerDeletion() {
        let cards = ClozeParser.expandToCards(
            noteText: "{{c1::Vancomycin}} binds {{c2::D-Ala-D-Ala}}",
            tags: ["antibiotics"],
            deckName: "AnKing Step 1"
        )
        #expect(cards.count == 2)
        #expect(cards.map(\.clozeOrdinal) == [0, 1])
        #expect(cards.allSatisfy { $0.cardType == .cloze })
        // First card: only one spoken blank; second answer omitted from speech.
        let q0 = cards[0].spokenQuestion
        #expect(q0.components(separatedBy: "blank").count - 1 == 1)
        #expect(cards[0].spokenAnswer == "Vancomycin")
        #expect(cards[1].spokenAnswer == "D-Ala-D-Ala")
    }

    @Test func sharedClozeNumberIsOneBlankAtATime() {
        let note = "present with {{c1::hyperthyroidism}}, then {{c1::hypothyroid}} state"
        let cards = ClozeParser.expandToCards(
            noteText: note,
            tags: [],
            deckName: "AnKing"
        )
        #expect(cards.count == 2)

        let display0 = cards[0].displayQuestion
        #expect(display0.contains("[...]"))
        #expect(display0.contains("⋯"))
        #expect(!display0.replacingOccurrences(of: "[...]", with: "").contains("[...]"))

        let spoken0 = cards[0].spokenQuestion
        #expect(spoken0.components(separatedBy: "blank").count - 1 == 1)
        #expect(cards[0].spokenAnswer == "hyperthyroidism")
        #expect(!spoken0.localizedCaseInsensitiveContains("hyperthyroidism"))

        let spoken1 = cards[1].spokenQuestion
        #expect(spoken1.contains("hyperthyroidism"))
        #expect(spoken1.components(separatedBy: "blank").count - 1 == 1)
        #expect(cards[1].spokenAnswer == "hypothyroid")
    }

    @Test func supportsClozeHints() {
        let note = "Drug of choice is {{c1::vancomycin::antibiotic}}"
        let question = ClozeParser.spokenQuestion(from: note, clozeNumber: 1)
        let display = ClozeParser.displayQuestion(from: note, clozeNumber: 1)
        #expect(question.contains("blank"))
        #expect(!question.contains("antibiotic"))
        #expect(display.contains("[antibiotic]"))
        #expect(!display.contains("blank"))
    }

    @Test func sanitizeSpokenScrubsLeakedMarkup() {
        let dirty = "May present with {{c1::hyperthyroidism}} then cloze deletion later"
        let clean = ClozeParser.sanitizeSpoken(dirty)
        #expect(clean.contains("blank"))
        #expect(!clean.contains("{{"))
        #expect(!clean.localizedCaseInsensitiveContains("cloze deletion"))
        #expect(!clean.contains("hyperthyroidism"))
    }
}

struct HeuristicGraderTests {
    @Test func acceptsEquivalentMetforminAnswer() async throws {
        let grader = HeuristicAnswerGrader()
        let result = try await grader.gradeAnswer(
            question: "What is the mechanism of action of metformin?",
            expectedAnswer: "Activates AMPK and decreases hepatic gluconeogenesis.",
            userAnswer: "It decreases hepatic gluconeogenesis through AMPK activation."
        )
        #expect(result.isCorrect)
        #expect(result.score >= 50)
    }

    @Test func rejectsVagueAnswer() async throws {
        let grader = HeuristicAnswerGrader()
        let result = try await grader.gradeAnswer(
            question: "What is the mechanism of action of metformin?",
            expectedAnswer: "Activates AMPK and decreases hepatic gluconeogenesis.",
            userAnswer: "It helps with diabetes."
        )
        #expect(!result.isCorrect)
    }
}

struct LLMGradeParsingTests {
    @Test func parsesProfessorJSON() throws {
        let raw = #"{"isCorrect":true,"confidence":0.92,"feedback":"Correct.","score":94}"#
        let result = try LLMAnswerGrader.parseGrade(from: raw)
        #expect(result.isCorrect)
        #expect(result.score == 94)
        #expect(result.feedback == "Correct.")
    }

    @Test func stripsMarkdownFences() throws {
        let raw = """
        ```json
        {"isCorrect":false,"confidence":0.8,"feedback":"Missing AMPK.","score":40}
        ```
        """
        let result = try LLMAnswerGrader.parseGrade(from: raw)
        #expect(!result.isCorrect)
        #expect(result.feedback == "Missing AMPK.")
    }
}

struct VoiceCommandTests {
    @Test func detectsDontKnowVariants() {
        #expect(VoiceCommand.detect(in: "I don't know") == .dontKnow)
        #expect(VoiceCommand.detect(in: "I don't know.") == .dontKnow)
        #expect(VoiceCommand.detect(in: "I don't know!") == .dontKnow)
        #expect(VoiceCommand.detect(in: "um I don't know") == .dontKnow)
        #expect(VoiceCommand.detect(in: "I do not know") == .dontKnow)
        #expect(VoiceCommand.detect(in: "I don't know the answer") == .dontKnow)
        #expect(VoiceCommand.detect(in: "idk") == .dontKnow)
        #expect(VoiceCommand.detect(in: "I'm not sure") == .dontKnow)
        #expect(VoiceCommand.detect(in: "skip") == .skip)
        #expect(VoiceCommand.detect(in: "repeat") == .repeat)
    }

    @Test func doesNotTreatPartialAnswersAsDontKnow() {
        #expect(VoiceCommand.detect(in: "I don't know if it's AMPK") == nil)
        #expect(VoiceCommand.detect(in: "not sure about the dose") == nil)
    }
}
