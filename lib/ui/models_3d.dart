import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../data/inventory.dart';

// ============================================================================
// SHARED 3D PRIMITIVES
// ============================================================================

class Point3D {
  final double x;
  final double y;
  final double z;

  const Point3D(this.x, this.y, this.z);
}

class Face3D {
  final List<Point3D> points;
  final Color color;

  const Face3D(this.points, this.color);
}

/// One real, solid sub-component of a model.
///
/// This is used for outlines only. The fill geometry may be chunked, but
/// outlines remain based on the original unsliced part so no seam lines
/// appear between chunks.
class BoxPart {
  final double x;
  final double y;
  final double z;
  final double width;
  final double height;
  final double depth;

  const BoxPart({
    required this.x,
    required this.y,
    required this.z,
    required this.width,
    required this.height,
    required this.depth,
  });
}

/// A complete 3D model.
///
/// faces = fill geometry
/// parts = original components used for clean outlines
class Model3D {
  final List<Face3D> faces;
  final List<BoxPart> parts;
  final List<int>? boxLayers;

  const Model3D(this.faces, this.parts, {this.boxLayers});
}

// ============================================================================
// BOX GENERATOR
// ============================================================================

List<Face3D> createBox({
  required double x,
  required double y,
  required double z,
  required double width,
  required double height,
  required double depth,
  required Color color,
}) {
  final x1 = x - width / 2;
  final x2 = x + width / 2;

  final y1 = y - height / 2;
  final y2 = y + height / 2;

  final z1 = z - depth / 2;
  final z2 = z + depth / 2;

  final p000 = Point3D(x1, y1, z1);
  final p100 = Point3D(x2, y1, z1);
  final p110 = Point3D(x2, y2, z1);
  final p010 = Point3D(x1, y2, z1);

  final p001 = Point3D(x1, y1, z2);
  final p101 = Point3D(x2, y1, z2);
  final p111 = Point3D(x2, y2, z2);
  final p011 = Point3D(x1, y2, z2);

  return [
    // Front
    Face3D(
      [p001, p101, p111, p011],
      color,
    ),

    // Back
    Face3D(
      [p100, p000, p010, p110],
      color.withOpacity(0.65),
    ),

    // Left
    Face3D(
      [p000, p001, p011, p010],
      color.withOpacity(0.75),
    ),

    // Right
    Face3D(
      [p101, p100, p110, p111],
      color.withOpacity(0.85),
    ),

    // Top
    Face3D(
      [p011, p111, p110, p010],
      color.withOpacity(0.90),
    ),

    // Bottom
    Face3D(
      [p000, p100, p101, p001],
      color.withOpacity(0.55),
    ),
  ];
}

// ============================================================================
// CHUNKED BOX GENERATOR
// ============================================================================

List<Face3D> createChunkedBox({
  required double x,
  required double y,
  required double z,
  required double width,
  required double height,
  required double depth,
  required Color color,
  int chunksX = 1,
  int chunksY = 1,
  int chunksZ = 1,
}) {
  final faces = <Face3D>[];

  final w = width / chunksX;
  final h = height / chunksY;
  final d = depth / chunksZ;

  for (int i = 0; i < chunksX; i++) {
    for (int j = 0; j < chunksY; j++) {
      for (int k = 0; k < chunksZ; k++) {
        faces.addAll(
          createBox(
            x: x - width / 2 + w / 2 + i * w,
            y: y - height / 2 + h / 2 + j * h,
            z: z - depth / 2 + d / 2 + k * d,
            width: w,
            height: h,
            depth: d,
            color: color,
          ),
        );
      }
    }
  }

  return faces;
}

Point3D getBoxCenter(List<Face3D> box) {
  double sumX = 0;
  double sumY = 0;
  double sumZ = 0;
  int count = 0;

  for (final face in box) {
    for (final point in face.points) {
      sumX += point.x;
      sumY += point.y;
      sumZ += point.z;
      count++;
    }
  }

  if (count == 0) {
    return const Point3D(0, 0, 0);
  }

  return Point3D(
    sumX / count,
    sumY / count,
    sumZ / count,
  );
}

// ============================================================================
// FACE NORMALS
// ============================================================================

const List<Point3D> _kFaceNormals = [
  Point3D(0, 0, 1),  // Front
  Point3D(0, 0, -1), // Back
  Point3D(-1, 0, 0), // Left
  Point3D(1, 0, 0),  // Right
  Point3D(0, 1, 0),  // Top
  Point3D(0, -1, 0), // Bottom
];

List<List<Point3D>> _boxFaceCorners({
  required double x,
  required double y,
  required double z,
  required double width,
  required double height,
  required double depth,
}) {
  final faces = createBox(
    x: x,
    y: y,
    z: z,
    width: width,
    height: height,
    depth: depth,
    color: const Color(0x00000000),
  );

  return faces.map((face) => face.points).toList();
}

// ============================================================================
// SHARED 3D PAINTER
// ============================================================================

void paintModel3D(
  Canvas canvas,
  Size size,
  Model3D model,
  Point3D Function(Point3D) rotate,
  Offset Function(Point3D, Size) project, {
  Color outlineColor = Colors.black,
  double outlineOpacity = 0.55,
  double outlineWidth = 1.0,
  bool outlineFacesInFillPass = false,
}) {
  // --------------------------------------------------------------------------
  // FILL PASS
  //
  // Group every 6 faces back into their source box/chunk.
  // --------------------------------------------------------------------------

  final boxes = <({List<Face3D> faces, int layer})>[];

  for (int i = 0; i < model.faces.length; i += 6) {
    final end = math.min(i + 6, model.faces.length);

    boxes.add((
      faces: model.faces.sublist(i, end),
      layer: model.boxLayers?[i ~/ 6] ?? 0,
    ));
  }

  // Sort complete boxes from farthest to nearest.
  boxes.sort(
    (boxA, boxB) {
      final layerOrder = boxA.layer.compareTo(boxB.layer);
      if (layerOrder != 0) return layerOrder;
      final centerA = getBoxCenter(boxA.faces);
      final centerB = getBoxCenter(boxB.faces);

      final depthA = rotate(centerA).z;
      final depthB = rotate(centerB).z;

      return depthA.compareTo(depthB);
    },
  );

  final faceOutlinePaint = outlineFacesInFillPass && outlineOpacity > 0
      ? (Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = outlineWidth
          ..strokeJoin = StrokeJoin.round
          ..color = outlineColor.withValues(alpha: outlineOpacity))
      : null;

  for (final entry in boxes) {
    final box = entry.faces;
    // Sort faces within each box.
    box.sort(
      (a, b) {
        final avgA = a.points
                .map((p) => rotate(p).z)
                .fold<double>(0, (sum, value) => sum + value) /
            a.points.length;

        final avgB = b.points
                .map((p) => rotate(p).z)
                .fold<double>(0, (sum, value) => sum + value) /
            b.points.length;

        return avgA.compareTo(avgB);
      },
    );

    for (final face in box) {
      if (face.points.length < 3) {
        continue;
      }

      final path = Path();

      final first =
          project(rotate(face.points.first), size);

      path.moveTo(
        first.dx,
        first.dy,
      );

      for (int i = 1; i < face.points.length; i++) {
        final point =
            project(rotate(face.points[i]), size);

        path.lineTo(
          point.dx,
          point.dy,
        );
      }

      path.close();

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = face.color,
      );
      if (faceOutlinePaint != null) {
        canvas.drawPath(path, faceOutlinePaint);
      }
    }
  }

  if (outlineOpacity <= 0 || outlineFacesInFillPass) return;

  // --------------------------------------------------------------------------
  // OUTLINE PASS
  // --------------------------------------------------------------------------

  final parts = [...model.parts]
    ..sort(
      (a, b) {
        final za = rotate(
          Point3D(a.x, a.y, a.z),
        ).z;

        final zb = rotate(
          Point3D(b.x, b.y, b.z),
        ).z;

        return za.compareTo(zb);
      },
    );

  final outlinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = outlineWidth
    ..strokeJoin = StrokeJoin.round
    ..color = outlineColor.withOpacity(
      outlineOpacity,
    );

  for (final part in parts) {
    final faceCorners = _boxFaceCorners(
      x: part.x,
      y: part.y,
      z: part.z,
      width: part.width,
      height: part.height,
      depth: part.depth,
    );

    for (int f = 0; f < faceCorners.length; f++) {
      final normal = rotate(
        _kFaceNormals[f],
      );

      // Only outline camera-facing faces.
      if (normal.z <= 0.0001) {
        continue;
      }

      final pts = faceCorners[f];

      if (pts.length < 3) {
        continue;
      }

      final path = Path();

      final first =
          project(rotate(pts.first), size);

      path.moveTo(
        first.dx,
        first.dy,
      );

      for (int i = 1; i < pts.length; i++) {
        final point =
            project(rotate(pts[i]), size);

        path.lineTo(
          point.dx,
          point.dy,
        );
      }

      path.close();

      canvas.drawPath(
        path,
        outlinePaint,
      );
    }
  }
}

// ============================================================================
// FOOTPRINT OUTLINE
// ============================================================================

class FootprintOutlinePainter extends CustomPainter {
  final double width;
  final double depth;
  final double rotationX;
  final double rotationY;
  final Color color;
  final double strokeWidth;
  final double groundY;
  final double height;
  final double? cameraDistance;
  final double scale;

  FootprintOutlinePainter({
    required this.width,
    required this.depth,
    required this.rotationX,
    required this.rotationY,
    this.groundY = 0,
    this.height = 0,
    this.cameraDistance,
    this.scale = 40.0,
    this.color = Colors.yellowAccent,
    this.strokeWidth = 3,
  });

  Point3D rotate(Point3D p) {
    final cosY = math.cos(rotationY);
    final sinY = math.sin(rotationY);

    final x1 =
        p.x * cosY - p.z * sinY;

    final z1 =
        p.x * sinY + p.z * cosY;

    final cosX = math.cos(rotationX);
    final sinX = math.sin(rotationX);

    final y2 =
        p.y * cosX - z1 * sinX;

    final z2 =
        p.y * sinX + z1 * cosX;

    return Point3D(
      x1,
      y2,
      z2,
    );
  }

  Offset project(
    Point3D p,
    Size size,
  ) {
    if (cameraDistance != null) {
      final perspective =
          cameraDistance! /
          (cameraDistance! - p.z);

      return Offset(
        size.width / 2 +
            p.x * scale * perspective,
        size.height / 2 -
            p.y * scale * perspective,
      );
    }

    return Offset(
      size.width / 2 + p.x * scale,
      size.height / 2 - p.y * scale,
    );
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final corners = [
      Point3D(
        -width / 2,
        groundY,
        -depth / 2,
      ),
      Point3D(
        width / 2,
        groundY,
        -depth / 2,
      ),
      Point3D(
        width / 2,
        groundY,
        depth / 2,
      ),
      Point3D(
        -width / 2,
        groundY,
        depth / 2,
      ),
    ];

    final projected = corners
        .map(
          (corner) =>
              project(rotate(corner), size),
        )
        .toList();

    if (projected.isEmpty) {
      return;
    }

    final path = Path()
      ..moveTo(
        projected.first.dx,
        projected.first.dy,
      );

    for (int i = 1; i < projected.length; i++) {
      path.lineTo(
        projected[i].dx,
        projected[i].dy,
      );
    }

    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(
    covariant FootprintOutlinePainter oldDelegate,
  ) {
    return true;
  }
}

// ============================================================================
// RACK
// ============================================================================

class Rack3D {
  final double width;
  final double height;
  final double depth;

  const Rack3D({
    this.width = 3.0,
    this.height = 4.0,
    this.depth = 1.5,
  });

  Model3D build() {
    final faces = <Face3D>[];
    final parts = <BoxPart>[];

    const postThickness = 0.15;
    const shelfThickness = 0.10;

    const postColor =
        Color(0xff37474F);

    const shelfColor =
        Color(0xff90A4AE);

    final cX = math.max(
      1,
      (width / 0.75).ceil(),
    );

    const cY = 6;

    // ------------------------------------------------------------------------
    // POSTS
    // ------------------------------------------------------------------------

    final postPositions = [
      Offset(
        -width / 2 +
            postThickness / 2,
        -depth / 2 +
            postThickness / 2,
      ),
      Offset(
        width / 2 -
            postThickness / 2,
        -depth / 2 +
            postThickness / 2,
      ),
      Offset(
        -width / 2 +
            postThickness / 2,
        depth / 2 -
            postThickness / 2,
      ),
      Offset(
        width / 2 -
            postThickness / 2,
        depth / 2 -
            postThickness / 2,
      ),
    ];

    for (final pos in postPositions) {
      faces.addAll(
        createChunkedBox(
          x: pos.dx,
          y: 0,
          z: pos.dy,
          width: postThickness,
          height: height,
          depth: postThickness,
          color: postColor,
          chunksY: cY,
        ),
      );

      parts.add(
        BoxPart(
          x: pos.dx,
          y: 0,
          z: pos.dy,
          width: postThickness,
          height: height,
          depth: postThickness,
        ),
      );
    }

    // ------------------------------------------------------------------------
    // SHELVES
    // ------------------------------------------------------------------------

    const numShelves = 4;

    for (int i = 0; i < numShelves; i++) {
      final yPos =
          -height / 2 +
          (height / (numShelves - 1)) * i;

      faces.addAll(
        createChunkedBox(
          x: 0,
          y: yPos,
          z: 0,
          width: width,
          height: shelfThickness,
          depth: depth,
          color: shelfColor,
          chunksX: cX,
        ),
      );

      parts.add(
        BoxPart(
          x: 0,
          y: yPos,
          z: 0,
          width: width,
          height: shelfThickness,
          depth: depth,
        ),
      );
    }

    return Model3D(
      faces,
      parts,
    );
  }
}

class RackPainter extends CustomPainter {
  final Rack3D rack;
  final double rotationY;
  final double rotationX;

  RackPainter({
    required this.rack,
    required this.rotationY,
    required this.rotationX,
  });

  Point3D rotate(Point3D p) {
    final cosY = math.cos(rotationY);
    final sinY = math.sin(rotationY);

    final x1 =
        p.x * cosY - p.z * sinY;

    final z1 =
        p.x * sinY + p.z * cosY;

    final cosX = math.cos(rotationX);
    final sinX = math.sin(rotationX);

    final y2 =
        p.y * cosX - z1 * sinX;

    final z2 =
        p.y * sinX + z1 * cosX;

    return Point3D(
      x1,
      y2,
      z2,
    );
  }

  Offset project(
    Point3D p,
    Size size,
  ) {
    const scale = 40.0;

    return Offset(
      size.width / 2 +
          p.x * scale,
      size.height / 2 -
          p.y * scale,
    );
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    paintModel3D(
      canvas,
      size,
      rack.build(),
      rotate,
      project,
    );
  }

  @override
  bool shouldRepaint(
    covariant RackPainter oldDelegate,
  ) {
    return true;
  }
}

// ============================================================================
// SHELF
// ============================================================================

class Shelf3D {
  final double width;
  final double height;
  final double depth;

  const Shelf3D({
    this.width = 2.6,
    this.height = 4.2,
    this.depth = 1.2,
  });

  Model3D build() {
    final faces = <Face3D>[];
    final parts = <BoxPart>[];

    const thick = 0.15;

    const exteriorColor =
        Color(0xff5D4037);

    const interiorColor =
        Color(0xff795548);

    const backColor =
        Color(0xff4E342E);

    final cX = math.max(
      1,
      (width / 0.75).ceil(),
    );

    const cY = 6;

    // Left
    faces.addAll(
      createChunkedBox(
        x: -width / 2 + thick / 2,
        y: 0,
        z: 0,
        width: thick,
        height: height,
        depth: depth,
        color: exteriorColor,
        chunksY: cY,
      ),
    );

    parts.add(
      BoxPart(
        x: -width / 2 + thick / 2,
        y: 0,
        z: 0,
        width: thick,
        height: height,
        depth: depth,
      ),
    );

    // Right
    faces.addAll(
      createChunkedBox(
        x: width / 2 - thick / 2,
        y: 0,
        z: 0,
        width: thick,
        height: height,
        depth: depth,
        color: exteriorColor,
        chunksY: cY,
      ),
    );

    parts.add(
      BoxPart(
        x: width / 2 - thick / 2,
        y: 0,
        z: 0,
        width: thick,
        height: height,
        depth: depth,
      ),
    );

    final innerWidth =
        width - thick * 2;

    // Bottom
    faces.addAll(
      createChunkedBox(
        x: 0,
        y: -height / 2 + thick / 2,
        z: 0,
        width: innerWidth,
        height: thick,
        depth: depth,
        color: exteriorColor,
        chunksX: cX,
      ),
    );

    parts.add(
      BoxPart(
        x: 0,
        y: -height / 2 + thick / 2,
        z: 0,
        width: innerWidth,
        height: thick,
        depth: depth,
      ),
    );

    // Top
    faces.addAll(
      createChunkedBox(
        x: 0,
        y: height / 2 - thick / 2,
        z: 0,
        width: innerWidth,
        height: thick,
        depth: depth,
        color: exteriorColor,
        chunksX: cX,
      ),
    );

    parts.add(
      BoxPart(
        x: 0,
        y: height / 2 - thick / 2,
        z: 0,
        width: innerWidth,
        height: thick,
        depth: depth,
      ),
    );

    const backThick = 0.05;

    // Back
    faces.addAll(
      createChunkedBox(
        x: 0,
        y: 0,
        z: -depth / 2 +
            backThick / 2,
        width: innerWidth,
        height: height - thick * 2,
        depth: backThick,
        color: backColor,
        chunksX: cX,
        chunksY: cY,
      ),
    );

    parts.add(
      BoxPart(
        x: 0,
        y: 0,
        z: -depth / 2 +
            backThick / 2,
        width: innerWidth,
        height: height - thick * 2,
        depth: backThick,
      ),
    );

    // Inner shelves
    const numInnerShelves = 3;

    final spacing =
        (height - thick * 2) /
        (numInnerShelves + 1);

    for (int i = 1; i <= numInnerShelves; i++) {
      final yPos =
          -height / 2 +
          thick +
          spacing * i -
          thick / 2;

      faces.addAll(
        createChunkedBox(
          x: 0,
          y: yPos,
          z: backThick / 2,
          width: innerWidth,
          height: thick,
          depth: depth - backThick,
          color: interiorColor,
          chunksX: cX,
        ),
      );

      parts.add(
        BoxPart(
          x: 0,
          y: yPos,
          z: backThick / 2,
          width: innerWidth,
          height: thick,
          depth: depth - backThick,
        ),
      );
    }

    return Model3D(
      faces,
      parts,
    );
  }
}

class ShelfPainter extends CustomPainter {
  final Shelf3D shelf;
  final double rotationY;
  final double rotationX;

  ShelfPainter({
    required this.shelf,
    required this.rotationY,
    required this.rotationX,
  });

  Point3D rotate(Point3D p) {
    final cosY = math.cos(rotationY);
    final sinY = math.sin(rotationY);

    final x1 =
        p.x * cosY - p.z * sinY;

    final z1 =
        p.x * sinY + p.z * cosY;

    final cosX = math.cos(rotationX);
    final sinX = math.sin(rotationX);

    final y2 =
        p.y * cosX - z1 * sinX;

    final z2 =
        p.y * sinX + z1 * cosX;

    return Point3D(
      x1,
      y2,
      z2,
    );
  }

  Offset project(
    Point3D p,
    Size size,
  ) {
    const scale = 40.0;

    return Offset(
      size.width / 2 +
          p.x * scale,
      size.height / 2 -
          p.y * scale,
    );
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    paintModel3D(
      canvas,
      size,
      shelf.build(),
      rotate,
      project,
      outlineOpacity: 0.6,
    );
  }

  @override
  bool shouldRepaint(
    covariant ShelfPainter oldDelegate,
  ) {
    return true;
  }
}

// ============================================================================
// CASHIER
// ============================================================================

class Cashier3D {
  final double width;
  final double height;
  final double depth;

  const Cashier3D({
    this.width = 4.2,
    this.height = 2.0,
    this.depth = 1.6,
  });

  Model3D build({double rotationY = 0}) {
    final faces = <Face3D>[];
    final parts = <BoxPart>[];
    final boxLayers = <int>[];
    var currentLayer = 0;

    const baseColor = Color(0xffD4DEE5);

    const topColor = Color(0xff2D3E4B);

    const deviceColor = Color(0xff526875);

    const screenColor = Color(0xff74D0F5);

    const scannerColor =
        Color(0xffB0BEC5);

    const glassColor = Color(0xffDDF3F5);

    // Keep cashier faces solid. The shared createBox primitive uses alpha for
    // shading, which lets the floor grid show through this light-colored body.
    // Both long faces should have the same finish when the counter rotates.
    const faceShades = <double>[1.0, 1.0, 0.86, 0.86, 0.95, 0.62];
    final fixtureScale = math.min(1.0, math.min(width / 3.8, depth / 1.5));

    void addPart({
      required double x,
      required double y,
      required double z,
      required double width,
      required double height,
      required double depth,
      required Color color,
    }) {
      final boxFaces = createBox(
        x: x,
        y: y,
        z: z,
        width: width,
        height: height,
        depth: depth,
        color: color,
      );
      for (var i = 0; i < boxFaces.length; i++) {
        faces.add(
          Face3D(
            boxFaces[i].points,
            Color.lerp(Colors.black, color, faceShades[i])!,
          ),
        );
      }

      parts.add(
        BoxPart(
          x: x,
          y: y,
          z: z,
          width: width,
          height: height,
          depth: depth,
        ),
      );
      boxLayers.add(currentLayer);
    }

    addPart(
      x: 0,
      y: -1.375,
      z: 0,
      width: width,
      height: 2.75,
      depth: depth,
      color: baseColor,
    );

    // Draw only the camera-facing cabinet details. Painting the hidden panels
    // through the wide base would expose them in the painter's 2.5D ordering.
    final visibleLongSide = math.cos(rotationY) >= 0 ? 1.0 : -1.0;
    final visibleEndSide = math.sin(rotationY) >= 0 ? 1.0 : -1.0;
    currentLayer = 1;
    final panelCount = (width / 2.0).round().clamp(1, 6);
    final panelWidth = (width - 0.3) / panelCount;
    addPart(
      x: 0,
      y: -2.62,
      z: visibleLongSide * (depth / 2 + 0.015),
      width: math.max(0.2, width - 0.16),
      height: 0.22,
      depth: 0.05,
      color: const Color(0xff344653),
    );
    for (var i = 0; i < panelCount; i++) {
      addPart(
        x: -width / 2 + 0.15 + panelWidth * (i + 0.5),
        y: -1.35,
        z: visibleLongSide * (depth / 2 + 0.02),
        width: math.max(0.1, panelWidth - 0.1),
        height: 1.9,
        depth: 0.04,
        color: const Color(0xffE8EEF2),
      );
    }

    addPart(
      x: visibleEndSide * (width / 2 + 0.02),
      y: -1.35,
      z: 0,
      width: 0.04,
      height: 1.9,
      depth: math.max(0.2, depth - 0.28),
      color: const Color(0xffE8EEF2),
    );

    currentLayer = 2;
    addPart(
      x: 0,
      y: 0.1,
      z: 0,
      width: width + 0.2,
      height: 0.2,
      depth: depth + 0.2,
      color: topColor,
    );

    addPart(
      x: 0,
      y: -0.04,
      z: visibleLongSide * (depth / 2 + 0.08),
      width: width + 0.12,
      height: 0.08,
      depth: 0.07,
      color: const Color(0xff326BA4),
    );

    currentLayer = 3;
    final leftSide = -(width / 4);

    final rightSide = width / 4;

    addPart(
      x: leftSide,
      y: 0.29,
      z: 0,
      width: 1.4 * fixtureScale,
      height: 0.05,
      depth: 1.2 * fixtureScale,
      color: scannerColor,
    );

    addPart(
      x: leftSide,
      y: 0.34,
      z: 0,
      width: 1.0 * fixtureScale,
      height: 0.02,
      depth: 0.8 * fixtureScale,
      color: glassColor,
    );

    addPart(
      x: rightSide,
      y: 0.4,
      z: 0,
      width: 0.3 * fixtureScale,
      height: 0.4,
      depth: 0.3 * fixtureScale,
      color: deviceColor,
    );

    addPart(
      x: rightSide,
      y: 0.8,
      z: 0,
      width: 1.2 * fixtureScale,
      height: 0.8,
      depth: 0.15,
      color: deviceColor,
    );

    addPart(
      x: rightSide,
      y: 0.8,
      z: 0.08,
      width: 1.0 * fixtureScale,
      height: 0.65,
      depth: 0.05,
      color: screenColor,
    );

    addPart(
      x: rightSide,
      y: 0.85,
      z: -0.08,
      width: 0.8 * fixtureScale,
      height: 0.4,
      depth: 0.05,
      color: screenColor,
    );

    addPart(
      x: rightSide,
      y: 0.26,
      z: 0.5,
      width: 1.1 * fixtureScale,
      height: 0.1,
      depth: 0.6 * fixtureScale,
      color: deviceColor,
    );

    return Model3D(
      faces,
      parts,
      boxLayers: boxLayers,
    );
  }
}

class CashierPainter extends CustomPainter {
  final Cashier3D cashier;
  final double rotationY;
  final double rotationX;

  CashierPainter({
    required this.cashier,
    required this.rotationY,
    required this.rotationX,
  });

  Point3D rotate(Point3D p) {
    final cosY = math.cos(rotationY);
    final sinY = math.sin(rotationY);

    final x1 =
        p.x * cosY - p.z * sinY;

    final z1 =
        p.x * sinY + p.z * cosY;

    final cosX = math.cos(rotationX);
    final sinX = math.sin(rotationX);

    final y2 =
        p.y * cosX - z1 * sinX;

    final z2 =
        p.y * sinX + z1 * cosX;

    return Point3D(
      x1,
      y2,
      z2,
    );
  }

  Offset project(
    Point3D p,
    Size size,
  ) {
    const scale = 40.0;

    return Offset(
      size.width / 2 +
          p.x * scale,
      size.height / 2 -
          p.y * scale,
    );
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    paintModel3D(
      canvas,
      size,
      cashier.build(rotationY: rotationY),
      rotate,
      project,
      outlineColor: const Color(0xff203442),
      outlineOpacity: 0.42,
      outlineWidth: 0.8,
      outlineFacesInFillPass: true,
    );
  }

  @override
  bool shouldRepaint(
    covariant CashierPainter oldDelegate,
  ) {
    return true;
  }
}

// ============================================================================
// DOOR
// ============================================================================

class Door3D {
  final double width;
  final double height;
  final double depth;
  final DoorStyle style;

  const Door3D({
    this.width = 2.0,
    this.height = 3.5,
    this.depth = 0.25,
    this.style = DoorStyle.single,
  });

  Model3D build() {
    final faces = <Face3D>[];
    final parts = <BoxPart>[];

    const frame = 0.22;
    const faceShades = <double>[1.0, 0.72, 0.78, 0.86, 0.95, 0.62];

    void addPart({
      required double x,
      required double y,
      required double z,
      required double width,
      required double height,
      required double depth,
      required Color color,
    }) {
      final boxFaces = createBox(
        x: x,
        y: y,
        z: z,
        width: width,
        height: height,
        depth: depth,
        color: color,
      );
      for (var i = 0; i < boxFaces.length; i++) {
        faces.add(
          Face3D(
            boxFaces[i].points,
            Color.lerp(Colors.black, color, faceShades[i])!,
          ),
        );
      }

      parts.add(
        BoxPart(
          x: x,
          y: y,
          z: z,
          width: width,
          height: height,
          depth: depth,
        ),
      );
    }

    final frameColor = style == DoorStyle.loading
        ? const Color(0xff405260)
        : const Color(0xff6D4C41);

    addPart(
      x: -width / 2 + frame / 2,
      y: 0,
      z: 0,
      width: frame,
      height: height,
      depth: depth,
      color: frameColor,
    );

    addPart(
      x: width / 2 - frame / 2,
      y: 0,
      z: 0,
      width: frame,
      height: height,
      depth: depth,
      color: frameColor,
    );

    addPart(
      x: 0,
      y: height / 2 - frame / 2,
      z: 0,
      width: width,
      height: frame,
      depth: depth,
      color: frameColor,
    );

    if (style == DoorStyle.loading) {
      final panelHeight = height - frame * 1.5;
      addPart(
        x: 0,
        y: -frame / 4,
        z: 0,
        width: width - frame * 2,
        height: panelHeight,
        depth: depth * 0.7,
        color: const Color(0xff91A4B2),
      );
      // Horizontal slats make a wide loading entrance read as a shutter.
      for (var i = 1; i < 10; i++) {
        addPart(
          x: 0,
          y: -panelHeight / 2 + i * panelHeight / 10,
          z: depth * 0.4,
          width: width - frame * 2.2,
          height: 0.055,
          depth: 0.04,
          color: const Color(0xff506674),
        );
      }
      addPart(
        x: 0,
        y: -height / 2 + 0.28,
        z: depth * 0.5,
        width: 0.65,
        height: 0.1,
        depth: 0.06,
        color: const Color(0xff253745),
      );
    } else {
      final isDouble = style == DoorStyle.doubleDoor;
      final centerFrame = isDouble ? 0.12 : 0.0;
      final leafWidth =
          (width - frame * 2 - centerFrame) / (isDouble ? 2 : 1);
      if (isDouble) {
        addPart(
          x: 0,
          y: 0,
          z: depth * 0.2,
          width: centerFrame,
          height: height - frame,
          depth: depth * 0.8,
          color: frameColor,
        );
      }
      for (var i = 0; i < (isDouble ? 2 : 1); i++) {
        final x = isDouble
            ? (i == 0 ? -1 : 1) * (leafWidth + centerFrame) / 2
            : 0.0;
        addPart(
          x: x,
          y: -0.05,
          z: -0.01,
          width: leafWidth,
          height: height - frame,
          depth: depth * 0.7,
          color: const Color(0xffA1887F),
        );
        addPart(
          x: x,
          y: 0,
          z: depth * 0.4,
          width: leafWidth - frame * 0.4,
          height: height - frame * 1.6,
          depth: 0.05,
          color: const Color(0xff8D6E63),
        );
      }
    }

    return Model3D(
      faces,
      parts,
    );
  }
}

class DoorPainter extends CustomPainter {
  final Door3D door;
  final double rotationY;
  final double rotationX;

  DoorPainter({
    required this.door,
    required this.rotationY,
    required this.rotationX,
  });

  Point3D rotate(Point3D p) {
    final cosY = math.cos(rotationY);
    final sinY = math.sin(rotationY);

    final x1 =
        p.x * cosY - p.z * sinY;

    final z1 =
        p.x * sinY + p.z * cosY;

    final cosX = math.cos(rotationX);
    final sinX = math.sin(rotationX);

    final y2 =
        p.y * cosX - z1 * sinX;

    final z2 =
        p.y * sinX + z1 * cosX;

    return Point3D(
      x1,
      y2,
      z2,
    );
  }

  Offset project(
    Point3D p,
    Size size,
  ) {
    const scale = 40.0;

    return Offset(
      size.width / 2 +
          p.x * scale,
      size.height / 2 -
          p.y * scale,
    );
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    paintModel3D(
      canvas,
      size,
      door.build(),
      rotate,
      project,
      outlineWidth: 1.5,
      outlineOpacity: 0.7,
    );

    // ------------------------------------------------------------------------
    // HANDLE
    // ------------------------------------------------------------------------

    final facingFront =
        rotate(
          const Point3D(0, 0, 1),
        ).z >
        0;

    final handleZ =
        facingFront
            ? door.depth * 0.6
            : -door.depth * 0.6;

    if (door.style != DoorStyle.loading) {
      final handleXs = door.style == DoorStyle.doubleDoor
          ? <double>[-0.24, 0.24]
          : <double>[door.width * 0.35];
      for (final handleX in handleXs) {
        final handlePosition = project(
          rotate(Point3D(handleX, -0.5, handleZ)),
          size,
        );
        canvas.drawCircle(
          handlePosition,
          4,
          Paint()
            ..color = const Color(0xffD6B36A)
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          handlePosition,
          4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.black,
        );
      }
    }
  }

  @override
  bool shouldRepaint(
    covariant DoorPainter oldDelegate,
  ) {
    return true;
  }
}

// ============================================================================
// WALL
// ============================================================================

class Wall3D {
  final double width;
  final double height;
  final double depth;

  const Wall3D({
    this.width = 4.0,
    this.height = 6.0,
    this.depth = 0.5,
  });

  Model3D build() {
    final faces = createBox(
      x: 0,
      y: 0,
      z: 0,
      width: width,
      height: height,
      depth: depth,
      color: const Color(0xff9E9E9E),
    );

    final parts = [
      BoxPart(
        x: 0,
        y: 0,
        z: 0,
        width: width,
        height: height,
        depth: depth,
      ),
    ];

    return Model3D(
      faces,
      parts,
    );
  }
}

class WallPainter extends CustomPainter {
  final Wall3D wall;
  final double rotationY;
  final double rotationX;

  WallPainter({
    required this.wall,
    required this.rotationY,
    required this.rotationX,
  });

  Point3D rotate(Point3D p) {
    final cosY = math.cos(rotationY);
    final sinY = math.sin(rotationY);

    final x1 =
        p.x * cosY - p.z * sinY;

    final z1 =
        p.x * sinY + p.z * cosY;

    final cosX = math.cos(rotationX);
    final sinX = math.sin(rotationX);

    final y2 =
        p.y * cosX - z1 * sinX;

    final z2 =
        p.y * sinX + z1 * cosX;

    return Point3D(
      x1,
      y2,
      z2,
    );
  }

  Offset project(
    Point3D p,
    Size size,
  ) {
    const scale = 40.0;

    return Offset(
      size.width / 2 +
          p.x * scale,
      size.height / 2 -
          p.y * scale,
    );
  }

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    paintModel3D(
      canvas,
      size,
      wall.build(),
      rotate,
      project,
      outlineOpacity: 0.55,
    );
  }

  @override
  bool shouldRepaint(
    covariant WallPainter oldDelegate,
  ) {
    return true;
  }
}
