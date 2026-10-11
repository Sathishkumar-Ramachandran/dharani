import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/geocoder.dart';
import '../theme.dart';

/// Bordered surface used for every grouped block.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(Tokens.pad), this.onTap, this.tint});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) => Card(
        color: tint,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.textTheme.titleMedium),
          if (subtitle != null)
            Text(subtitle!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
      if (trailing != null) trailing!,
    ]);
  }
}

/// Large number with a small caption.
class Kpi extends StatelessWidget {
  const Kpi(this.label, this.value, {super.key, this.unit, this.color});
  final String label, value;
  final String? unit;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 2),
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, mainAxisSize: MainAxisSize.min, children: [
        Text(value, style: t.textTheme.titleLarge?.copyWith(color: color)),
        if (unit != null) Padding(padding: const EdgeInsets.only(left: 3), child: Text(unit!, style: t.textTheme.bodySmall)),
      ]),
    ]);
  }
}

enum PillTone { neutral, success, warning, danger, info }

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.icon, this.tone = PillTone.neutral});
  final String text;
  final IconData? icon;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = switch (tone) {
      PillTone.success => Tokens.success,
      PillTone.warning => Tokens.warning,
      PillTone.danger => Tokens.danger,
      PillTone.info => t.colorScheme.primary,
      PillTone.neutral => t.colorScheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: c), const SizedBox(width: 5)],
        Flexible(child: Text(text, style: t.textTheme.labelMedium?.copyWith(color: c, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

class InlineNotice extends StatelessWidget {
  const InlineNotice(this.text, {super.key, this.tone = PillTone.info, this.action, this.onAction});
  final String text;
  final PillTone tone;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = switch (tone) {
      PillTone.success => Tokens.success,
      PillTone.warning => Tokens.warning,
      PillTone.danger => Tokens.danger,
      _ => t.colorScheme.primary,
    };
    final icon = switch (tone) {
      PillTone.success => Icons.check_circle_outline,
      PillTone.warning => Icons.warning_amber_rounded,
      PillTone.danger => Icons.error_outline,
      _ => Icons.info_outline,
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withValues(alpha: 0.25))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: c, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
        if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
      ]),
    );
  }
}

/// Vertical journey stepper (e.g. ride or contract stages).
class StageStepper extends StatelessWidget {
  const StageStepper({super.key, required this.steps, required this.current});
  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(children: [
      for (var i = 0; i < steps.length; i++) ...[
        Expanded(
          child: Column(children: [
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: i <= current ? t.colorScheme.primary : t.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            Text(steps[i],
                style: t.textTheme.labelSmall?.copyWith(
                    color: i <= current ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant,
                    fontWeight: i == current ? FontWeight.w700 : FontWeight.w500),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (i != steps.length - 1) const SizedBox(width: 4),
      ]
    ]);
  }
}

class DragHandle extends StatelessWidget {
  const DragHandle({super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(top: 8, bottom: 12),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
        ),
      );
}

/// Search box backed by Nominatim with debounce; calls `onPicked` with the chosen place.
class PlaceSearchField extends StatefulWidget {
  const PlaceSearchField({
    super.key,
    required this.hint,
    required this.onPicked,
    this.nearLat,
    this.nearLon,
    this.geocoder,
    this.icon = Icons.search,
    this.selectedLabel,
    this.onClear,
  });

  final String hint;
  final void Function(GeoResult) onPicked;
  final double? nearLat, nearLon;
  final Geocoder? geocoder;
  final IconData icon;
  final String? selectedLabel;
  final VoidCallback? onClear;

  @override
  State<PlaceSearchField> createState() => _PlaceSearchFieldState();
}

class _PlaceSearchFieldState extends State<PlaceSearchField> {
  final _controller = TextEditingController();
  late final Geocoder _geo = widget.geocoder ?? Geocoder();
  Timer? _debounce;
  List<GeoResult> _results = const [];
  bool _loading = false;
  String? _error;

  @override
  void didUpdateWidget(PlaceSearchField old) {
    super.didUpdateWidget(old);
    if (widget.selectedLabel != old.selectedLabel) {
      _controller.text = widget.selectedLabel ?? '';
      _results = const [];
    }
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 3) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final r = await _geo.search(q, nearLat: widget.nearLat, nearLon: widget.nearLon);
        if (mounted) setState(() => _results = r);
      } catch (_) {
        if (mounted) setState(() => _error = 'Search needs internet. You can also long-press the map to drop a pin.');
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _controller,
        onChanged: _onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: Icon(widget.icon),
          suffixIcon: _loading
              ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : (_controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _results = const []);
                        widget.onClear?.call();
                      })
                  : null),
        ),
      ),
      if (_error != null)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: t.textTheme.bodySmall?.copyWith(color: Tokens.warning))),
      if (_results.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(border: Border.all(color: t.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            for (final r in _results)
              ListTile(
                dense: true,
                leading: const Icon(Icons.place_outlined, size: 20),
                title: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () {
                  FocusScope.of(context).unfocus();
                  _controller.text = r.name.split(',').first;
                  setState(() => _results = const []);
                  widget.onPicked(r);
                },
              ),
          ]),
        ),
    ]);
  }
}
