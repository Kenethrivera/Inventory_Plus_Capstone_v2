import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class ApprovalProofSelection {
  const ApprovalProofSelection({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
}

class ApprovalProofPicker extends StatefulWidget {
  const ApprovalProofPicker({
    super.key,
    required this.onChanged,
    this.busy = false,
  });

  final ValueChanged<ApprovalProofSelection?> onChanged;
  final bool busy;

  @override
  State<ApprovalProofPicker> createState() => _ApprovalProofPickerState();
}

class _ApprovalProofPickerState extends State<ApprovalProofPicker> {
  static const _blue = Color(0xFF2563EB);
  static const _font = 'Hellix';
  final ImagePicker _picker = ImagePicker();
  ApprovalProofSelection? _selection;
  bool _picking = false;
  String? _error;

  String? _mimeTypeFor(XFile file) {
    final reported = file.mimeType?.toLowerCase();
    if (const {
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
    }.contains(reported)) {
      return reported;
    }
    final name = file.name.toLowerCase();
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.gif')) return 'image/gif';
    return null;
  }

  Future<void> _pick(ImageSource source) async {
    if (_picking || widget.busy) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final file = await _picker.pickImage(source: source, imageQuality: 88);
      if (file == null) return;
      final mimeType = _mimeTypeFor(file);
      if (mimeType == null) {
        throw const FormatException(
          'Only JPG, PNG, WebP, or GIF images are allowed.',
        );
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        throw const FormatException('Proof image must be smaller than 10 MB.');
      }
      final selection = ApprovalProofSelection(
        bytes: bytes,
        fileName: file.name,
        mimeType: mimeType,
      );
      if (!mounted) return;
      setState(() => _selection = selection);
      widget.onChanged(selection);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('FormatException: ', '');
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _remove() {
    if (widget.busy) return;
    setState(() {
      _selection = null;
      _error = null;
    });
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final selection = _selection;
    final disabled = _picking || widget.busy;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _error == null ? const Color(0xFFE2E8F0) : Colors.red,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(LucideIcons.camera, size: 17, color: _blue),
              SizedBox(width: 8),
              Text(
                'Proof of Request',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontFamily: _font,
                ),
              ),
              SizedBox(width: 6),
              Text(
                '*',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Photo evidence is required for Admin verification.',
            style: TextStyle(
              color: Color(0xFF64748B),
              fontSize: 12,
              fontFamily: _font,
            ),
          ),
          if (selection != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                selection.bytes,
                width: double.infinity,
                height: 150,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              selection.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontFamily: _font),
            ),
          ],
          if (widget.busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(color: _blue),
            const SizedBox(height: 6),
            const Text(
              'Uploading proof securely...',
              style: TextStyle(fontSize: 12, fontFamily: _font),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.red,
                fontSize: 12,
                fontFamily: _font,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: disabled ? null : () => _pick(ImageSource.gallery),
                icon: const Icon(LucideIcons.image, size: 16),
                label: Text(selection == null ? 'Select image' : 'Replace'),
              ),
              OutlinedButton.icon(
                onPressed: disabled ? null : () => _pick(ImageSource.camera),
                icon: const Icon(LucideIcons.camera, size: 16),
                label: const Text('Take photo'),
              ),
              if (selection != null)
                TextButton.icon(
                  onPressed: disabled ? null : _remove,
                  icon: const Icon(LucideIcons.trash2, size: 16),
                  label: const Text('Remove'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
