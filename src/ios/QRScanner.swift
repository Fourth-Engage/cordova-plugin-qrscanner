import Foundation
import AVFoundation

@objc(QRScanner)
final class QRScanner : CDVPlugin, AVCaptureMetadataOutputObjectsDelegate {
    final class CameraView: UIView {
        var videoPreviewLayer:AVCaptureVideoPreviewLayer?
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidChangeFrame), name: .UIKeyboardDidChangeFrame, object: nil)
        }
        
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        
        private func interfaceOrientationToVideoOrientation(_ orientation : UIInterfaceOrientation) -> AVCaptureVideoOrientation {
            switch (orientation) {
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: return .portrait
            }
        }
        
        override func layoutSublayers(of layer: CALayer) {
            super.layoutSublayers(of: layer)
            
            guard layer === self.layer else { return }
            layer.sublayers?.forEach { $0.frame = bounds }
            
            if videoPreviewLayer?.connection?.isVideoOrientationSupported == true {
                videoPreviewLayer?.connection?.videoOrientation = interfaceOrientationToVideoOrientation(UIApplication.shared.statusBarOrientation)
            }
            
            updateRectOfInterest()
        }
        
        func pause() {
            videoPreviewLayer?.connection?.isEnabled = false
        }
        
        func resume() {
            videoPreviewLayer?.connection?.isEnabled = true
        }
        
        func addPreviewLayer(_ previewLayer:AVCaptureVideoPreviewLayer) {
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = bounds
            layer.addSublayer(previewLayer)
            videoPreviewLayer = previewLayer
            updateRectOfInterest()
        }
        
        func removePreviewLayer() {
            videoPreviewLayer?.removeFromSuperlayer()
            videoPreviewLayer = nil
        }
        
        func updateRectOfInterest() {
            guard let videoPreviewLayer = videoPreviewLayer else { return }
            
            var scanRect = CGRect.zero
            
            //            1. If app screen width > (600 browser pixels * display density)
            //            scanning window width = (568 browser pixels * display density)
            //            scanning window height = 1/2 scanning window width
            //            scanning window top = (60 browser pixels * display density)
            //            scanning window left = (app screen width - scanning window width) / 2
            //            2. If app screen width <= (600 browser pixels * display density)
            //            scanning window width = app screen width - (2 * 16 browser pixels * display density)
            //            scanning window height = 1/2 scanning window width
            //            scanning window top = (48 browser pixels * display density)
            //            scanning window left = (16 browser pixels * display density)
            
            switch bounds.width {
            case 0:
                return
            case 0...600:
                scanRect.origin.x = 16
                scanRect.origin.y = 38
                scanRect.size.width = bounds.insetBy(dx: scanRect.origin.x, dy: 0).width
            case 600...:
                scanRect.size.width = 568
                scanRect.origin.y = 34
                scanRect.origin.x = (bounds.width - scanRect.width) / 2
            default:
                return
            }
            
            scanRect.size.height = scanRect.width/2
            let rectOfInterest = videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: scanRect)
            (videoPreviewLayer.session?.outputs.first(where: { $0 is AVCaptureMetadataOutput }) as? AVCaptureMetadataOutput)?.rectOfInterest = rectOfInterest
        }
        
        @objc private func keyboardDidChangeFrame(_ notification: Notification) {
            layer.setNeedsLayout()
            layer.layoutIfNeeded()
        }
    }
    
    lazy var cameraView: CameraView = {
        let frame = UIScreen.main.bounds
        let cameraView = CameraView(frame: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        return cameraView
    }()
    
    var captureSession:AVCaptureSession?
    var captureVideoPreviewLayer:AVCaptureVideoPreviewLayer?
    var metaOutput: AVCaptureMetadataOutput?

    var currentCamera = Camera.back
    var frontCamera: AVCaptureDevice?
    var backCamera: AVCaptureDevice?

    var isScanning = false
    var isPaused = false
    var nextScanningCommand: CDVInvokedUrlCommand?

    enum QRScannerError: Int32 {
        case unexpected
        case cameraAccessDenied
        case cameraAccessRestricted
        case backCameraUnavailable
        case frontCameraUnavailable
        case cameraUnavailable
        case scanCancelled
        case lightUnavailable
        case openSettingsUnavailable
    }

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    enum LightError: Error {
        case torchUnavailable
    }
    
    enum Camera: Int {
        case back
        case front
        
        var device: AVCaptureDevice? {
            switch self {
            case .back:
                return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            case .front:
                return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            }
        }
    }
    
    enum TorchMode {
        case on
        case off
        case unavailable
    }
    
    private var initialWebViewState: (isOpaque: Bool, backgroundColor: UIColor?)?
    private var torchMode = TorchMode.off

    override func pluginInitialize() {
        torchMode = .off
        super.pluginInitialize()
        initialWebViewState = (webView.isOpaque, webView.backgroundColor)
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidLoad), name: .CDVPageDidLoad, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: .UIApplicationDidBecomeActive, object: nil)
    }

    func sendErrorCode(command: CDVInvokedUrlCommand, error: QRScannerError){
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.rawValue)
        commandDelegate?.send(pluginResult, callbackId:command.callbackId)
    }

    @objc func prepScanner(command: CDVInvokedUrlCommand) -> Bool{
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .restricted:
            sendErrorCode(command: command, error: .cameraAccessRestricted)
            return false
        case .denied:
            sendErrorCode(command: command, error: .cameraAccessDenied)
            return false
        default:
            break
        }
        
        do {
            if captureSession?.isRunning != true {
                webView?.superview?.insertSubview(cameraView, belowSubview: webView!)
                cameraView.translatesAutoresizingMaskIntoConstraints = false
                cameraView.topAnchor.constraint(equalTo: webView.topAnchor).isActive = true
                cameraView.bottomAnchor.constraint(equalTo: webView.bottomAnchor).isActive = true
                cameraView.leadingAnchor.constraint(equalTo: webView.leadingAnchor).isActive = true
                cameraView.trailingAnchor.constraint(equalTo: webView.trailingAnchor).isActive = true
                
                backCamera = Camera.back.device
                frontCamera = Camera.front.device
                
                // older iPods have no back camera
                if backCamera == nil {
                    currentCamera = .front
                }
                
                let session = AVCaptureSession()
                session.addInput(try createCaptureDeviceInput())
                let metaOutput = AVCaptureMetadataOutput()
                session.addOutput(metaOutput)
                metaOutput.setMetadataObjectsDelegate(self, queue: .main)
                metaOutput.metadataObjectTypes = metaOutput.availableMetadataObjectTypes
                let captureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: session)
                cameraView.addPreviewLayer(captureVideoPreviewLayer)
                
                captureSession = session
                self.metaOutput = metaOutput
                self.captureVideoPreviewLayer = captureVideoPreviewLayer
                
                captureSession?.startRunning()
                cameraView.updateRectOfInterest()
            }
            
            return true
        } catch CaptureError.backCameraUnavailable {
            sendErrorCode(command: command, error: .backCameraUnavailable)
        } catch CaptureError.frontCameraUnavailable {
            sendErrorCode(command: command, error: .frontCameraUnavailable)
        } catch CaptureError.couldNotCaptureInput(let error){
            print(error.localizedDescription)
            sendErrorCode(command: command, error: .cameraUnavailable)
        } catch {
            sendErrorCode(command: command, error: .unexpected)
        }
        
        return false
    }

    @objc func createCaptureDeviceInput() throws -> AVCaptureDeviceInput {
        let captureDevice: AVCaptureDevice = try {
            switch currentCamera {
            case .back:
                guard let backCamera = backCamera else { throw CaptureError.backCameraUnavailable }
                return backCamera
            case .front:
                guard let frontCamera = frontCamera else { throw CaptureError.frontCameraUnavailable }
                return frontCamera
            }
        }()
        
        let device = captureDevice
        do {
            return try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.couldNotCaptureInput(error: error as NSError)
        }
    }
    
    private func executeHide() {
        webView?.backgroundColor = initialWebViewState?.backgroundColor
        webView?.isOpaque = initialWebViewState?.isOpaque ?? true
        
        cameraView.pause()
        cameraView.isHidden = true
    }
    
    private func executeShow() {
        webView?.backgroundColor = .clear
        webView?.isOpaque = false
        
        cameraView.resume()
        cameraView.isHidden = false
    }
    
    private func setTorchMode(_ torchMode: TorchMode) throws {
        guard torchMode != .unavailable else { throw LightError.torchUnavailable }
        
        let mode: AVCaptureDevice.TorchMode = {
            return torchMode == .on ? .on : .off
        }()
        
        // torch is only available for back camera
        guard backCamera != nil, backCamera?.hasTorch == true, backCamera?.isTorchAvailable == true, backCamera?.isTorchModeSupported(mode) == true else {
            self.torchMode = .unavailable
            throw LightError.torchUnavailable
        }
        
        self.torchMode = .off
        try backCamera?.lockForConfiguration()
        backCamera?.torchMode = mode
        backCamera?.unlockForConfiguration()
        self.torchMode = torchMode
    }

    @objc func configureLight(command: CDVInvokedUrlCommand, state: Bool) {
        do {
            try setTorchMode(state ? .on : .off)
            getStatus(command)
        } catch LightError.torchUnavailable {
            sendErrorCode(command: command, error: .lightUnavailable)
        } catch {
            print((error as NSError).debugDescription)
            sendErrorCode(command: command, error: .unexpected)
        }
    }

    // This method processes metadataObjects captured by iOS.
    func metadataOutput(_ captureOutput: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard isScanning, metadataObjects.isEmpty == false, let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject else {
            // while nothing is detected, or if scanning is false, do nothing.
            return
        }
        
        if captureOutput.metadataObjectTypes.contains(object.type), let stringValue = object.stringValue {
            isScanning = false
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: stringValue)
            commandDelegate?.send(pluginResult, callbackId: nextScanningCommand?.callbackId)
            nextScanningCommand = nil
        }
    }

    @objc private func pageDidLoad() {
        executeShow()
    }
    
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        try? setTorchMode(torchMode)
    }

    //MARK: - EXTERNAL API
    @objc func prepare(_ command: CDVInvokedUrlCommand){
        let prepareClosure = { [weak self] in
            if self?.prepScanner(command: command) == true {
                self?.getStatus(command)
            }
        }
        
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            prepareClosure()
            return
        }
        
        AVCaptureDevice.requestAccess(for: .video) { (granted) in
            // attempt to prepScanner only after the request returns
            DispatchQueue.main.async(execute: prepareClosure)
        }
    }

    @objc func scan(_ command: CDVInvokedUrlCommand){
        guard prepScanner(command: command) else { return }
        nextScanningCommand = command
        isScanning = true
    }

    @objc func cancelScan(_ command: CDVInvokedUrlCommand){
        guard prepScanner(command: command) else { return }
        isScanning = false
        
        if nextScanningCommand != nil {
            sendErrorCode(command: nextScanningCommand!, error: .scanCancelled)
        }
        
        getStatus(command)
    }

    @objc func show(_ command: CDVInvokedUrlCommand) {
        executeShow()
        getStatus(command)
    }

    @objc func hide(_ command: CDVInvokedUrlCommand) {
        executeHide()
        getStatus(command)
    }

    @objc func pausePreview(_ command: CDVInvokedUrlCommand) {
        if isScanning {
            isPaused = true
            isScanning = false
        }
        
        captureVideoPreviewLayer?.connection?.isEnabled = false
        getStatus(command)
    }

    @objc func resumePreview(_ command: CDVInvokedUrlCommand) {
        if isPaused {
            isPaused = false
            isScanning = true
        }
        
        captureVideoPreviewLayer?.connection?.isEnabled = true
        getStatus(command)
    }

    // backCamera is 0, frontCamera is 1
    @objc func useCamera(_ command: CDVInvokedUrlCommand){
        guard let index = command.arguments[0] as? Int, let newCamera = Camera(rawValue: index) else { return }
        guard currentCamera != newCamera else {
            // immediately return status if camera is unchanged
            self.getStatus(command)
            return
        }
        
        guard backCamera != nil, frontCamera != nil else {
            self.sendErrorCode(command: command, error: backCamera == nil ? QRScannerError.backCameraUnavailable : QRScannerError.frontCameraUnavailable)
            return
        }
        
        currentCamera = newCamera
        
        if self.prepScanner(command: command) {
            do {
                captureSession?.beginConfiguration()
                let currentInput = captureSession?.inputs[0] as! AVCaptureDeviceInput
                captureSession?.removeInput(currentInput)
                let input = try self.createCaptureDeviceInput()
                captureSession?.addInput(input)
                captureSession?.commitConfiguration()
                self.getStatus(command)
            } catch CaptureError.backCameraUnavailable {
                sendErrorCode(command: command, error: .backCameraUnavailable)
            } catch CaptureError.frontCameraUnavailable {
                sendErrorCode(command: command, error: .frontCameraUnavailable)
            } catch CaptureError.couldNotCaptureInput(let error){
                print(error.debugDescription)
                sendErrorCode(command: command, error: .cameraUnavailable)
            } catch {
                sendErrorCode(command: command, error: .unexpected)
            }
        }
    }

    @objc func enableLight(_ command: CDVInvokedUrlCommand) {
        if prepScanner(command: command) {
            configureLight(command: command, state: true)
        }
    }

    @objc func disableLight(_ command: CDVInvokedUrlCommand) {
        if prepScanner(command: command) {
            configureLight(command: command, state: false)
        }
    }

    @objc func destroy(_ command: CDVInvokedUrlCommand) {
        executeHide()
        
        guard captureSession != nil else {
            getStatus(command)
            return
        }
        
        captureSession?.stopRunning()
        cameraView.removePreviewLayer()
        captureVideoPreviewLayer = nil
        metaOutput = nil
        captureSession = nil
        currentCamera = .back
        frontCamera = nil
        backCamera = nil
        
        getStatus(command)
    }

    @objc func getStatus(_ command: CDVInvokedUrlCommand){
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let authorized = authorizationStatus == .authorized
        let denied = authorizationStatus == .denied
        let restricted = authorizationStatus == .restricted
        let prepared = captureSession?.isRunning == true
        let previewing = captureVideoPreviewLayer?.connection?.isEnabled == true
        let showing = webView?.backgroundColor == .clear
        let lightEnabled = backCamera?.torchMode == .on
        let canEnableLight = backCamera?.hasTorch == true && backCamera?.isTorchAvailable == true && backCamera?.isTorchModeSupported(.on) == true
        let canChangeCamera = backCamera != nil && frontCamera != nil
        
        func boolToNumberString(bool: Bool) -> String {
            return bool ? "1" : "0"
        }

        let status = [
            "authorized": boolToNumberString(bool: authorized),
            "denied": boolToNumberString(bool: denied),
            "restricted": boolToNumberString(bool: restricted),
            "prepared": boolToNumberString(bool: prepared),
            "scanning": boolToNumberString(bool: isScanning),
            "previewing": boolToNumberString(bool: previewing),
            "showing": boolToNumberString(bool: showing),
            "lightEnabled": boolToNumberString(bool: lightEnabled),
            "canOpenSettings": boolToNumberString(bool: true),
            "canEnableLight": boolToNumberString(bool: canEnableLight),
            "canChangeCamera": boolToNumberString(bool: canChangeCamera),
            "currentCamera": String(currentCamera.rawValue)
        ]

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        commandDelegate?.send(pluginResult, callbackId:command.callbackId)
    }

    @objc func openSettings(_ command: CDVInvokedUrlCommand) {
        let urlString: String
        #if swift(>=5)
            urlString = UIApplication.openSettingsURLString
        #else
            urlString = UIApplicationOpenSettingsURLString
        #endif
        
        guard let settingsUrl = URL(string: urlString) else {
            sendErrorCode(command: command, error: .openSettingsUnavailable)
            return
        }
        
        if UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl) { [weak self] _ in self?.getStatus(command) }
        } else {
            sendErrorCode(command: command, error: .openSettingsUnavailable)
        }
    }
}
