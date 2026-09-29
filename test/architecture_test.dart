import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regla de dependencias de la arquitectura limpia (ver README →
/// Arquitectura). Si un test de acá falla, un import cruzó una capa:
/// corregí el import, no el test.
///
///   presentation ─┐
///                 ├─> services (infraestructura) ─┐
///   data ─────────┘                               ├─> domain
///                                                 └─> core
///
/// - domain: Dart puro (solo `meta`), no conoce a nadie.
/// - data: implementa los repositorios del dominio; puede usar adaptadores
///   de plataforma de services. Nunca presentation.
/// - services: motores y adaptadores de plataforma. Nunca data ni
///   presentation (lo que necesitan de data lo piden por una interfaz del
///   dominio registrada en `core/di`).
/// - presentation: pantallas y estado de UI. Nunca data, ni acceso directo
///   a archivos, preferencias o canales nativos (eso va en services).
/// - core/di/service_locator.dart y main.dart arman todo: pueden ver todo.
void main() {
  final files = _dartFiles('lib');

  test('domain es Dart puro y no depende de otras capas', () {
    final problems = [
      for (final file in _inLayer(files, 'domain'))
        for (final imp in file.imports)
          if (!_isDomainImport(file, imp)) '${file.path} importa $imp',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('data no depende de presentation', () {
    final problems =
        _crossing(files, from: 'data', forbidden: {'presentation'});
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('services no depende de data ni de presentation', () {
    final problems =
        _crossing(files, from: 'services', forbidden: {'data', 'presentation'});
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('presentation no depende de data', () {
    final problems =
        _crossing(files, from: 'presentation', forbidden: {'data'});
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('core (salvo la inyección de dependencias) no depende de las capas', () {
    final problems = [
      for (final problem in _crossing(files,
          from: 'core', forbidden: {'data', 'services', 'presentation'}))
        if (!problem.startsWith('lib/core/di/')) problem,
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('la UI no toca archivos, preferencias ni canales nativos', () {
    const forbiddenImports = {
      'dart:io',
      'package:shared_preferences/shared_preferences.dart',
      'package:path_provider/path_provider.dart',
      'package:device_info_plus/device_info_plus.dart',
    };
    final problems = <String>[
      for (final file in _inLayer(files, 'presentation')) ...[
        for (final imp in file.imports)
          if (forbiddenImports.contains(imp)) '${file.path} importa $imp',
        if (RegExp(r'\b(MethodChannel|EventChannel)\s*\(').hasMatch(file.code))
          '${file.path} abre un canal nativo',
      ],
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}

class _DartFile {
  _DartFile(this.path, this.code)
      : imports = [
          for (final match in RegExp(
                  r'''^\s*(?:import|export)\s+'([^']+)'\s*''',
                  multiLine: true)
              .allMatches(code))
            match.group(1)!,
        ];

  /// Relativa a la raíz del proyecto, con "/" (lib/domain/…).
  final String path;
  final String code;
  final List<String> imports;

  String get layer => path.split('/')[1];

  /// A qué archivo de lib/ apunta [imp] (null: paquete externo o dart:).
  String? target(String imp) {
    if (imp.startsWith('package:tk_music/')) {
      return 'lib/${imp.substring('package:tk_music/'.length)}';
    }
    if (imp.contains(':')) return null;
    final parts = [...path.split('/')..removeLast(), ...imp.split('/')];
    final out = <String>[];
    for (final part in parts) {
      if (part == '..') {
        out.removeLast();
      } else if (part != '.') {
        out.add(part);
      }
    }
    return out.join('/');
  }
}

List<_DartFile> _dartFiles(String root) => [
      for (final entity in Directory(root).listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          _DartFile(
              entity.path.replaceAll(r'\', '/'), entity.readAsStringSync()),
    ];

Iterable<_DartFile> _inLayer(List<_DartFile> files, String layer) =>
    files.where((f) => f.layer == layer);

String? _layerOf(String path) {
  final parts = path.split('/');
  return parts.length > 2 ? parts[1] : null;
}

List<String> _crossing(List<_DartFile> files,
        {required String from, required Set<String> forbidden}) =>
    [
      for (final file in _inLayer(files, from))
        for (final imp in file.imports)
          if (file.target(imp) case final target?)
            if (forbidden.contains(_layerOf(target)))
              '${file.path} importa $imp',
    ];

bool _isDomainImport(_DartFile file, String imp) {
  if (imp.startsWith('dart:')) return imp != 'dart:io' && imp != 'dart:ui';
  if (imp == 'package:meta/meta.dart') return true;
  final target = file.target(imp);
  return target != null && _layerOf(target) == 'domain';
}
