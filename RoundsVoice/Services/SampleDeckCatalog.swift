import Foundation

/// Curated AnKing-style sample cards for Phase 1 demos and development.
///
/// Content mirrors the style of AnKing Step 1 / Step 2 (mechanisms, first-line
/// treatments, classic associations) without redistributing copyrighted deck text.
enum SampleDeckCatalog {
    static var all: [ImportedDeck] {
        [ankingStep1, ankingStep2, premedBasics]
    }

    static let ankingStep1 = ImportedDeck(
        name: "AnKing Step 1",
        description: "High-yield Step 1 mechanisms and associations for voice review.",
        source: .sample,
        notes: [
            ImportedNote(
                front: "What is the mechanism of action of metformin?",
                back: "Activates AMPK and decreases hepatic gluconeogenesis.",
                tags: ["pharmacology", "endocrine", "#AK_Step1_v12"],
                ankiNoteId: "sample-metformin"
            ),
            ImportedNote(
                front: "What is the mechanism of action of loop diuretics (e.g., furosemide)?",
                back: "Inhibit the Na-K-2Cl cotransporter in the thick ascending limb.",
                tags: ["pharmacology", "renal", "#AK_Step1_v12"],
                ankiNoteId: "sample-loop"
            ),
            ImportedNote(
                front: "{{c1::Vancomycin}} binds {{c2::D-Ala-D-Ala}}",
                back: "",
                tags: ["pharmacology", "antibiotics", "cloze", "#AK_Step1_v12"],
                cardType: .cloze,
                ankiNoteId: "sample-vanco-cloze"
            ),
            ImportedNote(
                front: "Aspirin irreversibly inhibits which enzyme?",
                back: "Cyclooxygenase (COX-1 and COX-2).",
                tags: ["pharmacology", "hematology", "#AK_Step1_v12"],
                ankiNoteId: "sample-aspirin"
            ),
            ImportedNote(
                front: "What organism is associated with rusty sputum pneumonia in alcoholics and elderly?",
                back: "Streptococcus pneumoniae.",
                tags: ["microbiology", "respiratory", "#AK_Step1_v12"],
                ankiNoteId: "sample-strep-pneumo"
            ),
            ImportedNote(
                front: "{{c1::Isoniazid}} causes vitamin {{c2::B6}} deficiency and sideroblastic anemia.",
                back: "",
                tags: ["pharmacology", "TB", "cloze", "#AK_Step1_v12"],
                cardType: .cloze,
                ankiNoteId: "sample-inh-cloze"
            ),
            ImportedNote(
                front: "What is the most common cause of osteomyelitis in sickle cell disease?",
                back: "Salmonella.",
                tags: ["microbiology", "ortho", "#AK_Step1_v12"],
                ankiNoteId: "sample-salmonella"
            ),
            ImportedNote(
                front: "Bethanechol is a {{c1::muscarinic}} agonist used for postoperative ileus and urinary retention.",
                back: "",
                tags: ["pharmacology", "autonomic", "cloze", "#AK_Step1_v12"],
                cardType: .cloze,
                ankiNoteId: "sample-bethanechol"
            ),
            ImportedNote(
                front: "What enzyme does allopurinol inhibit?",
                back: "Xanthine oxidase.",
                tags: ["pharmacology", "rheum", "#AK_Step1_v12"],
                ankiNoteId: "sample-allopurinol"
            ),
            ImportedNote(
                front: "Cushing disease is caused by an ACTH-secreting adenoma of the {{c1::anterior pituitary}}.",
                back: "",
                tags: ["endocrine", "pathology", "cloze", "#AK_Step1_v12"],
                cardType: .cloze,
                ankiNoteId: "sample-cushing"
            ),
            ImportedNote(
                front: "What is the antidote for acetaminophen overdose?",
                back: "N-acetylcysteine.",
                tags: ["pharmacology", "toxicology", "#AK_Step1_v12"],
                ankiNoteId: "sample-nac"
            ),
            ImportedNote(
                front: "Warfarin inhibits vitamin {{c1::K}}-dependent clotting factors {{c2::II, VII, IX, X}}.",
                back: "",
                tags: ["pharmacology", "hematology", "cloze", "#AK_Step1_v12"],
                cardType: .cloze,
                ankiNoteId: "sample-warfarin"
            )
        ]
    )

    static let ankingStep2 = ImportedDeck(
        name: "AnKing Step 2",
        description: "Clinical decision-making cards for clerkships and Step 2 CK.",
        source: .sample,
        notes: [
            ImportedNote(
                front: "First-line treatment for community-acquired pneumonia in a healthy outpatient?",
                back: "Amoxicillin or doxycycline (or a macrolide if local resistance is low).",
                tags: ["medicine", "ID", "#AK_Step2_v12"],
                ankiNoteId: "sample-cap"
            ),
            ImportedNote(
                front: "Next step in management for suspected aortic dissection with hemodynamic instability?",
                back: "Immediate surgical consultation / OR; stabilize blood pressure with beta blockade first if going to imaging.",
                tags: ["surgery", "emergency", "#AK_Step2_v12"],
                ankiNoteId: "sample-dissection"
            ),
            ImportedNote(
                front: "Most appropriate initial imaging for suspected appendicitis in pregnancy?",
                back: "Ultrasound (MRI if ultrasound is nondiagnostic).",
                tags: ["surgery", "OB", "#AK_Step2_v12"],
                ankiNoteId: "sample-appy-preg"
            ),
            ImportedNote(
                front: "{{c1::Metformin}} should be held before giving IV contrast in patients with reduced GFR due to risk of lactic acidosis.",
                back: "",
                tags: ["medicine", "pharmacology", "cloze", "#AK_Step2_v12"],
                cardType: .cloze,
                ankiNoteId: "sample-metformin-contrast"
            ),
            ImportedNote(
                front: "Centor criteria are used to decide testing/treatment for which infection?",
                back: "Group A streptococcal pharyngitis.",
                tags: ["pediatrics", "ENT", "#AK_Step2_v12"],
                ankiNoteId: "sample-centor"
            ),
            ImportedNote(
                front: "First-line pharmacotherapy for alcohol withdrawal?",
                back: "Benzodiazepines (e.g., chlordiazepoxide or lorazepam).",
                tags: ["psychiatry", "emergency", "#AK_Step2_v12"],
                ankiNoteId: "sample-aws"
            )
        ]
    )

    static let premedBasics = ImportedDeck(
        name: "Premed Foundations",
        description: "Foundational physiology and biochem for early learners.",
        source: .sample,
        notes: [
            ImportedNote(
                front: "Where does the Krebs cycle occur in eukaryotic cells?",
                back: "Mitochondrial matrix.",
                tags: ["biochem", "premed"],
                ankiNoteId: "sample-krebs"
            ),
            ImportedNote(
                front: "What ion is primarily responsible for the resting membrane potential?",
                back: "Potassium (K+).",
                tags: ["physiology", "premed"],
                ankiNoteId: "sample-rmp"
            ),
            ImportedNote(
                front: "Hemoglobin binds oxygen cooperatively due to its {{c1::quaternary}} structure.",
                back: "",
                tags: ["biochem", "cloze", "premed"],
                cardType: .cloze,
                ankiNoteId: "sample-hb"
            ),
            ImportedNote(
                front: "Which hormone lowers blood glucose?",
                back: "Insulin.",
                tags: ["physiology", "endocrine", "premed"],
                ankiNoteId: "sample-insulin"
            )
        ]
    )
}
