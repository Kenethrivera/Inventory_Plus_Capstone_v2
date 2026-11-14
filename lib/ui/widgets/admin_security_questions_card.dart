import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../logic/inventory_controller.dart';
import '../../logic/security_questions.dart';
import '../../services/app_logger.dart';
import 'app_styled_dropdown.dart';
import 'app_toast.dart';

class AdminSecurityQuestionsCard extends StatefulWidget {
  const AdminSecurityQuestionsCard({super.key, required this.controller});

  final InventoryController controller;

  @override
  State<AdminSecurityQuestionsCard> createState() =>
      _AdminSecurityQuestionsCardState();
}

class _AdminSecurityQuestionsCardState
    extends State<AdminSecurityQuestionsCard> {
  static const _orange = Color(0xFFC83D08);
  static const _border = Color(0xFFE7DED8);
  static const _muted = Color(0xFF756D67);

  final _answers = List.generate(3, (_) => TextEditingController());
  final _password = TextEditingController();
  final _selected = <String>['first_pet', 'birth_city', 'first_school'];
  bool _expanded = false;
  bool _saving = false;
  bool _loadingStatus = true;
  bool _statusUnavailable = false;
  bool _configured = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadStatus());
  }

  Future<void> _loadStatus() async {
    try {
      final ids = await widget.controller.securityQuestionIds();
      if (!mounted) return;
      setState(() {
        _configured = ids.length == 3;
        if (_configured && ids.every(securityQuestionChoices.containsKey)) {
          _selected.setAll(0, ids);
        }
        _loadingStatus = false;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'Security question status failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _loadingStatus = false;
          _statusUnavailable = true;
        });
      }
    }
  }

  bool get _canSave {
    final answers = _answers
        .map(
          (answer) =>
              answer.text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
        )
        .toList();
    return !_saving &&
        _password.text.isNotEmpty &&
        _selected.toSet().length == 3 &&
        answers.toSet().length == 3 &&
        answers.every(
          (answer) => answer.length >= 2 && utf8.encode(answer).length <= 72,
        );
  }

  @override
  void dispose() {
    for (final answer in _answers) {
      answer.dispose();
    }
    _password.dispose();
    super.dispose();
  }

  void _cancel() {
    for (final answer in _answers) {
      answer.clear();
    }
    _password.clear();
    setState(() {
      _expanded = false;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.controller.saveSecurityQuestions(
        currentPassword: _password.text,
        questions: [
          for (var index = 0; index < 3; index++)
            {'id': _selected[index], 'answer': _answers[index].text},
        ],
      );
      if (!mounted) return;
      if (!saved) {
        setState(
          () => _error =
              'Could not save. Check your current password and answers.',
        );
        return;
      }
      for (final answer in _answers) {
        answer.clear();
      }
      _password.clear();
      setState(() {
        _configured = true;
        _statusUnavailable = false;
        _expanded = false;
      });
      AppToast.success(context, 'Security questions saved.');
    } catch (error, stackTrace) {
      AppLogger.error(
        'Security questions setup failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(
          () => _error = 'Could not save security questions. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _badge() {
    final label = _loadingStatus
        ? 'Checking…'
        : _statusUnavailable
        ? 'Status unavailable'
        : _configured
        ? 'Set up'
        : 'Not set up';
    final color = _configured && !_statusUnavailable
        ? const Color(0xFF13764A)
        : const Color(0xFF9A4B00);
    final background = _configured && !_statusUnavailable
        ? const Color(0xFFE7F5ED)
        : const Color(0xFFFFF1C4);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }

  Widget _header(bool compact) {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text(
          'Security questions',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 4),
        Text(
          'Used to recover your password if you cannot get a code by email or SMS.',
          style: TextStyle(color: _muted, fontSize: 13),
        ),
      ],
    );
    final action = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _badge(),
        if (!_expanded) ...[
          const SizedBox(width: 14),
          OutlinedButton(
            onPressed: _saving ? null : () => setState(() => _expanded = true),
            style: OutlinedButton.styleFrom(
              foregroundColor: _orange,
              side: const BorderSide(color: _border),
              shape: const StadiumBorder(),
            ),
            child: Text(_configured ? 'Change' : 'Set up'),
          ),
        ],
      ],
    );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [title, const SizedBox(height: 12), action],
      );
    }
    return Row(
      children: [
        Expanded(child: title),
        const SizedBox(width: 18),
        action,
      ],
    );
  }

  InputDecoration _inputDecoration({String? hint, String? suffix}) =>
      InputDecoration(
        hintText: hint,
        suffixText: suffix,
        counterText: '',
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 14,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _border),
        ),
      );

  Widget _questionRow(int index, bool compact) {
    final number = CircleAvatar(
      radius: 17,
      backgroundColor: const Color(0xFFFFE9DE),
      child: Text(
        '${index + 1}',
        style: const TextStyle(color: _orange, fontWeight: FontWeight.w700),
      ),
    );
    final question = AppStyledDropdown<String>(
      value: _selected[index],
      style: const TextStyle(fontSize: 14),
      decoration: _inputDecoration(),
      items: [
        for (final entry in securityQuestionChoices.entries)
          DropdownMenuItem(
            value: entry.key,
            enabled: !_selected.asMap().entries.any(
              (selected) =>
                  selected.key != index && selected.value == entry.key,
            ),
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _saving
          ? null
          : (value) => setState(() {
              _selected[index] = value ?? _selected[index];
              _error = null;
            }),
    );
    final answer = TextField(
      controller: _answers[index],
      style: const TextStyle(fontSize: 14),
      enabled: !_saving,
      obscureText: true,
      maxLength: 70,
      onChanged: (_) => setState(() => _error = null),
      decoration: _inputDecoration(
        hint: 'Your answer',
        suffix: '${_answers[index].text.length}/70',
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 8), child: number),
          const SizedBox(width: 12),
          Expanded(
            child: compact
                ? Column(
                    children: [question, const SizedBox(height: 8), answer],
                  )
                : Row(
                    children: [
                      Expanded(child: question),
                      const SizedBox(width: 12),
                      Expanded(child: answer),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _form(bool compact) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Choose 3 different questions. Recovery asks all 3. Use answers others cannot easily guess.',
          style: TextStyle(color: _muted, fontSize: 13),
        ),
        const SizedBox(height: 14),
        for (var index = 0; index < 3; index++) _questionRow(index, compact),
        const Divider(color: _border),
        const SizedBox(height: 12),
        if (compact) ...[
          const Text(
            'Current password',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          TextField(
            controller: _password,
            style: const TextStyle(fontSize: 14),
            enabled: !_saving,
            obscureText: true,
            onChanged: (_) => setState(() => _error = null),
            decoration: _inputDecoration(hint: 'Confirm it is you'),
          ),
          const SizedBox(height: 16),
        ],
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
          const SizedBox(height: 12),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!compact) ...[
              SizedBox(
                width: 300,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Current password',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 7),
                    TextField(
                      controller: _password,
                      style: const TextStyle(fontSize: 14),
                      enabled: !_saving,
                      obscureText: true,
                      onChanged: (_) => setState(() => _error = null),
                      decoration: _inputDecoration(hint: 'Confirm it is you'),
                    ),
                  ],
                ),
              ),
              const Spacer(),
            ],
            OutlinedButton(
              onPressed: _saving ? null : _cancel,
              style: OutlinedButton.styleFrom(
                foregroundColor: _orange,
                side: const BorderSide(color: _border),
                shape: const StadiumBorder(),
              ),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _canSave ? _save : null,
              style: FilledButton.styleFrom(backgroundColor: _orange),
              child: Text(_saving ? 'Saving…' : 'Save questions'),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 700;
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              child: _header(compact),
            ),
            if (_expanded) ...[
              const Divider(height: 1, color: _border),
              _form(compact),
            ],
          ],
        ),
      );
    },
  );
}
