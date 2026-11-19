import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../runtime/agent_runtime.dart';
import 'chat_bubbles.dart';

enum _Source { photo, camera, video, file }

/// The message box above the keyboard: text, attachments, slash hints and send or stop.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.busy,
    required this.hints,
    required this.onSend,
    required this.onStop,
    this.controller,
  });

  final bool busy;

  /// Slash commands the runtime understands, without the leading `/`.
  final List<String> hints;
  final void Function(String text, List<Attachment> attachments) onSend;
  final VoidCallback onStop;

  /// Text box owned by the parent, so it can fill the box (suggestions). Optional.
  final TextEditingController? controller;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late TextEditingController _text;
  late bool _ownsText;
  final _focus = FocusNode();
  final List<Attachment> _attachments = [];
  final _trayKey = GlobalKey<AnimatedListState>();

  @override
  void initState() {
    super.initState();
    _adopt(widget.controller);
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _text.removeListener(_changed);
      if (_ownsText) _text.dispose();
      _adopt(widget.controller);
    }
  }

  void _adopt(TextEditingController? controller) {
    _text = controller ?? TextEditingController();
    _ownsText = controller == null;
    _text.addListener(_changed);
  }

  @override
  void dispose() {
    _text.removeListener(_changed);
    if (_ownsText) _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _canSend => _text.text.trim().isNotEmpty || _attachments.isNotEmpty;

  void _submit() {
    if (widget.busy || !_canSend) return;
    HapticFeedback.selectionClick();
    final text = _text.text.trim();
    final attachments = List<Attachment>.of(_attachments);
    _text.clear();
    _clearAttachments();
    widget.onSend(text, attachments);
  }

  void _stop() {
    HapticFeedback.lightImpact();
    widget.onStop();
  }

  /// Hints that match what follows the `/`. Empty unless the box starts with a slash.
  List<String> get _slashMatches {
    final value = _text.text;
    if (!value.startsWith('/') || value.contains('\n')) return const [];
    final query = value.substring(1).trim().toLowerCase();
    return [
      for (final hint in widget.hints)
        if (hint.toLowerCase().contains(query)) hint,
    ].take(4).toList();
  }

  void _useHint(String hint) {
    final text = '/$hint ';
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _focus.requestFocus();
  }

  Future<void> _showAttachMenu() async {
    final choice = await showModalBottomSheet<_Source>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SourceTile(icon: Icons.photo_library_outlined, label: 'Photo', source: _Source.photo),
            _SourceTile(icon: Icons.photo_camera_outlined, label: 'Camera', source: _Source.camera),
            _SourceTile(icon: Icons.videocam_outlined, label: 'Video', source: _Source.video),
            _SourceTile(icon: Icons.insert_drive_file_outlined, label: 'File', source: _Source.file),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _pick(choice);
  }

  Future<void> _pick(_Source source) async {
    try {
      final added = switch (source) {
        _Source.photo => await _image(ImageSource.gallery),
        _Source.camera => await _image(ImageSource.camera),
        _Source.video => await _video(),
        _Source.file => await _files(),
      };
      if (!mounted || added.isEmpty) return;
      _addAttachments(added);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't attach that. Try again.")),
      );
    }
  }

  Future<List<Attachment>> _image(ImageSource source) async {
    final file = await Flute.externalFlow(
      () => ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 85),
    );
    if (file == null) return const [];
    return [Attachment(kind: AttachmentKind.image, path: file.path, name: file.name)];
  }

  Future<List<Attachment>> _video() async {
    final file = await Flute.externalFlow(() => ImagePicker().pickVideo(source: ImageSource.gallery));
    if (file == null) return const [];
    return [Attachment(kind: AttachmentKind.video, path: file.path, name: file.name)];
  }

  Future<List<Attachment>> _files() async {
    final picked = await Flute.externalFlow(() => FilePicker.pickFiles());
    return [
      for (final file in picked)
        if (file.path != null) Attachment(kind: AttachmentKind.file, path: file.path!, name: file.name),
    ];
  }

  /// Adds thumbnails to the tray one by one, each one animating in.
  void _addAttachments(List<Attachment> added) {
    for (final attachment in added) {
      _attachments.add(attachment);
      _trayKey.currentState?.insertItem(_attachments.length - 1, duration: motion(context, 220));
    }
    setState(() {});
  }

  void _removeAttachment(Attachment attachment) {
    final index = _attachments.indexOf(attachment);
    if (index < 0) return;
    _attachments.removeAt(index);
    _trayKey.currentState?.removeItem(
      index,
      (_, animation) => _trayItem(attachment, animation),
      duration: motion(context, 200),
    );
    setState(() {});
  }

  void _clearAttachments() {
    for (var i = _attachments.length - 1; i >= 0; i--) {
      final attachment = _attachments.removeAt(i);
      _trayKey.currentState?.removeItem(
        i,
        (_, animation) => _trayItem(attachment, animation),
        duration: motion(context, 200),
      );
    }
    setState(() {});
  }

  Widget _trayItem(Attachment attachment, Animation<double> animation, {VoidCallback? onRemove}) {
    return SizeTransition(
      axis: Axis.horizontal,
      sizeFactor: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: FadeTransition(
        opacity: animation,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 8, 0),
          child: AttachmentThumb(attachment: attachment, size: 64, onRemove: onRemove),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final matches = _slashMatches;
    final busy = widget.busy;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedSize(
              duration: motion(context, 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: matches.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final hint in matches)
                            ActionChip(
                              label: Text('/$hint', style: const TextStyle(fontSize: 13)),
                              backgroundColor: FluteColors.surfaceHigh,
                              side: const BorderSide(color: FluteColors.line),
                              onPressed: () => _useHint(hint),
                            ),
                        ],
                      ),
                    ),
            ),
            // The tray stays in the tree so its list can animate thumbnails in and out.
            AnimatedSize(
              duration: motion(context, 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: _attachments.isEmpty ? 0 : 80,
                child: AnimatedList(
                  key: _trayKey,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 4),
                  itemBuilder: (_, index, animation) {
                    final attachment = _attachments[index];
                    return _trayItem(attachment, animation, onRemove: () => _removeAttachment(attachment));
                  },
                ),
              ),
            ),
            AnimatedSize(
              duration: motion(context, 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
                decoration: BoxDecoration(
                  color: FluteColors.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: FluteColors.line),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Attach',
                      onPressed: busy ? null : _showAttachMenu,
                      icon: const Icon(Icons.add_circle_outline, color: FluteColors.muted),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        cursorColor: FluteColors.accent,
                        style: const TextStyle(fontSize: 16, height: 1.35),
                        decoration: const InputDecoration(
                          hintText: 'Ask Flute',
                          hintStyle: TextStyle(color: FluteColors.muted),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _SendButton(
                      busy: busy,
                      enabled: _canSend,
                      onPressed: busy ? _stop : _submit,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.icon, required this.label, required this.source});

  final IconData icon;
  final String label;
  final _Source source;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      minLeadingWidth: 28,
      leading: Icon(icon, color: FluteColors.muted),
      title: Text(label, style: const TextStyle(fontSize: 16)),
      onTap: () => Navigator.of(context).pop(source),
    );
  }
}

/// Send becomes a stop square while a reply is running. Its states cross-fade.
class _SendButton extends StatelessWidget {
  const _SendButton({required this.busy, required this.enabled, required this.onPressed});

  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final active = busy || enabled;
    final background = !busy && enabled ? FluteColors.accent : FluteColors.surfaceHigh;
    final foreground = busy
        ? FluteColors.text
        : enabled
            ? const Color(0xFF00201B)
            : FluteColors.muted;
    final radius = BorderRadius.circular(busy ? 12 : 20);
    return SizedBox(
      width: 48,
      height: 48,
      child: Tooltip(
        message: busy ? 'Stop' : 'Send',
        child: Center(
          child: AnimatedContainer(
            duration: motion(context, 200),
            curve: Curves.easeOutCubic,
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: background, borderRadius: radius),
            child: Material(
              color: Colors.transparent,
              borderRadius: radius,
              child: InkWell(
                borderRadius: radius,
                onTap: active ? onPressed : null,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: motion(context, 180),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: Icon(
                      busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                      key: ValueKey(busy ? 'stop' : 'send'),
                      color: foreground,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
