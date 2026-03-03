import Foundation

#if DEBUG
enum CoreSelfTests {
    static func run() async {
        testPersistenceStore()
        testClusterer()
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
}
#endif
