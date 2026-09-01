# Task 10 Report: ApiClient Migration - Attendance & Checkin Screens

**Status:** ✅ Complete
**Date:** 2026-09-01
**Branch:** feat/mobile-v2-align
**Commit:** bea632c

## Summary

Migrated all attendance and checkin screens from manual SharedPreferences token handling + http calls to use the centralized ApiClient that automatically injects JWT bearer tokens.

## Files Migrated (9 files)

### lib/attendance_views/ (5 files)
1. **attendance_attendance.dart** - 19 API calls migrated
   - getMyAttendance, getAllNonValidatedAttendance, getAllOvertimeAttendance, getAllValidatedAttendance
   - prefetchData, permissionChecks, managerChecks, attendanceTypeChecks, getShiftDetails, getEmployees
   - createNewAttendance, updateAttendance, updateOvertimeAttendance, deleteAttendance, deleteNonValidatedAttendance
   - validateAttendance, validateOverTime

2. **attendance_overview.dart** - 10 API calls migrated
   - permissionChecks, prefetchData, getAllOfflineEmployees, getTodayAttendance, getOfflineEmployeeCount
   - getAllOvertimeValidateEmployees, getAllNonValidatedAttendance, getTemplate
   - getConvertedMailTemplate (multipart PUT), sendEmail (multipart POST)

3. **attendance_request.dart** - 12 API calls migrated
   - getEmployees, getShiftDetails, getWorkTypeDetails
   - getAllRequestedAttendances (2 branches), createNewAttendance
   - permissionChecks, prefetchData, getAllAttendances (2 branches)
   - rejectLeave, approveRequest

4. **hour_account.dart** - 8 API calls migrated
   - permissionChecks, prefetchData, getHourAccountRecords, getEmployees
   - addOvertime, updateHourAccountRecords, createHourAccountRecords, deleteHourAccountRecord

5. **my_attendance_view.dart** - 2 API calls migrated
   - prefetchData, getAllShiftNames

### lib/checkin_checkout/checkin_checkout_views/ (4 files)
6. **checkin_checkout_form.dart** - 5 API calls migrated
   - getCheckIn, prefetchData, getLoginEmployeeRecord, getLoginEmployeeWorkInfoRecord, getFaceDetection
   - **Left as-is:** postCheckIn, postCheckout, and inline geofencing clock POSTs (T11 scope)

7. **face_detection.dart** - 2 API calls migrated
   - _fetchBiometricImage (uses ApiClient getters for baseUrl/accessToken with IOClient)
   - _handleComparisonResult (clock-in/clock-out POST)

8. **geofencing.dart** - 4 API calls migrated
   - createGeoFenceLocation, updateGeoFenceLocation, deleteGeoFenceLocation, getGeoFenceLocation

9. **setup_imageface.dart** - 1 API call migrated
   - _submitPicture (multipart file upload via ApiClient.instance.multipart)

### lib/core/ (1 file)
10. **api_client.dart** - Added public getters
    - `String? get baseUrl => _baseUrl;`
    - `String? get accessToken => _access;`
    - Required for image download use case in face_detection.dart

## Changes Made

### Pattern Applied
**Before:**
```dart
final prefs = await SharedPreferences.getInstance();
var token = prefs.getString("token");
var typedServerUrl = prefs.getString("typed_url");
var uri = Uri.parse('$typedServerUrl/api/endpoint/');
var response = await http.get(uri, headers: {
  "Content-Type": "application/json",
  "Authorization": "Bearer $token",
});
```

**After:**
```dart
var response = await ApiClient.instance.get('/api/endpoint/');
```

### Import Changes
- Added: `import '../core/api_client.dart';` (or appropriate relative path)
- Removed: `import 'package:http/http.dart' as http;` where no longer needed
- Kept: http import in files using `http.Response.fromStream()` or `IOClient`

### Special Cases Handled
1. **Multipart uploads:** Migrated to `ApiClient.instance.multipart(method, path, fields: {}, files: {})`
2. **Image downloads:** Used `ApiClient.instance.baseUrl` and `ApiClient.instance.accessToken` getters with IOClient for custom headers
3. **Clock POSTs:** Left checkin_checkout_form.dart clock POSTs untouched (T11 scope per task brief)
4. **SharedPreferences:** Kept reads for employee_id, company_id, etc. Only removed token/typed_url reads

## Verification

### Grep Check
```bash
grep -rn 'getString("token")\|Bearer \$token' lib/attendance_views lib/checkin_checkout
```
**Result:** ✅ Zero matches except:
- Image.network widget headers (not http calls)
- Clock POSTs in checkin_checkout_form.dart (T11 scope)

### Flutter Analyze
```bash
flutter analyze lib/attendance_views lib/checkin_checkout
```
**Result:** ✅ No issues found

## Statistics
- **Files changed:** 10
- **Lines added:** 135
- **Lines removed:** 597
- **Net reduction:** 462 lines (77% reduction in boilerplate)
- **API calls migrated:** 63 total

## Notes
- All response-handling code preserved unchanged
- No functional changes to business logic
- ApiClient automatically handles JWT refresh on 401
- Token injection now centralized and consistent across all screens
