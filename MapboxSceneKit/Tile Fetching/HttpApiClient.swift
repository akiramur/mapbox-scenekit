//
//  HttpApiClient.swift
//  MapboxRealityKit
//
//  Created by Akira Murao on 2023/06/15.
//

import Foundation

enum APIError: Error {
    case noResponse
    case unacceptableStatusCode(Int)
    case failedToCreateComponents(URL)
    case failedToCreateURL(URLComponents)
}

internal class HttpApiClient {
    enum HTTPMethod: String {
        case OPTIONS, GET, HEAD, POST, PUT, PATCH, DELETE, TRACE, CONNECT
    }

    func buildRequest(url: URL, headers: [String: String] = [String: String](), method: HTTPMethod = .GET) -> URLRequest? {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
    
    func request(url: URL, headers: [String: String] = [String: String](), method: HTTPMethod = .GET, session: URLSession) async throws -> Data {
        guard let request = buildRequest(url: url, headers: headers, method: method) else {
            //endTaskAndCallbackWithSuccess(false, responseCode: 0)
            throw APIError.failedToCreateComponents(url)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            NSLog("Server response was not HTTP, likely offline")
            throw APIError.noResponse
        }

        guard case 200...304 = httpResponse.statusCode else {
            NSLog("Non-OK response from server: \(httpResponse.statusCode)")
            throw APIError.unacceptableStatusCode(httpResponse.statusCode)
        }

        if httpResponse.statusCode > 304 {
            NSLog("Error accessing server: \(httpResponse.statusCode)")
            throw APIError.unacceptableStatusCode(httpResponse.statusCode)
        }

        return data
    }
}
