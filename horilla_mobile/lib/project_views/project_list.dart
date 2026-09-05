import 'package:flutter/material.dart';

import 'project_api.dart';
import 'task_list.dart';

/// Projects: list, create, edit, delete. Tapping a project opens its tasks.
class ProjectListPage extends StatefulWidget {
  const ProjectListPage({super.key});

  @override
  State<ProjectListPage> createState() => _ProjectListPageState();
}

class _ProjectListPageState extends State<ProjectListPage> {
  List<Map<String, dynamic>> _projects = [];
  bool _loading = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final rows = await ProjectApi.projects();
    // Always clear the spinner: a permission failure returns an empty list
    // rather than leaving the screen loading forever.
    if (mounted) {
      setState(() {
        _projects = rows;
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _visible {
    if (_search.isEmpty) return _projects;
    final q = _search.toLowerCase();
    return _projects
        .where((p) => (p['title'] ?? '').toString().toLowerCase().contains(q))
        .toList();
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red : Colors.green,
    ));
  }

  Future<void> _openForm({Map<String, dynamic>? project}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ProjectForm(project: project),
    );
    if (saved == true) {
      _toast(project == null ? 'Project created' : 'Project updated');
      await _load();
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Delete project'),
        content: Text(
            'Delete "${project['title']}"? Its tasks are removed as well.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await ProjectApi.deleteProject(project['id'] as int);
    // Report what the server did, not what was attempted.
    _toast(res.ok ? 'Project deleted' : res.message!, error: !res.ok);
    if (res.ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text('Projects',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.black),
        actions: [
          TextButton(
            onPressed: () => _openForm(),
            child: const Text('CREATE',
                style: TextStyle(
                    color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _visible.isEmpty
                    ? const Center(child: Text('No projects yet'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          itemCount: _visible.length,
                          itemBuilder: (context, i) {
                            final p = _visible[i];
                            final managers =
                                (p['managers'] as List?)?.length ?? 0;
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              child: ListTile(
                                title: Text(p['title']?.toString() ?? '',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                                subtitle: Text([
                                  ProjectApi.projectStatuses[p['status']] ??
                                      p['status']?.toString() ??
                                      '',
                                  if (p['start_date'] != null)
                                    'from ${p['start_date']}',
                                  if (managers > 0) '$managers manager(s)',
                                ].join(' · ')),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => TaskListPage(
                                      projectId: p['id'] as int,
                                      projectTitle:
                                          p['title']?.toString() ?? 'Project',
                                    ),
                                  ),
                                ),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (v) => v == 'edit'
                                      ? _openForm(project: p)
                                      : _confirmDelete(p),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'edit', child: Text('Edit')),
                                    PopupMenuItem(
                                        value: 'delete', child: Text('Delete')),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Create/edit dialog. Pops true when the server accepted the write.
class _ProjectForm extends StatefulWidget {
  const _ProjectForm({this.project});
  final Map<String, dynamic>? project;

  @override
  State<_ProjectForm> createState() => _ProjectFormState();
}

class _ProjectFormState extends State<_ProjectForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title =
      TextEditingController(text: widget.project?['title']?.toString() ?? '');
  late final TextEditingController _description = TextEditingController(
      text: widget.project?['description']?.toString() ?? '');
  late String _status =
      widget.project?['status']?.toString() ?? 'new';
  late String _startDate = widget.project?['start_date']?.toString() ??
      DateTime.now().toIso8601String().split('T').first;
  late String _endDate = widget.project?['end_date']?.toString() ?? '';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool start) async {
    final initial = DateTime.tryParse(start ? _startDate : _endDate) ??
        DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked == null) return;
    final text = picked.toIso8601String().split('T').first;
    setState(() => start ? _startDate = text : _endDate = text);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final res = await ProjectApi.saveProject(
      id: widget.project?['id'] as int?,
      title: _title.text.trim(),
      status: _status,
      startDate: _startDate,
      endDate: _endDate,
      description: _description.text.trim(),
    );
    if (!mounted) return;
    if (res.ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = res.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      title: Text(widget.project == null ? 'Add Project' : 'Edit Project'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red)),
                ),
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Name is required' : null,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: ProjectApi.projectStatuses.entries
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() => _status = v ?? 'new'),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start date'),
                subtitle: Text(_startDate),
                trailing: const Icon(Icons.calendar_today, size: 18),
                onTap: () => _pickDate(true),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('End date'),
                subtitle: Text(_endDate.isEmpty ? 'Not set' : _endDate),
                trailing: const Icon(Icons.calendar_today, size: 18),
                onTap: () => _pickDate(false),
              ),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 3,
                // The model requires it; an empty value is rejected with 400.
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Description is required'
                    : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Save', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
