import 'dart:convert';
import 'package:horilla/horilla_main/home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_marker_popup/flutter_map_marker_popup.dart';
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geocoding/geocoding.dart';
import '../../core/api_client.dart';
import '../../horilla_main/login.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({Key? key}) : super(key: key);

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final List<LocationWithRadius> locations = [];
  LocationWithRadius? selectedLocation;
  final PopupController _popupController = PopupController();
  late final AnimatedMapController _mapController;
  double _currentRadius = 50.0;
  Position? userLocation;
  Map<String, dynamic> responseData = {};
  bool _showCurrentLocationCircle = false;
  bool _showTappedLocationCircle = false;
  bool _isExistingGeofence = false;
  bool _isDisposed = false;

  // Department exemption multi-select
  List<Map<String, dynamic>> _departments = [];
  List<int> _selectedDepartmentIds = [];

  @override
  void initState() {
    super.initState();
    _mapController = AnimatedMapController(vsync: this);
    _fetchDepartments();
    getGeoFenceLocation().then((_) {
      if (mounted && selectedLocation != null) {
        _mapController.animateTo(dest: selectedLocation!.coordinates, zoom: 12.0);
      }
    });
  }

  Future<void> _fetchDepartments() async {
    if (_isDisposed) return;
    try {
      var response = await ApiClient.instance.get('/api/base/departments/');
      if (_isDisposed) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data is List ? data : (data['results'] ?? []);
        if (mounted) {
          setState(() {
            _departments = results.map<Map<String, dynamic>>((d) => {
              'id': d['id'] as int,
              'name': (d['name'] ?? 'Unknown').toString(),
            }).toList();
          });
        }
      }
    } catch (e) {
      print('Error fetching departments: $e');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _mapController.dispose();
    super.dispose();
  }

  Future<String> _getLocationName(double latitude, double longitude) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(latitude, longitude);
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks[0];
        String name = "${place.locality ?? ''}, ${place.country ?? ''}".trim();
        return name.isEmpty ? "Unknown Location" : name;
      }
      return "Unknown Location";
    } catch (e) {
      print('Error getting location name: $e');
      return "Unknown Location";
    }
  }

  Future<void> createGeoFenceLocation() async {
    if (_isDisposed) return;

    final prefs = await SharedPreferences.getInstance();
    var companyId = prefs.getInt("company_id");

    try {
      var response = await ApiClient.instance.post(
        '/api/geofencing/setup/',
        jsonBody: {
          'latitude': selectedLocation?.coordinates.latitude,
          'longitude': selectedLocation?.coordinates.longitude,
          'radius_in_meters': selectedLocation?.radius,
          'start': true,
          'company_id': companyId,
          'exempt_departments': _selectedDepartmentIds,
        },
      );

      if (_isDisposed) return;

      if (response.statusCode == 201) {
        await showCreateAnimation();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error in Saving'),
              duration: Duration(seconds: 2),
            ),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error in Saving'),
            duration: Duration(seconds: 2),
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> updateGeoFenceLocation() async {
    if (_isDisposed) return;
    var locationId = responseData['id'];
    final prefs = await SharedPreferences.getInstance();
    var companyId = prefs.getInt("company_id");

    try {
      var response = await ApiClient.instance.put(
        '/api/geofencing/setup/$locationId/',
        jsonBody: {
          'latitude': selectedLocation?.coordinates.latitude,
          'longitude': selectedLocation?.coordinates.longitude,
          'radius_in_meters': selectedLocation?.radius,
          'start': true,
          'company_id': companyId,
          'exempt_departments': _selectedDepartmentIds,
        },
      );

      if (_isDisposed) return;
      if (response.statusCode == 200) {
        await showCreateAnimation();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error in Saving'),
              duration: Duration(seconds: 2),
            ),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error in Saving'),
            duration: Duration(seconds: 2),
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> deleteGeoFenceLocation() async {
    if (_isDisposed) return;

    final prefs = await SharedPreferences.getInstance();
    var locationId = responseData['id'];

    try {
      var response = await ApiClient.instance.delete(
        '/api/geofencing/setup/$locationId/',
      );

      if (_isDisposed) return;

      if (response.statusCode == 204) {
        await showDeleteAnimation();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Error in delete'),
                duration: Duration(seconds: 2),
              )
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error in delete'),
              duration: Duration(seconds: 2),
            )
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> getGeoFenceLocation() async {
    if (_isDisposed) return;

    final prefs = await SharedPreferences.getInstance();

    try {
      var response = await ApiClient.instance.get('/api/geofencing/setup/');

      if (_isDisposed) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data.isNotEmpty) {
          final lat = data['latitude'];
          final lng = data['longitude'];
          final rad = data['radius_in_meters'];

          if (lat != null && lng != null && rad != null) {
            final locationName = await _getLocationName(lat, lng);
            final location = LocationWithRadius(
              LatLng(lat, lng),
              locationName,
              (rad).toDouble(),
              isExisting: true,
            );
            if (mounted) {
              setState(() {
                responseData = data;
                locations.clear();
                locations.add(location);
                selectedLocation = location;
                _currentRadius = rad.toDouble();
                _isExistingGeofence = true;
                final exemptRaw = data['exempt_departments'] ?? [];
                _selectedDepartmentIds = (exemptRaw as List)
                    .map((e) => e is int ? e : int.tryParse(e.toString()) ?? 0)
                    .where((id) => id > 0)
                    .toList();
              });
            }
          }
        }
      } else {
        print('Failed to load data: ${response.statusCode}');
      }
    } catch (e) {
      print("Error fetching geofence data: $e");
    }
  }

  Future<void> showCreateAnimation() async {
    if (_isDisposed) return;

    String jsonContent = '''
{
  "imagePath": "Assets/gif22.gif"
}
''';
    Map<String, dynamic> jsonData = json.decode(jsonContent);
    String imagePath = jsonData['imagePath'];

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.3,
            width: MediaQuery.of(context).size.width * 0.85,
            child: SingleChildScrollView(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(imagePath,
                        width: 180, height: 180, fit: BoxFit.cover),
                    const SizedBox(height: 16),
                    const Text(
                      "Geofence Location Added Successfully",
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.red),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => HomePage(),
          ),
        );
      }
    });
  }

  Future<void> showDeleteAnimation() async {
    if (_isDisposed) return;

    String jsonContent = '''
{
  "imagePath": "Assets/gif22.gif"
}
''';
    Map<String, dynamic> jsonData = json.decode(jsonContent);
    String imagePath = jsonData['imagePath'];

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.3,
            width: MediaQuery.of(context).size.width * 0.85,
            child: SingleChildScrollView(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(imagePath,
                        width: 180, height: 180, fit: BoxFit.cover),
                    const SizedBox(height: 16),
                    const Text(
                      "Geofence Location Deleted Successfully",
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.red),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => HomePage(),
          ),
        );
      }
    });
  }

  Future<Position?> fetchCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }

      if (permission == LocationPermission.deniedForever) return null;

      return await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
    } catch (e) {
      print('Error fetching location: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.red,
        automaticallyImplyLeading: false,
        title: const Text('Geofencing Map', style: TextStyle(color: Colors.white)),
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _mapController.mapController,
              options: MapOptions(
                center: selectedLocation != null
                    ? selectedLocation!.coordinates
                    : userLocation != null
                    ? LatLng(userLocation!.latitude, userLocation!.longitude)
                    : const LatLng(40.0, 0.0),
                zoom: (selectedLocation != null || userLocation != null) ? 12.0 : 2.0,
                minZoom: 2.0,
                maxZoom: 18.0,
                interactiveFlags: InteractiveFlag.all,
                onTap: (_, latLng) async {
                  String locationName = await _getLocationName(
                    latLng.latitude,
                    latLng.longitude,
                  );
                  if (mounted) {
                    setState(() {
                      locations.clear();
                      final newLocation = LocationWithRadius(
                        latLng,
                        locationName,
                        _currentRadius,
                      );
                      locations.add(newLocation);
                      selectedLocation = newLocation;
                      _showCurrentLocationCircle = false;
                      _showTappedLocationCircle = true;
                      _isExistingGeofence = false;
                    });
                    _mapController.animateTo(
                      dest: latLng,
                      zoom: 12.0,
                    );
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.cybrosys.horilla',
                ),
                CircleLayer(
                  circles: [
                    if (selectedLocation != null && _showTappedLocationCircle)
                      CircleMarker(
                        point: selectedLocation!.coordinates,
                        color: Colors.blue.withOpacity(0.3),
                        borderColor: Colors.blue,
                        borderStrokeWidth: 2.0,
                        radius: selectedLocation!.radius,
                      ),
                    if (_showCurrentLocationCircle && userLocation != null)
                      CircleMarker(
                        point: LatLng(userLocation!.latitude, userLocation!.longitude),
                        color: Colors.green.withOpacity(0.3),
                        borderColor: Colors.green,
                        borderStrokeWidth: 2.0,
                        radius: _currentRadius,
                      ),
                    if (responseData.isNotEmpty && !_showCurrentLocationCircle && !_showTappedLocationCircle)
                      CircleMarker(
                        point: LatLng(responseData['latitude'], responseData['longitude']),
                        color: Colors.green.withOpacity(0.3),
                        borderColor: Colors.green,
                        borderStrokeWidth: 2.0,
                        radius: _currentRadius,
                      ),
                  ],
                ),
                PopupMarkerLayerWidget(
                  options: PopupMarkerLayerOptions(
                    popupController: _popupController,
                    markers: locations
                        .map((loc) => Marker(
                      point: loc.coordinates,
                      width: 40.0,
                      height: 40.0,
                      child: GestureDetector(
                        onTap: () {
                          if (mounted) {
                            setState(() {
                              selectedLocation = loc;
                              if (loc.isExisting) {
                                _isExistingGeofence = true;
                              }
                            });
                            _mapController.animateTo(
                              dest: loc.coordinates,
                              zoom: 12.0,
                            );
                          }
                        },
                        child: Icon(
                          Icons.location_on,
                          color: Colors.red,
                          size: 40.0,
                        ),
                      ),
                    ))
                        .toList(),
                    popupDisplayOptions: PopupDisplayOptions(
                      builder: (BuildContext context, Marker marker) {
                        final loc = locations.firstWhere(
                              (loc) => loc.coordinates == marker.point,
                        );
                        return Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                loc.name,
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              Text('Radius: ${loc.radius.toStringAsFixed(1)} m'),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (selectedLocation != null)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Location: ${selectedLocation!.name}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          if (mounted) {
                            setState(() {
                              locations.remove(selectedLocation);
                              selectedLocation = null;
                              _showTappedLocationCircle = false;
                              _isExistingGeofence = false;
                            });
                          }
                        },
                        icon: const Icon(Icons.close, color: Colors.red),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Geofence Radius: '),
                      Expanded(
                        child: Slider(
                          value: _currentRadius,
                          min: 1,  // Minimum value is 1 (natural number)
                          max: 10000,
                          divisions: 9999,
                          label: '${_currentRadius.round()} m',  // Round to nearest integer
                          onChanged: (value) {
                            if (mounted) {
                              setState(() {
                                _currentRadius = value.roundToDouble();  // Round to nearest integer
                                if (selectedLocation != null) {
                                  final index = locations.indexOf(selectedLocation!);
                                  locations[index] = LocationWithRadius(
                                    selectedLocation!.coordinates,
                                    selectedLocation!.name,
                                    _currentRadius,  // Now a natural number
                                    isExisting: selectedLocation!.isExisting,
                                  );
                                  selectedLocation = locations[index];
                                }
                              });
                            }
                          },
                        ),
                      ),
                      Text('${_currentRadius.toStringAsFixed(2)} m'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_departments.isNotEmpty) ...[
                    const Text(
                      'Exempt Departments:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: _departments.map((dept) {
                        final id = dept['id'] as int;
                        final name = dept['name'] as String;
                        final selected = _selectedDepartmentIds.contains(id);
                        return FilterChip(
                          label: Text(name, style: const TextStyle(fontSize: 12)),
                          selected: selected,
                          onSelected: (checked) {
                            if (mounted) {
                              setState(() {
                                if (checked) {
                                  _selectedDepartmentIds.add(id);
                                } else {
                                  _selectedDepartmentIds.remove(id);
                                }
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (_isExistingGeofence)
                        ElevatedButton(
                          onPressed: () async {
                            await showGeofencingDelete(context);
                            if (mounted) {
                              setState(() {
                                locations.remove(selectedLocation);
                                selectedLocation = null;
                                _showTappedLocationCircle = false;
                                _isExistingGeofence = false;
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red),
                          child: const Text('Delete'),
                        ),
                      ElevatedButton(
                        onPressed: () async {
                          await showGeofencingSetting(context);
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final newLocation = await fetchCurrentLocation();
          if (newLocation != null && mounted) {
            String locationName = await _getLocationName(
              newLocation.latitude,
              newLocation.longitude,
            );
            setState(() {
              userLocation = newLocation;
              locations.clear();
              final newLoc = LocationWithRadius(
                LatLng(newLocation.latitude, newLocation.longitude),
                locationName,
                _currentRadius,
              );
              locations.add(newLoc);
              selectedLocation = newLoc;
              _showCurrentLocationCircle = true;
              _showTappedLocationCircle = false;
              _isExistingGeofence = false;
            });
            _mapController.animateTo(
              dest: LatLng(newLocation.latitude, newLocation.longitude),
              zoom: 12.0,
            );
          }
        },
        child: const Icon(Icons.my_location),
      ),
    );
  }

  Future<void> showGeofencingSetting(BuildContext context) async {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Set Geofencing Location"),
          content: const Text("Do you want to set this location for Geofencing?"),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                final prefs = await SharedPreferences.getInstance();
                var geo_fencing = prefs.getBool("geo_fencing");
                if (geo_fencing == true) {
                  await updateGeoFenceLocation();
                }
                else {
                  await createGeoFenceLocation();
                }
              },
              child: const Text("Confirm"),
            ),
          ],
        );
      },
    );
  }

  Future<void> showGeofencingDelete(BuildContext context) async {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Delete Geofencing Location"),
          content: const Text("Do you want to delete this location for Geofencing?"),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await deleteGeoFenceLocation();
              },
              child: const Text("Confirm"),
            ),
          ],
        );
      },
    );
  }
}

class LocationWithRadius {
  final LatLng coordinates;
  final String name;
  double radius; // in meters
  bool isExisting;

  LocationWithRadius(this.coordinates, this.name, double radius, {this.isExisting = false})
      : radius = radius.roundToDouble().clamp(1, double.infinity);  // Ensure at least 1
}
