import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../image/image_models.dart';
import '../llm/model_catalog.dart';
import '../llm/model_info.dart';

/// Which model draws pictures, on any saved provider. Auto searches them all, the active one first.
class ImageSettingsSection extends StatelessWidget {
  const ImageSettingsSection({super.key, required this.flute});

  final Flute flute;

  static const _auto = '';
  static const _sep = '\u0000';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([flute.imageSettings, flute.providers]),
      builder: (context, _) {
        final profiles = [
          for (final p in flute.providers.profiles)
            if (p.kind == ProviderKind.openaiCompatible) p,
        ];
        final entries = <_Entry>[];
        for (final profile in profiles) {
          final catalog = ModelCatalog.loadCache(flute.prefs, profile.id) ?? const <ModelInfo>[];
          for (final model in ImageModels.candidates(catalog)) {
            entries.add(_Entry(profile, model));
          }
        }
        final settings = flute.imageSettings;
        final chosenModel = settings.model;
        final chosenProfileId = settings.profileId ?? flute.providers.active?.id;
        final chosenKey = chosenModel == null ? _auto : '$chosenProfileId$_sep$chosenModel';
        if (chosenModel != null && !entries.any((e) => e.key == chosenKey)) {
          final owner = profiles.where((p) => p.id == chosenProfileId);
          if (owner.isNotEmpty) entries.insert(0, _Entry(owner.first, chosenModel));
        }
        final several = profiles.length > 1;
        final note = switch ((entries.isEmpty, several)) {
          (true, _) => "No image model was found yet. Open a provider's model list so Flute can look.",
          (false, true) => 'Auto tries every provider, starting with the active one.',
          (false, false) => 'Auto tries the image models this provider offers, in order.',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(note, style: FluteText.caption),
            if (entries.isNotEmpty) ...[
              const SizedBox(height: FluteSpace.lg),
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Model'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: chosenKey,
                    dropdownColor: FluteColors.surfaceTop,
                    style: FluteText.body.copyWith(color: FluteColors.text),
                    items: [
                      const DropdownMenuItem(value: _auto, child: Text('Auto')),
                      for (final e in entries)
                        DropdownMenuItem(
                          value: e.key,
                          child: Text(
                            several ? '${e.profile.label} · ${e.model}' : e.model,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null || value == _auto) {
                        settings.choose();
                        return;
                      }
                      final parts = value.split(_sep);
                      settings.choose(profileId: parts.first, model: parts.last);
                    },
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Entry {
  const _Entry(this.profile, this.model);

  final ProviderProfile profile;
  final String model;

  String get key => '${profile.id}${ImageSettingsSection._sep}$model';
}
