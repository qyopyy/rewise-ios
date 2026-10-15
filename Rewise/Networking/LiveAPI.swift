import Foundation

/// Talks to your Rewise backend over HTTPS. See BACKEND.md for the endpoints.
struct LiveAPI: RewiseAPI {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    func accounts() async throws -> [Account] {
        try await get("v1/accounts")
    }

    func rate() async throws -> FXRate {
        try await get("v1/rates/USD-HUF")
    }

    func rateHistory(days: Int) async throws -> [RatePoint] {
        try await get("v1/rates/USD-HUF/history", query: [URLQueryItem(name: "days", value: String(days))])
    }

    func quote(_ request: QuoteRequest) async throws -> Quote {
        try await post("v1/quotes", body: request)
    }

    func recipients() async throws -> [Recipient] {
        try await get("v1/recipients")
    }

    func createRecipient(_ draft: RecipientDraft) async throws -> Recipient {
        try await post("v1/recipients", body: draft)
    }

    func transfers() async throws -> [Transfer] {
        try await get("v1/transfers")
    }

    func createTransfer(_ request: TransferRequest) async throws -> Transfer {
        try await post("v1/transfers", body: request, idempotencyKey: request.idempotencyKey)
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = try makeRequest(method: "GET", path: path, query: query, body: nil, idempotencyKey: nil)
        return try await perform(request)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, idempotencyKey: String? = nil) async throws -> T {
        let data: Data
        do {
            data = try JSONCoding.encoder.encode(body)
        } catch {
            throw APIError.invalid("Couldn't prepare the request.")
        }
        let request = try makeRequest(method: "POST", path: path, query: [], body: data, idempotencyKey: idempotencyKey)
        return try await perform(request)
    }

    private func makeRequest(method: String, path: String, query: [URLQueryItem], body: Data?, idempotencyKey: String?) throws -> URLRequest {
        guard !token.isEmpty else { throw APIError.notSignedIn }
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw APIError.transport("Couldn't reach the Rewise server. Check your connection and try again.")
        }
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONCoding.decoder.decode(ServerError.self, from: data))?.message ?? ""
            switch status {
            case 401, 403: throw APIError.notSignedIn
            case 409: throw APIError.quoteExpired
            case 422 where message.lowercased().contains("balance"): throw APIError.insufficientFunds
            default: throw APIError.server(status: status, message: message)
            }
        }
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.invalid("The server sent a response the app couldn't read.")
        }
    }

    private struct ServerError: Decodable {
        let message: String?
    }
}

/// JSON uses snake_case keys and ISO 8601 dates, with or without fractional seconds.
enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = withFraction.date(from: text) ?? plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable date: \(text)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
