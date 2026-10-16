import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/models/model_assertion.dart';
import 'package:ubuntu_core_model_builder/models/snap_entry.dart';
import 'package:ubuntu_core_model_builder/models/wizard_step.dart';
import 'package:ubuntu_core_model_builder/services/rust_store_service.dart';
import 'package:ubuntu_core_model_builder/services/tool_locator.dart';

/// A snaps list that satisfies the Snaps step for base [base] (default
/// `core24`): snapd + a matching base + kernel + gadget.
List<SnapEntry> completeSnaps({String base = 'core24'}) => [
      SnapEntry(
          name: 'snapd',
          id: 's' * 32,
          type: SnapType.snapd,
          defaultChannel: 'stable'),
      SnapEntry(
          name: base,
          id: 'b' * 32,
          type: SnapType.base,
          defaultChannel: 'stable'),
      SnapEntry(
          name: 'pc-kernel',
          id: 'k' * 32,
          type: SnapType.kernel,
          defaultChannel: '24/stable'),
      SnapEntry(
          name: 'pc',
          id: 'g' * 32,
          type: SnapType.gadget,
          defaultChannel: '24/stable'),
    ];

/// A WizardState where every step is satisfiable/complete.
WizardState fullState() {
  final st = WizardState()
    ..setAccount(StoreAccount(email: 'a@b.c', accountId: 'acct123'))
    ..toolStatus = ToolStatus(hasSnap: true, hasPinentry: true);
  st.model
    ..model = 'my-device'
    ..base = 'core24'
    ..snaps = completeSnaps();
  st
    ..selectedKeyName = 'my-key'
    ..signedAssertion = 'signed-assertion';
  return st;
}

void main() {
  group('ToolStatus', () {
    test('ready reflects only hasSnap', () {
      expect(
          ToolStatus(hasSnap: true, hasPinentry: true).ready, isTrue);
      expect(
          ToolStatus(hasSnap: true, hasPinentry: false).ready, isTrue);
      expect(
          ToolStatus(hasSnap: false, hasPinentry: true).ready, isFalse);
      expect(
          ToolStatus(hasSnap: false, hasPinentry: false).ready, isFalse);
    });

    test('exposes the snap path', () {
      final s = ToolStatus(
          hasSnap: true, hasPinentry: false, snapPath: '/usr/bin/snap');
      expect(s.snapPath, '/usr/bin/snap');
      expect(ToolStatus(hasSnap: true, hasPinentry: false).snapPath, isNull);
    });
  });

  group('ToolLocator.check', () {
    test('returns a status and finds the installed snap', () async {
      final status = await ToolLocator.check();
      // snapd is present in the build environment.
      expect(status.hasSnap, isTrue);
      expect(status.snapPath, isNotNull);
      // pinentry is informational; just assert it is a well-formed bool.
      expect(status.hasPinentry, isA<bool>());
    });
  });

  group('WizardState initial', () {
    test('starts with no account, tools, key or signature', () {
      final st = WizardState();
      expect(st.account, isNull);
      expect(st.toolStatus, isNull);
      expect(st.selectedKeyName, isNull);
      expect(st.signedAssertion, isNull);
      expect(st.busy, isFalse);
    });

    test('only the account step is enabled; only extras is complete', () {
      final st = WizardState();
      expect(st.isStepEnabled(WizardStep.account), isTrue);
      for (final s in WizardStep.values.skip(1)) {
        expect(st.isStepEnabled(s), isFalse, reason: '$s must be blocked');
      }
      // Every step is incomplete except Extras, which is always "complete"
      // for gating purposes (it never blocks the wizard).
      for (final s in WizardStep.values) {
        expect(st.isStepComplete(s),
            s == WizardStep.extras,
            reason: '$s should be ${s == WizardStep.extras ? "complete" : "incomplete"}');
      }
    });
  });

  group('setAccount', () {
    test('populates brand-id and authority-id from the account id', () {
      final st = WizardState();
      st.setAccount(StoreAccount(email: 'a@b.c', accountId: 'acct-xyz'));
      expect(st.model.brandId, 'acct-xyz');
      expect(st.model.authorityId, 'acct-xyz');
    });

    test('clears brand-id and authority-id on sign-out', () {
      final st = fullState();
      st.setAccount(null);
      expect(st.model.brandId, isNull);
      expect(st.model.authorityId, isNull);
      expect(st.isStepComplete(WizardStep.account), isFalse);
    });
  });

  group('isStepComplete', () {
    test('every step completes on a fully-populated state', () {
      final st = fullState();
      for (final s in WizardStep.values) {
        expect(st.isStepComplete(s), isTrue, reason: '$s should be complete');
      }
    });

    test('account requires a signed-in account AND snapd', () {
      final withAccount = WizardState()
        ..setAccount(StoreAccount(email: 'a@b.c', accountId: 'x'))
        ..toolStatus = ToolStatus(hasSnap: false, hasPinentry: false);
      expect(withAccount.isStepComplete(WizardStep.account), isFalse);

      final withSnap = WizardState()
        ..setAccount(StoreAccount(email: 'a@b.c', accountId: 'x'))
        ..toolStatus = ToolStatus(hasSnap: true, hasPinentry: false);
      expect(withSnap.isStepComplete(WizardStep.account), isTrue);
    });

    test('metadata needs a valid name, a base, and a brand-id', () {
      // Valid name but no base.
      final noBase = fullState();
      noBase.model.base = null;
      expect(noBase.isStepComplete(WizardStep.metadata), isFalse);

      // No brand-id (signed out) but valid name + base.
      final noBrand = fullState();
      noBrand.setAccount(null);
      expect(noBrand.isStepComplete(WizardStep.metadata), isFalse);

      // Bad model name.
      final badName = fullState()..model.model = 'Bad Name';
      expect(badName.isStepComplete(WizardStep.metadata), isFalse);
    });

    test('snaps needs kernel, gadget, snapd, and a matching base', () {
      final base = fullState();
      base.model.snaps = base.model.snaps
          .where((s) => s.type != SnapType.kernel)
          .toList();
      expect(base.isStepComplete(WizardStep.snaps), isFalse);

      final base2 = fullState()
        ..model.base = 'core22' // no snap named core22 in the list
      ..model.snaps = completeSnaps(base: 'core24');
      expect(base2.isStepComplete(WizardStep.snaps), isFalse);

      final base3 = fullState();
      base3.model.snaps = base3.model.snaps
          .where((s) => s.type != SnapType.snapd)
          .toList();
      expect(base3.isStepComplete(WizardStep.snaps), isFalse);
    });

    test('keys needs a selected key', () {
      final st = fullState()..selectedKeyName = null;
      expect(st.isStepComplete(WizardStep.keys), isFalse);
    });

    test('review needs a signature', () {
      final st = fullState()..signedAssertion = null;
      expect(st.isStepComplete(WizardStep.review), isFalse);
    });
  });

  group('isStepEnabled (gating)', () {
    test('a step is enabled only when all prior steps are complete', () {
      final st = fullState();
      // Knock out the Snaps step; everything after it must be disabled.
      st.model.snaps = st.model.snaps
          .where((s) => s.type != SnapType.gadget)
          .toList();
      expect(st.isStepComplete(WizardStep.snaps), isFalse);
      expect(st.isStepEnabled(WizardStep.snaps), isTrue);
      expect(st.isStepEnabled(WizardStep.extras), isFalse);
      expect(st.isStepEnabled(WizardStep.keys), isFalse);
      expect(st.isStepEnabled(WizardStep.review), isFalse);
    });

    test('account is always enabled', () {
      expect(fullState().isStepEnabled(WizardStep.account), isTrue);
      expect(WizardState().isStepEnabled(WizardStep.account), isTrue);
    });
  });

  group('showStepComplete (checkmark display)', () {
    test('extras checkmark only appears once prior steps are complete', () {
      // Fresh state: extras is "complete" for gating but must NOT show a
      // checkmark because the steps before it are not done.
      final fresh = WizardState();
      expect(fresh.isStepComplete(WizardStep.extras), isTrue);
      expect(fresh.showStepComplete(WizardStep.extras), isFalse);

      // Fully-populated: extras shows the checkmark.
      expect(fullState().showStepComplete(WizardStep.extras), isTrue);
    });

    test('non-extras steps mirror isStepComplete', () {
      final st = fullState();
      for (final s in WizardStep.values.where((x) => x != WizardStep.extras)) {
        expect(st.showStepComplete(s), st.isStepComplete(s));
      }
    });
  });

  group('validationErrors', () {
    test('account lists sign-in and tooling problems', () {
      final errors = WizardState().validationErrors(WizardStep.account);
      expect(errors, contains('Sign in to your Snap Store account.'));
      expect(errors, contains('Install the snap tooling (snapd).'));
    });

    test('metadata reports name and base problems', () {
      final st = fullState();
      expect(st.validationErrors(WizardStep.metadata), isEmpty);

      st.model.model = null;
      expect(
          st.validationErrors(WizardStep.metadata),
          contains('Model name is required.'));

      st.model.model = 'No Good Name';
      expect(
          st.validationErrors(WizardStep.metadata),
          contains('Model name must be lowercase alphanumeric with dashes.'));

      st.model.model = 'good-name';
      st.model.base = null;
      expect(st.validationErrors(WizardStep.metadata),
          contains('Select a base snap.'));
    });

    test('snaps reports each missing component', () {
      final st = WizardState();
      st.model.base = 'core24';
      final errors = st.validationErrors(WizardStep.snaps);
      expect(errors, contains('Add a kernel snap.'));
      expect(errors, contains('Add a gadget snap.'));
      expect(errors, contains('Add the snapd snap.'));
      expect(errors, contains('Add the "core24" base snap.'));
    });

    test('snaps distinguishes "no base selected" from "missing base snap"',
          () {
      final st = fullState();
      st.model.snaps = st.model.snaps
          .where((s) => s.type != SnapType.base)
          .toList();
      expect(st.validationErrors(WizardStep.snaps),
          contains('Add the "core24" base snap.'));

      st.model.snaps = completeSnaps();
      st.model.base = null;
      expect(st.validationErrors(WizardStep.snaps),
          contains('Select a base on the Metadata step first.'));
    });

    test('keys and review report their single requirement', () {
      final st = fullState()..selectedKeyName = null..signedAssertion = null;
      expect(st.validationErrors(WizardStep.keys),
          contains('Select or create a signing key.'));
      expect(st.validationErrors(WizardStep.review),
          contains('Sign the model to finish.'));
    });

    test('extras has no required fields', () {
      expect(WizardState().validationErrors(WizardStep.extras), isEmpty);
    });

    test('a fully-valid state reports no errors for any step', () {
      final st = fullState();
      for (final s in WizardStep.values) {
        expect(st.validationErrors(s), isEmpty, reason: '$s should be clean');
      }
    });
  });

  group('busy lifecycle', () {
    test('setBusy stores a message and cancel callback', () {
      final st = WizardState();
      var cancelled = false;
      st.setBusy(true,
          message: 'Working…', onCancel: () => cancelled = true);
      expect(st.busy, isTrue);
      expect(st.busyMessage, 'Working…');
      st.busyCancelCallback!();
      expect(cancelled, isTrue);

      st.busy = false;
      expect(st.busy, isFalse);
      expect(st.busyMessage, isNull);
      expect(st.busyCancelCallback, isNull);
    });
  });

  group('invalidateSignature', () {
    test('clears a prior signature and notifies', () {
      final st = fullState();
      var notified = 0;
      st.addListener(() => notified++);
      st.invalidateSignature();
      expect(st.signedAssertion, isNull);
      expect(notified, 1);
    });

    test('does nothing (no notify) when already empty', () {
      final st = WizardState();
      var notified = 0;
      st.addListener(() => notified++);
      st.invalidateSignature();
      expect(notified, 0);
    });
  });

  group('importModel', () {
    test('copies the model fields and clears the signature', () {
      final st = fullState();
      final imported = ModelAssertion()
        ..model = 'imported'
        ..base = 'core22'
        ..brandId = 'imp'
        ..authorityId = 'imp'
        ..store = 'my-store'
        ..grade = ModelGrade.secured
        ..snaps = completeSnaps(base: 'core22');
      st.importModel(imported);

      expect(st.model.model, 'imported');
      expect(st.model.base, 'core22');
      expect(st.model.store, 'my-store');
      expect(st.model.grade, ModelGrade.secured);
      expect(st.signedAssertion, isNull);
      // The imported model is not yet signable -> review incomplete.
      expect(st.isStepComplete(WizardStep.review), isFalse);
    });
  });

  group('ChangeNotifier', () {
    test('refresh and setBusy notify listeners', () {
      final st = WizardState();
      var n = 0;
      st.addListener(() => n++);
      st.refresh();
      st.setBusy(true, message: 'x');
      st.setBusy(false);
      expect(n, 3);
    });
  });
}
