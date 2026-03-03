import Foundation

final class QuoteService {
    static let shared = QuoteService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    func fetchAQuote(code: String) async throws -> StockQuote {
        guard let secid = secidForAStock(code: code) else {
            throw QuoteServiceError.unsupportedCode
        }

        var comp = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/get")
        comp?.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "fields", value: "f57,f58,f43,f170"),
            URLQueryItem(name: "ut", value: "fa5fd1943c7b386f172d6893dbfba10b")
        ]

        guard let url = comp?.url else {
            throw QuoteServiceError.badURL
        }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw QuoteServiceError.httpFailed
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any] else {
            throw QuoteServiceError.badPayload
        }

        let codeValue = String(describing: dataObj["f57"] ?? code)
        let nameValue = String(describing: dataObj["f58"] ?? code)

        let rawPrice = number(dataObj["f43"])
        let rawPct = number(dataObj["f170"])

        // Eastmoney returns price * 1000, pct * 100
        let price = rawPrice / 1000.0
        let changePercent = rawPct / 100.0

        guard price > 0 else {
            throw QuoteServiceError.badPayload
        }

        return StockQuote(
            code: codeValue,
            name: nameValue,
            price: price,
            changePercent: changePercent,
            updatedAt: Date()
        )
    }

    private func secidForAStock(code: String) -> String? {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 6, cleaned.allSatisfy(\.isNumber) else { return nil }

        if cleaned.hasPrefix("6") || cleaned.hasPrefix("9") {
            return "1.\(cleaned)"
        }
        if cleaned.hasPrefix("0") || cleaned.hasPrefix("3") || cleaned.hasPrefix("2") {
            return "0.\(cleaned)"
        }
        return nil
    }

    private func number(_ raw: Any?) -> Double {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) ?? 0 }
        return 0
    }
}

enum QuoteServiceError: Error {
    case unsupportedCode
    case badURL
    case httpFailed
    case badPayload
}
