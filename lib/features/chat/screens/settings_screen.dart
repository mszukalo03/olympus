import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/core.dart';
import '../../../shared/shared.dart';


/// SettingsScreen
/// ---------------------------------------------------------------------------
/// Clean, modern settings UI for:
/// • Runtime endpoints (default / automation / history / websocket)
/// • Theme / appearance
/// • Informational guidance sections
///
/// All legacy local conversation persistence logic has been removed. Runtime
/// configuration persists to the writable documents directory via
/// `config_runtime.json` (handled by `AppConfig`).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Runtime config controllers
  final TextEditingController _defaultApiCtrl = TextEditingController();
  final TextEditingController _automationApiCtrl = TextEditingController();
  final TextEditingController _historyApiCtrl = TextEditingController();
  final TextEditingController _ragApiCtrl = TextEditingController();
  final TextEditingController _wsCtrl = TextEditingController();

  bool _saving = false;

  // Custom endpoints state
  Map<String, Map<String, String>> _customEndpoints = {};
  bool _showingCustomEndpoints = false;

  @override
  void initState() {
    super.initState();
    _seedFromConfig();
    _loadCustomEndpoints();
  }

  void _seedFromConfig() {
    final cfg = AppConfig.instance;
    _defaultApiCtrl.text = cfg.defaultApiEndpoint;
    _automationApiCtrl.text = cfg.automationEndpoint;
    _historyApiCtrl.text = cfg.historyEndpoint;
    _ragApiCtrl.text = cfg.ragApiEndpoint;
    _wsCtrl.text = cfg.websocketEndpoint;
  }

  void _loadCustomEndpoints() {
    _customEndpoints = Map<String, Map<String, String>>.from(
      AppConfig.instance.customEndpoints,
    );
  }

  @override
  void dispose() {
    _defaultApiCtrl
      ..removeListener(_onFieldChanged)
      ..dispose();
    _automationApiCtrl
      ..removeListener(_onFieldChanged)
      ..dispose();
    _historyApiCtrl
      ..removeListener(_onFieldChanged)
      ..dispose();
    _ragApiCtrl
      ..removeListener(_onFieldChanged)
      ..dispose();
    _wsCtrl
      ..removeListener(_onFieldChanged)
      ..dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    setState(() {});
  }

  Future<void> _saveRuntimeConfig() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await AppConfig.instance.saveAndReload({
        'default_api': _defaultApiCtrl.text.trim(),
        'automation_api': _automationApiCtrl.text.trim(),
        'history_api': _historyApiCtrl.text.trim(),
        'rag_api': _ragApiCtrl.text.trim(),
        'ws_endpoint': _wsCtrl.text.trim(),
        'custom_endpoints': _customEndpoints,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Runtime configuration saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reloadRuntimeConfig() async {
    await AppConfig.instance.load();
    if (!mounted) return;
    _seedFromConfig();
    _loadCustomEndpoints();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Runtime configuration reloaded')),
    );
  }

  Future<void> _showConfigSnapshot() async {
    final snapshot = AppConfig.instance.snapshot();
    final formatted = const JsonEncoder.withIndent('  ').convert(snapshot);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Config Snapshot'),
        content: SingleChildScrollView(
          child: SelectableText(
            formatted,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  bool get _hasPendingChanges {
    final cfg = AppConfig.instance;
    return _defaultApiCtrl.text.trim() != cfg.defaultApiEndpoint ||
        _automationApiCtrl.text.trim() != cfg.automationEndpoint ||
        _historyApiCtrl.text.trim() != cfg.historyEndpoint ||
        _ragApiCtrl.text.trim() != cfg.ragApiEndpoint ||
        _wsCtrl.text.trim() != cfg.websocketEndpoint ||
        !_customEndpointsEqual();
  }

  bool _customEndpointsEqual() {
    final current = AppConfig.instance.customEndpoints;
    if (current.length != _customEndpoints.length) return false;

    for (final entry in current.entries) {
      final local = _customEndpoints[entry.key];
      if (local == null) return false;

      for (final configEntry in entry.value.entries) {
        if (local[configEntry.key] != configEntry.value) return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final cfg = AppConfig.instance;
    final settings = context.watch<SettingsController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'View Config JSON',
            icon: const Icon(Icons.code),
            onPressed: _showConfigSnapshot,
          ),
          IconButton(
            tooltip: 'Reload Runtime Config',
            icon: const Icon(Icons.refresh),
            onPressed: _reloadRuntimeConfig,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(UIConstants.spacingL),
        children: [
          _runtimeSection(context, cfg),
          _customEndpointsSection(context),
          _appearanceSection(settings),
          const SizedBox(height: UIConstants.spacingM),
          _footer(context),
        ],
      ),
      floatingActionButton: _hasPendingChanges
          ? FloatingActionButton.extended(
              onPressed: _saving ? null : _saveRuntimeConfig,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving...' : 'Save Changes'),
            )
          : null,
    );
  }

  // --- Sections ----------------------------------------------------------------

  Widget _runtimeSection(BuildContext context, AppConfig cfg) {
    return SectionCard(
      title: 'Runtime',
      trailing: Icon(
        cfg.hasWebsocket ? Icons.check_circle : Icons.info_outline,
        color: cfg.hasWebsocket
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Environment', cfg.environment),
          _kv('Default API', cfg.defaultApiEndpoint),
          _kv('Automation API', cfg.automationEndpoint),
          _kv('History API', cfg.historyEndpoint),
          _kv('RAG API', cfg.ragApiEndpoint),
          _kv(
            'WebSocket',
            cfg.websocketEndpoint.isEmpty
                ? '(disabled)'
                : cfg.websocketEndpoint,
          ),
          const SizedBox(height: UIConstants.spacingM),
          Text(
            'Edit Endpoints',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: UIConstants.spacingS),
          _endpointField(
            controller: _defaultApiCtrl,
            label: 'Default API Endpoint',
            hint: 'http://localhost:11434',
          ),
          _endpointField(
            controller: _automationApiCtrl,
            label: 'Automation API Endpoint',
            hint: 'http://localhost:5678',
          ),
          _endpointField(
            controller: _historyApiCtrl,
            label: 'History API Endpoint',
            hint: 'http://localhost:5000',
            helper:
                'Base URL of the Flask/Postgres history service (e.g. https://your-host:5000)',
          ),
          _endpointField(
            controller: _ragApiCtrl,
            label: 'RAG API Endpoint',
            hint: 'http://localhost:8890',
            helper:
                'Base URL of the FastAPI RAG service (collections & documents)',
          ),
          _endpointField(
            controller: _wsCtrl,
            label: 'WebSocket Endpoint (optional)',
            hint: 'ws://localhost:9000/ws',
          ),
          const SizedBox(height: UIConstants.spacingS),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _hasPendingChanges ? _seedFromConfig : null,
                icon: const Icon(Icons.undo),
                label: const Text('Reset Fields'),
              ),
              const Spacer(),
              if (_hasPendingChanges)
                Text(
                  'Unsaved changes',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveCustomEndpoints() async {
    try {
      await AppConfig.instance.saveAndReload({
        'custom_endpoints': _customEndpoints,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Custom endpoints saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Widget _appearanceSection(SettingsController settings) {
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      heightFactor: 1,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Appearance',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.auto_mode),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode_outlined),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode_outlined),
                      ),
                    ],
                    selected: {settings.themeMode},
                    showSelectedIcon: true,
                    onSelectionChanged: (selection) {
                      final mode = selection.first;
                      if (mode != settings.themeMode) {
                        settings.setTheme(mode);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _customEndpointsSection(BuildContext context) {
    return SectionCard(
      title: 'Custom Endpoints',
      trailing: IconButton(
        icon: Icon(
          _showingCustomEndpoints ? Icons.expand_less : Icons.expand_more,
        ),
        onPressed: () =>
            setState(() => _showingCustomEndpoints = !_showingCustomEndpoints),
        tooltip: _showingCustomEndpoints ? 'Collapse' : 'Expand',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Configure custom shortcuts for different APIs (e.g., /j for Jellyseerr)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UIConstants.spacingM),

          if (_showingCustomEndpoints) ...[
            ..._customEndpoints.entries.map(
              (entry) => _buildCustomEndpointTile(entry.key, entry.value),
            ),
            const SizedBox(height: UIConstants.spacingM),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _addCustomEndpoint,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Endpoint'),
                ),
                const SizedBox(width: UIConstants.spacingM),
                if (_customEndpoints.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: _saveCustomEndpoints,
                    icon: const Icon(Icons.save),
                    label: const Text('Save Changes'),
                  ),
              ],
            ),
          ] else ...[
            Text(
              'Active shortcuts: ${_customEndpoints.keys.map((k) => '/$k').join(', ')}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomEndpointTile(String shortcut, Map<String, String> config) {
    final name = config['name'] ?? '';
    final url = config['url'] ?? '';
    final type = config['type'] ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: UIConstants.spacingS),
      child: Padding(
        padding: const EdgeInsets.all(UIConstants.spacingM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '/$shortcut - $name',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (action) {
                    switch (action) {
                      case 'edit':
                        _editCustomEndpoint(shortcut, config);
                        break;
                      case 'test':
                        _testCustomEndpoint(config);
                        break;
                      case 'delete':
                        _deleteCustomEndpoint(shortcut);
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    const PopupMenuItem(value: 'test', child: Text('Test')),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: UIConstants.spacingXS),
            Text(
              'Type: $type\nURL: $url${config['api_key']?.isNotEmpty == true ? '\nAPI Key: ****' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  void _addCustomEndpoint() {
    _showCustomEndpointDialog();
  }

  void _editCustomEndpoint(String shortcut, Map<String, String> config) {
    _showCustomEndpointDialog(shortcut: shortcut, existing: config);
  }

  Future<void> _showCustomEndpointDialog({
    String? shortcut,
    Map<String, String>? existing,
  }) async {
    final isEditing = shortcut != null;
    final shortcutCtrl = TextEditingController(text: shortcut ?? '');
    final nameCtrl = TextEditingController(text: existing?['name'] ?? '');
    final urlCtrl = TextEditingController(text: existing?['url'] ?? '');
    final apiKeyCtrl = TextEditingController(text: existing?['api_key'] ?? '');
    String selectedType = existing?['type'] ?? 'jellyseerr';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            isEditing ? 'Edit Custom Endpoint' : 'Add Custom Endpoint',
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: shortcutCtrl,
                  enabled: !isEditing,
                  decoration: const InputDecoration(
                    labelText: 'Shortcut (without /)',
                    hintText: 'j, search, etc.',
                  ),
                ),
                const SizedBox(height: UIConstants.spacingM),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    hintText: 'Jellyseerr, SearXNG, etc.',
                  ),
                ),
                const SizedBox(height: UIConstants.spacingM),
                DropdownButtonFormField<String>(
                  value: selectedType,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const [
                    DropdownMenuItem(
                      value: 'jellyseerr',
                      child: Text('Jellyseerr'),
                    ),
                    DropdownMenuItem(value: 'searxng', child: Text('SearXNG')),
                    DropdownMenuItem(
                      value: 'duckduckgo',
                      child: Text('DuckDuckGo'),
                    ),
                    DropdownMenuItem(value: 'custom', child: Text('Custom')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedType = value);
                    }
                  },
                ),
                const SizedBox(height: UIConstants.spacingM),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'http://localhost:5055/api/v1',
                  ),
                ),
                const SizedBox(height: UIConstants.spacingM),
                TextField(
                  controller: apiKeyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API Key (optional)',
                    hintText: 'Enter API key if required',
                  ),
                  obscureText: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final shortcutText = shortcutCtrl.text.trim();
                final nameText = nameCtrl.text.trim();
                final urlText = urlCtrl.text.trim();
                final apiKeyText = apiKeyCtrl.text.trim();

                if (shortcutText.isEmpty ||
                    nameText.isEmpty ||
                    urlText.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Name, URL, and shortcut are required'),
                    ),
                  );
                  return;
                }

                Navigator.pop(ctx, {
                  'shortcut': shortcutText,
                  'name': nameText,
                  'url': urlText,
                  'type': selectedType,
                  'api_key': apiKeyText,
                });
              },
              child: Text(isEditing ? 'Save' : 'Add'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      final newShortcut = result['shortcut']!;
      setState(() {
        if (isEditing && shortcut != newShortcut) {
          _customEndpoints.remove(shortcut);
        }
        _customEndpoints[newShortcut] = {
          'name': result['name']!,
          'url': result['url']!,
          'type': result['type']!,
          'api_key': result['api_key'] ?? '',
        };
      });
    }
  }

  void _deleteCustomEndpoint(String shortcut) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Custom Endpoint'),
        content: Text('Delete the "/$shortcut" endpoint?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              setState(() => _customEndpoints.remove(shortcut));
              Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _testCustomEndpoint(Map<String, String> config) async {
    final type = config['type'] ?? '';

    // For Jellyseerr, use its specific test method with API key
    if (type == 'jellyseerr') {
      final result = await JellyseerrService.instance.testConnection(
        config['url'] ?? '',
        apiKey: config['api_key'],
      );

      if (!mounted) return;

      result.when(
        success: (reachable) {
          final hasApiKey = config['api_key']?.isNotEmpty == true;
          final message = reachable
              ? 'Jellyseerr connection successful ✓'
              : hasApiKey
              ? 'Jellyseerr reachable but may need different API key'
              : 'Jellyseerr reachable but requires API key';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        },
        failure: (error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Jellyseerr test failed: ${error.message}')),
          );
        },
      );
    } else if (type == 'searxng') {
      // For SearXNG, use its specific test method
      final result = await SearxngService.instance.testConnection(
        config['url'] ?? '',
      );

      if (!mounted) return;

      result.when(
        success: (reachable) {
          final message = reachable
              ? 'SearXNG connection successful ✓'
              : 'SearXNG reachable but may block API access';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        },
        failure: (error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('SearXNG test failed: ${error.message}')),
          );
        },
      );
    } else if (type == 'duckduckgo') {
      // For DuckDuckGo, use its specific test method
      final result = await DuckDuckGoService.instance.testConnection();

      if (!mounted) return;

      result.when(
        success: (reachable) {
          final message = reachable
              ? 'DuckDuckGo API connection successful ✓'
              : 'DuckDuckGo API test failed';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        },
        failure: (error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('DuckDuckGo test failed: ${error.message}')),
          );
        },
      );
    } else {
      // For other types, use generic test
      final service = CustomEndpointService.instance;
      final result = await service.testEndpoint(config);

      if (!mounted) return;

      result.when(
        success: (reachable) {
          final message = reachable
              ? 'Endpoint is reachable ✓'
              : 'Endpoint returned an error but is reachable';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        },
        failure: (error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Test failed: ${error.message}')),
          );
        },
      );
    }
  }

  Widget _securitySection() {
    return const SizedBox.shrink();
  }

  Widget _debugSection(BuildContext context) {
    // Removed: webhook debug UI
    return const SizedBox.shrink();
  }

  Widget _nextStepsSection() {
    return const SizedBox.shrink();
  }

  Widget _footer(BuildContext context) {
    return Center(
      child: Text(
        '${AppInfo.name} v${AppInfo.version}',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }

  // --- Helpers -----------------------------------------------------------------

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UIConstants.spacingXS),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(flex: 3, child: Text(v, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _endpointField({
    required TextEditingController controller,
    required String label,
    required String hint,
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UIConstants.spacingS),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
        ),
        onChanged: (_) => setState(() {}), // reflect pending changes
      ),
    );
  }

  Widget _themeModeTile({
    required SettingsController settings,
    required ThemeMode mode,
    required String label,
    required IconData icon,
  }) {
    final active = settings.themeMode == mode;
    return RadioListTile<ThemeMode>(
      value: mode,
      groupValue: settings.themeMode,
      onChanged: (m) {
        if (m != null) settings.setTheme(m);
      },
      title: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: UIConstants.spacingS),
          Text(label),
          if (active)
            Padding(
              padding: const EdgeInsets.only(left: UIConstants.spacingS * 0.75),
              child: Icon(
                Icons.check_circle,
                size: 16,
                color: Colors.green.shade600,
              ),
            ),
        ],
      ),
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }
}
