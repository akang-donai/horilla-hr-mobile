import 'package:flutter/material.dart';

import 'project_api.dart';

/// Tasks of one project: list, create, edit, delete.
class TaskListPage extends StatefulWidget {
  const TaskListPage({
    super.key,
    required this.projectId,
    required this.projectTitle,
  });

  final int projectId;
  final String projectTitle;

  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage> {
  List<Map<String, dynamic>> _tasks = [];
  List<Map<String, dynamic>> _stages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    // Stages come from the project: creating a project seeds a "Todo" stage,
    // and a task must be filed into one.
    final project = await ProjectApi.project(widget.projectId);
    final tasks = await ProjectApi.tasks(widget.projectId);
    if (!mounted) return;
    setState(() {
      _stages =
          List<Map<String, dynamic>>.from(project?['project_stages'] ?? []);
      _tasks = tasks;
      _loading = false;
    });
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red : Colors.green,
    ));
  }

  Future<void> _openForm({Map<String, dynamic>? task}) async {
    if (_stages.isEmpty) {
      _toast('This project has no stage to file a task under', error: true);
      return;
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TaskForm(
        projectId: widget.projectId,
        stages: _stages,
        task: task,
      ),
    );
    if (saved == true) {
      _toast(task == null ? 'Task created' : 'Task updated');
      await _load();
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Delete task'),
        content: Text('Delete "${task['title']}"?'),
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
    final res = await ProjectApi.deleteTask(task['id'] as int);
    _toast(res.ok ? 'Task deleted' : res.message!, error: !res.ok);
    if (res.ok) await _load();
  }

  String _stageName(Map<String, dynamic> task) {
    final stage = task['stage'];
    if (stage is Map) return stage['title']?.toString() ?? '';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
        title: Text(widget.projectTitle,
            style: const TextStyle(
                color: Colors.black, fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: () => _openForm(),
            child: const Text('CREATE',
                style:
                    TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tasks.isEmpty
              ? const Center(child: Text('No tasks yet'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _tasks.length,
                    itemBuilder: (context, i) {
                      final t = _tasks[i];
                      final members =
                          (t['task_members'] as List?)?.length ?? 0;
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: ListTile(
                          title: Text(t['title']?.toString() ?? '',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: Text([
                            ProjectApi.taskStatuses[t['status']] ??
                                t['status']?.toString() ??
                                '',
                            if (_stageName(t).isNotEmpty) _stageName(t),
                            if (t['end_date'] != null) 'due ${t['end_date']}',
                            if (members > 0) '$members member(s)',
                          ].join(' · ')),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) => v == 'edit'
                                ? _openForm(task: t)
                                : _confirmDelete(t),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _TaskForm extends StatefulWidget {
  const _TaskForm({
    required this.projectId,
    required this.stages,
    this.task,
  });

  final int projectId;
  final List<Map<String, dynamic>> stages;
  final Map<String, dynamic>? task;

  @override
  State<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<_TaskForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title =
      TextEditingController(text: widget.task?['title']?.toString() ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.task?['description']?.toString() ?? '');
  late String _status = widget.task?['status']?.toString() ?? 'to_do';
  late int _stageId = _initialStage();
  late String _endDate = widget.task?['end_date']?.toString() ?? '';
  bool _saving = false;
  String? _error;

  int _initialStage() {
    final stage = widget.task?['stage'];
    if (stage is Map && stage['id'] is int) {
      final id = stage['id'] as int;
      if (widget.stages.any((s) => s['id'] == id)) return id;
    }
    return widget.stages.first['id'] as int;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_endDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked == null) return;
    setState(() => _endDate = picked.toIso8601String().split('T').first);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final res = await ProjectApi.saveTask(
      id: widget.task?['id'] as int?,
      projectId: widget.projectId,
      stageId: _stageId,
      title: _title.text.trim(),
      status: _status,
      description: _description.text.trim(),
      endDate: _endDate,
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
      title: Text(widget.task == null ? 'Add Task' : 'Edit Task'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Title is required'
                    : null,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                value: _stageId,
                decoration: const InputDecoration(labelText: 'Stage'),
                items: widget.stages
                    .map((s) => DropdownMenuItem(
                          value: s['id'] as int,
                          child: Text(s['title']?.toString() ?? ''),
                        ))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _stageId = v ?? widget.stages.first['id']),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: ProjectApi.taskStatuses.entries
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() => _status = v ?? 'to_do'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Due date'),
                subtitle: Text(_endDate.isEmpty ? 'Not set' : _endDate),
                trailing: const Icon(Icons.calendar_today, size: 18),
                onTap: _pickEndDate,
              ),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 3,
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
