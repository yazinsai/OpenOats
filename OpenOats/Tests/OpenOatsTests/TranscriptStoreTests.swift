import XCTest
@testable import OpenOatsKit

@MainActor
final class TranscriptStoreTests: XCTestCase {

    private func makeStore() -> TranscriptStore {
        TranscriptStore()
    }

    private func makeUtterance(
        text: String,
        speaker: Speaker = .them,
        timestamp: Date = Date()
    ) -> Utterance {
        Utterance(text: text, speaker: speaker, timestamp: timestamp)
    }

    // MARK: - Append

    func testAppendAddsUtterance() {
        let store = makeStore()
        let u = makeUtterance(text: "Hello world")
        let accepted = store.append(u)
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(store.utterances.first?.text, "Hello world")
    }

    func testAppendMultipleUtterances() {
        let store = makeStore()
        store.append(makeUtterance(text: "First", speaker: .them))
        store.append(makeUtterance(text: "Second", speaker: .you))
        store.append(makeUtterance(text: "Third", speaker: .them))
        XCTAssertEqual(store.utterances.count, 3)
    }

    // MARK: - Clear

    func testClearRemovesAllUtterances() {
        let store = makeStore()
        store.append(makeUtterance(text: "One"))
        store.append(makeUtterance(text: "Two"))
        XCTAssertEqual(store.utterances.count, 2)

        store.clear()
        XCTAssertTrue(store.utterances.isEmpty)
        XCTAssertEqual(store.volatileYouText, "")
        XCTAssertEqual(store.volatileThemText, "")
    }

    func testClearResetsConversationState() {
        let store = makeStore()
        let state = ConversationState(
            currentTopic: "Testing",
            shortSummary: "A test",
            openQuestions: [],
            activeTensions: [],
            recentDecisions: [],
            themGoals: [],
            suggestedAnglesRecentlyShown: [],
            lastUpdatedAt: Date()
        )
        store.updateConversationState(state)
        XCTAssertEqual(store.conversationState.currentTopic, "Testing")

        store.clear()
        XCTAssertEqual(store.conversationState.currentTopic, "")
    }

    // MARK: - Conversation State

    func testUpdateConversationState() {
        let store = makeStore()
        let state = ConversationState(
            currentTopic: "Architecture",
            shortSummary: "Discussing system design",
            openQuestions: ["Which DB?"],
            activeTensions: [],
            recentDecisions: ["Use Swift"],
            themGoals: [],
            suggestedAnglesRecentlyShown: [],
            lastUpdatedAt: Date()
        )
        store.updateConversationState(state)
        XCTAssertEqual(store.conversationState.currentTopic, "Architecture")
        XCTAssertEqual(store.conversationState.shortSummary, "Discussing system design")
        XCTAssertEqual(store.conversationState.openQuestions, ["Which DB?"])
    }

    func testNeedsStateUpdateAfterThemUtterances() {
        let store = makeStore()
        XCTAssertFalse(store.needsStateUpdate)

        store.append(makeUtterance(text: "First thing", speaker: .them))
        XCTAssertFalse(store.needsStateUpdate)

        store.append(makeUtterance(text: "Second thing", speaker: .them))
        XCTAssertTrue(store.needsStateUpdate)
    }

    func testNeedsStateUpdateResetsAfterUpdate() {
        let store = makeStore()
        store.append(makeUtterance(text: "A", speaker: .them))
        store.append(makeUtterance(text: "B", speaker: .them))
        XCTAssertTrue(store.needsStateUpdate)

        store.updateConversationState(.empty)
        XCTAssertFalse(store.needsStateUpdate)
    }

    func testYouUtterancesDoNotTriggerStateUpdate() {
        let store = makeStore()
        store.append(makeUtterance(text: "My reply", speaker: .you))
        store.append(makeUtterance(text: "Another reply", speaker: .you))
        XCTAssertFalse(store.needsStateUpdate)
    }

    // MARK: - Last Them Utterance

    func testLastThemUtteranceReturnsCorrectOne() {
        let store = makeStore()
        store.append(makeUtterance(text: "Them first", speaker: .them))
        store.append(makeUtterance(text: "You reply", speaker: .you))
        store.append(makeUtterance(text: "Them second", speaker: .them))

        XCTAssertEqual(store.lastThemUtterance?.text, "Them second")
    }

    func testLastThemUtteranceWhenNone() {
        let store = makeStore()
        store.append(makeUtterance(text: "You only", speaker: .you))
        XCTAssertNil(store.lastThemUtterance)
    }

    // MARK: - Recent Utterances

    func testRecentUtterancesReturnsUpTo10() {
        let store = makeStore()
        for i in 1...15 {
            store.append(makeUtterance(text: "Utterance \(i)", speaker: .them))
        }
        XCTAssertEqual(store.recentUtterances.count, 10)
        XCTAssertEqual(store.recentUtterances.first?.text, "Utterance 6")
        XCTAssertEqual(store.recentUtterances.last?.text, "Utterance 15")
    }

    func testRecentExchangeReturnsUpTo6() {
        let store = makeStore()
        for i in 1...10 {
            store.append(makeUtterance(text: "U\(i)", speaker: i.isMultiple(of: 2) ? .you : .them))
        }
        XCTAssertEqual(store.recentExchange.count, 6)
    }

    func testRecentThemUtterancesFiltersCorrectly() {
        let store = makeStore()
        store.append(makeUtterance(text: "Them 1", speaker: .them))
        store.append(makeUtterance(text: "You 1", speaker: .you))
        store.append(makeUtterance(text: "Them 2", speaker: .them))
        store.append(makeUtterance(text: "You 2", speaker: .you))

        let recent = store.recentThemUtterances
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent.allSatisfy { $0.speaker == .them })
    }

    // MARK: - Volatile Text

    func testVolatileTextDefaultsEmpty() {
        let store = makeStore()
        XCTAssertEqual(store.volatileYouText, "")
        XCTAssertEqual(store.volatileThemText, "")
    }

    func testVolatileTextCanBeSet() {
        let store = makeStore()
        store.volatileYouText = "partial you input"
        store.volatileThemText = "partial them input"
        XCTAssertEqual(store.volatileYouText, "partial you input")
        XCTAssertEqual(store.volatileThemText, "partial them input")
    }
}
