import 'package:flutter/foundation.dart';

@immutable
class Profile {
  const Profile({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Profile && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
