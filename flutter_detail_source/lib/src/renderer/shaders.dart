// ignore_for_file: public_member_api_docs

import 'package:meta/meta.dart';

@internal
abstract class ShaderKeys {
  const ShaderKeys._();

  static const lightweight = 'shaders/lightweight_glass.frag';
  static const interactiveIndicator = 'shaders/interactive_indicator.frag';
  static const blendedGeometry =
      'shaders/liquid_glass_geometry_blended.frag';

  static const liquidGlassRender = 'shaders/liquid_glass_final_render.frag';
}
