import Foundation
import UIKit
import CoreLocation

enum HTTPAPIError: Error {
    case failedToCreateURL
    case failedToCreateImage
}

enum FetchError: Int {
    case notFound = 404
    case unknown = 1000
    static private let errorDomain = "com.mapboxSceneKit.TileFetching.errorDomain"
    
    var localizedDescription: String {
        switch self {
        case .notFound:
            return NSLocalizedString("Data for given point was not found on the server", comment: "Description of Not Found error")
        default:
            return NSLocalizedString("Unknown error", comment: "Description of Unknown error")
        }
    }
    
    init(code: Int) {
        self = FetchError(rawValue: code) ?? .unknown
    }
    
    func toNSError() -> NSError {
        return NSError(domain: FetchError.errorDomain, code: rawValue, userInfo: [NSLocalizedDescriptionKey: localizedDescription])
    }
}

internal final class MapboxHTTPAPI {
    
    private let httpApiClient = HttpApiClient()

    private var accessToken: String

    init(accessToken token: String) {
        accessToken = token
    }

    func tileset(_ tileset: String, zoomLevel z: Int, xTile x: Int, yTile y: Int, format: String) async throws -> UIImage {
        guard let url = URL(string: "https://api.mapbox.com/v4/\(tileset)/\(z)/\(x)/\(y).\(format)?access_token=\(accessToken)") else {
            NSLog("Couldn't get URL for fetch task")
            throw HTTPAPIError.failedToCreateURL
        }

        let data = try await httpApiClient.request(url: url, session: URLSession.shared)
        
        guard let image = UIImage(data: data) else {
            throw  HTTPAPIError.failedToCreateImage
        }
        return image
    }

    func style(_ s: String, zoomLevel z: Int, xTile x: Int, yTile y: Int, tileSize: CGSize) async throws -> UIImage {
        let boundingBox = Math.tile2BoundingBox(x: x, y: y, z: z)
        let centerLat = boundingBox.latBounds.1 - (boundingBox.latBounds.1 - boundingBox.latBounds.0) / 2.0
        let centerLon = boundingBox.lonBounds.1 - (boundingBox.lonBounds.1 - boundingBox.lonBounds.0) / 2.0

        return try await style(s, zoomLevel: z, centerLat: centerLat, centerLon: centerLon, tileSize: tileSize)
    }

    func style(_ style: String, zoomLevel z: Int, centerLat: CLLocationDegrees, centerLon: CLLocationDegrees, tileSize: CGSize) async throws -> UIImage {
        guard let url = URL(string: "https://api.mapbox.com/styles/v1/\(style)/static/\(centerLon),\(centerLat),\(z)/\(Int(tileSize.width))x\(Int(tileSize.height))?access_token=\(accessToken)&attribution=false&logo=false") else {
            NSLog("Couldn't get URL for fetch task")
            throw HTTPAPIError.failedToCreateURL
        }

        let headers: [String: String] = ["Accept": "image/*;q=0.8"]
        let data = try await httpApiClient.request(url: url, headers: headers, session: URLSession.shared)

        guard let image = UIImage(data: data) else {
            throw  HTTPAPIError.failedToCreateImage
        }
        return image
    }
}
