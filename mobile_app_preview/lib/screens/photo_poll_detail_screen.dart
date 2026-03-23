import 'package:flutter/material.dart';

import '../services/photo_polls_api.dart';
import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';

class PhotoPollDetailScreen extends StatefulWidget {
  final String sessionToken;
  final PhotoPoll initialPoll;

  const PhotoPollDetailScreen({
    super.key,
    required this.sessionToken,
    required this.initialPoll,
  });

  @override
  State<PhotoPollDetailScreen> createState() => _PhotoPollDetailScreenState();
}

class _PhotoPollDetailScreenState extends State<PhotoPollDetailScreen> {
  late PhotoPoll _poll;
  final Map<int, int> _draftAnswers = <int, int>{};
  bool _loading = false;
  bool _submitting = false;
  String _error = '';

  bool get _isLoggedIn => widget.sessionToken.trim().isNotEmpty;
  bool get _canSubmit =>
      _isLoggedIn &&
      _poll.isActive &&
      !_poll.hasVoted &&
      _draftAnswers.length == _poll.questions.length &&
      _poll.questions.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _poll = widget.initialPoll;
    for (final question in _poll.questions) {
      if ((question.myOptionId ?? 0) > 0) {
        _draftAnswers[question.id] = question.myOptionId!;
      }
    }
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final fresh = await PhotoPollsApi.fetchOne(
        widget.sessionToken,
        pollId: _poll.id,
      );
      if (!mounted) return;
      setState(() {
        _poll = fresh;
        _draftAnswers
          ..clear()
          ..addEntries(
            fresh.questions
                .where((question) => (question.myOptionId ?? 0) > 0)
                .map((question) => MapEntry(question.id, question.myOptionId!)),
          );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit || _submitting) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Oyunu Gönder'),
            content: const Text('Gönder tuşuna bastıktan sonra cevaplarını değiştiremezsin. Devam etmek istiyor musun?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('İptal'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Gönder'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    setState(() => _submitting = true);
    try {
      final updated = await PhotoPollsApi.submit(
        widget.sessionToken,
        pollId: _poll.id,
        answers: _draftAnswers,
      );
      if (!mounted) return;
      setState(() => _poll = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            updated.canViewResults ? 'Oyun kaydedildi. Sonuçlar güncellendi.' : 'Oyun kaydedildi.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Anket'),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: AppTheme.panel(tone: AppTone.photos, radius: 22, elevated: true),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        EmojiText(
                          _poll.title,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_poll.questionCount} soru',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _poll.isActive ? 'Anket şu an açık.' : 'Bu anket yayından kaldırıldı.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                        ),
                        if (_error.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            _error,
                            style: const TextStyle(color: AppTheme.error),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ..._poll.questions.asMap().entries.map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _PollQuestionCard(
                            index: entry.key,
                            question: entry.value,
                            selectedOptionId: _poll.hasVoted ? entry.value.myOptionId : _draftAnswers[entry.value.id],
                            canSelect: _isLoggedIn && _poll.isActive && !_poll.hasVoted,
                            canViewResults: _poll.canViewResults,
                            onSelect: (optionId) {
                              if (_poll.hasVoted) return;
                              setState(() => _draftAnswers[entry.value.id] = optionId);
                            },
                          ),
                        ),
                      ),
                  if (!_isLoggedIn)
                    _PollInfoCard(
                      text: 'Oy kullanmak için giriş yapın.',
                    )
                  else if (_poll.hasVoted && !_poll.canViewResults)
                    _PollInfoCard(
                      text: 'Oyun kaydedildi. Bu ankette sonuçlar katılımcılara gösterilmiyor.',
                    )
                  else if (_poll.canViewResults)
                    _PollInfoCard(
                      text: '${_poll.totalVotes ?? 0} kişi oy kullandı.',
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _canSubmit ? _submit : null,
                      icon: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded),
                      label: Text(_submitting ? 'Gönderiliyor...' : 'Gönder'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _PollQuestionCard extends StatelessWidget {
  final int index;
  final PhotoPollQuestion question;
  final int? selectedOptionId;
  final bool canSelect;
  final bool canViewResults;
  final ValueChanged<int> onSelect;

  const _PollQuestionCard({
    required this.index,
    required this.question,
    required this.selectedOptionId,
    required this.canSelect,
    required this.canViewResults,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.photos, radius: 22, elevated: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Soru ${index + 1}',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 6),
          EmojiText(
            question.text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          ...question.options.map(
            (option) {
              final percentage = option.percentage ?? 0;
              final selected = selectedOptionId == option.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: canSelect ? () => onSelect(option.id) : null,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppTheme.surfacePrimary,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: selected ? AppTheme.cyan : AppTheme.borderSoft,
                      ),
                    ),
                    child: Stack(
                      children: [
                        if (canViewResults)
                          Positioned.fill(
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: (percentage.clamp(0, 100)) / 100,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppTheme.cyan.withOpacity(0.14),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          child: Row(
                            children: [
                              Expanded(
                                child: EmojiText(
                                  option.text,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                      ),
                                ),
                              ),
                              if (selected)
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: Icon(Icons.check_circle_rounded, size: 18, color: AppTheme.cyan),
                                ),
                              if (canViewResults)
                                Text(
                                  '%${percentage.toStringAsFixed(percentage.truncateToDouble() == percentage ? 0 : 1)}',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: AppTheme.textSecondary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PollInfoCard extends StatelessWidget {
  final String text;

  const _PollInfoCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.photos, radius: 18, subtle: true),
      child: EmojiText(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
      ),
    );
  }
}
