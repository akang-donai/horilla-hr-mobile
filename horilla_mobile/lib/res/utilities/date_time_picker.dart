import 'package:flutter/material.dart';

Future<DateTime?> selectDate(BuildContext context, DateTime initialDate, {DateTime? firstDate, DateTime? lastDate}) async {
  return await showDatePicker(
    context: context,
    initialDate: initialDate,
    firstDate: firstDate ?? DateTime(2000),
    lastDate: lastDate ?? DateTime(2100),
  );
}

Future<TimeOfDay?> selectTime(BuildContext context, {TimeOfDay? initialTime}) async {
  return await showTimePicker(
    context: context,
    initialTime: initialTime ?? TimeOfDay.now(),
  );
}

Future<DateTime?> pickDateTime(BuildContext context, {required bool isStartTime, DateTime? initialDate, DateTime? minDate, DateTime? lastDate}) async {
  final DateTime? pickedDate = await selectDate(
    context,
    initialDate ?? DateTime.now(),
    firstDate: minDate ?? (isStartTime ? DateTime.now() : initialDate),
    lastDate: lastDate ?? DateTime.now().add(const Duration(days: 3650)),
  );

  if (pickedDate != null) {
    final TimeOfDay? pickedTime = await selectTime(context);
    if (pickedTime != null) {
      return DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    }
  }
  return null;
}
