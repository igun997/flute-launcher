import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'sky_ink.dart';

import '../weather/weather_service.dart';

const _chipTextColor = Color(0xFFE8EEF2);
const _chipMutedColor = Color(0xFFC3CED4);
const _sheetColor = Color(0xFF10161E);
const _searchDebounce = Duration(milliseconds: 350);

/// Compact current-weather readout: temperature, condition and city. Tapping
/// it opens a city search sheet that updates the chosen city.
class WeatherChip extends StatelessWidget {
  const WeatherChip(this.service, {super.key});

  final WeatherService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final now = service.now;
        final temp = now == null ? '--°' : '${now.tempC.round()}°';
        final condition = now == null ? 'Weather unavailable' : now.kind.label;
        final ink = SkyInk.of(context);

        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openCitySheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  temp,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                    color: ink.ink,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      condition,
                      style: TextStyle(
                        fontSize: 14,
                        color: ink.ink,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (service.followLocation) ...[
                          Icon(Icons.near_me, size: 12, color: ink.inkSoft),
                          const SizedBox(width: 3),
                        ],
                        Text(
                          service.city.name,
                          style: TextStyle(
                            fontSize: 13,
                            color: ink.inkSoft,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openCitySheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: _sheetColor,
      builder: (_) => _CitySheet(service: service),
    );
  }
}

/// Opens the weather location sheet: search a city or use the phone's location.
Future<void> showWeatherLocation(BuildContext context, WeatherService service) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: _sheetColor,
    builder: (_) => _CitySheet(service: service),
  );
}

class _CitySheet extends StatefulWidget {
  const _CitySheet({required this.service});

  final WeatherService service;

  @override
  State<_CitySheet> createState() => _CitySheetState();
}

class _CitySheetState extends State<_CitySheet> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  /// Incremented for every search so a slow, older response cannot overwrite
  /// the results of a newer query.
  int _searchSeq = 0;

  List<CitySuggestion> _results = const [];
  bool _busy = false;
  String? _error;
  bool _locating = false;
  String? _locationError;

  Future<void> _useMyLocation() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    final problem = await widget.service.useMyLocation();
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _locating = false;
        _locationError = problem;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final query = text.trim();
    if (query.length < 2) {
      _searchSeq++;
      setState(() {
        _results = const [];
        _busy = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(_searchDebounce, () => _search(query));
  }

  Future<void> _search(String query) async {
    final seq = ++_searchSeq;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final found = await widget.service.searchCity(query);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = found;
        _busy = false;
      });
    } catch (_) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = const [];
        _busy = false;
        _error = 'Could not search cities. Check your connection.';
      });
    }
  }

  Future<void> _select(CitySuggestion city) async {
    await widget.service.chooseCity(city);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final hasQuery = _controller.text.trim().length >= 2;

    String message;
    if (_error != null) {
      message = _error!;
    } else if (!hasQuery) {
      message = 'Type at least two letters.';
    } else if (_busy) {
      message = 'Searching...';
    } else if (_results.isEmpty) {
      message = 'No cities found.';
    } else {
      message = '';
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.near_me_outlined, color: _chipTextColor),
            title: Text(
              widget.service.followLocation ? 'Following your location' : 'Use my location',
              style: const TextStyle(color: _chipTextColor),
            ),
            subtitle: Text(
              _locationError ?? 'Weather follows you when you travel. Uses approximate location, only while Flute is open.',
              style: TextStyle(color: _locationError != null ? const Color(0xFFE0A38B) : _chipMutedColor, fontSize: 12),
            ),
            trailing: _locating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _locating ? null : _useMyLocation,
          ),
          const Divider(height: 1),
          TextField(
            controller: _controller,
            autofocus: false,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            style: const TextStyle(color: _chipTextColor, fontSize: 18),
            decoration: const InputDecoration(
              hintText: 'Search city',
              hintStyle: TextStyle(color: _chipMutedColor),
              border: InputBorder.none,
            ),
          ),
          const SizedBox(height: 8),
          if (message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 14,
                  color: _error != null ? const Color(0xFFE0A38B) : _chipMutedColor,
                ),
              ),
            ),
          if (_results.isNotEmpty)
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final city = _results[index];
                  return ListTile(
                    title: Text(
                      city.name,
                      style: const TextStyle(color: _chipTextColor),
                    ),
                    subtitle: Text(
                      city.label,
                      style: const TextStyle(color: _chipMutedColor),
                    ),
                    onTap: () => _select(city),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
