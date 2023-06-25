import Foundation
import SceneKit
import CoreLocation

/**
 The `TerrainNode` object represents the easiest way to generate terrain in SceneKit (if you prefer a custom solution, see the methods on `MapboxImageAPI`
 to help get you started with a custom solution using the base data.
 **/
open class TerrainNode: SCNNode {

    @MainActor
    public weak var textureImage: UIImage? {
        didSet {
            geometry?.materials[4].diffuse.contents = textureImage
        }
    }

    /// Basic TerrainNode Information
    private let southWestCorner: CLLocation
    private let northEastCorner: CLLocation
    private let styleZoomLevel: Int
    private var terrainZoomLevel: Int
    
    /// Unit conversions
    fileprivate let metersPerLat: Double
    fileprivate let metersPerLon: Double
    private(set) internal var metersPerPixelX: Double = 0
    private(set) internal var metersPerPixelY: Double = 0
    
    /// TerrainNode Sizes
    fileprivate var terrainHeights = [[Double]]()
    fileprivate var terrainSizeMeters: CGSize {
            let x = Double(northEastCorner.coordinate.longitude - southWestCorner.coordinate.longitude) * metersPerLon
            let z = Double(northEastCorner.coordinate.latitude - southWestCorner.coordinate.latitude) * metersPerLat
            return CGSize(width: x, height: z)
    }
    
    fileprivate var terrainImageSize: CGSize = CGSize.zero {
        didSet {
            //update meters per pixel value when terrain image size changes
            metersPerPixelX = Double(abs(terrainSizeMeters.width)) / Double(terrainImageSize.width)
            metersPerPixelY = Double(abs(terrainSizeMeters.height)) / Double(terrainImageSize.height)
        }
    }
    
    /// Convenience tuple represending the bounds of altitude after heightmaps have been loaded.
    private(set) var altitudeBounds: (minZ: CLLocationDistance, maxZ: CLLocationDistance) = (0.0, 1.0)
    
    /// APIs and Tile fetching
    private let api = MapboxImageAPI()

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public init(southWestCorner: CLLocation, northEastCorner: CLLocation) {
        
        assert(CLLocationCoordinate2DIsValid(southWestCorner.coordinate), "TerrainNode southWestCorner coordinates are invalid.")
        assert(CLLocationCoordinate2DIsValid(northEastCorner.coordinate), "TerrainNode northEastCorner coordinates are invalid.")
        assert(southWestCorner.coordinate.latitude < northEastCorner.coordinate.latitude, "southWestCorner must be South of northEastCorner")
        assert(southWestCorner.coordinate.longitude < northEastCorner.coordinate.longitude, "southWestCorner must be West of northEastCorner")

        self.southWestCorner = southWestCorner
        self.northEastCorner = northEastCorner
        self.styleZoomLevel = Math.zoomLevelForBounds(southWestCorner: southWestCorner,
                                                               northEastCorner: northEastCorner)
        self.terrainZoomLevel = min(styleZoomLevel, Constants.maxTerrainRGBZoomLevel)
        
        self.metersPerLat = 1 / Math.metersToDegreesForLat(atLongitude: northEastCorner.coordinate.longitude)
        self.metersPerLon = 1 / Math.metersToDegreesForLon(atLatitude: northEastCorner.coordinate.latitude)

        super.init()
        geometry = SCNBox(width: terrainSizeMeters.width,
                          height: 10.0,
                          length: terrainSizeMeters.height,
                          chamferRadius: 0.0)
    }

    public convenience init(minLat: CLLocationDegrees, maxLat: CLLocationDegrees, minLon: CLLocationDegrees, maxLon: CLLocationDegrees) {
        self.init(southWestCorner: CLLocation(latitude: minLat, longitude: minLon),
                  northEastCorner: CLLocation(latitude: maxLat, longitude: maxLon))
    }

    deinit {
    }

    private func centerPivot() {
        var min = SCNVector3Zero
        var max = SCNVector3Zero
        self.__getBoundingBoxMin(&min, max: &max)
        self.pivot = SCNMatrix4MakeTranslation(min.x + (max.x - min.x) / 2,
                                               min.y,
                                               min.z + (max.z - min.z) / 2)
    }

    //MARK: - Public API

    /// Will return the local position relative to the terrain node for a given lat/lon/alt.
    ///
    /// - Parameter location: Location in the real world.
    /// - Returns: Vector position should be converted from the terrain local space to the world space (or another node's corrdinate space, as needed).
    public func positionForLocation(_ location: CLLocation) -> SCNVector3 {
        let coords = latLonToMeters(location: location)
        let groundLevel = heightForLocalPosition(SCNVector3(coords.x, 0.0, coords.z))
        
        return SCNVector3(coords.x, Float(max(groundLevel, location.altitude)), coords.z)
    }
    
    /// Returns the height at ground level of the terrain node at a given local position.
    ///
    /// - Parameter position: postion for the height lookup in the terrainNode's local space.
    /// - Returns: height value at the input position. Apply this to the Y component of the input position to place it on the TerrainNode's surface.
    public func heightForLocalPosition(_ position: SCNVector3) -> Double {
        let coords = (x: position.x, z: position.z)
        
        if let groundLevel = TerrainNode.height(heights: terrainHeights, x: coords.x, z: coords.z, metersPerX: metersPerPixelX, metersPerY: metersPerPixelY) {
            return groundLevel
        } else {
            return 0.0
        }
    }
    
    /// Begins the fetch of terrain-rgb data throught the mapbox API, and then updates the geometry to repersent a to-scale model of the terrain at this location.
    /// Fetches an image representing a style (either mapbox or user created) to cover this terrain node.
    ///
    /// - Parameters:
    ///   - minWallHeight: Padding amount (in meters) of the walls beyond the returned altitude minumum for the region.
    ///   - multiplier: Scale factor used to artificially exaggerate or flatten the terrain heights. Useful if you are trying to make an area with relatively flat terrain look for dramatic. Default 1.
    ///   - shadows: Depending on your applied texture / style, you may want to enable dynamic shadowing based on the contour of the terrain for interaction with Scene Kit lighting.
    ///   - style: Mapbox style ID for given texture.
    ///   - heightProgress: Handler for height progress change.
    ///   - heightCompletion: Handler for complete height update.
    ///   - textureProgress: Handler for texture progress change.
    ///   - textureCompletion: Handler for complete texture update. It is up to the caller to apply it as a material component, but this gives the caller the opportunity to modify the image or apply it as something other then default diffuse contents. For the simplist usage, you'll want to apply it as the diffuse contents in position 4 (the top): `myTerrainNode.geometry?.materials[4].diffuse.contents = image`.
    public func fetchTerrain(
        minWallHeight: CLLocationDistance = 0.0,
        multiplier: Float = 1,
        enableDynamicShadows shadows: Bool = false,
        heightProgress: MapboxImageAPI.TileLoadProgressCallback? = nil,
        rendererProgress: MapboxImageAPI.TileLoadProgressCallback? = nil
    ) async throws {
        let retryNumber = Constants.maxRequestAttempts
        try await doFetchTerrain(
            minWallHeight: minWallHeight,
            multiplier: multiplier,
            enableDynamicShadows: shadows,
            retryNumber: retryNumber,
            heightProgress: heightProgress,
            rendererProgress: rendererProgress
        )
    }

    private func doFetchTerrain(
        minWallHeight: CLLocationDistance = 0.0,
        multiplier: Float,
        enableDynamicShadows shadows: Bool = false,
        retryNumber: Int,
        heightProgress: MapboxImageAPI.TileLoadProgressCallback? = nil,
        rendererProgress: MapboxImageAPI.TileLoadProgressCallback? = nil
    ) async throws {

        heightProgress?(0, 1)

        let terrainImage = try await fetchTerrainHeights(
            zoomLevel: terrainZoomLevel,
            retryNumber: retryNumber,
            progress: heightProgress
        )

        heightProgress?(1, 1)
        
        guard let terrainImage = terrainImage else {
            throw FetchError.unknown.toNSError()
        }
        
        rendererProgress?(0, 1)
        
        try Task.checkCancellation()
        try await self.applyTerrainHeightmap(terrainImage, withWallHeight: minWallHeight, multiplier: multiplier, enableShadows: shadows, progress: rendererProgress)

        rendererProgress?(1, 1)
    }
    
    public func fetchTexture(
        textureStyle style: String,
        textureProgress: MapboxImageAPI.TileLoadProgressCallback? = nil
    ) async throws -> UIImage? {
        print("fetchTexture isMainThread?: \(Thread.isMainThread) <<")

        self.textureImage = nil
        
        print("fetchTextureTask isMainThread?: \(Thread.isMainThread) <<")
        
        let retryNumber = Constants.maxRequestAttempts
        return try await self.doFetchTexture(
            textureStyle: style,
            textureProgress: textureProgress
        )
    }

    private func doFetchTexture(
        textureStyle style: String,
        textureProgress: MapboxImageAPI.TileLoadProgressCallback? = nil
    ) async throws -> UIImage? {
        print("doFetchTexture style: \(style), isMainThread?: \(Thread.isMainThread) <<")
        
        textureProgress?(0, 1)
        
        try Task.checkCancellation()
        //fetch texture in parallel to heights
        let textureImage = try await self.fetchTerrainTexture(style, zoom: self.styleZoomLevel, progress: textureProgress)
        
        textureProgress?(1, 1)
        
        self.textureImage = textureImage
        
        print("doFetchTerrainAndTexture style: \(style) >>")
        return textureImage
    }

    /// DEPRECATED - Please use instead fetchTerrainAndTexture.
    /// Begins the fetch of terrain-rgb data throught the mapbox API, and then updates the geometry to repersent a to-scale model of the terrain at this location.
    ///
    /// - Parameters:
    ///   - minWallHeight: Padding amount (in meters) of the walls beyond the returned altitude minumum for the region.
    ///   - multiplier: Scale factor used to artificially exaggerate or flatten the terrain heights. Useful if you are trying to make an area with relatively flat terrain look for dramatic. Default 1.
    ///   - shadows: Depending on your applied texture / style, you may want to enable dynamic shadowing based on the contour of the terrain for interaction with Scene Kit lighting.
    ///   - progress: Handler for height progress change.
    ///   - completion: Handler for complete height update.
    private func fetchTerrainHeights(
        zoomLevel: Int,
        retryNumber: Int = 3,
        progress: MapboxImageAPI.TileLoadProgressCallback? = nil
    ) async throws -> UIImage? {

        let southWestCorner = self.southWestCorner
        let northEastCorner = self.northEastCorner
        
        var image: UIImage?
        var heightFetchError: Error?
        var zoomLevel = zoomLevel
        for i in 0 ..< retryNumber {
            do {
                try Task.checkCancellation()
                image = try await api.image(forTileset: "mapbox.terrain-rgb",
                                                zoomLevel: zoomLevel,
                                                southWestCorner: southWestCorner,
                                                northEastCorner: northEastCorner,
                                                format: MapboxImageAPI.TileImageFormatPNG,
                                                progress: progress)
            }
            catch {
                try Task.checkCancellation() // throw cancelation here again if canceled to avoid retry
                heightFetchError = error
            }
            
            if let _ = image {
                break
            }
            
            zoomLevel -= 1
            print("retrying: \(i)")
        }
        
        guard let image = image else {
            progress?(1, 1)
            throw heightFetchError ?? FetchError.unknown.toNSError()
        }
        
        return image
    }
    
    /// Fetches an image representing a style (either mapbox or user created) to cover this terrain node.
    /// It is up to the caller to apply it as a material component, but this gives the caller the opportunity to modify the image or apply it as something other then default diffuse contents.
    /// For the simplist usage, you'll want to apply it as the diffuse contents in position 4 (the top): `myRerrainNode.geometry?.materials[4].diffuse.contents = image`.
    ///
    /// - Parameters:
    ///   - style: Mapbox style ID for given texture.
    ///   - progress: Handler for fetch progress change.
    ///   - completion: Handler for complete texture update.
    private func fetchTerrainTexture(_ style: String, zoom: Int, progress: MapboxImageAPI.TileLoadProgressCallback? = nil) async throws -> UIImage? {
        let southWestCorner = self.southWestCorner
        let northEastCorner = self.northEastCorner

        return try await api.image(
            forStyle: style,
            zoomLevel: zoom,
            southWestCorner: southWestCorner,
            northEastCorner: northEastCorner,
            progress: progress
        )
    }
    
    //MARK: - Geometry Creation
    
    private func terrainHeights(from image: UIImage, multiplier: Float, wallHeight: CLLocationDistance) async throws -> (heights: [[Double]], altitudeBounds: (minZ: CLLocationDistance, maxZ: CLLocationDistance)) {
        
        print("terrainHeights isMainThread?: \(Thread.isMainThread) <<")
        
        guard let pixelData = image.cgImage?.dataProvider?.data, let terrainData = CFDataGetBytePtr(pixelData) else {
            NSLog("Couldn't get CGImage color data for terrain")
            throw FetchError.unknown.toNSError()
        }

        var minZ = Double.greatestFiniteMagnitude
        var maxZ = Double.leastNormalMagnitude
        var newTerrainHeights = [[Double]]()
        newTerrainHeights.reserveCapacity(Int(image.size.height))
        
        for y in 0 ..< Int(image.size.height) {
            try Task.checkCancellation()

            var rowData = [Double]()
            rowData.reserveCapacity(Int(image.size.width))
            for x in 0 ..< Int(image.size.width) {
                guard let z = TerrainNode.heightFromImage(x: x, y: y, terrainData: terrainData, terrainSize: image.size, multiplier: multiplier) else {
                    NSLog("Couldn't get Z data for {\(x),\(y)}")
                    continue
                }
                rowData.append(z)
                minZ = min(z, minZ)
                maxZ = max(z, maxZ)
            }
            newTerrainHeights.append(rowData)
        }

        let heights = newTerrainHeights.map({ $0.map({ $0 - minZ + wallHeight })})
        let bounds = (minZ, maxZ)
        
        return (heights, bounds)
    }

    private func applyTerrainHeightmap(
        _ image: UIImage,
        withWallHeight wallHeight: CLLocationDistance? = nil,
        multiplier: Float,
        enableShadows shadows: Bool,
        progress: MapboxImageAPI.TileLoadProgressCallback? = nil
    ) async throws {
        var vertices = [SCNVector3]()
        var normals = [SCNVector3]()
        var uvList: [vector_float2] = []
        var sources = [SCNGeometrySource]()
        var elements = [SCNGeometryElement]()

        progress?(0, 1)
        let terrainHeights = try await self.terrainHeights(from: image, multiplier: multiplier, wallHeight: wallHeight ?? 0.0)
        
        self.terrainImageSize = image.size
        self.terrainHeights = terrainHeights.heights
        self.altitudeBounds = terrainHeights.altitudeBounds

        //Adding these geometries in the same order they'd appear in an SCNBox, so previously applied materials stay on the same side / order
        
        //let imageSize = self.terrainImageSize
        let imageSize = image.size
        let heights = self.terrainHeights
        let sizeInMeters = self.terrainSizeMeters
        let metersPerPixelX = self.metersPerPixelX
        let metersPerPixelY = self.metersPerPixelY
        
        let minZ = self.altitudeBounds.minZ
        let maxZ = self.altitudeBounds.maxZ
        
        if let wallHeight = wallHeight {
            // MARK: South
            progress?(0.1, 1)
            try Task.checkCancellation()
            let south = try await createGeometryForWall(
                xs: [Int](0..<Int(imageSize.width)),
                ys: [Int(imageSize.height) - 1],
                normal: SCNVector3Make(0, 0, -1),
                maxHeight: Float(maxZ + wallHeight - minZ),
                vertexOffset: vertices.count,
                terrainImageSize: imageSize,
                terrainHeights: heights,
                terrainSizeInMeters: sizeInMeters,
                metersPerPixelX: metersPerPixelX,
                metersPerPixelY: metersPerPixelY
            )

            await Task.yield()
            vertices.append(contentsOf: south.vertices)
            normals.append(contentsOf: south.normals)
            uvList.append(contentsOf: south.uvList)
            elements.append(south.element)
            
            // MARK: East
            progress?(0.2, 1)
            try Task.checkCancellation()
            let east = try await createGeometryForWall(
                xs: [Int(terrainImageSize.width) - 1],
                ys: [Int](0..<Int(terrainImageSize.height)),
                normal: SCNVector3Make(1, 0, 0),
                maxHeight: Float(maxZ + wallHeight - minZ),
                vertexOffset: vertices.count,
                terrainImageSize: imageSize,
                terrainHeights: heights,
                terrainSizeInMeters: sizeInMeters,
                metersPerPixelX: metersPerPixelX,
                metersPerPixelY: metersPerPixelY
            )
            
            await Task.yield()
            vertices.append(contentsOf: east.vertices)
            normals.append(contentsOf: east.normals)
            uvList.append(contentsOf: east.uvList)
            elements.append(east.element)

            // MARK: North
            progress?(0.3, 1)
            try Task.checkCancellation()
            let north = try await createGeometryForWall(
                xs: [Int](0..<Int(terrainImageSize.width)),
                ys: [0],
                normal: SCNVector3Make(0, 0, -1),
                maxHeight: Float(maxZ + wallHeight - minZ),
                vertexOffset: vertices.count,
                terrainImageSize: imageSize,
                terrainHeights: heights,
                terrainSizeInMeters: sizeInMeters,
                metersPerPixelX: metersPerPixelX,
                metersPerPixelY: metersPerPixelY
            )

            await Task.yield()
            vertices.append(contentsOf: north.vertices)
            normals.append(contentsOf: north.normals)
            uvList.append(contentsOf: north.uvList)
            elements.append(north.element)

            // MARK: West
            progress?(0.4, 1)
            try Task.checkCancellation()
            let west = try await createGeometryForWall(
                xs: [0],
                ys: [Int](0..<Int(terrainImageSize.height)),
                normal: SCNVector3Make(1, 0, 0),
                maxHeight: Float(maxZ + wallHeight - minZ),
                vertexOffset: vertices.count,
                terrainImageSize: imageSize,
                terrainHeights: heights,
                terrainSizeInMeters: sizeInMeters,
                metersPerPixelX: metersPerPixelX,
                metersPerPixelY: metersPerPixelY
            )
            
            await Task.yield()
            vertices.append(contentsOf: west.vertices)
            normals.append(contentsOf: west.normals)
            uvList.append(contentsOf: west.uvList)
            elements.append(west.element)
        }

        // MARK: Top
        progress?(0.5, 1)
        try Task.checkCancellation()
        let top = try await self.createTopGeometry(vertexOffset: vertices.count, enableShadows: shadows, imageSize: imageSize, heights: heights, sizeInMeters: sizeInMeters)

        await Task.yield()
        vertices.append(contentsOf: top.vertices)
        normals.append(contentsOf: top.normals)
        uvList.append(contentsOf: top.uvList)
        elements.append(top.element)

        if wallHeight != nil {
            // MARK: Bottom
            progress?(0.6, 1)
            try Task.checkCancellation()
            let bottom = await createGeometryForBottom(vertexOffset: vertices.count, imageSize: imageSize)
	    
            await Task.yield()
            vertices.append(contentsOf: bottom.vertices)
            normals.append(contentsOf: bottom.normals)
            uvList.append(contentsOf: bottom.uvList)
            elements.append(bottom.element)
        }

        let float: Float = 0.0
        let sizeOfFloat = MemoryLayout.size(ofValue: float)
        let vec2: vector_float2 = vector2(0, 0)
        let sizeOfVecFloat = MemoryLayout.size(ofValue: vec2)

        sources.append(SCNGeometrySource(vertices: vertices))
        sources.append(SCNGeometrySource(normals: normals))
        let uvData = NSData(bytes: uvList, length: uvList.count * sizeOfVecFloat)
        let uvSource = SCNGeometrySource(data: uvData as Data,
                                         semantic: SCNGeometrySource.Semantic.texcoord,
                                         vectorCount: uvList.count,
                                         usesFloatComponents: true,
                                         componentsPerVector: 2,
                                         bytesPerComponent: sizeOfFloat,
                                         dataOffset: 0,
                                         dataStride: sizeOfVecFloat)
        sources.append(uvSource)

        let originalPosition = position
        let originalMaterials = geometry?.materials ?? [SCNMaterial]()
        
        geometry = SCNGeometry(sources: sources, elements: elements)
        geometry?.materials = originalMaterials
        centerPivot()
        position = originalPosition

        progress?(1, 1)
    }

    //private func createTopGeometry(vertexOffset: Int, enableShadows: Bool) -> (element: SCNGeometryElement, vertices: [SCNVector3], normals: [SCNVector3], uvList: [vector_float2]) {
    private func createTopGeometry(vertexOffset: Int, enableShadows: Bool, imageSize: CGSize, heights: [[Double]], sizeInMeters: CGSize) async throws -> (element: SCNGeometryElement, vertices: [SCNVector3], normals: [SCNVector3], uvList: [vector_float2]) {
     
        var vertices = [SCNVector3]()
        vertices.reserveCapacity(Int(imageSize.height * imageSize.width))
        var normals = [SCNVector3](repeating: SCNVector3(0, 1, 0), count: Int(imageSize.height * imageSize.width))
        var uvList: [vector_float2] = []
        uvList.reserveCapacity(Int(imageSize.height * imageSize.width))
        let cint: CInt = 0
        let sizeOfCInt = MemoryLayout.size(ofValue: cint)

        let geometryData = NSMutableData()
        for y in 0..<Int(imageSize.height) {
            let previousRowStart = (y - 1) * Int(imageSize.width)
            let currentRowStart = y * Int(imageSize.width)

            for x in 0..<Int(imageSize.width) {
                guard let z = TerrainNode.height(heights: heights, x: x, y: y), let xz = terrainImagePixelsToMeters(imageX: x, imageY: y) else {
                    NSLog("Couldn't coordinates for \(x),\(y)")
                    continue
                }

                vertices.append(SCNVector3Make(xz.x, Float(z), xz.z))

                //texture support
                uvList.append(vector_float2(Float(Float(x) / Float(imageSize.width)), Float(Float(y) / Float(imageSize.height))))

                //past first row, build the faces as we go (skipping first column)
                if y > 0 && x > 0 {
                    let globalBytes: [CInt] = [CInt(previousRowStart + x - 1 + vertexOffset), CInt(currentRowStart + x + vertexOffset), CInt(previousRowStart + x + vertexOffset),
                                         CInt(previousRowStart + x - 1 + vertexOffset), CInt(currentRowStart + x - 1 + vertexOffset), CInt(currentRowStart + x + vertexOffset)]
                    geometryData.append(globalBytes, length: sizeOfCInt * 6)

                    if (enableShadows) {
                        let bytes: [CInt] = [CInt(previousRowStart + x - 1), CInt(currentRowStart + x), CInt(previousRowStart + x),
                                             CInt(previousRowStart + x - 1), CInt(currentRowStart + x - 1), CInt(currentRowStart + x)]
                        TerrainNode.updateNormals(&normals, vertices: vertices, bytes: bytes)
                    }
                }
            }
        }

        for i in 0..<normals.count {
            normals[i] = SCNVector3Normalize(vector: normals[i])
        }

        return (element: SCNGeometryElement(data: geometryData as Data,
                                            primitiveType: .triangles,
                                            primitiveCount: (Int(imageSize.height) - 1) * (Int(imageSize.width) - 1) * 2,
                                            bytesPerIndex: sizeOfCInt),
                vertices: vertices,
                normals: normals,
                uvList: uvList)
    }

    //private func createGeometryForBottom(vertexOffset: Int) -> (element: SCNGeometryElement, vertices: [SCNVector3], normals: [SCNVector3], uvList: [vector_float2]) {
    private func createGeometryForBottom(vertexOffset: Int, imageSize: CGSize) async -> (element: SCNGeometryElement, vertices: [SCNVector3], normals: [SCNVector3], uvList: [vector_float2]) {

        let bottomGeometryData = NSMutableData()
        var vertices = [SCNVector3]()
        vertices.reserveCapacity(4)
        var uvList: [vector_float2] = []
        uvList.reserveCapacity(4)

        let minXZ = terrainImagePixelsToMeters(imageX: 0, imageY: 0)!
        let maxXZ = terrainImagePixelsToMeters(imageX: Int(imageSize.width) - 1, imageY: Int(imageSize.height) - 1)!
        vertices.append(SCNVector3Make(minXZ.x, Float(0.0), minXZ.z))
        uvList.append(vector_float2(Float(0.0), Float(0.0)))
        vertices.append(SCNVector3Make(maxXZ.x, Float(0.0), minXZ.z))
        uvList.append(vector_float2(Float(1.0), Float(0.0)))
        vertices.append(SCNVector3Make(minXZ.x, Float(0.0), maxXZ.z))
        uvList.append(vector_float2(Float(0.0), Float(1.0)))
        vertices.append(SCNVector3Make(maxXZ.x, Float(0.0), maxXZ.z))
        uvList.append(vector_float2(Float(1.0), Float(1.0)))

        let cint: CInt = 0
        let sizeOfCInt = MemoryLayout.size(ofValue: cint)

        let bottomEnd = vertices.count - 1 + vertexOffset
        let bytes: [CInt] = [CInt(bottomEnd - 3), CInt(bottomEnd), CInt(bottomEnd - 1),
                             CInt(bottomEnd - 3), CInt(bottomEnd - 2), CInt(bottomEnd)]
        bottomGeometryData.append(bytes, length: sizeOfCInt * 6)

        return (element: SCNGeometryElement(data: bottomGeometryData as Data,
                                            primitiveType: .triangles,
                                            primitiveCount: (vertices.count / 2 - 1) * 2,
                                            bytesPerIndex: sizeOfCInt),
                vertices: vertices,
                normals: [SCNVector3](repeating: SCNVector3(0, -1, 0), count: vertices.count),
                uvList: uvList)
    }

    //private func createGeometryForWall(xs: [Int], ys: [Int], normal: SCNVector3, maxHeight: Float, vertexOffset: Int) -> (element: SCNGeometryElement, vertices: [SCNVector3], normals: [SCNVector3], uvList: [vector_float2]) {
    private func createGeometryForWall(
            xs: [Int],
            ys: [Int],
            normal: SCNVector3,
            maxHeight: Float,
            vertexOffset: Int,
            terrainImageSize: CGSize,
            terrainHeights: [[Double]],
            terrainSizeInMeters: CGSize,
            metersPerPixelX: Double,
            metersPerPixelY: Double
        ) async throws -> (element: SCNGeometryElement, vertices: [SCNVector3], normals: [SCNVector3], uvList: [vector_float2]) {

        let sideGeometryData = NSMutableData()
        var vertices = [SCNVector3]()
        vertices.reserveCapacity(xs.count * ys.count * 2)
        var uvList: [vector_float2] = []
        uvList.reserveCapacity(xs.count * ys.count * 2)
        let cint: CInt = 0
        let sizeOfCInt = MemoryLayout.size(ofValue: cint)

        var textureX: Float = 0
        let length = Float(max(xs.count, ys.count))
        let lengthInMeters = Float(!xs.isEmpty ? metersPerPixelX : metersPerPixelY) * Float(length)
        let heightRatio: Float = maxHeight / lengthInMeters

        for x in xs {
            for y in ys {
                guard let z = TerrainNode.height(heights: terrainHeights, x: x, y: y), let xz = terrainImagePixelsToMeters(imageX: x, imageY: y) else {
                    NSLog("Couldn't coordinates for \(x),\(y)")
                    continue
                }

                let vertexBottom = SCNVector3Make(xz.x, 0.0, xz.z)
                vertices.append(vertexBottom)
                let vertexTop = SCNVector3Make(xz.x, Float(z), xz.z)
                vertices.append(vertexTop)

                uvList.append(vector_float2(Float(textureX / length), Float(Float(z) / maxHeight) * heightRatio))
                uvList.append(vector_float2(Float(textureX / length), Float(0)))

                textureX += 1
            }
        }

        for x in 0..<vertices.count where x > 2 && x % 2 != 0 {
            let bytes: [CInt] = [CInt(x + vertexOffset - 3), CInt(x + vertexOffset), CInt(x - 1 + vertexOffset),
                                 CInt(x + vertexOffset - 3), CInt(x - 2 + vertexOffset), CInt(x + vertexOffset)]
            sideGeometryData.append(bytes, length: sizeOfCInt * 6)
        }

        return (element: SCNGeometryElement(data: sideGeometryData as Data,
                                            primitiveType: .triangles,
                                            primitiveCount: (vertices.count / 2 - 1) * 2,
                                            bytesPerIndex: sizeOfCInt),
                vertices: vertices,
                normals: [SCNVector3](repeating: normal, count: vertices.count),
                uvList: uvList)
    }
}

//MARK: - Helpers

extension TerrainNode {
    fileprivate func terrainImagePixelsToMeters(imageX: Int, imageY: Int) -> (x: Float, z: Float)? {
        return (x: Float(imageX) * Float(metersPerPixelX), z: Float(imageY) * Float(metersPerPixelY))
    }

    fileprivate func latLonToMeters(location: CLLocation) -> (x: Float, z: Float) {
        let x = Float(location.coordinate.longitude - southWestCorner.coordinate.longitude) * Float(metersPerLon)
        let z = Float(northEastCorner.coordinate.latitude - location.coordinate.latitude) * Float(metersPerLat)
        return (x: Float(x), z: Float(z))
    }

    fileprivate static func updateNormals(_ normals: inout [SCNVector3], vertices: [SCNVector3], bytes: [CInt]) {
        //normal calculation for the faces. We'll normalize the final value later
        //http://www.iquilezles.org/www/articles/normals/normals.htm

        //TODO: I'm not 100% sure on this, I'm noticing weird shadowing (only noticable with less-complex texture images, like solid colors)
        let face1e1 = vertices[Int(bytes[0])] - vertices[Int(bytes[1])]
        let face1e2 = vertices[Int(bytes[2])] - vertices[Int(bytes[1])]
        let face2e1 = vertices[Int(bytes[3])] - vertices[Int(bytes[4])]
        let face2e2 = vertices[Int(bytes[5])] - vertices[Int(bytes[4])]
        let face1no = SCNVector3CrossProduct(left: face1e2, right: face1e1)
        let face2no = SCNVector3CrossProduct(left: face2e2, right: face2e1)

        for i in [bytes[0], bytes[1], bytes[2]] {
            normals[Int(i)] += face1no
        }
        for i in [bytes[3], bytes[4], bytes[5]] {
            normals[Int(i)] += face2no
        }
    }

    fileprivate static func height(heights: [[Double]], x: Float, z: Float, metersPerX: Double, metersPerY: Double) -> Double? {
        let imageX: Int = Int(x / Float(metersPerX))
        let imageY: Int = Int(z / Float(metersPerY))
        guard let imageHeight = TerrainNode.height(heights: heights, x: imageX, y: imageY) else {
            return nil
        }
        return imageHeight
    }

    fileprivate static func height(heights: [[Double]], x: Int, y: Int) -> Double? {
        guard heights.count > y, y >= 0, heights[y].count > x, x >= 0 else {
            return nil
        }
        return heights[y][x]
    }

    fileprivate static func heightFromImage(x: Int, y: Int, terrainData: UnsafePointer<UInt8>, terrainSize: CGSize, multiplier: Float) -> Double? {
        guard x < Int(terrainSize.width) && y < Int(terrainSize.height) else {
            return nil
        }

        let pixelInfo: Int = ((Int(terrainSize.width) * Int(y)) + Int(x)) * 4

        let r = Float(terrainData[pixelInfo])
        let g = Float(terrainData[pixelInfo + 1])
        let b = Float(terrainData[pixelInfo + 2])

        let terrainHeight = -10000 + ((r * 256 * 256 + g * 256 + b) * 0.1)
        return Double(terrainHeight * multiplier)
    }
}
