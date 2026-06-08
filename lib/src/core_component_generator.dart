import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:source_gen/source_gen.dart';

class CoreSerializableComponentsBuilder extends Builder {
  final BuilderOptions options;

  CoreSerializableComponentsBuilder(this.options);

  @override
  Map<String, List<String>> get buildExtensions => {
    r'$lib$': [
      'components/serializable/register_serializable_components.g.dart',
    ],
  };

  bool _implementsSerializableComponent(ClassElement element) {
    for (final interface in element.allSupertypes) {
      if (interface.element.name == 'ProtoSerializable') {
        return true;
      }
    }
    return false;
  }

  String? _getProtoTypeName(ClassElement element) {
    for (final interface in element.allSupertypes) {
      if (interface.element.name == 'ProtoSerializable') {
        final typeArg = interface.typeArguments.isNotEmpty
            ? interface.typeArguments.first
            : null;
        return typeArg?.element?.name;
      }
    }
    return null;
  }

  bool _hasValidConstructor(ClassElement element) {
    return element.constructors.any(_isValidConstructor);
  }

  bool _isValidConstructor(ConstructorElement constructor) {
    final positionalParams = constructor.formalParameters
        .where((p) => p.isPositional)
        .toList();
    if (positionalParams.length != 1) return false;

    final otherRequiredParams = constructor.formalParameters.where((p) {
      if (p == positionalParams.first) return false;
      return p.isRequired;
    });

    if (otherRequiredParams.isNotEmpty) return false;

    return true;
  }

  bool _constructorHasRegistryParam(ClassElement element) {
    ConstructorElement? validConstructor;
    for (final constructor in element.constructors) {
      if (_isValidConstructor(constructor)) {
        validConstructor = constructor;
        break;
      }
    }
    validConstructor ??= element.unnamedConstructor;
    if (validConstructor == null) return false;

    return validConstructor.formalParameters.any(
      (p) =>
          p.isNamed &&
          p.name == 'registry' &&
          p.type.element?.name == 'SerializableComponentRegistry',
    );
  }

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final allFiles = await buildStep
        .findAssets(Glob('lib/**/*.{sc,scp}.dart'))
        .toList();

    allFiles.sort();

    final factories =
        <
          String,
          ({String className, String importLine, bool hasRegistryParam, String protoImport})
        >{};
    final metaProviders = <String, ({String className, String importLine})>{};

    final packageName = buildStep.inputId.package;

    for (final file in allFiles) {
      print('[DEBUG] Found file: ${file.path}');
      final isScFile = file.path.endsWith('.sc.dart');
      final isScpFile = file.path.endsWith('.scp.dart');

      final library = await buildStep.resolver.libraryFor(file);
      final libraryReader = LibraryReader(library);

      for (final clazz in libraryReader.allElements.whereType<ClassElement>()) {
        final className = clazz.name;
        if (className == null) continue;

        print('[DEBUG] Analyzing class: $className');
        final supertypeNames = clazz.allSupertypes.map((s) => s.element.name).toList();
        print('[DEBUG] Class $className supertypes: $supertypeNames');

        final importPath = file.path.replaceFirst('lib/', 'package:$packageName/');
        final importLine = 'import "$importPath";';

        if (_implementsSerializableComponent(clazz) && !clazz.isAbstract) {
          if (!isScFile) continue;
          final protoTypeName = _getProtoTypeName(clazz);
          final hasValidConstructor = _hasValidConstructor(clazz);

          if (protoTypeName != null && hasValidConstructor) {
            final hasRegistryParam = _constructorHasRegistryParam(clazz);
            
            // Look up the import URI for protoTypeName dynamically
            String? protoImport;
            for (final interface in clazz.allSupertypes) {
              if (interface.element.name == 'ProtoSerializable') {
                final typeArg = interface.typeArguments.isNotEmpty
                    ? interface.typeArguments.first
                    : null;
                final uri = typeArg?.element?.library?.uri;
                if (uri != null) {
                  protoImport = 'import "$uri";';
                }
              }
            }
            
            factories[protoTypeName] = (
              className: className,
              importLine: importLine,
              hasRegistryParam: hasRegistryParam,
              protoImport: protoImport ?? '',
            );
          }
        }

        // Check for ProtoComponentMeta
        for (final interface in clazz.allSupertypes) {
          if (interface.element.name == 'ProtoComponentMeta') {
            if (!isScpFile) continue;
            final protoType = interface.typeArguments.isNotEmpty
                ? interface.typeArguments.first.element?.name
                : null;
            if (protoType != null) {
              metaProviders[protoType] = (
                className: className,
                importLine: importLine,
              );
            }
          }
        }
      }
    }

    final allProtoTypes = factories.keys.toList()..sort();
    final allImportLines = <String>{};
    
    // Add additional imports from config options if any
    final configImports = options.config['imports'];
    if (configImports is List) {
      for (final imp in configImports) {
        allImportLines.add('import "$imp";');
      }
    } else if (configImports is String) {
      allImportLines.add('import "$configImports";');
    }

    for (final protoType in allProtoTypes) {
      final factory = factories[protoType]!;
      allImportLines.add(factory.importLine);
      if (factory.protoImport.isNotEmpty) {
        allImportLines.add(factory.protoImport);
      }
      final meta = metaProviders[protoType];
      if (meta != null) {
        allImportLines.add(meta.importLine);
      }
    }

    final sortedImports = allImportLines.toList()..sort();

    final registerLines = <String>[];
    for (final protoType in allProtoTypes) {
      final factory = factories[protoType]!;
      final meta = metaProviders[protoType];

      final registryArg = factory.hasRegistryParam
          ? ', registry: registry'
          : '';

      final metaArg = meta != null ? 'meta: const ${meta.className}(),' : '';

      registerLines.add('''
  registry.registerDescriptor(
    ComponentDescriptor(
      defaultInstance: $protoType.getDefault(),
      factory: (data, {registry}) => ${factory.className}(data as $protoType$registryArg),
      $metaArg
    ),
  );''');
    }

    final importLines = sortedImports.join('\n');
    final registerContent = registerLines.join('\n');

    final outputContent =
        '''
// This file is automatically generated. Do not edit manually.
// Generated by CoreSerializableComponentsBuilder

import 'package:protobuf_serializable_components/protobuf_serializable_components.dart';

$importLines

void registerSerializableComponents(SerializableComponentRegistry registry) {
$registerContent
}''';

    await buildStep.writeAsString(
      AssetId(
        buildStep.inputId.package,
        'lib/components/serializable/register_serializable_components.g.dart',
      ),
      outputContent,
    );
  }
}
