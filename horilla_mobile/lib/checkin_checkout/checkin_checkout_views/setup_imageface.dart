import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:nira/horilla_main/home.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../../core/api_client.dart';
import 'checkin_checkout_form.dart';

class CameraSetupPage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraSetupPage({required this.cameras});

  @override
  _CameraSetupPageState createState() => _CameraSetupPageState();
}

class _CameraSetupPageState extends State<CameraSetupPage> {
  CameraController? _controller;
  late Future _initializeControllerFuture;
  XFile? _capturedImage;
  final ImagePicker _picker = ImagePicker();
  int selectedCameraIndex = 0;
  bool _isControllerInitialized = false;

  @override
  void initState() {
    super.initState();
    _setupCamera();
  }

  Future _setupCamera() async {
    try {
      CameraDescription selectedCamera;

      CameraDescription? frontCamera;
      CameraDescription? backCamera;

      for (var camera in widget.cameras) {
        if (camera.lensDirection == CameraLensDirection.front) {
          frontCamera = camera;
        } else if (camera.lensDirection == CameraLensDirection.back) {
          backCamera = camera;
        }
      }

      if (selectedCameraIndex == 0 && frontCamera != null) {
        selectedCamera = frontCamera;
      } else if (backCamera != null) {
        selectedCamera = backCamera;
      } else {
        selectedCamera = widget.cameras.first;
      }

      _controller = CameraController(selectedCamera, ResolutionPreset.medium);

      _initializeControllerFuture = _controller!.initialize();

      await _initializeControllerFuture;

      if (mounted) {
        setState(() {
          _isControllerInitialized = true;
        });
      }
    } catch (e) {
      print('Error setting up camera: $e');
    }
  }

  Future _takePicture() async {
    if (_controller == null || !_isControllerInitialized) return;
    try {
      await _initializeControllerFuture;
      final image = await _controller!.takePicture();
      if (mounted) {
        setState(() => _capturedImage = image);
      }
    } catch (e) {
      print('Error taking picture: $e');
    }
  }

  Future _pickImage() async {
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked != null && mounted) {
        setState(() {
          _capturedImage = picked;
        });
      }
    } catch (e) {
      print('Error picking image: $e');
    }
  }

  // Future _submitPicture() async {
  //   if (_capturedImage == null) return;
  //
  //   final prefs = await SharedPreferences.getInstance();
  //   var token = prefs.getString("token");
  //   var typedServerUrl = prefs.getString("typed_url");
  //
  //   var request = http.MultipartRequest('POST', Uri.parse('$typedServerUrl/api/facedetection/setup/'));
  //
  //   try {
  //     var attachment = await http.MultipartFile.fromPath('image', _capturedImage!.path);
  //     String fileName = _capturedImage!.name;
  //     final setImagePath = prefs.setString("imagePath", fileName);
  //     request.files.add(attachment);
  //     request.headers['Authorization'] = 'Bearer $token';
  //     var response = await request.send();
  //     print('eeeecccccc');
  //     print(response.request);
  //     print(response.statusCode);
  //     print(response.headers);
  //
  //     if (response.statusCode == 201) {
  //       _showCreateAnimation(context);
  //     } else {
  //       _showErrorDialog(context, 'Error uploading image. Please try again.');
  //     }
  //   } catch (e) {
  //     print('Exception: $e');
  //     _showErrorDialog(context, 'Something went wrong. Please try again.');
  //   }
  // }

  Future _submitPicture() async {
    if (_capturedImage == null) return;

    final prefs = await SharedPreferences.getInstance();

    try {
      String fileName = _capturedImage!.name;

      // Save image path in prefs
      await prefs.setString("imagePath", fileName);

      // Send multipart upload via ApiClient
      var streamedResponse = await ApiClient.instance.multipart(
        'POST',
        '/api/facedetection/setup/',
        files: {'image': _capturedImage!.path},
      );
      var response = await http.Response.fromStream(streamedResponse);

      print('===== Upload Debug Info =====');
      print("Status Code: ${response.statusCode}");
      print("Headers: ${response.headers}");
      print("Body: ${response.body}");
      print("=============================");

      if (response.statusCode == 201) {
        var face_detection_image = jsonDecode(response.body)['image'];
        print('face_detection_image : $face_detection_image');
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('face_detection_image');
        await prefs.setString("face_detection_image", face_detection_image);
        _showCreateAnimation(context);
      } else {
        _showErrorDialog(context, 'Error uploading image. Please try again.\n${response.body}');
      }
    } catch (e) {
      print('Exception: $e');
      _showErrorDialog(context, 'Something went wrong. Please try again.');
    }
  }


  void _showCreateAnimation(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.3,
            width: MediaQuery.of(context).size.width * 0.85,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset("Assets/gif22.gif", width: 180, height: 180, fit: BoxFit.cover),
                  const SizedBox(height: 16),
                  const Text(
                    "Face Image Uploaded Successfully",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    Future.delayed(const Duration(seconds: 2), () {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => CheckInCheckOutFormPage()));
    });
  }

  void _showErrorDialog(BuildContext context, String errorMessage) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Error"),
        content: Text(errorMessage),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  Future _switchCamera() async {
    if (widget.cameras.length < 2 || _controller == null) return;

    setState(() {
      _capturedImage = null;
      _isControllerInitialized = false;
      selectedCameraIndex = (selectedCameraIndex + 1) % 2;
    });
    await _setupCamera();
  }

  void _retakePicture() {
    if (mounted) setState(() => _capturedImage = null);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => CheckInCheckOutFormPage()));
        return false;
      },
      child: Scaffold(
        backgroundColor: Colors.grey[200],
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Face Image Capture', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.red,
          elevation: 0,
          actions: [
            IconButton(
              icon: Icon(selectedCameraIndex == 0 ? Icons.camera_rear : Icons.camera_front, color: Colors.white),
              onPressed: widget.cameras.length > 1 ? _switchCamera : null,
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: 300,
                    height: 400,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.red[700]!, width: 3),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(color: Colors.grey.withOpacity(0.3), spreadRadius: 2, blurRadius: 5),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: _capturedImage == null
                            ? FutureBuilder(
                          future: _initializeControllerFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.done) {
                              if (snapshot.hasError || _controller == null || !_isControllerInitialized) {
                                return const Center(child: Text('Camera Error'));
                              }
                              return CameraPreview(_controller!);
                            } else {
                              return Center(child: CircularProgressIndicator(color: Colors.red[700]));
                            }
                          },
                        )
                            : Image.file(File(_capturedImage!.path), fit: BoxFit.cover),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.3), spreadRadius: 2, blurRadius: 5)],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (_capturedImage == null) ...[
                      ElevatedButton.icon(
                        onPressed: _isControllerInitialized ? _takePicture : null,
                        icon: const Icon(Icons.camera_alt, color: Colors.white),
                        label: const Text('Capture', style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _pickImage,
                        icon: const Icon(Icons.photo_library, color: Colors.white),
                        label: const Text('Gallery', style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                    if (_capturedImage != null) ...[
                      OutlinedButton.icon(
                        onPressed: _retakePicture,
                        icon: const Icon(Icons.refresh, color: Colors.red),
                        label: const Text('Retake'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red[700],
                          side: BorderSide(color: Colors.red!),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _submitPicture,
                        icon: const Icon(Icons.check, color: Colors.white),
                        label: const Text('Submit', style: TextStyle(color: Colors.white)),
                        style: ButtonStyle(
                          backgroundColor: MaterialStateProperty.resolveWith((states) {
                            if (states.contains(MaterialState.pressed)) {
                              return Colors.green.withOpacity(0.6);
                            }
                            return Colors.green;
                          }),
                          foregroundColor: MaterialStateProperty.all(Colors.white),
                          padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                          shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
