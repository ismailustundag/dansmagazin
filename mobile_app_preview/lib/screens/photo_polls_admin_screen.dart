import 'package:flutter/material.dart';

import '../services/photo_polls_api.dart';
import '../theme/app_theme.dart';

class PhotoPollsAdminScreen extends StatefulWidget {
  final String sessionToken;

  const PhotoPollsAdminScreen({
    super.key,
    required this.sessionToken,
  });

  @override
  State<PhotoPollsAdminScreen> createState() => _PhotoPollsAdminScreenState();
}

class _PhotoPollsAdminScreenState extends State<PhotoPollsAdminScreen> {
  final TextEditingController _questionCtrl = TextEditingController();
  final List<TextEditingController> _optionCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _showResultsAfterVote = true;
  bool _saving = false;
  bool _loading = true;
  String _error = '';
  List<PhotoPoll> _polls = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _questionCtrl.dispose();
    for (final ctrl in _optionCtrls) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final polls = await PhotoPollsApi.fetch(
        widget.sessionToken,
        includeInactive: true,
      );
      if (!mounted) return;
      setState(() => _polls = polls);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _addOption() {
    if (_optionCtrls.length >= 8) return;
    setState(() => _optionCtrls.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_optionCtrls.length <= 2) return;
    final ctrl = _optionCtrls.removeAt(index);
    ctrl.dispose();
    setState(() {});
  }

  Future<void> _save() async {
    if (_saving) return;
    final question = _questionCtrl.text.trim();
    final options = _optionCtrls.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
    if (question.length < 5) {
      setState(() => _error = 'Anket sorusu en az 5 karakter olmalı.');
      return;
    }
    if (options.length < 2) {
      setState(() => _error = 'En az 2 seçenek girin.');
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final created = await PhotoPollsApi.create(
        widget.sessionToken,
        question: question,
        options: options,
        showResultsAfterVote: _showResultsAfterVote,
      );
      if (!mounted) return;
      _questionCtrl.clear();
      for (final ctrl in _optionCtrls) {
        ctrl.clear();
      }
      while (_optionCtrls.length > 2) {
        _optionCtrls.removeLast().dispose();
      }
      setState(() {
        _showResultsAfterVote = true;
        _polls = [created, ..._polls];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Anket oluşturuldu.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Anket Oluştur'),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: AppTheme.panel(tone: AppTone.admin, radius: 20, elevated: true),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _questionCtrl,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Anket Sorusu',
                            hintText: 'Topluluğa sormak istediğin soruyu yaz',
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Seçenekler',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        for (int i = 0; i < _optionCtrls.length; i++) ...[
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _optionCtrls[i],
                                  decoration: InputDecoration(
                                    labelText: 'Seçenek ${i + 1}',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: _optionCtrls.length <= 2 ? null : () => _removeOption(i),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _optionCtrls.length >= 8 ? null : _addOption,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Seçenek Ekle'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile.adaptive(
                          value: _showResultsAfterVote,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Oy verdikten sonra yüzdeleri göster'),
                          subtitle: const Text('Kapalıysa kullanıcı oy verdikten sonra sadece oyunun kaydedildiğini görür.'),
                          onChanged: _saving ? null : (value) => setState(() => _showResultsAfterVote = value),
                        ),
                        if (_error.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            _error,
                            style: const TextStyle(color: AppTheme.error),
                          ),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: const Icon(Icons.poll_outlined),
                            label: Text(_saving ? 'Oluşturuluyor...' : 'Anket Oluştur'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Mevcut Anketler',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  if (_polls.isEmpty)
                    const _AdminInfoCard(text: 'Henüz anket yok.')
                  else
                    ..._polls.map(
                      (poll) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _AdminPollCard(poll: poll),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _AdminPollCard extends StatelessWidget {
  final PhotoPoll poll;

  const _AdminPollCard({required this.poll});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.admin, radius: 18, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            poll.question,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            poll.showResultsAfterVote
                ? 'Oy verdikten sonra sonuçlar görünüyor'
                : 'Oy verdikten sonra sonuçlar gizli kalıyor',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          ...poll.options.map(
            (option) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(child: Text(option.text)),
                  Text(
                    '${option.voteCount ?? 0} oy',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminInfoCard extends StatelessWidget {
  final String text;

  const _AdminInfoCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.admin, radius: 18, subtle: true),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
      ),
    );
  }
}
