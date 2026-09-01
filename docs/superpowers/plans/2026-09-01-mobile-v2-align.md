# Horilla Mobile v2 Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a mobile release aligned with Horilla 2.0: strict server-side geofencing with department exemptions, mandatory server-side face verification on clock-in/out, JWT refresh flow, a single mobile ApiClient, and security/release hardening.

**Architecture:** Phase A adds additive server features to the Django API (refresh endpoint, geofence exemptions + strict enforcement, DeepFace verification gated behind a flag). Phase B refactors the Flutter app onto an ApiClient/session core, replaces the Regula client-side face flow with one selfie upload per clock action, and hardens platform configs. Server deploys first with the strict-face flag off; the flag flips after mobile rollout.

**Tech Stack:** Django 5.2 + DRF + SimpleJWT (server, repo `/var/www/html/horilla`), DeepFace (ArcFace), Flutter/Dart (`/var/www/html/HorillaMobile/horilla_mobile`), `flutter_secure_storage`, `google_mlkit_face_detection`, `camera`, `geolocator`.

**Spec:** `docs/superpowers/specs/2026-09-01-mobile-v2-align-design.md`

## Global Constraints

- Server repo: `/var/www/html/horilla` (branch `2.0`). Mobile repo: `/var/www/html/HorillaMobile`, app source in `horilla_mobile/`.
- Strict face verification is gated by env-driven setting `STRICT_FACE_ATTENDANCE` (default `False`). Old clients must keep working until the flag flips.
- Geofence policy: fail closed for non-exempt departments — missing coords, outside radius, or any check error ⇒ HTTP 403 `{"error_code": "outside_geofence"}`, no attendance record.
- Face errors: HTTP 403 `{"error_code": "face_mismatch"}`, HTTP 400 `{"error_code": "not_enrolled"}`.
- Mobile: all HTTP goes through `ApiClient`; tokens ONLY in `flutter_secure_storage`; server URL must be `https://`.
- No new mobile feature modules. No screen-file splitting.
- Commit after every task; server tasks commit in the horilla repo, mobile tasks in the HorillaMobile repo.
- Before writing server tests, look at one existing test under the horilla repo (`git ls-files '*test*' | head`) and reuse its user/employee fixture pattern; the test code below shows intent and asserts, adapt fixture construction to the existing pattern.

---

# Phase A — Server (`/var/www/html/horilla`)

### Task 1: JWT refresh + logout endpoints, refresh in login response

**Files:**
- Modify: `horilla/settings/base.py:115-117` (SIMPLE_JWT), INSTALLED_APPS list
- Modify: `horilla_api/api_urls/auth/urls.py`
- Modify: `horilla_api/api_views/auth/views.py` (login `result` dict)
- Test: `horilla_api/tests/test_auth_tokens.py` (create; add `horilla_api/tests/__init__.py` if missing)

**Interfaces:**
- Produces: `POST /api/auth/refresh/` (body `{"refresh": str}` → `{"access": str, "refresh": str}`), `POST /api/auth/logout/` (body `{"refresh": str}` → 200), login response now includes `"refresh"`.

- [ ] **Step 1: Write failing tests**

```python
# horilla_api/tests/test_auth_tokens.py
from django.test import TestCase
from rest_framework.test import APIClient

class AuthTokenTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        # ADAPT: create a user+employee the way existing horilla tests do,
        # with username "apitest" / password "pass12345".
        self.user = make_user_with_employee("apitest", "pass12345")

    def login(self):
        return self.client.post(
            "/api/auth/login/",
            {"username": "apitest", "password": "pass12345"},
        )

    def test_login_returns_refresh(self):
        data = self.login().json()
        self.assertIn("access", data)
        self.assertIn("refresh", data)

    def test_refresh_returns_new_access(self):
        refresh = self.login().json()["refresh"]
        res = self.client.post("/api/auth/refresh/", {"refresh": refresh})
        self.assertEqual(res.status_code, 200)
        self.assertIn("access", res.json())

    def test_logout_blacklists_refresh(self):
        refresh = self.login().json()["refresh"]
        res = self.client.post("/api/auth/logout/", {"refresh": refresh})
        self.assertEqual(res.status_code, 200)
        res2 = self.client.post("/api/auth/refresh/", {"refresh": refresh})
        self.assertEqual(res2.status_code, 401)
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd /var/www/html/horilla && python manage.py test horilla_api.tests.test_auth_tokens -v 2`
Expected: FAIL (`refresh` key missing; 404 on `/api/auth/refresh/`).

- [ ] **Step 3: Implement**

`horilla/settings/base.py` — add `"rest_framework_simplejwt.token_blacklist",` to `INSTALLED_APPS` and replace the SIMPLE_JWT block:

```python
SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=60),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=14),
    "ROTATE_REFRESH_TOKENS": True,
    "BLACKLIST_AFTER_ROTATION": True,
}
```

`horilla_api/api_urls/auth/urls.py`:

```python
from rest_framework_simplejwt.views import TokenBlacklistView, TokenRefreshView

urlpatterns = [
    path("login/", LoginAPIView.as_view()),
    path("refresh/", TokenRefreshView.as_view(), name="api-token-refresh"),
    path("logout/", TokenBlacklistView.as_view(), name="api-token-logout"),
    path("reset-password/", PasswordResetAPIView.as_view(), name="api-reset-password"),
]
```

`horilla_api/api_views/auth/views.py` — in the login `result` dict add:

```python
"refresh": str(refresh),
```

Run: `python manage.py migrate token_blacklist`

- [ ] **Step 4: Run tests, verify pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(api): add JWT refresh/logout endpoints and refresh token in login response"`

### Task 2: GeoFencing exempt departments + lookup-bug fix

**Files:**
- Modify: `geofencing/models.py`
- Modify: `geofencing/views.py:30` (`GeoFencingSetupGetPostAPIView.get`)
- Modify: `geofencing/serializers.py` (add field)
- Test: `geofencing/tests/test_models.py` (create; add `geofencing/tests/__init__.py`)

**Interfaces:**
- Produces: `GeoFencing.exempt_departments` M2M to `base.Department`; helper `GeoFencing.is_department_exempt(department) -> bool`. Serializer accepts/returns `exempt_departments` as id list.

- [ ] **Step 1: Write failing tests**

```python
# geofencing/tests/test_models.py
from unittest.mock import patch
from django.test import TestCase
from base.models import Company, Department
from geofencing.models import GeoFencing

class GeoFencingExemptionTests(TestCase):
    @patch("geofencing.models.Nominatim")  # skip network reverse-geocode
    def setUp(self, _nom):
        self.company = Company.objects.create(company="ACME")
        self.sales = Department.objects.create(department="Sales")
        self.eng = Department.objects.create(department="Engineering")
        self.fence = GeoFencing(
            latitude=10.0, longitude=76.0, radius_in_meters=100,
            company_id=self.company, start=True,
        )
        self.fence.save()
        self.fence.exempt_departments.add(self.sales)

    def test_exempt_department(self):
        self.assertTrue(self.fence.is_department_exempt(self.sales))

    def test_non_exempt_department(self):
        self.assertFalse(self.fence.is_department_exempt(self.eng))

    def test_none_department_not_exempt(self):
        self.assertFalse(self.fence.is_department_exempt(None))
```

Note: if `GeoFencing.save()`'s `full_clean()` still hits Nominatim despite the patch (import path differences), patch `geofencing.models.GeoFencing.clean` instead.

- [ ] **Step 2: Run, verify fail** — `python manage.py test geofencing -v 2` → FAIL (no field/method).

- [ ] **Step 3: Implement**

`geofencing/models.py` — inside `GeoFencing`:

```python
    exempt_departments = models.ManyToManyField(
        "base.Department",
        blank=True,
        related_name="geofence_exemptions",
        help_text=_("Departments exempt from the geofence check."),
    )

    def is_department_exempt(self, department):
        if department is None:
            return False
        return self.exempt_departments.filter(pk=department.pk).exists()
```

`geofencing/serializers.py` — ensure `exempt_departments` is included (if the serializer uses `fields = "__all__"` it picks the M2M up automatically; otherwise append it).

`geofencing/views.py` — fix the GET lookup:

```python
        location = get_object_or_404(GeoFencing, company_id=company)
```

Run: `python manage.py makemigrations geofencing && python manage.py migrate`

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Commit** — `git commit -am "feat(geofencing): department exemption list; fix company lookup bug"`

### Task 3: Strict geofence enforcement on clock-in/out

**Files:**
- Create: `horilla_api/api_views/attendance/guards.py`
- Modify: `horilla_api/api_views/attendance/views.py` (`ClockInAPIView.post`, `ClockOutAPIView.post`)
- Test: `horilla_api/tests/test_clock_guards.py`

**Interfaces:**
- Produces: `geofence_guard(request) -> Response | None` (None = allowed). Later Task 5 adds `face_guard(request)` to the same module.
- Consumes: `GeoFencing.is_department_exempt` (Task 2).

- [ ] **Step 1: Write failing tests**

```python
# horilla_api/tests/test_clock_guards.py
from unittest.mock import MagicMock, patch
from django.test import TestCase
from horilla_api.api_views.attendance.guards import geofence_guard

def _req(lat=None, lng=None):
    r = MagicMock()
    r.data = {}
    if lat is not None:
        r.data = {"latitude": lat, "longitude": lng}
    return r

class GeofenceGuardTests(TestCase):
    def _fence(self, exempt=False, start=True):
        fence = MagicMock()
        fence.start = start
        fence.latitude, fence.longitude, fence.radius_in_meters = 10.0, 76.0, 200
        fence.is_department_exempt.return_value = exempt
        return fence

    def _wire(self, req, fence, dept="Engineering"):
        req.user.employee_get.get_company.return_value.geo_fencing = fence
        req.user.employee_get.employee_work_info.department_id = dept

    def test_disabled_fence_allows(self):
        req = _req()
        self._wire(req, self._fence(start=False))
        self.assertIsNone(geofence_guard(req))

    def test_exempt_department_allows_without_coords(self):
        req = _req()
        self._wire(req, self._fence(exempt=True))
        self.assertIsNone(geofence_guard(req))

    def test_missing_coords_rejected(self):
        req = _req()
        self._wire(req, self._fence())
        res = geofence_guard(req)
        self.assertEqual(res.status_code, 403)
        self.assertEqual(res.data["error_code"], "outside_geofence")

    def test_inside_radius_allows(self):
        req = _req(lat=10.0001, lng=76.0001)   # ~15 m away
        self._wire(req, self._fence())
        self.assertIsNone(geofence_guard(req))

    def test_outside_radius_rejected(self):
        req = _req(lat=10.01, lng=76.01)       # ~1.5 km away
        self._wire(req, self._fence())
        self.assertEqual(geofence_guard(req).status_code, 403)

    def test_error_fails_closed(self):
        req = _req(lat="garbage", lng=None)
        self._wire(req, self._fence())
        self.assertEqual(geofence_guard(req).status_code, 403)
```

- [ ] **Step 2: Run, verify fail** — module doesn't exist.

- [ ] **Step 3: Implement**

```python
# horilla_api/api_views/attendance/guards.py
"""Pre-conditions applied to clock-in / clock-out API calls."""
import logging

from django.utils.translation import gettext_lazy as _
from geopy.distance import geodesic
from rest_framework.response import Response

logger = logging.getLogger(__name__)

def _outside():
    return Response(
        {"error_code": "outside_geofence",
         "error": _("You are outside the allowed clock-in area.")},
        status=403,
    )

def geofence_guard(request):
    """Return a 403 Response when the geofence blocks this request, else None.

    Fail closed: any error while checking a non-exempt employee rejects.
    """
    try:
        company = request.user.employee_get.get_company()
        fence = getattr(company, "geo_fencing", None)
        if fence is None or not fence.start:
            return None
    except Exception:
        return None  # no company/fence configured -> feature off

    try:
        department = request.user.employee_get.employee_work_info.department_id
    except Exception:
        department = None
    try:
        if fence.is_department_exempt(department):
            return None
        lat = float(request.data.get("latitude"))
        lng = float(request.data.get("longitude"))
        meters = geodesic((fence.latitude, fence.longitude), (lat, lng)).meters
        if meters <= fence.radius_in_meters:
            return None
        return _outside()
    except Exception:
        logger.exception("Geofence check failed; rejecting (fail closed)")
        return _outside()
```

`horilla_api/api_views/attendance/views.py` — in BOTH `ClockInAPIView.post` and `ClockOutAPIView.post`, delete the whole `try: ... geo_fencing.start ... except: pass` block and put at the top of each method:

```python
        from .guards import geofence_guard

        blocked = geofence_guard(request)
        if blocked is not None:
            return blocked
```

(For ClockIn keep it inside the `if not ...check_online():` branch, before `employee_exists(request)`.)

- [ ] **Step 4: Run tests, verify pass** — `python manage.py test horilla_api.tests.test_clock_guards -v 2`.

- [ ] **Step 5: Commit** — `git commit -am "feat(api): strict fail-closed geofence enforcement with department exemptions"`

### Task 4: DeepFace verification service

**Files:**
- Modify: `requirements.txt` (add `deepface==0.0.93`, `tf-keras`)
- Create: `facedetection/services.py`
- Modify: `facedetection/apps.py` (model warm-up)
- Test: `facedetection/tests/test_services.py` (create; add `facedetection/tests/__init__.py`)

**Interfaces:**
- Produces: `verify_employee_face(employee, uploaded_file) -> tuple[bool, float]` raising `FaceNotEnrolled`. Consumed by Task 5.

- [ ] **Step 1: Write failing tests (DeepFace mocked)**

```python
# facedetection/tests/test_services.py
from unittest.mock import MagicMock, patch
from django.test import TestCase
from facedetection.services import FaceNotEnrolled, verify_employee_face

class VerifyFaceTests(TestCase):
    def _employee(self, enrolled=True):
        emp = MagicMock()
        if enrolled:
            emp.face_detection.image.path = "/media/faces/ref.jpg"
        else:
            emp.face_detection = None
        return emp

    def _upload(self):
        f = MagicMock()
        f.chunks.return_value = [b"jpegbytes"]
        return f

    @patch("facedetection.services.DeepFace")
    def test_match(self, deepface):
        deepface.verify.return_value = {"verified": True, "distance": 0.31}
        ok, dist = verify_employee_face(self._employee(), self._upload())
        self.assertTrue(ok)
        self.assertAlmostEqual(dist, 0.31)
        kwargs = deepface.verify.call_args.kwargs
        self.assertEqual(kwargs["model_name"], "ArcFace")

    @patch("facedetection.services.DeepFace")
    def test_mismatch(self, deepface):
        deepface.verify.return_value = {"verified": False, "distance": 0.92}
        ok, _ = verify_employee_face(self._employee(), self._upload())
        self.assertFalse(ok)

    def test_not_enrolled_raises(self):
        emp = MagicMock()
        emp.face_detection = None
        with self.assertRaises(FaceNotEnrolled):
            verify_employee_face(emp, self._upload())

    @patch("facedetection.services.DeepFace")
    def test_no_face_in_selfie_is_mismatch(self, deepface):
        deepface.verify.side_effect = ValueError("Face could not be detected")
        ok, _ = verify_employee_face(self._employee(), self._upload())
        self.assertFalse(ok)
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement**

`pip install deepface tf-keras` and append both to `requirements.txt`.

```python
# facedetection/services.py
"""Server-side face verification for attendance clock actions."""
import logging
import os
import tempfile

from deepface import DeepFace

logger = logging.getLogger(__name__)

MODEL_NAME = "ArcFace"
DETECTOR = "opencv"

class FaceNotEnrolled(Exception):
    pass

def warm_up():
    """Load the ArcFace model once so first verification isn't slow."""
    try:
        DeepFace.build_model(MODEL_NAME)
    except Exception:
        logger.exception("DeepFace warm-up failed")

def verify_employee_face(employee, uploaded_file):
    """Compare an uploaded selfie against the employee's enrolled image.

    Returns (verified: bool, distance: float).
    Raises FaceNotEnrolled when no reference image exists.
    A selfie in which no face is detected counts as a mismatch.
    """
    enrolled = getattr(employee, "face_detection", None)
    if not enrolled or not getattr(enrolled, "image", None):
        raise FaceNotEnrolled()

    tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
    try:
        for chunk in uploaded_file.chunks():
            tmp.write(chunk)
        tmp.close()
        try:
            result = DeepFace.verify(
                img1_path=tmp.name,
                img2_path=enrolled.image.path,
                model_name=MODEL_NAME,
                detector_backend=DETECTOR,
                enforce_detection=True,
            )
        except ValueError:
            # no face found in one of the images
            return False, 1.0
        return bool(result["verified"]), float(result["distance"])
    finally:
        os.unlink(tmp.name)
```

`facedetection/apps.py` — in `FacedetectionConfig.ready()` (create the method if absent):

```python
    def ready(self):
        from django.conf import settings
        if getattr(settings, "STRICT_FACE_ATTENDANCE", False):
            from threading import Thread
            from .services import warm_up
            Thread(target=warm_up, daemon=True).start()
```

- [ ] **Step 4: Run tests, verify pass.** Also run one manual smoke test with two real photos via `python manage.py shell` and note the distance observed.

- [ ] **Step 5: Commit** — `git commit -am "feat(facedetection): DeepFace ArcFace verification service with warm-up"`

### Task 5: Face requirement on clock-in/out (flag-gated)

**Files:**
- Modify: `horilla/settings/base.py` (add `STRICT_FACE_ATTENDANCE = os.environ.get("STRICT_FACE_ATTENDANCE", "false").lower() == "true"`)
- Modify: `horilla_api/api_views/attendance/guards.py` (add `face_guard`)
- Modify: `horilla_api/api_views/attendance/views.py` (call `face_guard` after `geofence_guard` in both clock views)
- Test: `horilla_api/tests/test_clock_guards.py` (extend)

**Interfaces:**
- Consumes: `verify_employee_face`, `FaceNotEnrolled` (Task 4).
- Produces: `face_guard(request) -> Response | None`. Clock endpoints accept multipart with `image`, `latitude`, `longitude` (DRF parses both JSON and multipart transparently; `request.FILES["image"]`).

- [ ] **Step 1: Write failing tests** (append to `test_clock_guards.py`)

```python
from django.test import override_settings
from horilla_api.api_views.attendance.guards import face_guard

class FaceGuardTests(TestCase):
    def _req(self, with_image=True):
        r = MagicMock()
        r.FILES = {"image": MagicMock()} if with_image else {}
        return r

    @override_settings(STRICT_FACE_ATTENDANCE=False)
    def test_flag_off_allows(self):
        self.assertIsNone(face_guard(self._req(with_image=False)))

    @override_settings(STRICT_FACE_ATTENDANCE=True)
    def test_missing_image_rejected(self):
        res = face_guard(self._req(with_image=False))
        self.assertEqual(res.status_code, 403)
        self.assertEqual(res.data["error_code"], "face_mismatch")

    @override_settings(STRICT_FACE_ATTENDANCE=True)
    @patch("horilla_api.api_views.attendance.guards.verify_employee_face")
    def test_match_allows(self, verify):
        verify.return_value = (True, 0.3)
        self.assertIsNone(face_guard(self._req()))

    @override_settings(STRICT_FACE_ATTENDANCE=True)
    @patch("horilla_api.api_views.attendance.guards.verify_employee_face")
    def test_mismatch_rejected(self, verify):
        verify.return_value = (False, 0.9)
        self.assertEqual(face_guard(self._req()).status_code, 403)

    @override_settings(STRICT_FACE_ATTENDANCE=True)
    @patch("horilla_api.api_views.attendance.guards.verify_employee_face")
    def test_not_enrolled_400(self, verify):
        from facedetection.services import FaceNotEnrolled
        verify.side_effect = FaceNotEnrolled()
        res = face_guard(self._req())
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.data["error_code"], "not_enrolled")
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** — append to `guards.py`:

```python
from django.conf import settings

def face_guard(request):
    """Verify the uploaded selfie when STRICT_FACE_ATTENDANCE is on."""
    if not getattr(settings, "STRICT_FACE_ATTENDANCE", False):
        return None
    from facedetection.services import FaceNotEnrolled, verify_employee_face

    image = request.FILES.get("image")
    if image is None:
        return Response(
            {"error_code": "face_mismatch",
             "error": _("A selfie image is required to clock in or out.")},
            status=403,
        )
    try:
        verified, _distance = verify_employee_face(request.user.employee_get, image)
    except FaceNotEnrolled:
        return Response(
            {"error_code": "not_enrolled",
             "error": _("No enrolled face image. Please enroll first.")},
            status=400,
        )
    except Exception:
        logger.exception("Face verification error; rejecting (fail closed)")
        verified = False
    if verified:
        return None
    return Response(
        {"error_code": "face_mismatch", "error": _("Face verification failed.")},
        status=403,
    )
```

In both clock views, directly after the geofence guard call:

```python
        blocked = face_guard(request)
        if blocked is not None:
            return blocked
```

- [ ] **Step 4: Run full guard test file, verify pass.**

- [ ] **Step 5: Commit** — `git commit -am "feat(api): mandatory face verification on clock-in/out behind STRICT_FACE_ATTENDANCE"`

### Task 6: Web geofence config UI — exemption multi-select

**Files:**
- Modify: `geofencing/forms.py` (`GeoFencingSetupForm`)
- Modify: `geofencing/templates/geo_config.html` (render new field; follow the template's existing field markup)

**Interfaces:**
- Consumes: `GeoFencing.exempt_departments` (Task 2).

- [ ] **Step 1: Add field to form** — in `GeoFencingSetupForm.Meta.fields` include `"exempt_departments"` (if `fields = "__all__"`, nothing to do). Widget: the project's `horilla_widgets` multi-select if the form already uses it, otherwise `forms.SelectMultiple`.
- [ ] **Step 2: Render field in `geo_config.html`** next to the radius field, copying the surrounding form-group markup.
- [ ] **Step 3: Manual check** — `python manage.py runserver`, open the geofencing config page, verify departments listed, select Sales, save, reload, still selected.
- [ ] **Step 4: Commit** — `git commit -am "feat(geofencing): department exemption selection in web config"`

---

# Phase B — Mobile (`/var/www/html/HorillaMobile/horilla_mobile`)

### Task 7: Dependency + platform config cleanup

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/app/build.gradle.kts`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `ios/Runner/Info.plist`
- Delete: `lib.zip`, repo-root `pubspec.yaml` (`/var/www/html/HorillaMobile/pubspec.yaml`)
- Modify: `.gitignore` (add `**/ios/build/`), untrack `ios/build/`

**Interfaces:**
- Produces: deps available to later tasks: `flutter_secure_storage`, `google_mlkit_face_detection`; removed: `flutter_face_api`, `google_ml_kit`, `dio`, `odoo_rpc`, and other dead deps.

- [ ] **Step 1: pubspec.yaml edits** — remove: `odoo_rpc`, `dio`, `quickalert`, `cool_alert`, `timeline_tile`, `percent_indicator`, `table_calendar`, `convex_bottom_bar`, `salomon_bottom_bar`, `animated_bottom_navigation_bar`, `contained_tab_bar_view`, `fl_chart`, `flutter_pdfview`, `webview_flutter`, `web_socket_channel`, `google_ml_kit`, `image`, `flutter_face_api`, `path_provider`, `open_file`, `internet_connection_checker`. Add:

```yaml
  flutter_secure_storage: ^9.2.2
  google_mlkit_face_detection: ^0.13.1
```

Then `flutter pub get`. If any kept file still imports a removed package (check with `grep -rn "package:<name>" lib/`), re-add that package and note it — the list above was derived from an import scan, verify it.

- [ ] **Step 2: build.gradle.kts** — delete the five `com.google.mlkit:text-recognition*` lines; in `buildTypes.release` set:

```kotlin
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
```

and above `buildTypes` add keystore loading:

```kotlin
    val keystoreProperties = java.util.Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(java.io.FileInputStream(keystorePropertiesFile))
    }
    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }
```

Add `android/key.properties` to `.gitignore`. Create an empty `android/app/proguard-rules.pro` if absent.

- [ ] **Step 3: AndroidManifest.xml** — fix/add:

```xml
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-feature android:name="android.hardware.camera" android:required="false"/>
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false"/>
```

(replacing the malformed `ACCESS_NETWORK-STATE` line and the two existing `uses-feature` lines).

- [ ] **Step 4: Info.plist** — delete the `NSAppTransportSecurity` dict (lines 18-22).
- [ ] **Step 5: Repo hygiene** — `git rm horilla_mobile/lib.zip`, `git rm ../pubspec.yaml` (repo-root stale file), `git rm -r --cached horilla_mobile/ios/build`, append `horilla_mobile/ios/build/` to root `.gitignore`.
- [ ] **Step 6: Verify** — `flutter analyze` (expect pre-existing warnings, no new errors about missing packages except in files being replaced in Task 11 — if `face_detection_controller.dart` fails on the removed Regula import, delete its import lines' file usage is handled in Task 11; acceptable to defer if analyze was already failing). `flutter build apk --debug` must succeed.
- [ ] **Step 7: Commit** — `git commit -am "chore: prune dead deps, fix manifest perms, release signing, drop ATS bypass"`

### Task 8: `ApiClient` + `Session` core

**Files:**
- Create: `lib/core/session.dart`
- Create: `lib/core/api_client.dart`
- Test: `test/api_client_test.dart` (replaces nothing yet; broken `test/widget_test.dart` deleted here)

**Interfaces:**
- Produces (used by every later task):

```dart
class Session {
  static final Session instance;
  Future<void> saveLogin({required String baseUrl, required String access, required String refresh});
  Future<String?> get access; Future<String?> get refresh; Future<String?> get baseUrl;
  Future<void> updateTokens({required String access, String? refresh});
  Future<void> clear();               // wipes secure storage + ALL SharedPreferences session keys
}
class ApiException implements Exception { final int status; final String message; }
class ApiClient {
  static final ApiClient instance;
  http.Client httpClient;             // swappable for tests
  void Function()? onSessionExpired;  // wired to navigation in Task 9
  Future<http.Response> get(String path);
  Future<http.Response> post(String path, {Object? jsonBody});
  Future<http.Response> put(String path, {Object? jsonBody});
  Future<http.Response> delete(String path);
  Future<http.StreamedResponse> multipart(String method, String path,
      {Map<String, String> fields = const {}, Map<String, String> files = const {}});
}
```

- [ ] **Step 1: Write failing tests** using `package:http/testing.dart` `MockClient`:

```dart
// test/api_client_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:horilla/core/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('injects bearer header and base url', () async {
    late http.Request seen;
    ApiClient.instance.configureForTest(
      baseUrl: 'https://hr.example.com', access: 'AT', refresh: 'RT');
    ApiClient.instance.httpClient = MockClient((req) async {
      seen = req; return http.Response('{}', 200);
    });
    await ApiClient.instance.get('/api/employee/employees/');
    expect(seen.url.toString(), 'https://hr.example.com/api/employee/employees/');
    expect(seen.headers['Authorization'], 'Bearer AT');
  });

  test('401 triggers refresh then retry once', () async {
    var calls = <String>[];
    ApiClient.instance.configureForTest(
      baseUrl: 'https://hr.example.com', access: 'OLD', refresh: 'RT');
    ApiClient.instance.httpClient = MockClient((req) async {
      calls.add('${req.url.path}:${req.headers['Authorization']}');
      if (req.url.path == '/api/auth/refresh/') {
        return http.Response(jsonEncode({'access': 'NEW', 'refresh': 'RT2'}), 200);
      }
      final auth = req.headers['Authorization'];
      return http.Response('{}', auth == 'Bearer NEW' ? 200 : 401);
    });
    final res = await ApiClient.instance.get('/api/leave/user-request/');
    expect(res.statusCode, 200);
    expect(calls.where((c) => c.startsWith('/api/leave')).length, 2);
  });

  test('failed refresh calls onSessionExpired', () async {
    var expired = false;
    ApiClient.instance.configureForTest(
      baseUrl: 'https://hr.example.com', access: 'OLD', refresh: 'BAD');
    ApiClient.instance.onSessionExpired = () => expired = true;
    ApiClient.instance.httpClient = MockClient((req) async =>
      http.Response('{}', 401));
    final res = await ApiClient.instance.get('/api/x/');
    expect(res.statusCode, 401);
    expect(expired, isTrue);
  });
}
```

- [ ] **Step 2: `flutter test` → FAIL** (files missing). Also `git rm test/widget_test.dart` (imports nonexistent `package:shimmer/main.dart`).

- [ ] **Step 3: Implement**

```dart
// lib/core/session.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Session {
  Session._();
  static final Session instance = Session._();
  final _secure = const FlutterSecureStorage();

  Future<void> saveLogin({required String baseUrl, required String access, required String refresh}) async {
    await _secure.write(key: 'access', value: access);
    await _secure.write(key: 'refresh', value: refresh);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('typed_url', baseUrl);
  }

  Future<String?> get access => _secure.read(key: 'access');
  Future<String?> get refresh => _secure.read(key: 'refresh');
  Future<String?> get baseUrl async =>
      (await SharedPreferences.getInstance()).getString('typed_url');

  Future<void> updateTokens({required String access, String? refresh}) async {
    await _secure.write(key: 'access', value: access);
    if (refresh != null) await _secure.write(key: 'refresh', value: refresh);
  }

  Future<void> clear() async {
    await _secure.deleteAll();
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().toList()) {
      await prefs.remove(k);
    }
  }
}
```

```dart
// lib/core/api_client.dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'session.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  http.Client httpClient = http.Client();
  void Function()? onSessionExpired;
  static const _timeout = Duration(seconds: 15);

  String? _baseUrl;
  String? _access;
  String? _refresh;

  Future<void> init() async {
    _baseUrl = await Session.instance.baseUrl;
    _access = await Session.instance.access;
    _refresh = await Session.instance.refresh;
  }

  void configureForTest({required String baseUrl, required String access, required String refresh}) {
    _baseUrl = baseUrl; _access = access; _refresh = refresh;
  }

  Future<void> onLogin({required String baseUrl, required String access, required String refresh}) async {
    _baseUrl = baseUrl; _access = access; _refresh = refresh;
    await Session.instance.saveLogin(baseUrl: baseUrl, access: access, refresh: refresh);
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        'Authorization': 'Bearer $_access',
      };

  Future<http.Response> get(String path) => _send('GET', path);
  Future<http.Response> post(String path, {Object? jsonBody}) => _send('POST', path, jsonBody: jsonBody);
  Future<http.Response> put(String path, {Object? jsonBody}) => _send('PUT', path, jsonBody: jsonBody);
  Future<http.Response> delete(String path) => _send('DELETE', path);

  Future<http.Response> _send(String method, String path, {Object? jsonBody, bool retried = false}) async {
    final req = http.Request(method, _uri(path));
    req.headers.addAll(_headers());
    if (jsonBody != null) req.body = jsonEncode(jsonBody);
    final res = await http.Response.fromStream(
        await httpClient.send(req).timeout(_timeout));
    if (res.statusCode == 401 && !retried && !path.startsWith('/api/auth/')) {
      if (await _tryRefresh()) {
        return _send(method, path, jsonBody: jsonBody, retried: true);
      }
      onSessionExpired?.call();
    }
    return res;
  }

  Future<http.StreamedResponse> multipart(String method, String path,
      {Map<String, String> fields = const {}, Map<String, String> files = const {}, bool retried = false}) async {
    final req = http.MultipartRequest(method, _uri(path));
    req.headers['Authorization'] = 'Bearer $_access';
    req.fields.addAll(fields);
    for (final e in files.entries) {
      req.files.add(await http.MultipartFile.fromPath(e.key, e.value));
    }
    final res = await httpClient.send(req).timeout(_timeout);
    if (res.statusCode == 401 && !retried) {
      if (await _tryRefresh()) {
        return multipart(method, path, fields: fields, files: files, retried: true);
      }
      onSessionExpired?.call();
    }
    return res;
  }

  Future<bool> _tryRefresh() async {
    if (_refresh == null) return false;
    try {
      final res = await httpClient
          .post(_uri('/api/auth/refresh/'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'refresh': _refresh}))
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      _access = data['access'] as String?;
      final newRefresh = data['refresh'] as String?;
      if (newRefresh != null) _refresh = newRefresh;
      await Session.instance.updateTokens(access: _access!, refresh: newRefresh);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> logoutServerSide() async {
    if (_refresh == null) return;
    try {
      await httpClient.post(_uri('/api/auth/logout/'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh': _refresh})).timeout(_timeout);
    } catch (_) {}
    _access = null; _refresh = null;
  }
}
```

Note: `Session` uses plugins, so `api_client_test.dart` avoids touching it — `configureForTest` keeps tests plugin-free; the `updateTokens` call inside `_tryRefresh` will throw `MissingPluginException` in tests, so wrap it: `try { await Session.instance.updateTokens(...) } catch (_) {}`.

- [ ] **Step 4: `flutter test` → PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: ApiClient with 401 refresh-retry and secure-storage Session"`

### Task 9: Login + startup + logout wiring

**Files:**
- Modify: `lib/horilla_main/login.dart` (`_login()`, remove `_startNotificationTimer` duplicate)
- Modify: `lib/main.dart` (startup gate, `onSessionExpired` wiring, notification timer 3s→60s)
- Modify: `lib/horilla_main/home.dart` (logout block, ~lines 472-481)
- Modify: `lib/res/utilities/date_time_picker.dart:24`

**Interfaces:**
- Consumes: `ApiClient.onLogin`, `Session.clear`, `ApiClient.logoutServerSide` (Task 8).

- [ ] **Step 1: `_login()` rewrite** in `login.dart`:

```dart
  Future<void> _login() async {
    String serverAddress = serverController.text.trim();
    if (serverAddress.endsWith('/')) {
      serverAddress = serverAddress.substring(0, serverAddress.length - 1);
    }
    if (serverAddress.startsWith('http://')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Server address must use https://'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    if (!serverAddress.startsWith('https://')) {
      serverAddress = 'https://$serverAddress';
    }
    String username = usernameController.text.trim();
    String password = passwordController.text.trim();

    try {
      final response = await http.post(
        Uri.parse('$serverAddress/api/auth/login/'),
        body: {'username': username, 'password': password},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final responseBody = jsonDecode(response.body);
        await ApiClient.instance.onLogin(
          baseUrl: serverAddress,
          access: responseBody['access'] ?? '',
          refresh: responseBody['refresh'] ?? '',
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('typed_url', serverAddress);
        await prefs.setString('face_detection_image',
            responseBody['face_detection_image']?.toString() ?? '');
        await prefs.setBool('face_detection', responseBody['face_detection'] ?? false);
        await prefs.setBool('geo_fencing', responseBody['geo_fencing'] ?? false);
        await prefs.setInt('employee_id', responseBody['employee']?['id'] ?? 0);
        await prefs.setInt('company_id', responseBody['company_id'] ?? 0);

        isAuthenticated = true;
        prefetchData();
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/home');
      } else { /* keep existing snackbar branches */ }
    } // keep existing on TimeoutException / catch branches
  }
```

Delete `_startNotificationTimer` and its call — `main.dart` owns the single timer.

- [ ] **Step 2: `main.dart`** — after login-state detection in `FutureBuilderPage`, call `await ApiClient.instance.init();` before showing `HomePage`. Wire session expiry once during app init:

```dart
  ApiClient.instance.onSessionExpired = () async {
    isAuthenticated = false;
    await Session.instance.clear();
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (r) => false);
  };
```

Auth gate change: token now lives in secure storage, so replace `prefs.getString("token") != null` with `await Session.instance.access != null`. Change `Timer.periodic(Duration(seconds: 3)` to `Duration(seconds: 60)`.

- [ ] **Step 3: Logout in `home.dart`** — replace the token-remove block with:

```dart
      await ApiClient.instance.logoutServerSide();
      await Session.instance.clear();
      isAuthenticated = false;
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
```

- [ ] **Step 4: date picker** — `date_time_picker.dart:24`:

```dart
    lastDate: lastDate ?? DateTime.now().add(const Duration(days: 3650)),
```

(add optional `lastDate` param to `pickDateTime` and pass through).

- [ ] **Step 5: Verify** — `flutter analyze` clean for touched files; run app against a dev server: login lands on home, logout returns to login and back-button does not re-enter home.
- [ ] **Step 6: Commit** — `git commit -am "feat: https-enforced login with refresh token, full logout, 60s polling, date picker fix"`

### Task 10: Call-site migration — attendance + checkin directories

**Files:**
- Modify: every file in `lib/attendance_views/` and `lib/checkin_checkout/checkin_checkout_views/` (except files deleted in Task 11)

**Interfaces:**
- Consumes: `ApiClient.instance.get/post/put/delete/multipart` (Task 8).

- [ ] **Step 1: Mechanical transform, file by file.** Pattern — before:

```dart
final prefs = await SharedPreferences.getInstance();
var token = prefs.getString("token");
var typedServerUrl = prefs.getString("typed_url");
var uri = Uri.parse('$typedServerUrl/api/attendance/attendance/');
var response = await http.get(uri, headers: {
  "Content-Type": "application/json",
  "Authorization": "Bearer $token",
});
```

after:

```dart
final response = await ApiClient.instance.get('/api/attendance/attendance/');
```

Rules: keep response-handling code untouched; keep SharedPreferences reads that are NOT `token`/`typed_url` (employee_id etc.); add `import '../core/api_client.dart';` (adjust relative depth); delete now-unused `http` imports only when no other call remains in the file.

- [ ] **Step 2: Verify no stragglers in these directories:**

Run: `grep -rn 'getString("token")\|Bearer \$token' lib/attendance_views lib/checkin_checkout` → expect zero matches (Task 11 rewrites the clock POST bodies; leave `checkin_checkout_form.dart` clock POSTs as-is here, migrate its other calls).

- [ ] **Step 3: `flutter analyze` + launch app, open each attendance screen against dev server.**
- [ ] **Step 4: Commit** — `git commit -am "refactor: attendance and checkin screens use ApiClient"`

### Task 11: New clock flow — selfie capture + single multipart POST

**Files:**
- Create: `lib/checkin_checkout/checkin_checkout_views/face_capture_screen.dart`
- Create: `lib/core/clock_service.dart`
- Modify: `lib/checkin_checkout/checkin_checkout_views/checkin_checkout_form.dart` (swipe handler)
- Delete: `lib/checkin_checkout/checkin_checkout_views/face_detection.dart`, `lib/checkin_checkout/controllers/face_detection_controller.dart`
- Modify: `lib/main.dart` (remove commented Regula imports/init, lines 4/35/79), `lib/horilla_main/home.dart` (remove duplicated geofence CRUD block ~540-685; keep the enable/disable toggles calling `/api/geofencing/setup/` and `/api/facedetection/config/` via ApiClient)

**Interfaces:**
- Produces:

```dart
// clock_service.dart
class ClockResult { final bool ok; final String? errorCode; final String? message; }
Future<ClockResult> clockAction({required bool checkIn, required String selfiePath});
// face_capture_screen.dart — Navigator.pop with String? (captured image path)
class FaceCaptureScreen extends StatefulWidget { ... }
```

- [ ] **Step 1: `clock_service.dart`:**

```dart
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'api_client.dart';

class ClockResult {
  final bool ok;
  final String? errorCode; // outside_geofence | face_mismatch | not_enrolled
  final String? message;
  ClockResult(this.ok, {this.errorCode, this.message});
}

Future<Position?> _position() async {
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) return null;
  try {
    return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high))
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    return await Geolocator.getLastKnownPosition();
  }
}

Future<ClockResult> clockAction({required bool checkIn, required String selfiePath}) async {
  final pos = await _position();
  final path = checkIn ? '/api/attendance/clock-in/' : '/api/attendance/clock-out/';
  final res = await ApiClient.instance.multipart('POST', path,
      fields: {
        if (pos != null) 'latitude': pos.latitude.toString(),
        if (pos != null) 'longitude': pos.longitude.toString(),
      },
      files: {'image': selfiePath});
  final body = await res.stream.bytesToString();
  if (res.statusCode == 200) return ClockResult(true);
  String? code, msg;
  try {
    final data = jsonDecode(body) as Map<String, dynamic>;
    code = data['error_code'] as String?;
    msg = (data['error'] ?? data['message'])?.toString();
  } catch (_) {}
  return ClockResult(false, errorCode: code, message: msg);
}
```

- [ ] **Step 2: `face_capture_screen.dart`** — front camera preview (`camera` package, `ResolutionPreset.medium`, `enableAudio: false`), a capture button; on capture run `google_mlkit_face_detection`:

```dart
final options = FaceDetectorOptions(performanceMode: FaceDetectorMode.fast);
final detector = FaceDetector(options: options);
final faces = await detector.detectImage(InputImage.fromFilePath(file.path));
if (faces.length != 1) { /* show "Position your face in the frame" and stay */ }
else { Navigator.pop(context, file.path); }
```

Dispose controller + detector in `dispose()`. Guard every `setState` with `mounted`.

- [ ] **Step 3: Rewire swipe handler in `checkin_checkout_form.dart`** — collapse the three branches (face / geofence / plain) into one:

```dart
final selfiePath = await Navigator.push<String>(context,
    MaterialPageRoute(builder: (_) => const FaceCaptureScreen()));
if (selfiePath == null) return;
final result = await clockAction(checkIn: !clockCheckedIn, selfiePath: selfiePath);
if (result.ok) {
  // keep the existing success setState block (stopwatch, times, swipeDirection)
} else if (result.errorCode == 'not_enrolled') {
  Navigator.pushNamed(context, '/setup_imageface'); // route name as registered in main.dart
} else if (result.errorCode == 'face_mismatch' && _faceAttempts < 3) {
  _faceAttempts++;
  showCheckInFailedDialog(context, result.message ?? 'Face verification failed. Try again.');
} else {
  _faceAttempts = 0;
  showCheckInFailedDialog(context, result.message ?? 'Clock action failed');
}
```

Add `int _faceAttempts = 0;` to the state; reset to 0 on success. Extract the duplicated success-`setState` block (stopwatch parse, `checkInFormattedTime`, `_saveClockState`) into one private method `_applyClockSuccess(bool checkedIn)` — it currently appears 3×.

- [ ] **Step 4: Deletions** — remove `face_detection.dart` (contains the TLS bypass — this closes it), `face_detection_controller.dart`, Regula comment lines in `main.dart`, the geofence CRUD duplicate in `home.dart` (keep toggles, now via ApiClient). Verify: `grep -rn "badCertificateCallback\|flutter_face_api" lib/` → zero matches.
- [ ] **Step 5: Manual device test** — with dev server flag ON: enroll → clock-in happy path; wrong face → mismatch dialog; server geofence with test dept non-exempt + GPS spoofed off-site → "outside" message; Sales-dept user off-site → success.
- [ ] **Step 6: Commit** — `git commit -am "feat: single-selfie clock flow with server-side verification; remove Regula and TLS bypass"`

### Task 12: Call-site migration — employee, leave, main directories

**Files:**
- Modify: every file in `lib/employee_views/`, `lib/horilla_leave/`, `lib/horilla_main/` (login already done), plus `lib/main.dart` notification fetches

**Interfaces:**
- Consumes: `ApiClient` (Task 8). Same mechanical pattern as Task 10.

- [ ] **Step 1: Transform all remaining `http.*` call sites** (same before/after pattern as Task 10 Step 1; multipart uploads — leave attachments, profile images — use `ApiClient.instance.multipart`).
- [ ] **Step 2: Verify repo-wide:** `grep -rn 'getString("token")' lib/` → zero; `grep -rln 'package:http/http.dart' lib/ | grep -v core/` → only files with a documented reason (login.dart pre-auth call).
- [ ] **Step 3: `flutter analyze`; launch and click through employee, leave, notification screens.**
- [ ] **Step 4: Commit** — `git commit -am "refactor: remaining screens use ApiClient"`

### Task 13: Geofence admin UI — exemption multi-select

**Files:**
- Modify: `lib/checkin_checkout/checkin_checkout_views/geofencing.dart` (`MapScreen`)

**Interfaces:**
- Consumes: `GET /api/base/departments/` (existing), `exempt_departments` list field on `/api/geofencing/setup/` (Task 2).

- [ ] **Step 1:** Fetch departments on screen load (`ApiClient.instance.get('/api/base/departments/')`, parse `results` id+name pairs). Render checkboxes (the app's existing `multiselect_dropdown_flutter` dependency is fine) below the radius slider. Include selected ids as `exempt_departments` in the existing POST/PUT payloads; pre-select from the GET response.
- [ ] **Step 2:** Slider fix while here: `divisions: 9999` so small radii are selectable.
- [ ] **Step 3:** Manual test: select Sales, save, reload screen, still selected; server rejects/accepts accordingly.
- [ ] **Step 4: Commit** — `git commit -am "feat: geofence exemption departments in admin map screen"`

### Task 14: Release verification

**Files:**
- Modify: `pubspec.yaml` (bump `version: 1.1.0+12`), `android/app/build.gradle.kts` (`versionCode = 12`, `versionName = "1.1.0"`)

- [ ] **Step 1:** `flutter test` — all pass.
- [ ] **Step 2:** `flutter build apk --release` (requires a real `android/key.properties`; if unavailable, verify the build fails ONLY on missing keystore, not on code).
- [ ] **Step 3:** iOS: `flutter build ios --no-codesign` succeeds; confirm `Info.plist` has no `NSAllowsArbitraryLoads`.
- [ ] **Step 4:** Full manual pass on one Android + one iOS device against the staging server: login (https enforced), clock-in/out with face, geofence block/allow, exempt dept, leave request, logout, expired-token recovery (shorten `ACCESS_TOKEN_LIFETIME` to 1 minute on staging and confirm silent refresh).
- [ ] **Step 5: Commit** — `git commit -am "chore: bump version to 1.1.0"`

---

## Rollout checklist (ops, after both phases merge)

1. Server: install deps (`pip install -r requirements.txt`), run migrations, deploy with `STRICT_FACE_ATTENDANCE=false`. Old app keeps working.
2. Delete `/var/www/html/horilla/.horilla` and rotate the admin password it exposed. Create a real `.env` (SECRET_KEY, ALLOWED_HOSTS, DB) — server currently runs on insecure defaults.
3. Admin: set geofence exemption = Sales in web config; confirm every employee has an enrolled face image (employees without one will be blocked once the flag flips).
4. Release mobile 1.1.0; wait for adoption.
5. Set `STRICT_FACE_ATTENDANCE=true`, restart; verify clock-in without selfie is now rejected.
