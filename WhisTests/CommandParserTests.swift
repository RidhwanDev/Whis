import Testing
@testable import Whis

struct CommandParserTests {
    private let parser = CommandParser()

    @Test("Weight command variants")
    func weightCommands() {
        #expect(parser.parse("weight 80", lastEditedField: nil) == .recognized(.setWeight(80)))
        #expect(parser.parse("80 kg", lastEditedField: nil) == .recognized(.setWeight(80)))
        #expect(parser.parse("80 kilos", lastEditedField: nil) == .recognized(.setWeight(80)))
    }

    @Test("Rep command variants")
    func repCommands() {
        #expect(parser.parse("8 reps", lastEditedField: nil) == .recognized(.setReps(8)))
        #expect(parser.parse("reps 8", lastEditedField: nil) == .recognized(.setReps(8)))
    }

    @Test("Robust speech-like variants")
    func robustVariants() {
        #expect(parser.parse("wait 80", lastEditedField: nil) == .recognized(.setWeight(80)))
        #expect(parser.parse("10 rep", lastEditedField: nil) == .recognized(.setReps(10)))
        #expect(parser.parse("10 rep.", lastEditedField: nil) == .recognized(.setReps(10)))
        #expect(parser.parse("eight reps", lastEditedField: nil) == .recognized(.setReps(8)))
        #expect(parser.parse("to reps", lastEditedField: nil) == .recognized(.setReps(2)))
        #expect(parser.parse("for reps", lastEditedField: nil) == .recognized(.setReps(4)))
    }

    @Test("Done and done with reps")
    func doneCommands() {
        #expect(parser.parse("done", lastEditedField: nil) == .recognized(.done))
        #expect(parser.parse("done 8", lastEditedField: nil) == .recognized(.doneWithReps(8)))
    }

    @Test("Navigation and undo")
    func navCommands() {
        #expect(parser.parse("next", lastEditedField: nil) == .recognized(.next))
        #expect(parser.parse("previous", lastEditedField: nil) == .recognized(.previous))
        #expect(parser.parse("undo", lastEditedField: nil) == .recognized(.undo))
        #expect(parser.parse("clear", lastEditedField: nil) == .recognized(.clear))
    }

    @Test("Rest commands")
    func restCommands() {
        #expect(parser.parse("rest 90", lastEditedField: nil) == .recognized(.rest(90)))
        #expect(parser.parse("rest 2 minutes", lastEditedField: nil) == .recognized(.rest(120)))
        #expect(parser.parse("stop rest", lastEditedField: nil) == .recognized(.stopRest))
    }

    @Test("Ambiguity rules")
    func ambiguityRules() {
        #expect(parser.parse("8", lastEditedField: .reps) == .recognized(.setReps(8)))
        #expect(parser.parse("8", lastEditedField: .weight) == .ambiguousNumber(8))
        #expect(parser.parse("80.5", lastEditedField: nil) == .recognized(.setWeight(80.5)))
    }

    @Test("Unrecognized command")
    func unrecognized() {
        #expect(parser.parse("banana", lastEditedField: nil) == .unrecognized)
    }
}
