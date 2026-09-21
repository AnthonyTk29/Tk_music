import 'package:flutter/material.dart';

import 'package:tk_music/domain/entities/profile.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';

class ProfilePickerScreen extends StatefulWidget {
  const ProfilePickerScreen({super.key});

  @override
  State<ProfilePickerScreen> createState() => _ProfilePickerScreenState();
}

class _ProfilePickerScreenState extends State<ProfilePickerScreen> {
  bool _rememberMe = true;
  bool _busy = false;

  Future<void> _choose(Profile profile) async {
    if (_busy) return;
    setState(() => _busy = true);
    await AppProviders.profileOf(context)
        .selectProfile(profile, rememberMe: _rememberMe);
  }

  Future<void> _createAndChoose() async {
    final name = await _promptForName();
    if (name == null || name.isEmpty || !mounted) return;

    setState(() => _busy = true);
    final provider = AppProviders.profileOf(context);
    final profile = await provider.createProfile(name);
    await provider.selectProfile(profile, rememberMe: _rememberMe);
  }

  Future<String?> _promptForName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nuevo perfil'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nombre'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            label: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            icon: const Icon(Icons.add),
            label: const Text('Crear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = AppProviders.profileOf(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(),
              Icon(Icons.library_music_rounded,
                  size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('¿Quién escucha?', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 32),
              if (provider.profiles.isEmpty)
                Text(
                  'Todavía no hay perfiles en este dispositivo.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                )
              else
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  alignment: WrapAlignment.center,
                  children: provider.profiles
                      .map((p) => _ProfileAvatar(
                            profile: p,
                            onTap: _busy ? null : () => _choose(p),
                          ))
                      .toList(),
                ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _busy ? null : _createAndChoose,
                icon: const Icon(Icons.add),
                label: const Text('Crear perfil'),
              ),
              const Spacer(),
              CheckboxListTile(
                value: _rememberMe,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _rememberMe = value ?? true),
                title: const Text('Recordarme'),
                subtitle: const Text('No volver a preguntar en este dispositivo'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile, required this.onTap});

  final Profile profile;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = profile.name.isNotEmpty ? profile.name[0].toUpperCase() : '?';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 88,
        child: Column(
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Text(initial,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            ),
            const SizedBox(height: 8),
            Text(
              profile.name,
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
