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
  final TextEditingController _titleCtrl = TextEditingController();
  final List<_QuestionEditor> _questionEditors = [_QuestionEditor()];
  final Set<int> _busyPollIds = <int>{};
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
    _titleCtrl.dispose();
    for (final editor in _questionEditors) {
      editor.dispose();
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
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _addQuestion() {
    if (_questionEditors.length >= 10) return;
    setState(() => _questionEditors.add(_QuestionEditor()));
  }

  void _removeQuestion(int index) {
    if (_questionEditors.length <= 1) return;
    final editor = _questionEditors.removeAt(index);
    editor.dispose();
    setState(() {});
  }

  void _addOption(_QuestionEditor editor) {
    if (editor.optionCtrls.length >= 8) return;
    setState(() => editor.optionCtrls.add(TextEditingController()));
  }

  void _removeOption(_QuestionEditor editor, int index) {
    if (editor.optionCtrls.length <= 2) return;
    final ctrl = editor.optionCtrls.removeAt(index);
    ctrl.dispose();
    setState(() {});
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _titleCtrl.text.trim();
    if (title.length < 3) {
      setState(() => _error = 'Anket başlığı en az 3 karakter olmalı.');
      return;
    }
    final questions = <PhotoPollDraftQuestion>[];
    for (int i = 0; i < _questionEditors.length; i++) {
      final editor = _questionEditors[i];
      final questionText = editor.questionCtrl.text.trim();
      final options = editor.optionCtrls.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
      if (questionText.length < 5) {
        setState(() => _error = '${i + 1}. soru en az 5 karakter olmalı.');
        return;
      }
      if (options.length < 2) {
        setState(() => _error = '${i + 1}. soru için en az 2 seçenek girin.');
        return;
      }
      if (options.toSet().length != options.length) {
        setState(() => _error = '${i + 1}. sorudaki seçenekler benzersiz olmalı.');
        return;
      }
      questions.add(PhotoPollDraftQuestion(question: questionText, options: options));
    }

    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final created = await PhotoPollsApi.create(
        widget.sessionToken,
        title: title,
        questions: questions,
        showResultsAfterVote: _showResultsAfterVote,
      );
      if (!mounted) return;
      _titleCtrl.clear();
      for (final editor in _questionEditors) {
        editor.dispose();
      }
      _questionEditors
        ..clear()
        ..add(_QuestionEditor());
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
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _toggleActive(PhotoPoll poll) async {
    if (_busyPollIds.contains(poll.id)) return;
    setState(() => _busyPollIds.add(poll.id));
    try {
      final updated = await PhotoPollsApi.setActive(
        widget.sessionToken,
        pollId: poll.id,
        active: !poll.isActive,
      );
      if (!mounted) return;
      setState(() {
        _polls = _polls.map((item) => item.id == poll.id ? updated : item).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updated.isActive ? 'Anket yeniden yayına alındı.' : 'Anket yayından kaldırıldı.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() => _busyPollIds.remove(poll.id));
      }
    }
  }

  Future<void> _delete(PhotoPoll poll) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Anketi Sil'),
            content: Text('"${poll.title}" anketini tamamen silmek istediğine emin misin?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('İptal'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Sil'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || _busyPollIds.contains(poll.id)) return;
    setState(() => _busyPollIds.add(poll.id));
    try {
      await PhotoPollsApi.delete(widget.sessionToken, pollId: poll.id);
      if (!mounted) return;
      setState(() {
        _polls = _polls.where((item) => item.id != poll.id).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Anket silindi.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() => _busyPollIds.remove(poll.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Anketleri Yönet'),
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
                          controller: _titleCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Anket Başlığı',
                            hintText: 'Örn: Bahar Festivali geri bildirim anketi',
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Text(
                              'Soru Sayısı: ${_questionEditors.length}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const Spacer(),
                            IconButton(
                              onPressed: _questionEditors.length <= 1 ? null : () => _removeQuestion(_questionEditors.length - 1),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                            IconButton(
                              onPressed: _questionEditors.length >= 10 ? null : _addQuestion,
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (int i = 0; i < _questionEditors.length; i++) ...[
                          _QuestionEditorCard(
                            index: i,
                            editor: _questionEditors[i],
                            canRemove: _questionEditors.length > 1,
                            onRemove: () => _removeQuestion(i),
                            onAddOption: () => _addOption(_questionEditors[i]),
                            onRemoveOption: (optionIndex) => _removeOption(_questionEditors[i], optionIndex),
                          ),
                          const SizedBox(height: 12),
                        ],
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
                            label: Text(_saving ? 'Kaydediliyor...' : 'Anket Oluştur'),
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
                        child: _AdminPollCard(
                          poll: poll,
                          busy: _busyPollIds.contains(poll.id),
                          onToggleActive: () => _toggleActive(poll),
                          onDelete: () => _delete(poll),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _QuestionEditorCard extends StatelessWidget {
  final int index;
  final _QuestionEditor editor;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onAddOption;
  final ValueChanged<int> onRemoveOption;

  const _QuestionEditorCard({
    required this.index,
    required this.editor,
    required this.canRemove,
    required this.onRemove,
    required this.onAddOption,
    required this.onRemoveOption,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.admin, radius: 18, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Soru ${index + 1}',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (canRemove)
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          TextField(
            controller: editor.questionCtrl,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Soru Metni',
              hintText: 'Örn: En çok hangi bölümü beğendin?',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Seçenekler',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < editor.optionCtrls.length; i++) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: editor.optionCtrls[i],
                    decoration: InputDecoration(labelText: 'Seçenek ${i + 1}'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: editor.optionCtrls.length <= 2 ? null : () => onRemoveOption(i),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          TextButton.icon(
            onPressed: editor.optionCtrls.length >= 8 ? null : onAddOption,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Seçenek Ekle'),
          ),
        ],
      ),
    );
  }
}

class _AdminPollCard extends StatelessWidget {
  final PhotoPoll poll;
  final bool busy;
  final VoidCallback onToggleActive;
  final VoidCallback onDelete;

  const _AdminPollCard({
    required this.poll,
    required this.busy,
    required this.onToggleActive,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.admin, radius: 18, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  poll.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: poll.isActive ? AppTheme.cyan.withOpacity(0.16) : AppTheme.surfaceSecondary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  poll.isActive ? 'Yayında' : 'Pasif',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: poll.isActive ? AppTheme.cyan : AppTheme.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${poll.questionCount} soru',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            poll.showResultsAfterVote
                ? 'Oy verdikten sonra sonuçlar görünüyor'
                : 'Oy verdikten sonra sonuçlar gizli kalıyor',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          ...poll.questions.take(3).map(
                (question) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '• ${question.text}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
          if (poll.questions.length > 3)
            Text(
              '+ ${poll.questions.length - 3} soru daha',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onToggleActive,
                icon: Icon(poll.isActive ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                label: Text(poll.isActive ? 'Yayından Kaldır' : 'Yayına Al'),
              ),
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed: busy ? null : onDelete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Sil'),
              ),
            ],
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

class _QuestionEditor {
  final TextEditingController questionCtrl = TextEditingController();
  final List<TextEditingController> optionCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];

  void dispose() {
    questionCtrl.dispose();
    for (final ctrl in optionCtrls) {
      ctrl.dispose();
    }
  }
}
