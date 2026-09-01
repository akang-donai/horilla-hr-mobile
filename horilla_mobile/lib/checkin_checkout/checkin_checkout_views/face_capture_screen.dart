import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

class FaceCaptureScreen extends StatefulWidget {
  const FaceCaptureScreen({super.key});

  @override
  State<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends State<FaceCaptureScreen> {
  CameraController? _controller;
  late Future<void> _initFuture;
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(performanceMode: FaceDetectorMode.fast),
  );
  bool _processing = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _initFuture = _initCamera();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      throw Exception('Camera permission denied');
    }
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _controller = CameraController(front, ResolutionPreset.medium, enableAudio: false);
    await _controller!.initialize();
  }

  Future<void> _captureAndVerify() async {
    if (_processing || _controller == null || !_controller!.value.isInitialized) return;
    setState(() {
      _processing = true;
      _message = 'Verifying...';
    });
    try {
      final xfile = await _controller!.takePicture();
      final file = File(xfile.path);
      final faces = await _detector.processImage(InputImage.fromFile(file));
      if (!mounted) return;
      if (faces.length == 1) {
        final face = faces.first;
        final size = face.boundingBox.width * face.boundingBox.height;
        final imageSize = file.lengthSync();
        // ponytail: rough size check — server does real verification
        if (size > 1000 || imageSize > 10000) {
          Navigator.pop(context, file.path);
          return;
        }
      }
      setState(() {
        _message = 'Position your face in the frame';
        _processing = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = 'Error: $e';
          _processing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _detector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Capture Selfie'), backgroundColor: Colors.red),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || _controller == null) {
            return Center(child: Text('Camera error: ${snapshot.error}'));
          }
          return Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CameraPreview(_controller!),
                ),
              ),
              const SizedBox(height: 16),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(_message!, style: const TextStyle(fontSize: 16)),
                ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _processing ? null : _captureAndVerify,
                icon: const Icon(Icons.camera_alt),
                label: Text(_processing ? 'Verifying...' : 'Capture'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}
