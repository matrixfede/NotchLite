import Foundation

@main
struct UsageTests {
    static func main() {
        testAccessErrorsRemainVisible()
        testBusiestDayAggregatesProvidersInsteadOfChoosingLatestDate()
        testNoBusiestDayWithoutPositiveUsage()
        print("Usage regression checks passed")
    }
    static func testAccessErrorsRemainVisible() {
        precondition(AgentUsage(note: "Accesso scaduto").isActive)
        precondition(AgentUsage(stats: LocalStats(tokensWeek: 100)).isActive)
        precondition(!AgentUsage().isActive)
    }

    static func testBusiestDayAggregatesProvidersInsteadOfChoosingLatestDate() {
        let first = Date(timeIntervalSince1970: 86400)
        let second = Date(timeIntervalSince1970: 172800)
        let third = Date(timeIntervalSince1970: 259200)
        let a = LocalStats(tokensByDay: [first: 80, second: 100])
        let b = LocalStats(tokensByDay: [first: 80, third: 110])
        precondition(LocalStats.busiestDay(in: [a, b]) == first)
    }

    static func testNoBusiestDayWithoutPositiveUsage() {
        precondition(LocalStats.busiestDay(in: []) == nil)
        precondition(LocalStats.busiestDay(in: [LocalStats(tokensByDay: [Date(): 0])]) == nil)
    }

}
