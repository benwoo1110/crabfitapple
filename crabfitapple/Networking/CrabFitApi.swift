import Foundation

struct CrabFitEventInput: Codable, Equatable, Sendable {
    var name: String?
    var times: [String]
    var timezone: String

    init(name: String? = nil, times: [String], timezone: String) {
        self.name = name
        self.times = times
        self.timezone = timezone
    }
}

struct CrabFitEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let times: [String]
    let timezone: String
    let createdAt: TimeInterval

    var createdDate: Date {
        Date(timeIntervalSince1970: createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case times
        case timezone
        case createdAt = "created_at"
    }
}

struct CrabFitPersonInput: Codable, Equatable, Sendable {
    var availability: [String]

    init(availability: [String]) {
        self.availability = availability
    }
}

struct CrabFitPerson: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let availability: [String]
    let createdAt: TimeInterval

    var id: String { name }

    var createdDate: Date {
        Date(timeIntervalSince1970: createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case availability
        case createdAt = "created_at"
    }
}

struct CrabFitStats: Codable, Equatable, Sendable {
    let eventCount: Int
    let personCount: Int
    let version: String

    private enum CodingKeys: String, CodingKey {
        case eventCount = "event_count"
        case personCount = "person_count"
        case version
    }
}

enum CrabFitApiError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case invalidTextResponse
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Could not construct a valid Crab Fit API URL."
        case .invalidResponse:
            "The Crab Fit API returned an invalid response."
        case .invalidTextResponse:
            "The Crab Fit API returned text that could not be decoded."
        case .unexpectedStatusCode(let statusCode):
            "The Crab Fit API returned HTTP status code \(statusCode)."
        }
    }
}

final class CrabFitApi {
    static let productionBaseURL = makeBaseURL(scheme: "https", host: "api.crab.fit")
    static let localDevelopmentBaseURL = makeBaseURL(scheme: "http", host: "localhost", port: 3000)

    private let baseURL: URL
    private let urlSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = CrabFitApi.productionBaseURL,
        urlSession: URLSession = .shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.encoder = encoder
        self.decoder = decoder
    }

    func version() async throws -> String {
        let request = try makeRequest(method: "GET", pathComponents: [])
        let data = try await data(for: request, acceptedStatusCodes: [200])

        guard let version = String(data: data, encoding: .utf8) else {
            throw CrabFitApiError.invalidTextResponse
        }

        return version
    }

    func stats() async throws -> CrabFitStats {
        let request = try makeRequest(method: "GET", pathComponents: ["stats"])
        return try await decoded(CrabFitStats.self, from: request, acceptedStatusCodes: [200])
    }

    func createEvent(_ input: CrabFitEventInput) async throws -> CrabFitEvent {
        let request = try makeJSONRequest(method: "POST", pathComponents: ["event"], body: input)
        return try await decoded(CrabFitEvent.self, from: request, acceptedStatusCodes: [201])
    }

    func event(id eventID: String) async throws -> CrabFitEvent {
        let request = try makeRequest(method: "GET", pathComponents: ["event", eventID])
        return try await decoded(CrabFitEvent.self, from: request, acceptedStatusCodes: [200])
    }

    func people(eventID: String) async throws -> [CrabFitPerson] {
        let request = try makeRequest(method: "GET", pathComponents: ["event", eventID, "people"])
        return try await decoded([CrabFitPerson].self, from: request, acceptedStatusCodes: [200])
    }

    func person(eventID: String, name: String, password: String? = nil) async throws -> CrabFitPerson {
        let request = try makeRequest(
            method: "GET",
            pathComponents: ["event", eventID, "people", name],
            password: password
        )
        return try await decoded(CrabFitPerson.self, from: request, acceptedStatusCodes: [200])
    }

    func updatePerson(
        eventID: String,
        name: String,
        input: CrabFitPersonInput,
        password: String? = nil
    ) async throws -> CrabFitPerson {
        let request = try makeJSONRequest(
            method: "PATCH",
            pathComponents: ["event", eventID, "people", name],
            body: input,
            password: password
        )
        return try await decoded(CrabFitPerson.self, from: request, acceptedStatusCodes: [200])
    }

    func updatePerson(
        eventID: String,
        name: String,
        availability: [String],
        password: String? = nil
    ) async throws -> CrabFitPerson {
        try await updatePerson(
            eventID: eventID,
            name: name,
            input: CrabFitPersonInput(availability: availability),
            password: password
        )
    }

    func cleanup(cronKey: String? = nil) async throws {
        let request = try makeRequest(
            method: "GET",
            pathComponents: ["tasks", "cleanup"],
            cronKey: cronKey
        )
        _ = try await data(for: request, acceptedStatusCodes: [200])
    }

    private func decoded<Response: Decodable>(
        _ type: Response.Type,
        from request: URLRequest,
        acceptedStatusCodes: Set<Int>
    ) async throws -> Response {
        let data = try await data(for: request, acceptedStatusCodes: acceptedStatusCodes)
        return try decoder.decode(Response.self, from: data)
    }

    private func data(for request: URLRequest, acceptedStatusCodes: Set<Int>) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CrabFitApiError.invalidResponse
        }

        guard acceptedStatusCodes.contains(httpResponse.statusCode) else {
            throw CrabFitApiError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return data
    }

    private func makeRequest(
        method: String,
        pathComponents: [String],
        password: String? = nil,
        cronKey: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try makeURL(pathComponents: pathComponents))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let password {
            let token = Data(password.utf8).base64EncodedString()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let cronKey {
            request.setValue(cronKey, forHTTPHeaderField: "X-Cron-Key")
        }

        return request
    }

    private func makeJSONRequest<Body: Encodable>(
        method: String,
        pathComponents: [String],
        body: Body,
        password: String? = nil
    ) throws -> URLRequest {
        var request = try makeRequest(method: method, pathComponents: pathComponents, password: password)
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func makeURL(pathComponents: [String]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CrabFitApiError.invalidURL
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedPathComponents = pathComponents.compactMap(Self.percentEncodedPathComponent)

        guard encodedPathComponents.count == pathComponents.count else {
            throw CrabFitApiError.invalidURL
        }

        let path = ([basePath] + encodedPathComponents)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.percentEncodedPath = path.isEmpty ? "/" : "/\(path)"

        guard let url = components.url else {
            throw CrabFitApiError.invalidURL
        }

        return url
    }

    nonisolated private static func percentEncodedPathComponent(_ component: String) -> String? {
        component.addingPercentEncoding(withAllowedCharacters: pathComponentAllowedCharacters)
    }

    nonisolated private static var pathComponentAllowedCharacters: CharacterSet {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-._~")
        return characters
    }

    nonisolated private static func makeBaseURL(scheme: String, host: String, port: Int? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port

        guard let url = components.url else {
            preconditionFailure("Invalid Crab Fit API base URL")
        }

        return url
    }
}
