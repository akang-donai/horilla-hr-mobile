import 'dart:io';
import 'dart:developer';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

// TODO: Task 11 will replace this file with google_mlkit_face_detection implementation
class FaceScannerController {
  late CameraController cameraController;
  late CameraDescription selectedCamera;

  bool _isInitialized = false;

  Future initializeCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        throw Exception('Camera permission not granted');
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }
      selectedCamera = cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await cameraController.initialize();
      _isInitialized = true;
      log('Camera initialized successfully');
    } catch (e) {
      log('Error initializing camera: $e');
      _isInitialized = false;
      rethrow;
    }
  }

  Future<XFile?> captureImage() async {
    if (!_isInitialized || !cameraController.value.isInitialized) {
      log('Camera not initialized or already disposed');
      return null;
    }
    try {
      if (cameraController.value.isTakingPicture) {
        log('Camera is already taking a picture');
        return null;
      }
      await Future.delayed(const Duration(milliseconds: 200));
      final image = await cameraController.takePicture();
      log('Image captured successfully at ${image.path}');
      final file = File(image.path);
      if (!file.existsSync()) {
        throw Exception('Captured image file not found');
      }
      final length = await file.length();
      if (length == 0) {
        throw Exception('Captured image file is empty');
      }
      return image;
    } catch (e) {
      log('Error capturing image: $e');
      return null;
    }
  }

  Future<bool> compareFaces(File capturedImageFile, String storedImageBase64) async {
    // TODO: Task 11 will implement face comparison with google_mlkit_face_detection
    log('Face comparison not yet implemented - pending Task 11');
    return false;
  }

  void dispose() {
    if (cameraController.value.isInitialized) {
      cameraController.dispose();
      log('Camera controller disposed');
    }
  }
}
