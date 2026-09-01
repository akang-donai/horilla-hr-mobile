# Horilla Mobile v2 Alignment — Design Spec

**Date:** 2026-09-01
**Repos affected:** `/var/www/html/HorillaMobile` (Flutter app, source in `horilla_mobile/`) and `/var/www/html/horilla` (Django HRMS 2.0.0)
**Status:** Approved design, pending implementation plan

## Goal

Ship an updated mobile release aligned with the Horilla 2.0 web API that:

1. Fixes the mobile security holes (TLS bypass, ATS disabled, token in plain storage, incomplete logout).
2. Adds a JWT refresh flow (server endpoint + mobile 401 handling).
3. Introduces a single mobile ApiClient layer replacing 268 duplicated HTTP call sites.
4. Fixes the expired date picker (`lastDate: DateTime(2025, 12, 31)`).
5. Enforces strict server-side geofencing with a per-company fence and a department exemption list (Sales exempt).
6. Makes face verification mandatory for every clock-in/clock-out, with matching performed server-side using open-source tooling.

Out of scope: new feature modules (payroll, helpdesk, etc.), screen-file splitting, replacing notification polling with WebSocket/push, desktop/web platform support.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Geofence shape | One fence per company + `exempt_departments` M2M (admin selects Sales). |
| Geofence strictness | Fail closed: enabled + non-exempt dept + (missing coords, outside radius, or check error) → HTTP 403, no attendance record. |
| Face matching location | Server-side, open-source (DeepFace, ArcFace model, cosine distance). Regula SDK removed. |
| Face policy | Mandatory for everyone, always — including geofence-exempt departments. Company toggle forced on / ignored. |
| Web alignment depth | API compatibility only; no new mobile modules. |
| Location spoofing | Accepted risk per product owner; server trusts posted lat/lng. |

## 1. Server (Django) changes

### 1.1 Auth refresh

- `horilla_api/api_views/auth/views.py` login already creates a `RefreshToken`; add the `refresh` field to the login response.
- Add `POST /api/auth/refresh/` using SimpleJWT `TokenRefreshView` in `horilla_api/api_urls/auth/urls.py`.
- Enable `ROTATE_REFRESH_TOKENS` and the SimpleJWT token-blacklist app so logout can revoke refresh tokens.

### 1.2 Geofencing

- `geofencing/models.py`: add `exempt_departments = models.ManyToManyField("base.Department", blank=True)` to `GeoFencing`. Migration adds the field empty; the admin selects Sales in the config UI.
- Fix lookup bug: `get_object_or_404(GeoFencing, pk=company.id)` → filter by `company_id=company`.
- Clock-in/clock-out enforcement (`horilla_api/api_views/attendance/views.py`):
  - Remove the bare `except: pass` around the geofence check.
  - When geofencing is enabled and the employee's department is not exempt: missing coordinates, distance outside radius, or any check failure → HTTP 403 with error code `outside_geofence`; no attendance record is created.
  - Exempt departments skip the distance check entirely (face check still applies).
- Web config UI (`geo_config.html` + its view): add a department multi-select for exemptions.

### 1.3 Face verification

- New dependency: DeepFace (ArcFace model, cosine distance). Model warmed at startup (AppConfig.ready or lazy singleton) to avoid first-request stall. Expected per-request cost ~0.5–1.5 s CPU.
- Clock-in and clock-out become multipart requests carrying `{image, latitude, longitude}`. The server verifies the selfie against the enrolled `EmployeeFaceDetection.image` inline, before creating the attendance record. Single-step design: no separate verify-then-clock token to spoof.
- Error codes: `face_mismatch` (403), `not_enrolled` (400).
- A standalone `POST /api/facedetection/verify/` endpoint may be added for diagnostics but is not part of the clock path.
- Enrollment unchanged: existing `POST /api/facedetection/setup/`.
- Match threshold lives server-side in one place (settings or model field), not in the client.

### 1.4 Rollout flag

Strict face requirement is gated behind a server-side flag. Deploy order:

1. Deploy server: new endpoints are additive; the old app keeps working (no selfie → flag off → old behavior).
2. Ship the mobile update.
3. Flip the flag once mobile rollout is complete; from then on clock-in without a valid selfie is rejected.

## 2. Mobile core: ApiClient + session

### 2.1 `lib/core/api_client.dart`

- Single HTTP gateway. Holds base URL and access token in memory after one load.
- Methods: `get / post / put / delete / multipart`. All inject `Authorization: Bearer`, JSON headers, and a 15 s timeout (replacing ad-hoc 3 s timeouts).
- 401 interceptor: on 401 → call `/api/auth/refresh/` with the stored refresh token → retry the original request once. If refresh fails → wipe session and route to login via the global `navigatorKey`.
- Typed error: `ApiException { status, message }`; screens stop hand-parsing error responses.

### 2.2 `lib/core/session.dart`

- Access + refresh tokens stored in `flutter_secure_storage` (Keychain / Android Keystore).
- Non-secret values (typed_url, employee_id, company_id, perm flags) remain in SharedPreferences.
- `logout()`: POST the refresh token to the blacklist endpoint, clear all session keys (including `perm_*`, `employee_id`, `company_id`, `face_detection_image`, `imagePath`), then `Navigator.pushNamedAndRemoveUntil('/login', ...)` so the authenticated stack is destroyed.

### 2.3 Call-site migration

Mechanical swap only — screen parse logic untouched this release:

- `http.get(Uri.parse('$typedServerUrl/api/x'), headers: {...})` → `api.get('/api/x')` across ~268 call sites.
- Delete per-screen `getString("token")` reads (~293) and hand-built auth header maps (~314).
- File splitting of the 2k+ line screens is explicitly out of scope.

### 2.4 Small fixes riding along

- `res/utilities/date_time_picker.dart:29`: `lastDate: DateTime(2025, 12, 31)` → `DateTime.now().add(const Duration(days: 3650))`, overridable per call site.
- Remove the duplicate notification polling timer in `login.dart:44`; keep the single timer in `main.dart` and raise the interval from 3 s to 60 s.

## 3. Mobile clock-in/out flow

Replaces the three-branch swipe logic in `checkin_checkout_form.dart` and the 500 ms `takePicture()` polling loop in `face_detection.dart`.

1. Swipe → new `FaceCaptureScreen` opens the front camera.
2. Capture one selfie. On-device pre-gate with ML Kit face *detection* only (exactly one face, reasonable size) to avoid uploading unusable frames.
3. Acquire a GPS fix with `geolocator`; lat/lng always attached — the server decides whether the department is exempt.
4. Single multipart `POST /api/attendance/clock-in/` (or `clock-out/`) with `{image, latitude, longitude}`.
5. Response handling:
   - 403 `outside_geofence` → "Outside allowed area" message.
   - 403 `face_mismatch` → retry capture, max 3 attempts.
   - 400 `not_enrolled` → route to the enrollment screen (`setup_imageface.dart`).
   - 2xx → success UI + stopwatch update as today.

Removals: `flutter_face_api` (Regula) dependency, `face_detection_controller.dart`, commented Regula init cruft in `main.dart`, client-side thresholds (0.75 / 0.80), and the duplicated geofence CRUD block in `home.dart:540-685` (admin map screen in `geofencing.dart` stays and gains the department-exemption multi-select, fed by `/api/base/departments/`).

Keeps: `google_ml_kit` (now actually used), enrollment flow against `/api/facedetection/setup/`.

Sales-department users get the same selfie flow; the server merely skips the distance check for them.

## 4. Security and release hardening

- Delete the TLS bypass (`badCertificateCallback => true`, `face_detection.dart:138-139`); the new ApiClient must not introduce an equivalent.
- Remove `NSAllowsArbitraryLoads` from `ios/Runner/Info.plist`. HTTPS becomes mandatory. If a plain-HTTP LAN test server is required, use a scoped `NSExceptionDomains` entry for that single host (decided at implementation time), never the global bypass.
- Login screen enforces `https://` on the typed server URL (auto-prepend; reject `http://`).
- Tokens move to secure storage (§2.2).
- Server hygiene: delete `/var/www/html/horilla/.horilla` (plaintext admin credentials) and rotate that password. Outside app code but required before deployment.

Android (`android/app/build.gradle.kts` and manifest):

- `isMinifyEnabled = true` alongside the existing `isShrinkResources = true`.
- Add a release `signingConfig` backed by an uncommitted `key.properties`.
- Manifest: fix `ACCESS_NETWORK-STATE` → `ACCESS_NETWORK_STATE`; add `POST_NOTIFICATIONS`; add `android:required="false"` to the camera `uses-feature` entries.
- Remove the five unused ML Kit text-recognition dependencies (`build.gradle.kts:49-53`).

Repo hygiene: delete `horilla_mobile/lib.zip`, delete the stale root `pubspec.yaml`, untrack `ios/build/`, prune the ~20 unused pub dependencies (including `dio`, `odoo_rpc`).

## 5. Testing and rollout

Server (pytest):

- Geofence matrix: exempt / non-exempt department × inside / outside / missing coordinates.
- Face verify: match, mismatch, not enrolled. DeepFace mocked in unit tests; one real-model smoke test.
- Refresh flow: valid refresh, expired refresh, blacklisted after logout.

Mobile:

- Unit tests for ApiClient: 401 → refresh → retry, timeout, error mapping (first real tests in the repo; the broken template `test/widget_test.dart` is replaced).
- Manual device pass for camera + GPS clock flow on Android and iOS.

Rollout: server first (additive, flag off) → mobile release → flip strict-face flag (§1.4).
