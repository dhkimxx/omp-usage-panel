import Foundation

@main struct ModelsTests {
    static func main() throws {
        runDockModelTests()
        runDashboardModelTests()
        runCompactPreferencesTests()
        try runPanelConfigStoreTests()
        runGeneralSettingsDraftTests()
        runUpdateModelTests()
        runUpdatePreferencesTests()
        let json = #"{"snapshot":{"version":1,"capturedAt":1000,"accounts":[{"id":"a","provider":"mistral","label":"Work","fetchedAt":1000,"notes":[],"limits":[{"id":"x","label":"Window","amount":{"unit":"requests","used":0,"limit":100},"window":{"id":"w","label":"Month","durationMs":10000,"resetsAt":20000,"estimated":true},"usedFraction":1.2,"notes":[]}]}],"unavailable":[]},"source":"live","summaries":[{"provider":"mistral","label":"Mistral","percent":120,"value":"120%","severity":"critical","accountCount":1,"accountId":"a","accountLabel":"Work","metricId":"x","metricLabel":"Window","windowLabel":"Month","notes":[]}]}"#
        let result = try JSONDecoder().decode(PanelResult.self, from: Data(json.utf8))
        let limit = result.snapshot!.accounts[0].limits[0]
        precondition(result.summaries[0].percent == 120)
        precondition(limit.amount.used == 0 && limit.window?.estimated == true)
        precondition(DisplayModel.amount(limit.amount).contains("0"))
        precondition(DisplayModel.amount(UsageAmount(unit: "requests", used: nil, limit: nil, remaining: nil)).contains("unknown"))
        precondition(DisplayModel.elapsed(limit.window, now: Date(timeIntervalSince1970: 15)) == 0.5)
        precondition(DisplayModel.elapsed(limit.window, now: Date(timeIntervalSince1970: 30)) == 1)
        precondition(DisplayModel.countdown(20000, now: Date(timeIntervalSince1970: 21)) == "due now")
    }
}
