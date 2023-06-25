import UIKit
import SceneKit
import MapboxMaps
import MapboxSceneKit


class DemoExtrusionViewController: UIViewController {
    @IBOutlet private weak var sceneView: SCNView?

    private var mapView: MapView!
    private var terrainDemoScene: TerrainDemoScene?
    private var terrainNode: TerrainNode?

    private var progressHandler: ProgressCompositor!
    private var fetchTask: Task<Void, Error>?
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        
        //Progress handler is a helper to aggregate progress through the three stages causing user wait: fetching heightmap images, calculating/rendering the heightmap, fetching the texture images
        progressHandler = ProgressCompositor(updater: { [weak self] progress in
            //self?.progressView?.progress = progress
            //self?.progressView?.isHidden = false
        }, completer: { [weak self] in
            //self?.progressView?.isHidden = true
        })
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(red: 21.0/255.0, green:37.0/255.0, blue:54.0/255.0, alpha:1)
        mapView = MapView(frame: CGRect(x: 0, y: CGRectGetHeight(view.bounds) / 2.0, width: CGRectGetWidth(view.bounds), height: CGRectGetHeight(view.bounds) / 2.0))
        // _mapView.allowsRotating = NO;
        mapView.gestures.delegate = self
        view.addSubview(mapView)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        guard let sceneView = sceneView else {
            return
        }

        sceneView.frame = CGRect(x: 0, y: 0, width: CGRectGetWidth(self.view.bounds), height: CGRectGetHeight(self.view.bounds) / 2.0)
        sceneView.isUserInteractionEnabled = true
        sceneView.isMultipleTouchEnabled = true
        sceneView.allowsCameraControl = true
        view.insertSubview(sceneView, belowSubview: mapView)
        
        terrainDemoScene = TerrainDemoScene()
        terrainDemoScene?.background.contents = UIColor.clear
        terrainDemoScene?.floorColor = UIColor.clear
        terrainDemoScene?.floorReflectivity = 0
        sceneView.scene = terrainDemoScene

        sceneView.backgroundColor = UIColor.clear
        sceneView.pointOfView = terrainDemoScene?.cameraNode
        sceneView.defaultCameraController.pointOfView = sceneView.pointOfView
        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        sceneView.defaultCameraController.inertiaEnabled = true
        sceneView.showsStatistics = true
        
        
        mapView.mapboxMap.setCamera(to: CameraOptions(center: CLLocationCoordinate2D(latitude: 37.747706422053454, longitude: -122.45031891542874), zoom: 13))
    }
    
    override func viewDidLayoutSubviews() {
        mapView.frame = CGRect(x: 0, y: CGRectGetHeight(view.bounds) / 2.0, width: CGRectGetWidth(view.bounds), height: CGRectGetHeight(view.bounds) / 2.0)
        sceneView?.frame = CGRect(x: 0, y: 0, width: CGRectGetWidth(view.bounds), height: CGRectGetHeight(view.bounds) / 2.0)
    }
    
    // MARK: SceneKit Setup Methods
    
    private func defaultMaterials() -> [SCNMaterial] {
        let groundImage = SCNMaterial()
        groundImage.diffuse.contents = UIColor.darkGray
        groundImage.name = "Ground texture"

        let sideMaterial = SCNMaterial()
        sideMaterial.diffuse.contents = UIColor.darkGray
        //TODO: Some kind of bug with the normals for sides where not having them double-sided has them not show up
        sideMaterial.isDoubleSided = true
        sideMaterial.name = "Side"

        let bottomMaterial = SCNMaterial()
        bottomMaterial.diffuse.contents = UIColor.black
        bottomMaterial.name = "Bottom"

        return [sideMaterial, sideMaterial, sideMaterial, sideMaterial, groundImage, bottomMaterial]
    }
    
    private func refreshSceneView() {
        if let terrainNode = terrainNode {
            terrainNode.removeFromParentNode()
            self.terrainNode = nil
        }
        
        //let coordinateBounds = mapView.mapboxMap.cameraBounds
        let options = CameraOptions(center: mapView.cameraState.center, zoom: mapView.cameraState.zoom)
        let coordinateBounds = mapView.mapboxMap.coordinateBounds(for: options)

        terrainNode = TerrainNode(minLat: coordinateBounds.southwest.latitude, maxLat:coordinateBounds.northeast.latitude, minLon:coordinateBounds.southwest.longitude, maxLon:coordinateBounds.northeast.longitude)
        
        terrainNode?.position = SCNVector3(0, 0, 0)
        terrainNode?.geometry?.materials = defaultMaterials()
        if let terrainNode = terrainNode {
            terrainDemoScene?.rootNode.addChildNode(terrainNode)

            let boundingBox = terrainNode.boundingBox
            let boundingSphere = terrainNode.boundingSphere
            terrainDemoScene?.directionalLight.constraints = [SCNLookAtConstraint(target: terrainNode)]
            terrainDemoScene?.directionalLight.position = SCNVector3Make(boundingBox.max.x, boundingSphere.center.y + 5000, boundingBox.max.z)
            
            terrainDemoScene?.cameraNode.position = SCNVector3Make(boundingBox.max.x * 2, 2000, boundingBox.max.z * 2.0)
            
            terrainDemoScene?.cameraNode.look(at: terrainNode.position)
            #if false
            terrainNode.fetchTerrainAndTexture(minWallHeight: 50.0, multiplier: 1.5, enableDynamicShadows: true, textureStyle: "mapbox/satellite-v9") { error in
                if let fetchError = error {
                    print("Texture load failed: \(fetchError.localizedDescription)")
                } else {
                    print("Terrain load complete")
                }
            } textureCompletion: { [weak self] (image, error) in
                if let fetchError = error {
                    print("Texture load failed: \(fetchError.localizedDescription)")
                }
                
                if let image = image {
                    print("terrain texture fetch completed")
                    self?.terrainNode?.geometry?.materials[4].diffuse.contents = image
                }
            }
            #endif
            
            let terrainFetcherHandler = progressHandler.registerForProgress()
            let terrainRendererHandler = progressHandler.registerForProgress()
            let textureFetchHandler = progressHandler.registerForProgress()
            
            fetchTask?.cancel()
            fetchTask = Task {
                await loadTerrain(
                    terrainNode: terrainNode,
                    terrainFetcherHandler: terrainFetcherHandler,
                    terrainRendererHandler: terrainRendererHandler
                )

                await loadTexture(
                    style: "mapbox/satellite-v9",
                    terrainNode: terrainNode,
                    textureFetchHandler: textureFetchHandler
                )
            } // Task
        }
    }
    
    private func loadTerrain(
        terrainNode: TerrainNode,
        terrainFetcherHandler: Int,
        terrainRendererHandler: Int
    ) async {
        do {
            try await terrainNode.fetchTerrain(
                minWallHeight: 50.0,
                multiplier: 1.5,
                enableDynamicShadows: false,
                heightProgress: nil,
                rendererProgress: nil
            )
        }
        catch {
            print("error: \(error)")
        }
    }
    
    private func loadTexture(
            style: String,
            terrainNode: TerrainNode,
            textureFetchHandler: Int
    ) async {
        do {
            _ = try await terrainNode.fetchTexture(
                textureStyle: style,
                textureProgress: nil)
        }
        catch {
            print("Texture load failed: \(error.localizedDescription)")
        }
    }
}

extension DemoExtrusionViewController: GestureManagerDelegate {
    func gestureManager(_ gestureManager: MapboxMaps.GestureManager, didBegin gestureType: MapboxMaps.GestureType) {
        
    }
    
    func gestureManager(_ gestureManager: MapboxMaps.GestureManager, didEndAnimatingFor gestureType: MapboxMaps.GestureType) {
        
    }
    
    func gestureManager(_ gestureManager: MapboxMaps.GestureManager, didEnd gestureType: MapboxMaps.GestureType, willAnimate: Bool) {
        self.refreshSceneView()
    }

}
