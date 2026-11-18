import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inventory_plus/logic/loading_proof_photo.dart';

void main() {
  test('keeps a small JPEG without another encode', () {
    final jpeg = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 12, height: 12)),
    );

    expect(prepareLoadingProofPhoto(jpeg), same(jpeg));
  });

  test('converts and bounds a large non-JPEG photo', () {
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 1600, height: 1000)),
    );

    final proof = prepareLoadingProofPhoto(png);
    final decoded = img.decodeJpg(proof);

    expect(proof.length, lessThanOrEqualTo(maxLoadingProofPhotoBytes));
    expect(proof.sublist(0, 3), [0xff, 0xd8, 0xff]);
    expect(decoded, isNotNull);
    expect(decoded!.width, lessThanOrEqualTo(960));
    expect(decoded.height, lessThanOrEqualTo(960));
  });
}
