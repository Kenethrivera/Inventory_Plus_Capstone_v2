import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'loading_proof_photo.dart';

Future<Uint8List> prepareLoadingProofPhotoFromPicker(XFile image) async =>
    compute(prepareLoadingProofPhoto, await image.readAsBytes());
