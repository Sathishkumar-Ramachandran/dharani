import 'package:flutter/material.dart';

import '../theme.dart';
import 'ds.dart';

/// Full-bleed map with a draggable bottom sheet (the layout used by every mobility screen).
class MapSheetScaffold extends StatefulWidget {
  const MapSheetScaffold({
    super.key,
    required this.mapBuilder,
    required this.sheetChildren,
    this.header,
    this.initialSize = 0.46,
    this.minSize = 0.16,
    this.maxSize = 0.92,
    this.topOverlay,
  });

  /// Receives the current sheet height in pixels so the map can keep its controls above it.
  final Widget Function(double sheetHeightPx) mapBuilder;
  final List<Widget> sheetChildren;
  final Widget? header; // pinned above the scrolling content
  final Widget? topOverlay;
  final double initialSize, minSize, maxSize;

  @override
  State<MapSheetScaffold> createState() => _MapSheetScaffoldState();
}

class _MapSheetScaffoldState extends State<MapSheetScaffold> {
  final _sheet = DraggableScrollableController();
  double _size = 0;

  @override
  void initState() {
    super.initState();
    _size = widget.initialSize;
  }

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      return Stack(children: [
        Positioned.fill(
            child: widget.mapBuilder(
                (c.maxHeight * _size).clamp(0.0, c.maxHeight * 0.6))),
        if (widget.topOverlay != null)
          SafeArea(
              child: Padding(
                  padding: const EdgeInsets.all(12), child: widget.topOverlay)),
        DraggableScrollableSheet(
          // No snap sizes and no rebuild while dragging: both made the sheet fight the finger on device.
          controller: _sheet,
          initialChildSize: widget.initialSize,
          minChildSize: widget.minSize,
          maxChildSize: widget.maxSize,
          builder: (context, scroll) => DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26,
                    blurRadius: 16,
                    offset: Offset(0, -2))
              ],
            ),
            child: ListView(
              controller: scroll,
              // Without this, a sheet whose content is shorter than the sheet ignores drags and can
              // never be pulled up or down (the content "does not need to scroll").
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(Tokens.pad, 0, Tokens.pad, 24),
              children: [
                const DragHandle(),
                if (widget.header != null) widget.header!,
                ...widget.sheetChildren,
              ],
            ),
          ),
        ),
      ]);
    });
  }
}
