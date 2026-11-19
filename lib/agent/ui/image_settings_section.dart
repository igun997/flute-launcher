import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../image/image_models.dart';
import '../llm/model_catalog.dart';
import '../llm/model_info.dart';
import 'settings_widgets.dart';

/// Which model draws pictures. Auto uses the first image model the provider offers.
class ImageSettingsSection extends StatelessWidget {
  const ImageSettingsSection({super.key, required this.flute});

  final Flute flute;

  static const _auto = '';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([flute.imageSettings, flute.providers]),
      builder: (context, _) {
        final profile = flute.providers.active;
        final catalog = profile == null
            ? const <ModelInfo>[]
            : ModelCatalog.loadCache(flute.prefs, profile.id) ?? const <ModelInfo>[];
        final chosen = flute.imageSettings.model;
        final models = ImageModels.candidates(catalog);
        final shown = [
          if (chosen != null && !models.contains(chosen)) chosen,
          ...models,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SettingsLabel('Image generation'),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                shown.isEmpty
                    ? 'No image model was found on this provider yet. Open the model list from the provider menu so Flute can look.'
                    : 'The agent draws with the model below. Auto tries the ones this provider offers, in order.',
                style: settingsMuted,
              ),
            ),
            if (shown.isNotEmpty)
              DropdownButton<String>(
                isExpanded: true,
                value: chosen ?? _auto,
                dropdownColor: FluteColors.surfaceHigh,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(value: _auto, child: Text('Auto')),
                  for (final id in shown) DropdownMenuItem(value: id, child: Text(id, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (value) => flute.imageSettings.setModel(value == _auto ? null : value),
              ),
          ],
        );
      },
    );
  }
}
