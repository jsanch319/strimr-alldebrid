import Foundation
@testable import Strimr
import Testing

struct AllDebridAPIClientTests {
    @Test func `PIN authorization uses documented endpoints and verifies with bearer auth`() async throws {
        let stub = HTTPStub { request in
            switch request.url?.path {
            case "/v4.1/pin/get":
                return .json(#"{"status":"success","data":{"pin":"ABCD","check":"check-token","expires_in":600,"user_url":"https://alldebrid.com/pin/?pin=ABCD"}}"#)
            case "/v4/pin/check":
                return .json(#"{"status":"success","data":{"activated":true,"expires_in":570,"apikey":"user-api-key"}}"#)
            case "/v4/user":
                return .json(#"{"status":"success","data":{"user":{"username":"user"}}}"#)
            default:
                return .status(404)
            }
        }
        let client = AllDebridAPIClient(session: stub.session)

        let pin = try await client.requestPIN()
        let authorization = try await client.checkPIN(pin: pin.pin, check: pin.check)
        let apiKey = try #require(authorization.apiKey)
        let authenticatedClient = try AllDebridAPIClient(
            apiKey: apiKey,
            session: stub.session,
        )
        let username = try await authenticatedClient.verifyConnection()

        #expect(pin.pin == "ABCD")
        #expect(authorization.activated)
        #expect(username == "user")
        #expect(stub.requests.map(\.url?.path) == ["/v4.1/pin/get", "/v4/pin/check", "/v4/user"])
        #expect(stub.requests[0].httpMethod == "GET")
        #expect(stub.requests[1].httpMethod == "POST")
        #expect(
            String(data: try #require(stub.requests[1].httpBody), encoding: .utf8) == "pin=ABCD&check=check-token",
        )
        #expect(stub.requests[2].httpMethod == "GET")
        #expect(stub.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer user-api-key")
        #expect(stub.requests.allSatisfy { $0.url?.query == nil })
    }

    @Test func `verification rejects an invalid account response`() async throws {
        let stub = HTTPStub { _ in
            .json(#"{"status":"error","error":{"code":"AUTH_BAD_APIKEY","message":"Invalid API key"}}"#)
        }
        let client = try AllDebridAPIClient(apiKey: "invalid", session: stub.session)

        await #expect(throws: AllDebridAPIClient.APIError.serviceError("Invalid API key")) {
            try await client.verifyConnection()
        }
    }
}
