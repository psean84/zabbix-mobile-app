import 'package:flutter/material.dart';

String extractIp(dynamic host) {
  final interfaces = host['interfaces'];
  if (interfaces is List && interfaces.isNotEmpty) {
    final ip = interfaces.first['ip'];
    if (ip != null && ip.toString().isNotEmpty) return ip.toString();
  }
  return '-';
}

String entityName(dynamic item) {
  final name = (item['name'] ?? '').toString().trim();
  final key = (item['key_'] ?? '').toString().trim();

  if (name.contains(':')) {
    final prefix = name.split(':').first.trim();
    if (prefix.isNotEmpty && prefix.length < 80) return prefix;
  }

  final start = key.indexOf('[');
  final end = key.indexOf(']');
  if (start >= 0 && end > start) {
    final inside = key.substring(start + 1, end).trim();
    if (inside.isNotEmpty) return inside;
  }

  if (name.isNotEmpty) return 'General';
  return 'Misc';
}

bool isNumericItem(dynamic item) => itemNumericValue(item) != null;

double? itemNumericValue(dynamic item) {
  final valueType = item['value_type']?.toString();
  final raw = (item['lastvalue'] ?? '').toString().trim();
  if (valueType == '0' || valueType == '3') {
    final direct = double.tryParse(raw);
    if (direct != null) return direct;
  }
  final cleaned = raw.replaceAll(RegExp(r'[^0-9\.\-]'), '');
  return double.tryParse(cleaned);
}

int? parseTimeInputToEpoch(String input) {
  if (input.isEmpty) return null;
  final epoch = int.tryParse(input);
  if (epoch != null) return epoch;

  final normalized = input.replaceFirst('T', ' ');
  final parts = normalized.split(' ');
  if (parts.length != 2) return null;
  final date = parts[0].split('-');
  final time = parts[1].split(':');
  if (date.length != 3 || time.length < 2) return null;

  final y = int.tryParse(date[0]);
  final m = int.tryParse(date[1]);
  final d = int.tryParse(date[2]);
  final hh = int.tryParse(time[0]);
  final mm = int.tryParse(time[1]);
  if ([y, m, d, hh, mm].any((v) => v == null)) return null;

  return DateTime(y!, m!, d!, hh!, mm!).millisecondsSinceEpoch ~/ 1000;
}

String formatDateTimeInput(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

String severityText(String value) {
  switch (value) {
    case '0':
      return 'Not classified';
    case '1':
      return 'Information';
    case '2':
      return 'Warning';
    case '3':
      return 'Average';
    case '4':
      return 'High';
    case '5':
      return 'Disaster';
    default:
      return value;
  }
}

int severityValue(String value) => int.tryParse(value) ?? 0;

String severityCodeFromLabel(String label) {
  switch (label) {
    case 'Disaster':
      return '5';
    case 'High':
      return '4';
    case 'Average':
      return '3';
    case 'Warning':
      return '2';
    case 'Information':
      return '1';
    case 'Not classified':
      return '0';
    default:
      return '0';
  }
}

Color severityColor(String value) {
  switch (value) {
    case '5':
      return Colors.deepPurple;
    case '4':
      return Colors.red;
    case '3':
      return Colors.orange;
    case '2':
      return Colors.amber.shade700;
    case '1':
      return Colors.blue;
    case '0':
      return Colors.grey;
    default:
      return Colors.grey;
  }
}

Color seriesColor(int index) {
  const palette = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.indigo,
    Colors.brown,
  ];
  final i = index < 0 ? 0 : index % palette.length;
  return palette[i];
}
