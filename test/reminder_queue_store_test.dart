import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wall_reminder_display/models/reminder_trigger.dart';
import 'package:wall_reminder_display/services/reminder_queue_store.dart';

ReminderTrigger _trigger(String deliveryId, String reminderId) =>
    ReminderTrigger(
      deliveryId: deliveryId,
      reminderId: reminderId,
      messageText: 'Reminder $deliveryId',
      durationSeconds: 30,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('persists queued reminders and deduplicates redelivery after reload',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final store = await ReminderQueueStore.load(preferences);

    expect(await store.add(_trigger('delivery-1', 'reminder-1')), isTrue);
    expect(await store.add(_trigger('delivery-2', 'reminder-2')), isTrue);

    final restored = await ReminderQueueStore.load(preferences);
    expect(restored.state.reminders.map((item) => item.deliveryId),
        ['delivery-1', 'delivery-2']);
    expect(
      await restored.add(_trigger('delivery-1', 'reminder-1')),
      isFalse,
    );
    expect(restored.state.reminders, hasLength(2));
  });

  test('completion advances locally and keeps backend sync in durable outbox',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final store = await ReminderQueueStore.load(preferences);
    await store.add(_trigger('delivery-1', 'reminder-1'));
    await store.add(_trigger('delivery-2', 'reminder-2'));

    expect(await store.complete('delivery-1'), isTrue);
    expect(store.state.current?.deliveryId, 'delivery-2');
    expect(store.state.pendingDismissalDeliveryIds, ['delivery-1']);

    final restored = await ReminderQueueStore.load(preferences);
    expect(restored.state.current?.deliveryId, 'delivery-2');
    expect(restored.state.pendingDismissalDeliveryIds, ['delivery-1']);

    await restored.markDismissalSynced('delivery-1');
    expect(restored.state.pendingDismissalDeliveryIds, isEmpty);
  });

  test('does not enqueue the same delivery more than once concurrently',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final store = await ReminderQueueStore.load(preferences);
    final trigger = _trigger('delivery-1', 'reminder-1');

    final results = await Future.wait([
      store.add(trigger),
      store.add(trigger),
    ]);

    expect(results.where((added) => added), hasLength(1));
    expect(store.state.reminders, hasLength(1));
  });
}
