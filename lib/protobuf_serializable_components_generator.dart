library protobuf_serializable_components_generator;

import 'package:build/build.dart';
import 'src/core_component_generator.dart';

export 'src/descriptor_registry_builder.dart';
export 'src/export_index_builder.dart';
export 'src/type_registry_builder.dart';

Builder coreSerializableComponentsBuilder(BuilderOptions options) =>
    CoreSerializableComponentsBuilder(options);
