import 'package:dharani_mobile/ui/widgets/map_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a sheet with short content can still be dragged up and down', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android), // clamping physics, as on the phone
      home: Scaffold(
        body: MapSheetScaffold(
          mapBuilder: (_) => const ColoredBox(color: Colors.blueGrey),
          sheetChildren: const [SizedBox(height: 120, child: Text('short content'))],
        ),
      ),
    ));
    final y0 = tester.getTopLeft(find.text('short content')).dy;
    await tester.dragFrom(Offset(400, y0 + 200), const Offset(0, -400));
    await tester.pumpAndSettle();
    final y1 = tester.getTopLeft(find.text('short content')).dy;
    expect(y1, lessThan(y0 - 150), reason: 'sheet must move up when dragged');
    await tester.dragFrom(Offset(400, y1 + 100), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('short content')).dy, greaterThan(y1 + 150), reason: 'and back down');
  });

  testWidgets('sheet expands on drag and its content scrolls to the end', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android), // clamping physics, as on the phone
      home: Scaffold(
        body: MapSheetScaffold(
          mapBuilder: (_) => const ColoredBox(color: Colors.blueGrey),
          sheetChildren: [for (var i = 0; i < 30; i++) SizedBox(height: 80, child: Text('row $i'))],
        ),
      ),
    ));
    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row 29'), findsNothing);

    // Scroll the content with a finger on the sheet, repeatedly.
    for (var i = 0; i < 12; i++) {
      await tester.dragFrom(const Offset(400, 1200), const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    for (var i = 0; i < 30; i++) { if (find.text('row $i').hitTestable().evaluate().isNotEmpty) debugPrint('visible row $i'); }
    expect(find.text('row 29').hitTestable(), findsOneWidget, reason: 'must be able to reach the bottom');
  });
}
