// Widget tests for the two remaining leaf widgets:
//   * VerificationReportView - pure/synchronous; driven by a VerificationReport.
//   * SnapSearchField        - driven in BRAND mode (catalog != null), where
//     search filters the pre-fetched catalog CLIENT-SIDE (no network), so the
//     field is fully hermetic.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';

import 'package:ubuntu_core_model_builder/services/surl_service.dart';
import 'package:ubuntu_core_model_builder/services/assertion_verifier.dart';
import 'package:ubuntu_core_model_builder/widgets/snap_search_field.dart';
import 'package:ubuntu_core_model_builder/widgets/verification_report_view.dart';

Widget harness(Widget child) {
  return YaruTheme(
    builder: (context, yaru, _) {
      return MaterialApp(
        theme: yaru.theme,
        darkTheme: yaru.darkTheme,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
            body:
                SingleChildScrollView(child: Padding(
              padding: const EdgeInsets.all(16),
              child: child,
            ))),
      );
    },
  );
}

Future<void> pumpWidget2(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(harness(page));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// A report that passes with no warnings.
VerificationReport passingReport() => VerificationReport([
      VerificationCheck('Structure', CheckStatus.pass, 'ok'),
      VerificationCheck('Type', CheckStatus.pass, 'model'),
      VerificationCheck('Model name', CheckStatus.pass, 'my-device'),
    ]);

/// A report that passes but has a warning.
VerificationReport passingWithWarningsReport() => VerificationReport([
      VerificationCheck('Structure', CheckStatus.pass, 'ok'),
      VerificationCheck('Signing key', CheckStatus.warn, 'not registered'),
    ]);

/// A report with a failing check.
VerificationReport failingReport() => VerificationReport([
      VerificationCheck('Structure', CheckStatus.pass, 'ok'),
      VerificationCheck('Model name', CheckStatus.fail, 'Expected x, got y'),
    ]);

void main() {
  group('VerificationReportView', () {
    testWidgets('shows the "Verified" chip when all checks pass',
        (tester) async {
      await pumpWidget2(tester, VerificationReportView(report: passingReport()));

      expect(find.text('Verification'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Failed'), findsNothing);
      // Each check's label + detail is rendered.
      expect(find.text('Structure'), findsOneWidget);
      expect(find.text('ok'), findsOneWidget);
      expect(find.text('Model name'), findsOneWidget);
      // No "Test import" when the callback is null.
      expect(find.text('Test import'), findsNothing);
    });

    testWidgets('shows "Passed with warnings" when a check warns',
        (tester) async {
      await pumpWidget2(
          tester,
          VerificationReportView(report: passingWithWarningsReport()));

      expect(find.text('Passed with warnings'), findsOneWidget);
      expect(find.text('Verified'), findsNothing);
      expect(find.text('Failed'), findsNothing);
      expect(find.text('not registered'), findsOneWidget);
    });

    testWidgets('shows the "Failed" chip when a check fails', (tester) async {
      await pumpWidget2(
          tester, VerificationReportView(report: failingReport()));

      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Verified'), findsNothing);
      expect(find.text('Passed with warnings'), findsNothing);
      // The failing detail is shown.
      expect(find.text('Expected x, got y'), findsOneWidget);
    });

    testWidgets('shows and invokes the "Test import" button when provided',
        (tester) async {
      var invoked = 0;
      await pumpWidget2(
          tester,
          VerificationReportView(
              report: passingReport(), onTestImport: () => invoked++));

      expect(find.text('Test import'), findsOneWidget);
      // The explanatory note is shown.
      expect(
          find.textContaining('importing into snapd'), findsOneWidget);

      await tester.tap(find.text('Test import'));
      await tester.pump();
      expect(invoked, 1);
    });
  });

  group('SnapSearchField', () {
    final catalog = <StoreCatalogSnap>[
      const StoreCatalogSnap(id: 'i1', name: 'foo-snap'),
      const StoreCatalogSnap(id: 'i2', name: 'bar-snap'),
      const StoreCatalogSnap(id: 'i3', name: 'baz-widgets'),
    ];

    SnapSearchField brandField() => SnapSearchField(
          architecture: 'amd64',
          catalog: catalog,
          onSnapSelected: (entry, base) {},
        );

    testWidgets('renders the brand-store search hint and disabled Add',
        (tester) async {
      await pumpWidget2(tester, brandField());

      // Brand-mode hint.
      expect(find.text('Search brand store (amd64)'), findsOneWidget);
      // Channel + Type dropdowns.
      expect(find.text('Channel'), findsOneWidget);
      expect(find.text('Type'), findsOneWidget);
      // Add is present but disabled (nothing selected yet).
      final add = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Add'));
      expect(add.onPressed, isNull);
      // The manual-add affordance is shown.
      expect(find.text('Snap not listed? Add by exact name'), findsOneWidget);
      // No results and no spinner at rest.
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('filters the catalog client-side as you type (no network)',
        (tester) async {
      await pumpWidget2(tester, brandField());

      // Type a query matching exactly one catalog entry.
      await tester.enterText(find.byType(TextField).first, 'foo');
      await tester.pump();

      // Only the matching entry is listed.
      expect(find.byType(ListTile), findsNWidgets(1));
      expect(find.text('bar-snap'), findsNothing);
      expect(find.text('baz-widgets'), findsNothing);
    });

    testWidgets('shows no results for a non-matching query', (tester) async {
      await pumpWidget2(tester, brandField());

      await tester.enterText(find.byType(TextField).first, 'zzz');
      await tester.pump();
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('toggles the "add by exact name" form', (tester) async {
      await pumpWidget2(tester, brandField());

      // Initially the toggle button is shown, the form is not.
      expect(find.text('Snap not listed? Add by exact name'), findsOneWidget);
      expect(find.text('Exact snap name'), findsNothing);

      await tester.tap(find.text('Snap not listed? Add by exact name'));
      await tester.pump();

      // The form is now shown; the toggle is gone.
      expect(find.text('Exact snap name'), findsOneWidget);
      expect(find.text('Resolve'), findsOneWidget);
      expect(find.text('Snap not listed? Add by exact name'), findsNothing);
    });
  });
}
