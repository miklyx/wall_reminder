import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/reminder_trigger.dart';

class ReminderQueueState {
  ReminderQueueState({
    required List<ReminderTrigger> reminders,
    required List<String> receivedDeliveryIds,
    required List<String> pendingDismissalDeliveryIds,
  })  : reminders = List.unmodifiable(reminders),
        receivedDeliveryIds = List.unmodifiable(receivedDeliveryIds),
        pendingDismissalDeliveryIds =
            List.unmodifiable(pendingDismissalDeliveryIds);

  final List<ReminderTrigger> reminders;
  final List<String> receivedDeliveryIds;
  final List<String> pendingDismissalDeliveryIds;

  ReminderTrigger? get current => reminders.isEmpty ? null : reminders.first;

  ReminderQueueState copyWith({
    List<ReminderTrigger>? reminders,
    List<String>? receivedDeliveryIds,
    List<String>? pendingDismissalDeliveryIds,
  }) =>
      ReminderQueueState(
        reminders: reminders ?? this.reminders,
        receivedDeliveryIds: receivedDeliveryIds ?? this.receivedDeliveryIds,
        pendingDismissalDeliveryIds:
            pendingDismissalDeliveryIds ?? this.pendingDismissalDeliveryIds,
      );

  Map<String, Object> toJson() => {
        'reminders': reminders.map((reminder) => reminder.toJson()).toList(),
        'received_delivery_ids': receivedDeliveryIds,
        'pending_dismissal_delivery_ids': pendingDismissalDeliveryIds,
      };

  factory ReminderQueueState.fromJson(Map<String, dynamic> json) {
    final rawReminders = json['reminders'];
    final rawReceivedIds = json['received_delivery_ids'];
    final rawPendingDismissals = json['pending_dismissal_delivery_ids'];
    if (rawReminders is! List ||
        rawReceivedIds is! List ||
        rawPendingDismissals is! List) {
      throw const FormatException('Saved reminder queue has an invalid shape');
    }

    final reminders = rawReminders.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Saved reminder is invalid');
      }
      return ReminderTrigger.fromJson(value);
    }).toList();
    final receivedIds = rawReceivedIds.map((value) {
      if (value is! String || value.isEmpty) {
        throw const FormatException('Saved delivery ID is invalid');
      }
      return value;
    }).toList();
    final pendingDismissalDeliveryIds = rawPendingDismissals.map((value) {
      if (value is! String || value.isEmpty) {
        throw const FormatException('Saved dismissal is invalid');
      }
      return value;
    }).toList();
    return ReminderQueueState(
      reminders: reminders,
      receivedDeliveryIds: receivedIds,
      pendingDismissalDeliveryIds: pendingDismissalDeliveryIds,
    );
  }
}

class ReminderQueueStore {
  ReminderQueueStore._(this._preferences, this._state);

  static const _storageKey = 'wall_reminder_queue_v1';
  static const _maxReceivedIds = 1000;

  final SharedPreferences _preferences;
  ReminderQueueState _state;
  Future<void> _operationTail = Future<void>.value();

  ReminderQueueState get state => _state;

  static Future<ReminderQueueStore> load(
    SharedPreferences preferences,
  ) async {
    final encoded = preferences.getString(_storageKey);
    if (encoded == null) {
      return ReminderQueueStore._(
        preferences,
        ReminderQueueState(
          reminders: const [],
          receivedDeliveryIds: const [],
          pendingDismissalDeliveryIds: const [],
        ),
      );
    }

    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Saved reminder queue is not an object');
    }
    return ReminderQueueStore._(
      preferences,
      ReminderQueueState.fromJson(decoded),
    );
  }

  Future<bool> add(ReminderTrigger trigger) => _serialize(() async {
        if (_state.receivedDeliveryIds.contains(trigger.deliveryId) ||
            _state.reminders.any(
              (reminder) => reminder.deliveryId == trigger.deliveryId,
            ) ||
            _state.pendingDismissalDeliveryIds.contains(trigger.deliveryId)) {
          return false;
        }
        final receivedIds = [..._state.receivedDeliveryIds, trigger.deliveryId];
        if (receivedIds.length > _maxReceivedIds) {
          receivedIds.removeRange(0, receivedIds.length - _maxReceivedIds);
        }
        final next = _state.copyWith(
          reminders: [..._state.reminders, trigger],
          receivedDeliveryIds: receivedIds,
        );
        await _save(next);
        return true;
      });

  Future<bool> complete(String deliveryId) => _serialize(() async {
        final reminderIndex = _state.reminders.indexWhere(
          (reminder) => reminder.deliveryId == deliveryId,
        );
        if (reminderIndex < 0) return false;

        final reminders = [..._state.reminders]..removeAt(reminderIndex);
        final pendingDismissals = [
          ..._state.pendingDismissalDeliveryIds,
          deliveryId,
        ];
        final next = _state.copyWith(
          reminders: reminders,
          pendingDismissalDeliveryIds: pendingDismissals,
        );
        await _save(next);
        return true;
      });

  Future<void> markDismissalSynced(String deliveryId) => _serialize(() async {
        if (!_state.pendingDismissalDeliveryIds.contains(deliveryId)) return;
        final pendingDismissals = [..._state.pendingDismissalDeliveryIds]
          ..remove(deliveryId);
        await _save(
          _state.copyWith(
            pendingDismissalDeliveryIds: pendingDismissals,
          ),
        );
      });

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _save(ReminderQueueState next) async {
    final stored = await _preferences.setString(
      _storageKey,
      jsonEncode(next.toJson()),
    );
    if (!stored) {
      throw StateError('Could not persist the reminder queue');
    }
    _state = next;
  }
}
