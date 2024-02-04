//
//  ViewController.swift
//  ARPosture
//
//  Created by Alice Orlandini on 01/08/23.
//

import UIKit
import RealityKit
import ARKit
import FirebaseStorage
import ModelIO
import MetalKit
import AlertKit

class ViewController: UIViewController, ARSessionDelegate {

    @IBOutlet var mainView: UIView!
    @IBOutlet var scanButton: UIButton!
    @IBOutlet var arView: ARView!
    @IBOutlet var infoStackView: UIStackView!
    @IBOutlet var numberOfScansLabel: UILabel!
    @IBOutlet var timeNextScanLabel: UILabel!
    @IBOutlet var timeElapsedLabel: UILabel!
    
    let storage = Storage.storage()
    var timer: Timer? = nil { willSet { timer?.invalidate() } }
    let timeInterval: Int = 30 // minimum 30 seconds
    var isScanning: Bool = false
    var numberOfScans: Int = 0
    var timeNextScan: Int = 0
    var timeElapsed: Int = 0
    let savingAlert = AlertAppleMusic17View(title: "Saving...", subtitle: "", icon: .spinnerSmall)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.arView.session.delegate = self
        
        self.arView.debugOptions.insert(.showSceneUnderstanding)
        
        self.arView.automaticallyConfigureSession = false
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        // configuration.planeDetection = [.horizontal, .vertical]
        self.arView.session.run(configuration)
        
        self.scanButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        self.scanButton.titleLabel?.tintColor = .white
        self.scanButton.layer.cornerRadius = 5
        self.scanButton.backgroundColor = .systemGreen
        self.scanButton.setTitle("Start Scanning", for: .normal)
        
        self.infoStackView.addBackground(color: .systemGray5)
        self.timeElapsedLabel.text = "\(self.timeElapsed / 3600)h \((self.timeElapsed % 3600) / 60)m \((self.timeElapsed % 3600) % 60)s"
        self.timeNextScanLabel.text = "\(self.timeInterval)"
        self.numberOfScansLabel.text = "\(self.numberOfScans)"
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // prevent the screen from being dimmed to avoid interrupting the AR experience
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        guard error is ARError else { return }
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        DispatchQueue.main.async {
            // present an alert informing about the error that has occurred
            let alertController = UIAlertController(title: "The AR session failed.", message: errorMessage, preferredStyle: .alert)
            let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
                alertController.dismiss(animated: true, completion: nil)
            }
            alertController.addAction(restartAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    @IBAction func scanButtonPressed(_ sender: Any) {
        if(self.isScanning) {
            self.scanButton.setTitle("Start Scanning", for: .normal)
            self.scanButton.backgroundColor = .systemGreen
            
            self.stopTimer()
            AlertKitAPI.present(title: "Scans stopped successfully", icon: .done, style: .iOS17AppleMusic, haptic: .success)
        } else {
            self.scanButton.setTitle("Stop Scanning", for: .normal)
            self.scanButton.backgroundColor = .systemRed
            self.numberOfScans = 0
            self.timeNextScan = self.timeInterval
            self.timeElapsed = 0
            
            self.startTimer()
            AlertKitAPI.present(title: "Scan with a \(timeInterval) second interval started successfully", icon: .done, style: .iOS17AppleMusic, haptic: .success)
        }
        self.isScanning = !self.isScanning
    }
    
    private func startTimer() {
        self.stopTimer()
        guard self.timer == nil else { return }
        // scheduling timer to call the function "timerFunction" with the interval of 1 seconds
        self.timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(self.timerFunction), userInfo: nil, repeats: true)
    }
    
    private func stopTimer() {
        guard self.timer != nil else { return }
        self.timer?.invalidate()
        self.timer = nil
    }
    
    @objc func timerFunction() {
        self.timeNextScan -= 1
        self.timeNextScanLabel.text = "\(self.timeNextScan)"
        self.timeElapsed += 1
        self.timeElapsedLabel.text = "\(self.timeElapsed / 3600)h \((self.timeElapsed % 3600) / 60)m \((self.timeElapsed % 3600) % 60)s"
        
        if(self.timeNextScan == 0) {
            self.savingAlert.present(on: mainView)
            self.saveScan()
            self.timeNextScan = self.timeInterval
        } else if(self.timeNextScan == self.timeInterval/2) {
            self.resetSessionTracking()
        }
    }
    
    private func resetSessionTracking() {
        if let configuration = self.arView.session.configuration {
            self.arView.session.run(configuration, options: [.removeExistingAnchors, .resetTracking, ])
        }
    }
    
    // exporting the LIDAR scan as OBJ file
    // author: Stefan Pfeifer
    private func saveScan() {
        
        guard let frame = self.arView.session.currentFrame else {
            AlertKitAPI.present(title: "Couldn't get the current ARFrame", icon: .error, style: .iOS17AppleMusic, haptic: .error)
            return
        }
        
        // fetch the default MTLDevice to initialize a MetalKit buffer allocator with
        guard let device = MTLCreateSystemDefaultDevice() else {
            AlertKitAPI.present(title: "Failed to get the system's default Metal device!", icon: .error, style: .iOS17AppleMusic, haptic: .error)
            return
        }
        
        // using the Model I/O framework to export the scan, so we're initialising an MDLAsset object,
        // which we can export to a file later, with a buffer allocator
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(bufferAllocator: allocator)
        
        // fetch all ARMeshAncors
        let meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor })
        
        // convert the geometry of each ARMeshAnchor into a MDLMesh and add it to the MDLAsset
        for meshAncor in meshAnchors {
            
            // some short handles, otherwise stuff will get pretty long in a few lines
            let geometry = meshAncor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            let verticesPointer = vertices.buffer.contents()
            let facesPointer = faces.buffer.contents()
            
            // converting each vertex of the geometry from the local space of their ARMeshAnchor to world space
            for vertexIndex in 0..<vertices.count {
                
                // extracting the current vertex with an extension method provided by Apple in Extensions.swift
                let vertex = geometry.vertex(at: UInt32(vertexIndex))
                
                // building a transform matrix with only the vertex position
                // and apply the mesh anchors transform to convert into world space
                var vertexLocalTransform = matrix_identity_float4x4
                vertexLocalTransform.columns.3 = SIMD4<Float>(x: vertex.0, y: vertex.1, z: vertex.2, w: 1)
                let vertexWorldPosition = (meshAncor.transform * vertexLocalTransform).position
                
                // writing the world space vertex back into it's position in the vertex buffer
                let vertexOffset = vertices.offset + vertices.stride * vertexIndex
                let componentStride = vertices.stride / 3
                verticesPointer.storeBytes(of: vertexWorldPosition.x, toByteOffset: vertexOffset, as: Float.self)
                verticesPointer.storeBytes(of: vertexWorldPosition.y, toByteOffset: vertexOffset + componentStride, as: Float.self)
                verticesPointer.storeBytes(of: vertexWorldPosition.z, toByteOffset: vertexOffset + (2 * componentStride), as: Float.self)
            }
            
            // initializing MDLMeshBuffers with the content of the vertex and face MTLBuffers
            let byteCountVertices = vertices.count * vertices.stride
            let byteCountFaces = faces.count * faces.indexCountPerPrimitive * faces.bytesPerIndex
            let vertexBuffer = allocator.newBuffer(with: Data(bytesNoCopy: verticesPointer, count: byteCountVertices, deallocator: .none), type: .vertex)
            let indexBuffer = allocator.newBuffer(with: Data(bytesNoCopy: facesPointer, count: byteCountFaces, deallocator: .none), type: .index)
            
            // creating a MDLSubMesh with the index buffer and a generic material
            let indexCount = faces.count * faces.indexCountPerPrimitive
            let material = MDLMaterial(name: "mat1", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
            let submesh = MDLSubmesh(indexBuffer: indexBuffer, indexCount: indexCount, indexType: .uInt32, geometryType: .triangles, material: material)
            
            // creating a MDLVertexDescriptor to describe the memory layout of the mesh
            let vertexFormat = MTKModelIOVertexFormatFromMetal(vertices.format)
            let vertexDescriptor = MDLVertexDescriptor()
            vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: vertexFormat, offset: 0, bufferIndex: 0)
            vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: meshAncor.geometry.vertices.stride)
            
            // finally creating the MDLMesh and adding it to the MDLAsset
            let mesh = MDLMesh(vertexBuffer: vertexBuffer, vertexCount: meshAncor.geometry.vertices.count, descriptor: vertexDescriptor, submeshes: [submesh])
            asset.add(mesh)
        }
        
        // setting the path to export the OBJ file to
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let urlOBJ = documentsPath.appendingPathComponent("scan.obj")
        
        // exporting the OBJ file
        if MDLAsset.canExportFileExtension("obj") {
            do {
                try asset.export(to: urlOBJ)
                
                // upload the OBJ file to Firebase Storage
                // let file_name = formatter.string(from: Date())
                let current_timestamp = Int(Date().timeIntervalSince1970)
                let scanRef = self.storage.reference().child("public/\(current_timestamp).obj")
                scanRef.putFile(from: urlOBJ, metadata: nil) { metadata, error in
                    if let error = error {
                        print("Can't upload file: \(error.localizedDescription)")
                        AlertKitAPI.present(title: "Can't upload file: \(error.localizedDescription)", icon: .error, style: .iOS17AppleMusic, haptic: .error)
                        return
                    } else if let metadata = metadata {
                        // metadata contains file metadata such as size, content-type
                        self.numberOfScans += 1
                        self.numberOfScansLabel.text = String(self.numberOfScans)
                        print("File uploaded successfully, file size: \(metadata.size)")
                        self.savingAlert.dismiss()
                        AlertKitAPI.present(title: "File uploaded successfully", icon: .done, style: .iOS17AppleMusic, haptic: .success)
                    }
                    
                }
            } catch let error {
                AlertKitAPI.present(title: "Error: \(error.localizedDescription)", icon: .error, style: .iOS17AppleMusic, haptic: .error)
                return
            }
        } else {
            AlertKitAPI.present(title: "Can't export file", icon: .error, style: .iOS17AppleMusic, haptic: .error)
            return
        }
    }
}
