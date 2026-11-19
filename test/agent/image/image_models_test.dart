import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/image/image_models.dart';
import 'package:focus_launcher/agent/llm/model_catalog.dart';
import 'package:focus_launcher/agent/llm/model_info.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ModelInfo _m(String id, {bool? draws}) => ModelInfo(id: id, name: id, generatesImages: draws);

void main() {
  test('a gateway that lists cx/ and gemini/ models offers its image models, best first', () {
    final catalog = [_m('cx/gpt-6-luna'), _m('gemini/gemini-3.6-flash'), _m('claude-opus-4-6')];
    expect(ImageModels.candidates(catalog), [
      'cx/gpt-image-2',
      'gemini/gemini-3.1-flash-image-preview',
      'gemini/gemini-2.5-flash-image',
    ]);
  });

  test('a plain provider never gets another provider\'s models proposed', () {
    final catalog = [_m('gpt-4o'), _m('gpt-image-1'), _m('text-embedding-3-small')];
    expect(ImageModels.candidates(catalog), ['gpt-image-1']);
  });

  test('the provider\'s own capability flag beats the name, both ways', () {
    final catalog = [_m('mystery-draw', draws: true), _m('some-image-model', draws: false)];
    expect(ImageModels.candidates(catalog), ['mystery-draw']);
  });

  test('the chosen model is tried first, even when it is not in the list', () {
    final catalog = [_m('gpt-image-1'), _m('dall-e-3')];
    expect(ImageModels.candidates(catalog, preferred: 'custom/draw').first, 'custom/draw');
  });

  test('an empty model list offers nothing', () {
    expect(ImageModels.candidates(const []), isEmpty);
  });

  test('imageOutput and output_modalities in a model list are read', () async {
    final models = await ModelCatalog.fetch(
      kind: ProviderKind.openaiCompatible,
      baseUrl: 'https://gw.example.com/v1',
      token: 'sk-test',
      httpClient: MockClient((_) async => http.Response(jsonEncode({
            'data': [
        {
          'id': 'a',
          'capabilities': {'imageOutput': true},
        },
        {
          'id': 'b',
          'architecture': {
            'output_modalities': ['text', 'image'],
          },
        },
        {'id': 'c'},
      ],
          }), 200)),
    );
    expect({for (final m in models) m.id: m.generatesImages}, {'a': true, 'b': true, 'c': null});
  });

  test('plan keeps the chosen target first and searches providers in the given order', () {
    final plan = ImageModels.plan(
      {
        'a': [_m('gpt-4o')],
        'b': [_m('dall-e-3'), _m('gpt-image-1')],
        'c': [_m('flux-dev')],
      },
      first: const [ImageTarget('c', 'flux-dev')],
    );
    expect(plan, const [
      ImageTarget('c', 'flux-dev'),
      ImageTarget('b', 'gpt-image-1'),
      ImageTarget('b', 'dall-e-3'),
    ]);
  });

  test('a model the assistant names is found by id on the right provider, any case', () {
    final catalogs = {
      'a': [_m('gpt-4o')],
      'b': [_m('dall-e-3')],
      'c': [_m('cx/gpt-6-luna')],
    };
    const labels = {'a': 'Netra', 'b': 'OpenAI', 'c': 'Gateway'};
    expect(ImageModels.find(catalogs, labels, 'DALL-E-3'), const ImageTarget('b', 'dall-e-3'));
    // Not listed by the gateway, but a known image model of a gateway that lists cx/ models.
    expect(ImageModels.find(catalogs, labels, 'cx/gpt-image-2', provider: 'gateway'),
        const ImageTarget('c', 'cx/gpt-image-2'));
    expect(ImageModels.find(catalogs, labels, 'dall-e-3', provider: 'Netra'), isNull);
    expect(ImageModels.find(catalogs, labels, 'nonexistent'), isNull);
    // A loose name picks the first matching image model.
    expect(ImageModels.find(catalogs, labels, 'gpt image'), const ImageTarget('c', 'cx/gpt-image-2'));
    expect(ImageModels.find(catalogs, labels, 'dall e'), const ImageTarget('b', 'dall-e-3'));
  });
}
