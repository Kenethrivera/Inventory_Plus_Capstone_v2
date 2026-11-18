// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:inventory_plus/logic/loading_proof_photo.dart';
import 'package:inventory_plus/logic/loading_proof_photo_picker_web.dart';

void main() {
  test('browser converts a selected PNG into a bounded JPEG', () async {
    final canvas = html.CanvasElement(width: 1200, height: 800);
    canvas.context2D
      ..fillStyle = '#bf3900'
      ..fillRect(0, 0, 1200, 800);
    final png = await canvas.toBlob('image/png');
    final url = html.Url.createObjectUrlFromBlob(png);
    addTearDown(() => html.Url.revokeObjectUrl(url));

    final proof = await prepareLoadingProofPhotoFromPicker(XFile(url));

    expect(proof.length, inInclusiveRange(100, maxLoadingProofPhotoBytes));
    expect(proof.sublist(0, 3), [0xff, 0xd8, 0xff]);
  });
}
