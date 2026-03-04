import Foundation

#if DEBUG
enum CoreSelfTests {
    static func run() async {
        testPersistenceStore()
        testClusterer()
        testClustererQualityControls()
        testRefreshStateLabel()
        testTelemetryCenter()
        await testErrorCenter()
    }

    private static func testPersistenceStore() {
        let suite = "cls.debug.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assertionFailure("SelfTest: unable to create isolated defaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)

        let store = FeedPersistenceStore(defaults: defaults)
        _ = store.saveUIDSet(["u1", "u2", "u3"], bucket: .pinned, limit: 2)
        store.saveFilter(.later)

        let item = TelegraphItem(
            uid: "abc",
            source: "cls",
            sourceName: "财联社",
            ctime: 1,
            time: "09:30",
            title: "测试",
            text: "测试文本",
            author: "",
            level: "A",
            url: ""
        )
        store.saveLatestItems([item], limit: 10)

        let loaded = store.loadState()
        assert(loaded.pinnedUIDs.count == 2, "SelfTest: persistence UID clipping failed")
        assert(loaded.filter == .later, "SelfTest: persistence filter failed")
        assert(loaded.latestItems.first?.uid == "abc", "SelfTest: persistence items failed")

        defaults.removePersistentDomain(forName: suite)
    }

    private static func testClusterer() {
        let a = TelegraphItem(
            uid: "1",
            source: "cls",
            sourceName: "财联社",
            ctime: 1_700_000_000,
            time: "09:31",
            title: "央行下调存款准备金率",
            text: "央行宣布下调存款准备金率0.5个百分点",
            author: "",
            level: "A",
            url: ""
        )
        let b = TelegraphItem(
            uid: "2",
            source: "sina",
            sourceName: "新浪财经",
            ctime: 1_700_000_050,
            time: "09:32",
            title: "央行下调存款准备金率",
            text: "下调0.5个百分点，释放长期资金",
            author: "",
            level: "B",
            url: ""
        )

        let clusters = TelegraphClusterer.buildClusters(from: [a, b])
        assert(clusters.count == 1, "SelfTest: cluster merge failed")
        assert(clusters[0].items.count == 2, "SelfTest: cluster item count failed")
    }

    private static func testClustererQualityControls() {
        let lhs = TelegraphItem(
            uid: "qa-1",
            source: NewsSource.cls.rawValue,
            sourceName: "财联社",
            ctime: 1_700_001_100,
            time: "10:01",
            title: "央行下调逆回购利率10BP",
            text: "今日公开市场操作利率下调10个基点。",
            author: "",
            level: "A",
            url: ""
        )
        let rhs = TelegraphItem(
            uid: "qa-2",
            source: NewsSource.sina.rawValue,
            sourceName: "新浪财经",
            ctime: 1_700_001_120,
            time: "10:02",
            title: "央行宣布下调逆回购利率并释放流动性",
            text: "公开市场操作利率下调，释放短期流动性。",
            author: "",
            level: "B",
            url: ""
        )

        let conservative = FeedQualitySnapshot(collapseThreshold: 86, sourcePriorityByCode: [:])
        let aggressive = FeedQualitySnapshot(collapseThreshold: 66, sourcePriorityByCode: [:])
        let conservativeClusters = TelegraphClusterer.buildClusters(from: [lhs, rhs], quality: conservative)
        let aggressiveClusters = TelegraphClusterer.buildClusters(from: [lhs, rhs], quality: aggressive)
        assert(conservativeClusters.count >= aggressiveClusters.count, "SelfTest: threshold collapse regression")

        let prioritized = FeedQualitySnapshot(
            collapseThreshold: 70,
            sourcePriorityByCode: [NewsSource.sina.rawValue: 3]
        )
        let prioritizedClusters = TelegraphClusterer.buildClusters(from: [lhs, rhs], quality: prioritized)
        if let first = prioritizedClusters.first {
            assert(first.primary.source == NewsSource.sina.rawValue, "SelfTest: source priority not applied")
        }
    }

    @MainActor
    private static func testErrorCenter() {
        let center = AppErrorCenter()
        center.showBanner(title: "t", message: "m", source: "selftest", autoDismissAfter: 0)
        assert(center.banner != nil, "SelfTest: banner should be set")
        center.clearBanner()
        assert(center.banner == nil, "SelfTest: banner should be cleared")

        center.showAlert(title: "a", message: "b", source: "selftest")
        assert(center.alert != nil, "SelfTest: alert should be set")
        center.clearAlert()
        assert(center.alert == nil, "SelfTest: alert should be cleared")
    }

    private static func testRefreshStateLabel() {
        let a = FeedRefreshState.idle.displayText
        let b = FeedRefreshState.loading(.manual).displayText
        let c = FeedRefreshState.stagingPending(3).displayText
        assert(a == "空闲", "SelfTest: refresh idle label mismatch")
        assert(!b.isEmpty && b.contains("刷新"), "SelfTest: refresh loading label mismatch")
        assert(c.contains("3"), "SelfTest: refresh staging label mismatch")
    }

    private static func testTelemetryCenter() {
        let suite = "cls.debug.telemetry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assertionFailure("SelfTest: unable to create telemetry defaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)

        let center = AppTelemetryCenter(defaults: defaults, storageKey: "telemetry.selftest", maxEvents: 10)
        center.clear()
        center.record(name: "tab_switch", value: 12)
        center.record(name: "feed_refresh", value: 95, meta: ["state": "空闲"])
        center.record(name: "feed_refresh_error", meta: ["message": "mock"])
        center.record(name: "pending_apply", value: 4)

        // Wait shortly for async enqueue to flush into isolated defaults.
        Thread.sleep(forTimeInterval: 0.03)

        let summary = center.summary()
        assert(summary.totalEvents >= 4, "SelfTest: telemetry total mismatch")
        assert(summary.averageTabSwitchMS >= 12, "SelfTest: telemetry tab avg mismatch")
        assert(summary.averageFeedRefreshMS >= 95, "SelfTest: telemetry refresh avg mismatch")
        assert(summary.refreshErrorCount24h >= 1, "SelfTest: telemetry error count mismatch")
        assert(summary.pendingAppliedTotal >= 4, "SelfTest: telemetry pending count mismatch")

        defaults.removePersistentDomain(forName: suite)
    }
}
#endif
