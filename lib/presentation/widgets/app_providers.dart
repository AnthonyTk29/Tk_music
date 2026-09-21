import 'package:flutter/material.dart';

import 'package:tk_music/presentation/providers/permission_provider.dart';
import 'package:tk_music/presentation/providers/profile_provider.dart';
import 'package:tk_music/presentation/providers/song_provider.dart';

class AppProviders extends StatefulWidget {
  const AppProviders({
    super.key,
    required this.songProvider,
    required this.permissionProvider,
    required this.profileProvider,
    required this.child,
  });

  final SongProvider songProvider;
  final PermissionProvider permissionProvider;
  final ProfileProvider profileProvider;
  final Widget child;

  static SongProvider songOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InheritedProviders>()!
          .songProvider;

  static PermissionProvider permissionOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InheritedProviders>()!
          .permissionProvider;

  static ProfileProvider profileOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InheritedProviders>()!
          .profileProvider;

  @override
  State<AppProviders> createState() => _AppProvidersState();
}

class _AppProvidersState extends State<AppProviders> {
  late final MultiNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = MultiNotifier._([
      widget.songProvider,
      widget.permissionProvider,
      widget.profileProvider,
    ]);
  }

  @override
  void dispose() {
    _notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _InheritedProviders(
      notifier: _notifier,
      songProvider: widget.songProvider,
      permissionProvider: widget.permissionProvider,
      profileProvider: widget.profileProvider,
      child: widget.child,
    );
  }
}

class _InheritedProviders extends InheritedNotifier<MultiNotifier> {
  const _InheritedProviders({
    required MultiNotifier notifier,
    required this.songProvider,
    required this.permissionProvider,
    required this.profileProvider,
    required super.child,
  }) : super(notifier: notifier);

  final SongProvider songProvider;
  final PermissionProvider permissionProvider;
  final ProfileProvider profileProvider;
}

class MultiNotifier extends ChangeNotifier {
  MultiNotifier._(this._notifiers) {
    for (final n in _notifiers) {
      n.addListener(notifyListeners);
    }
  }

  final List<ChangeNotifier> _notifiers;

  @override
  void dispose() {
    for (final n in _notifiers) {
      n.removeListener(notifyListeners);
    }
    super.dispose();
  }
}
