import UIKit
import SceneKit
import MapKit
import MapboxSceneKit

/**
 Simplest example of the Mapbox Scene Kit API: placing a flat box in Scene Kit and applying a user-created map style to the top surface.
 **/
class DemoStyleViewController: UIViewController {
    @IBOutlet private weak var sceneView: SCNView?
    @IBOutlet private weak var progressView: UIProgressView?
    @IBOutlet private weak var stylePicker: UISegmentedControl?
    private weak var terrainNode: TerrainNode?
    private var progressHandler: ProgressCompositor!

    private let styles = ["mapbox/outdoors-v10", "mapbox/satellite-v9", "mapbox/navigation-preview-day-v2"]

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        //Progress handler is a helper to aggregate progress through the three stages causing user wait: fetching heightmap images, calculating/rendering the heightmap, fetching the texture images
        progressHandler = ProgressCompositor(updater: { [weak self] progress in
            self?.progressView?.progress = progress
            self?.progressView?.isHidden = false
        }, completer: { [weak self] in
            self?.progressView?.isHidden = true
        })
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        guard let sceneView = sceneView else {
            return
        }

        let scene = TerrainDemoScene()
        sceneView.scene = scene

        //Add the default camera controls for iOS 11
        sceneView.pointOfView = scene.cameraNode
        sceneView.defaultCameraController.pointOfView = sceneView.pointOfView
        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        sceneView.defaultCameraController.inertiaEnabled = true
        sceneView.showsStatistics = true

        //Set up initial terrain and materials
        let terrainNode = TerrainNode(minLat: 50.044660402821592, maxLat: 50.120873988090956,
                                      minLon: -122.99017089272466, maxLon: -122.86824490727534)
        terrainNode.position = SCNVector3(0, 500, 0)
        terrainNode.geometry?.materials = defaultMaterials()
        scene.rootNode.addChildNode(terrainNode)

        //Now that we've set up the terrain, lets place the lighting and camera in nicer positions
        scene.directionalLight.constraints = [SCNLookAtConstraint(target: terrainNode)]
        scene.directionalLight.position = SCNVector3Make(terrainNode.boundingBox.max.x, terrainNode.boundingSphere.center.y + 5000, terrainNode.boundingBox.max.z)
        scene.cameraNode.position = SCNVector3(terrainNode.boundingBox.max.x * 2, 9000, terrainNode.boundingBox.max.z * 2)
        scene.cameraNode.look(at: terrainNode.position)

        self.terrainNode = terrainNode

        //Time to hit the web API and load Mapbox data for the terrain node
        applyStyle(styles.first!)
    }

    private var fetchTask: Task<Void, Error>?

    private func applyStyle(_ style: String) {
        guard let terrainNode = terrainNode else {
            return
        }

        self.progressView?.progress = 0.0
        self.progressView?.isHidden = false

        let textureFetchHandler = progressHandler.registerForProgress()
        
        fetchTask?.cancel()
        fetchTask = Task {
            await loadTexture(
                style: style,
                terrainNode: terrainNode,
                textureFetchHandler: textureFetchHandler
            )
        } // Task
        
    }

    private func loadTexture(
            style: String,
            terrainNode: TerrainNode,
            textureFetchHandler: Int
        ) async {
            var textureImage: UIImage?
            var textureFetchError: Error?
            do {
                textureImage = try await terrainNode.fetchTexture(
                    textureStyle: style,
                    textureProgress: { [weak self] (progress, total) in
                        Task { @MainActor in
                            //print("progress: \(progress) / \(total)")
                            self?.progressHandler.updateProgress(handlerID: textureFetchHandler, progress: progress, total: total)
                        }
                    })
            }
            catch {
                Task { @MainActor in
                    progressHandler.updateProgress(handlerID: textureFetchHandler, progress: 1, total: 1)
                }
                textureFetchError = error
            }
            
            if let textureFetchError = textureFetchError {
                print("Texture load failed: \(textureFetchError.localizedDescription)")
            }
        }

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

    @IBAction func swtichStyle(_ sender: Any?) {
        applyStyle(styles[stylePicker!.selectedSegmentIndex])
    }
}
