import 'dart:convert';

import '../core/api_client.dart';

/// Thin wrapper over /api/project/.
///
/// Kept separate from the screens so the request shapes live in one place:
/// the write fields are not the read fields (the serializer exposes
/// `project_id`/`stage_id`/`managers_ids` write-only and returns nested
/// objects), and both deletes answer 204 rather than 200.
class ProjectApi {
  static const projectStatuses = <String, String>{
    'new': 'New',
    'in_progress': 'In Progress',
    'completed': 'Completed',
    'on_hold': 'On Hold',
    'cancelled': 'Cancelled',
    'expired': 'Expired',
  };

  static const taskStatuses = <String, String>{
    'to_do': 'To Do',
    'in_progress': 'In Progress',
    'completed': 'Completed',
    'expired': 'Expired',
  };

  /// Rows of a paginated or bare list response.
  static List<Map<String, dynamic>> _rows(String body) {
    final decoded = jsonDecode(body);
    final list = decoded is Map && decoded.containsKey('results')
        ? decoded['results']
        : decoded;
    return List<Map<String, dynamic>>.from(list as List);
  }

  /// The server's message for a failed call, for showing to the user.
  static String errorFrom(int status, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in ['error', 'detail', 'title', 'description']) {
          final v = decoded[key];
          if (v != null) return v is List ? v.join(', ') : v.toString();
        }
        if (decoded.isNotEmpty) {
          final first = decoded.entries.first;
          final v = first.value;
          return '${first.key}: ${v is List ? v.join(', ') : v}';
        }
      }
    } catch (_) {}
    return 'Request failed ($status)';
  }

  static Future<List<Map<String, dynamic>>> projects() async {
    final res = await ApiClient.instance.get('/api/project/project/');
    if (res.statusCode != 200) return [];
    return _rows(res.body);
  }

  static Future<List<Map<String, dynamic>>> tasks(int projectId) async {
    final res =
        await ApiClient.instance.get('/api/project/project/$projectId/task/');
    if (res.statusCode != 200) return [];
    return _rows(res.body);
  }

  static Future<Map<String, dynamic>?> project(int id) async {
    final res = await ApiClient.instance.get('/api/project/project/$id/');
    if (res.statusCode != 200) return null;
    return Map<String, dynamic>.from(jsonDecode(res.body));
  }

  static Future<ApiResult> saveProject({
    int? id,
    required String title,
    required String status,
    required String startDate,
    String? endDate,
    required String description,
  }) async {
    final body = <String, dynamic>{
      'title': title,
      'status': status,
      'start_date': startDate,
      // Required by the model; an empty description is rejected with 400.
      'description': description,
      if (endDate != null && endDate.isNotEmpty) 'end_date': endDate,
    };
    final res = id == null
        ? await ApiClient.instance
            .post('/api/project/project/', jsonBody: jsonEncode(body))
        : await ApiClient.instance
            .put('/api/project/project/$id/', jsonBody: jsonEncode(body));
    return ApiResult.from(res.statusCode, res.body, const [200, 201]);
  }

  static Future<ApiResult> deleteProject(int id) async {
    final res = await ApiClient.instance.delete('/api/project/project/$id/');
    return ApiResult.from(res.statusCode, res.body, const [200, 204]);
  }

  static Future<ApiResult> saveTask({
    int? id,
    required int projectId,
    required int stageId,
    required String title,
    required String status,
    required String description,
    String? startDate,
    String? endDate,
  }) async {
    final body = <String, dynamic>{
      'title': title,
      'project_id': projectId,
      'stage_id': stageId,
      'status': status,
      'description': description,
      if (startDate != null && startDate.isNotEmpty) 'start_date': startDate,
      if (endDate != null && endDate.isNotEmpty) 'end_date': endDate,
    };
    final res = id == null
        ? await ApiClient.instance
            .post('/api/project/task/', jsonBody: jsonEncode(body))
        : await ApiClient.instance
            .put('/api/project/task/$id/', jsonBody: jsonEncode(body));
    return ApiResult.from(res.statusCode, res.body, const [200, 201]);
  }

  static Future<ApiResult> deleteTask(int id) async {
    final res = await ApiClient.instance.delete('/api/project/task/$id/');
    return ApiResult.from(res.statusCode, res.body, const [200, 204]);
  }
}

/// Outcome of a write, so callers report what actually happened rather than
/// assuming success.
class ApiResult {
  final bool ok;
  final String? message;
  const ApiResult(this.ok, [this.message]);

  factory ApiResult.from(int status, String body, List<int> okCodes) {
    if (okCodes.contains(status)) return const ApiResult(true);
    return ApiResult(false, ProjectApi.errorFrom(status, body));
  }
}
