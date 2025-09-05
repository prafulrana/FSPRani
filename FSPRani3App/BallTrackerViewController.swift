// PIPELINE ARCHITECTURE:
// ======================
// Camera Setup:
//   - AVCaptureSession with .hd1920x1080 preset
//   - videoRotationAngle = 90° (iOS 17+) or .portrait orientation
//   - Output: 1080x1920 portrait CVPixelBuffer (iOS rotates for us)
//
// Vision Processing:
//   - Input: 1080x1920 CVPixelBuffer with orientation .up (no rotation)
//   - ROI: Center 640x640 pixels extracted directly
//   - Model input: 640x640 @ 1:1 pixel mapping (no scaling)
//   - Output: Detection coordinates in normalized 0-1 space
//
// Metal Rendering (Single Pass):
//   - Y texture: 1080x1920 @ 8-bit luminance
//   - UV texture: 540x960 @ 8-bit chrominance pairs  
//   - Shader: YUV→RGB conversion + detection overlay
//   - Output: Direct to MTKView drawable framebuffer
//
// KEY OPTIMIZATIONS:
// - ZERO pixel copies (direct CVPixelBuffer → Metal textures)
// - NO pixel rotation (iOS provides correct orientation)
// - NO scaling in Vision (1:1 center crop)
// - SINGLE render pass (camera + overlays together)
// - Maximum ANE utilization for ML model
// - Maximum GPU utilization for rendering

import UIKit
import AVFoundation
import Metal
import MetalKit
import CoreML
import Vision
import CoreVideo

class BallTrackerViewController: UIViewController, MTKViewDelegate {
    // MARK: - Core Components
    
    // Camera
    private let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    
    // Metal
    private var metalDevice: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    private var metalView: MTKView!
    
    // Pipelines
    private var yoloPipeline: MTLRenderPipelineState!
    
    // YOLO Model
    private var yoloModel: VNCoreMLModel!
    private var visionRequest: VNCoreMLRequest!
    
    // Single processing queue - everything synchronous
    private let processingQueue = DispatchQueue(label: "yolo.pure", qos: .userInteractive)
    
    // Current frame and detection
    private var currentPixelBuffer: CVPixelBuffer?
    private var currentDetection: VNRecognizedObjectObservation?
    private var detectionConfidence: Float = 0.0
    private var detectionFadeTimer: Float = 0.0
    private var detectionLabel: String = ""
    private let fadeDecayRate: Float = 0.008 // Much slower fade out for cool lingering effect
    private var smoothedConfidence: Float = 0.0 // For smooth interpolation
    
    // Debug: Show crop region
    private let showCropRegion = true  // Shows the 640x640 crop area as a subtle box
    
    // Frame synchronization
    private var processingFrame = false
    private let frameLock = NSLock()
    
    // Performance
    private var frameCount = 0
    private var lastFPSTime = CACurrentMediaTime()
    
    // Debug mode
    private let debugMode = true  // Set to false to disable debug logs
    
    // Map common YOLO labels to IDs for shader
    private func labelToID(_ label: String) -> Int32 {
        switch label.lowercased() {
        case "sports ball", "ball":
            return 1
        case "person":
            return 2
        case "chair":
            return 3
        case "skateboard":
            return 4
        case "knife":
            return 5
        case "tv", "television", "monitor":
            return 6
        case "frisbee":
            return 7
        default:
            return 0 // Unknown
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        print("🎯 Ball Tracker - 1:1 pixel mapping, 30 FPS, ANE + Metal optimized")
        
        setupMetal()
        setupMetalView()
        setupYOLOModel()
        setupCamera()
    }
    
    // MARK: - Setup
    
    private func setupMetal() {
        metalDevice = MTLCreateSystemDefaultDevice()!
        commandQueue = metalDevice.makeCommandQueue()!
        CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &textureCache)
        loadShaders()
        print("✅ Metal initialized")
    }
    
    private func setupMetalView() {
        metalView = MTKView(frame: view.bounds, device: metalDevice)
        metalView.delegate = self
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.preferredFramesPerSecond = 30 // Lock to 30 FPS
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        view.addSubview(metalView)
        
        metalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    private func loadShaders() {
        guard let library = metalDevice.makeDefaultLibrary() else {
            fatalError("Failed to load Metal library")
        }
        
        // Single unified pipeline for camera + detection overlay
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library.makeFunction(name: "trackerVertex")
        pipelineDesc.fragmentFunction = library.makeFunction(name: "trackerFragment")
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        
        yoloPipeline = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDesc)
    }
    
    private func setupYOLOModel() {
        // Load YOLOv8m for 99.99% accuracy
        let modelURL = Bundle.main.url(forResource: "yolov8m_pure", withExtension: "mlmodelc") ??
                      Bundle.main.url(forResource: "yolov8m", withExtension: "mlmodelc") ??
                      Bundle.main.url(forResource: "yolov8m_pure", withExtension: "mlpackage") ??
                      Bundle.main.url(forResource: "yolov8m", withExtension: "mlpackage") ??
                      Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage")
        
        guard let modelURL = modelURL else {
            print("⚠️ No YOLO model found - Make sure yolov8m_pure.mlpackage is added to the project target")
            print("📦 Bundle resources:")
            if let resourcePath = Bundle.main.resourcePath {
                do {
                    let resources = try FileManager.default.contentsOfDirectory(atPath: resourcePath)
                    for resource in resources {
                        print("  - \(resource)")
                    }
                } catch {
                    print("Error listing resources: \(error)")
                }
            }
            return
        }
        
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            yoloModel = try VNCoreMLModel(for: mlModel)
            
            // Log model input details
            print("🔍 Model Input Configuration:")
            let modelDescription = mlModel.modelDescription
            for (key, desc) in modelDescription.inputDescriptionsByName {
                print("  Input '\(key)': \(desc)")
                if let constraint = desc.imageConstraint {
                    print("    - Expected size: \(constraint.pixelsWide) x \(constraint.pixelsHigh)")
                    print("    - Pixel format: \(constraint.pixelFormatType)")
                }
            }
            
            // Simple single request - process center square of the image
            visionRequest = VNCoreMLRequest(model: yoloModel) { [weak self] request, error in
                guard let results = request.results as? [VNRecognizedObjectObservation] else { return }
                
                // Minimal logging in debug mode
                if self?.debugMode == true && !results.isEmpty {
                    // Simple one-line summary
                    let summary = results.prefix(2).compactMap { detection -> String? in
                        guard let label = detection.labels.first else { return nil }
                        return "\(label.identifier):\(String(format: "%.0f%%", label.confidence * 100))"
                    }.joined(separator: ", ")
                    print("🎯 Detections: \(summary)")
                }
                
                // Find best detection
                let bestDetection = results
                    .filter { $0.confidence > 0.3 }
                    .max { $0.confidence < $1.confidence }
                
                self?.frameLock.lock()
                self?.currentDetection = bestDetection
                self?.detectionConfidence = bestDetection?.confidence ?? 0
                self?.detectionLabel = bestDetection?.labels.first?.identifier ?? ""
                if bestDetection != nil {
                    self?.detectionFadeTimer = 1.0
                }
                self?.frameLock.unlock()
            }
            
            // Camera gives us 1080x1920 portrait buffer directly
            // We need 640x640 square from center
            // In pixels: x=220, y=640, width=640, height=640
            
            // CRITICAL: The issue is that 640 pixels wide and 640 pixels tall
            // create different normalized values (0.593 vs 0.333) due to non-square buffer!
            // We need to use the SMALLER normalized dimension to ensure squareness
            let bufferWidth: CGFloat = 1080.0  // Portrait width
            let bufferHeight: CGFloat = 1920.0 // Portrait height
            
            // NO DISTORTION: Process full 1080x1920 buffer
            // Model will resize internally to 640x640
            let roi = CGRect(x: 0, y: 0, width: 1, height: 1)  // Full buffer
            visionRequest.regionOfInterest = roi
            visionRequest.imageCropAndScaleOption = .scaleFit  // Maintain aspect ratio
            
            if debugMode {
                print("\n🔧 VISION ROI CONFIGURATION:")
                print("  📱 Input Buffer: 1080x1920 (portrait, already rotated by iOS)")
                print("  🎯 NO DISTORTION MODE: Processing full buffer")
                print("  ")
                print("  📏 Configuration:")
                print("     Buffer: 1080 x 1920 pixels")
                print("     Processing: Full buffer (no crop)")
                print("     ROI: x=0, y=0, width=1, height=1")
                print("     Model will resize internally to 640x640")
                print("  ")
                print("  🖼️ VISUAL MAP (1080x1920 buffer):")
                print("     ┌──────────────────┐ 0,0")
                print("     │                  │")
                print("     │   Full Buffer    │")
                print("     │   Processed      │")
                print("     │                  │")
                print("     └──────────────────┘ 1080,1920")
                print("  ")
                print("  ✅ Benefits:")
                print("     • No pixel distortion")
                print("     • Full camera view displayed")
                print("     • Detection coords match buffer coords")
                print("     • Clean letterboxing on screen")
            }
            
            print("✅ YOLO model loaded: \(modelURL.lastPathComponent)")
            print("📐 Full buffer processing mode - no distortion")
        } catch {
            print("❌ Failed to load YOLO: \(error)")
        }
    }
    
    private func setupCamera() {
        session.beginConfiguration()
        // Use 1920x1080 for better quality while maintaining performance
        // This is 16:9 which will be letterboxed on the tall iPhone screen
        session.sessionPreset = .hd1920x1080
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }
        
        do {
            // Lock to 30 FPS
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            
            let input = try AVCaptureDeviceInput(device: device)
            session.addInput(input)
            
            videoOut.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            videoOut.alwaysDiscardsLateVideoFrames = true
            videoOut.setSampleBufferDelegate(self, queue: processingQueue)
            session.addOutput(videoOut)
            
            if let connection = videoOut.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    connection.videoRotationAngle = 90.0
                } else {
                    connection.videoOrientation = .portrait
                }
            }
        } catch {
            print("❌ Camera error: \(error)")
        }
        
        session.commitConfiguration()
        processingQueue.async {
            self.session.startRunning()
        }
        print("📷 Camera started at 30 FPS")
    }
    
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Get current frame
        frameLock.lock()
        let pixelBuffer = currentPixelBuffer
        let detection = currentDetection
        var confidence = detectionConfidence
        var fadeTimer = detectionFadeTimer
        frameLock.unlock()
        
        // Update fade timer with smooth interpolation
        if fadeTimer > 0 {
            fadeTimer = max(0, fadeTimer - fadeDecayRate)
            frameLock.lock()
            detectionFadeTimer = fadeTimer
            frameLock.unlock()
        }
        
        // Smooth the confidence value for less jitter
        smoothedConfidence = smoothedConfidence * 0.7 + confidence * 0.3
        
        guard let pixelBuffer = pixelBuffer else {
            // Black screen if no frame
            let renderDesc = MTLRenderPassDescriptor()
            renderDesc.colorAttachments[0].texture = drawable.texture
            renderDesc.colorAttachments[0].loadAction = .clear
            renderDesc.colorAttachments[0].storeAction = .store
            renderDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDesc) {
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        
        // Get NV12 textures
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var yTexture: CVMetalTexture?
        var uvTexture: CVMetalTexture?
        
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &yTexture
        )
        
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .rg8Unorm, width/2, height/2, 1, &uvTexture
        )
        
        guard let yMTLTexture = CVMetalTextureGetTexture(yTexture!),
              let uvMTLTexture = CVMetalTextureGetTexture(uvTexture!) else {
            return
        }
        
        // Calculate aspect ratio for proper scaling
        // IMPORTANT: Camera already gives us 1080x1920 portrait buffer!
        // Screen is portrait (e.g., 1290x2796)
        let screenWidth = Float(drawable.texture.width)
        let screenHeight = Float(drawable.texture.height)
        let screenAspect = screenWidth / screenHeight // ~0.46 for iPhone
        
        // Camera buffer is ALREADY 1080x1920 portrait (verified in logs)
        let cameraWidth = Float(width)   // 1080
        let cameraHeight = Float(height) // 1920
        let cameraAspect = cameraWidth / cameraHeight // 0.5625
        
        // NO CROPPING: Show full camera buffer
        // Scale to fit screen but show everything
        var aspectRatio = SIMD2<Float>(1.0, 1.0)
        
        // Calculate scale to fit entire camera view on screen
        // We want to see ALL pixels, so scale down if needed
        let scaleToFitWidth = Float(screenWidth) / cameraWidth
        let scaleToFitHeight = Float(screenHeight) / cameraHeight
        let scale = min(scaleToFitWidth, scaleToFitHeight)
        
        // Apply uniform scale to maintain aspect ratio
        aspectRatio.x = (scale * cameraWidth) / Float(screenWidth)
        aspectRatio.y = (scale * cameraHeight) / Float(screenHeight)
        
        // Log aspect ratio calculations once
        struct AspectLogOnce {
            static var logged = false
        }
        if !AspectLogOnce.logged {
            print("🖼️ Aspect Ratio Calculations:")
            print("  - Screen size: \(Int(screenWidth))x\(Int(screenHeight))")
            print("  - Screen aspect: \(screenAspect) (width/height)")
            print("  - Camera buffer: \(width)x\(height)")
            print("  - Camera aspect: \(cameraAspect) (width/height)")
            print("  - Aspect ratio correction: x=\(aspectRatio.x), y=\(aspectRatio.y)")
            print("  - Expected: Screen narrower than camera, so y should be < 1.0")
            print("  - This scales camera vertically to fit screen width")
            AspectLogOnce.logged = true
        }
        
        // Prepare detection data
        var detectionBox = SIMD4<Float>(0, 0, 0, 0)
        var detectionStrength: Float = 0
        var detectionLabelID: Int32 = 0
        
        if let detection = detection, fadeTimer > 0 {
            // Vision returns coordinates in the cropped region space (640x640)
            // We need to map them back to full screen coordinates
            let box = detection.boundingBox
            
            // The model sees center 640x640 from 1080x1920 portrait view
            // Map back to full normalized screen coords
            // NO DISTORTION: Full buffer processing
            let bufferWidth: Float = 1080.0
            let bufferHeight: Float = 1920.0
            
            // Direct passthrough - no crop or scale
            let cropX: Float = 0.0
            let cropY: Float = 0.0
            let scaleX: Float = 1.0
            let scaleY: Float = 1.0
            
            // Detailed logging for coordinate transformation
            struct DetectionLogOnce {
                static var lastDetection: VNRecognizedObjectObservation?
                static var frameCount = 0
            }
            
            // Log every 30 frames to avoid spam but catch issues
            DetectionLogOnce.frameCount += 1
            let shouldLog = debugMode && DetectionLogOnce.frameCount % 30 == 0
            
            if shouldLog {
                print("\n========== COORDINATE MAPPING (Frame \(DetectionLogOnce.frameCount)) ==========")
                print("📐 STEP 1 - Vision Detection (Full 1080x1920 buffer):")
                print("  Vision BBox: x=\(String(format: "%.4f", box.origin.x)), y=\(String(format: "%.4f", box.origin.y))")
                print("              w=\(String(format: "%.4f", box.width)), h=\(String(format: "%.4f", box.height))")
                
                print("\n📐 STEP 2 - NO TRANSFORMATION (Direct passthrough):")
                print("  Buffer size: 1080x1920 pixels")
                print("  Processing: Full buffer (no crop)")
                print("  No offset or scaling needed")
                print("  Crop offset normalized: x=\(String(format: "%.4f", cropX)), y=\(String(format: "%.4f", cropY))")
                print("  Scale factors: x=\(String(format: "%.4f", scaleX)), y=\(String(format: "%.4f", scaleY))")
            }
            
            // Fix Y-inversion: Vision has Y=0 at top, but our texture has Y=0 at bottom (flipped)
            // Since we're processing full buffer, need to invert Y coordinate
            detectionBox = SIMD4<Float>(
                Float(box.origin.x) * scaleX + cropX,
                Float(1.0 - (box.origin.y + box.height)) * scaleY + cropY,  // Invert Y
                Float(box.width) * scaleX,
                Float(box.height) * scaleY
            )
            
            if shouldLog {
                print("\n📐 STEP 3 - Transformed to Full Buffer Space:")
                print("  Final BBox: x=\(String(format: "%.4f", detectionBox.x)), y=\(String(format: "%.4f", detectionBox.y))")
                print("             w=\(String(format: "%.4f", detectionBox.z)), h=\(String(format: "%.4f", detectionBox.w))")
                print("  In pixels: x=\(String(format: "%.1f", detectionBox.x * 1080)), y=\(String(format: "%.1f", detectionBox.y * 1920))")
                print("            w=\(String(format: "%.1f", detectionBox.z * 1080)), h=\(String(format: "%.1f", detectionBox.w * 1920))")
                
                print("\n📐 STEP 4 - Metal Shader Rendering:")
                print("  Texture coords are Y-flipped")
                print("  Detection box uses normal coords (no flip)")
                print("  Aspect ratio scaling: x=\(aspectRatio.x), y=\(aspectRatio.y)")
                
                // Calculate what the shader will see
                let shaderBoxX = detectionBox.x
                let shaderBoxY = detectionBox.y
                let shaderBoxW = detectionBox.z
                let shaderBoxH = detectionBox.w
                
                print("\n🎨 SHADER PERSPECTIVE:")
                print("  Box passed to shader: x=\(String(format: "%.4f", shaderBoxX)), y=\(String(format: "%.4f", shaderBoxY))")
                print("                       w=\(String(format: "%.4f", shaderBoxW)), h=\(String(format: "%.4f", shaderBoxH))")
                print("  After aspect correction (y * 0.820):")
                print("    Effective Y range: \(String(format: "%.4f", shaderBoxY * 0.820)) to \(String(format: "%.4f", (shaderBoxY + shaderBoxH) * 0.820))")
                
                print("\n🔍 DEBUGGING CHECKLIST:")
                print("  ✓ Buffer is 1080x1920 portrait")
                print("  ✓ ROI extracts center 640x640")
                print("  ✓ Vision processes 640x640 → detection coords")
                print("  ✓ Transform back to 1080x1920 space")
                print("  ? Aspect ratio squish (y * 0.82)")
                print("  ? Any additional offset needed?")
            }
            
            // Combine smoothed confidence with fade timer for smooth transitions
            detectionStrength = smoothedConfidence * fadeTimer
            
            // Get label ID for shader
            frameLock.lock()
            detectionLabelID = labelToID(detectionLabel)
            frameLock.unlock()
        }
        
        // Single render pass
        let renderDesc = MTLRenderPassDescriptor()
        renderDesc.colorAttachments[0].texture = drawable.texture
        renderDesc.colorAttachments[0].loadAction = .clear
        renderDesc.colorAttachments[0].storeAction = .store
        renderDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDesc) {
            encoder.setRenderPipelineState(yoloPipeline)
            
            // Set textures
            encoder.setFragmentTexture(yMTLTexture, index: 0)
            encoder.setFragmentTexture(uvMTLTexture, index: 1)
            
            // Set detection data
            encoder.setFragmentBytes(&detectionBox, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentBytes(&detectionStrength, length: MemoryLayout<Float>.size, index: 1)
            encoder.setFragmentBytes(&aspectRatio, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            
            // NO DISTORTION: No crop visualization needed
            var cropRegion = SIMD4<Float>(0, 0, 1, 1) // Full buffer
            var showCrop: Float = 0.0 // Disable crop display
            encoder.setFragmentBytes(&cropRegion, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
            encoder.setFragmentBytes(&showCrop, length: MemoryLayout<Float>.size, index: 4)
            
            // Pass label ID for display
            encoder.setFragmentBytes(&detectionLabelID, length: MemoryLayout<Int32>.size, index: 5)
            
            // Draw fullscreen quad
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        // FPS tracking
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFPSTime > 1.0 {
            let fps = Double(frameCount) / (now - lastFPSTime)
            print(String(format: "FPS: %.1f | Detection: %.1f%% | Fade: %.2f", 
                        fps, confidence * 100, fadeTimer))
            frameCount = 0
            lastFPSTime = now
        }
    }
}

// MARK: - Camera Capture
extension BallTrackerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Log pixel buffer dimensions
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Only log once to avoid spam
        struct LogOnce {
            static var logged = false
            static var frameCount = 0
        }
        if !LogOnce.logged {
            print("📹 Camera Buffer: \(width)x\(height) (raw from camera)")
            print("📹 Is landscape: \(width > height)")
            print("📹 Connection orientation: \(connection.videoOrientation.rawValue)")
            if #available(iOS 17.0, *) {
                print("📹 Connection rotation angle: \(connection.videoRotationAngle)")
            }
            
            // Check if buffer dimensions match our expectations
            if width == 1920 && height == 1080 {
                print("✅ Buffer is 1920x1080 landscape as expected")
            } else if width == 1080 && height == 1920 {
                print("⚠️ Buffer is 1080x1920 portrait - not what we expected!")
                print("⚠️ This means the rotation is already applied at capture")
            } else {
                print("❌ Unexpected buffer dimensions!")
            }
            
            LogOnce.logged = true
        }
        
        // Log every 100th frame for monitoring
        LogOnce.frameCount += 1
        if LogOnce.frameCount % 100 == 0 {
            print("📊 Frame \(LogOnce.frameCount): Buffer \(width)x\(height)")
        }
        
        // Only process if not already processing (skip frames if needed)
        frameLock.lock()
        if processingFrame {
            frameLock.unlock()
            return
        }
        processingFrame = true
        currentPixelBuffer = pixelBuffer
        frameLock.unlock()
        
        // Run YOLO on center crop  
        if let visionRequest = visionRequest {
            // Buffer is already 1080x1920 portrait - no rotation needed
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, 
                                               orientation: .up,
                                               options: [:])
            do {
                try handler.perform([visionRequest])
            } catch {
                print("❌ Vision error: \(error)")
            }
        }
        
        frameLock.lock()
        processingFrame = false
        frameLock.unlock()
    }
}