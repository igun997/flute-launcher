import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../runtime/agent_runtime.dart';
import 'chat_bubbles.dart';

enum _Source { photo, camera, video, file }

/// What the dock's round button does right now.
enum _Action { voice, send, stop }

/// The message box at the bottom: attachments, slash hints and one dock with `+`, the text and the
/// round button (mic while empty, send with text, stop while a reply runs).
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.busy,
    required this.hints,
    required this.onSend,
    required this.onStop,
    required this.onVoice,
    this.controller,
    this.header,
  });

  final bool busy;

  /// Slash commands the runtime understands, without the leading `/`.
  final List<String> hints;
  final void Function(String text, List<Attachment> attachments) onSend;
  final VoidCallback onStop;
  final VoidCallback onVoice;

  /// Text box owned by the parent, so it can fill the box (suggestions). Optional.
  final TextEditingController? controller;

  /// A quiet row shown above the dock, such as the model in use. Optional.
  final Widget? header;

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

  void _voice() {
    HapticFeedback.selectionClick();
    widget.onVoice();
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
          padding: const EdgeInsets.fromLTRB(0, FluteSpace.sm, FluteSpace.sm, 0),
          child: AttachmentThumb(attachment: attachment, size: 64, onRemove: onRemove),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final matches = _slashMatches;
    final busy = widget.busy;
    final header = widget.header;
    final action = busy ? _Action.stop : (_canSend ? _Action.send : _Action.voice);
    final onAction = switch (action) {
      _Action.stop => _stop,
      _Action.send => _submit,
      _Action.voice => _voice,
    };
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(FluteSpace.md, FluteSpace.xs, FluteSpace.md, FluteSpace.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) Align(alignment: Alignment.centerLeft, child: header),
            AnimatedSize(
              duration: motion(context, 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: matches.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(bottom: FluteSpace.sm),
                      child: Wrap(
                        spacing: FluteSpace.sm,
                        runSpacing: FluteSpace.sm,
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
                  padding: const EdgeInsets.only(left: FluteSpace.xs),
                  itemBuilder: (_, index, animation) {
                    final attachment = _attachments[index];
                    return _trayItem(attachment, animation, onRemove: () => _removeAttachment(attachment));
                  },
                ),
              ),
            ),
            // One surface for the whole dock: the field has no fill or border of its own.
            AnimatedSize(
              duration: motion(context, 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: DecoratedBox(
                decoration: fluteSurface(color: FluteColors.surfaceHigh, radius: FluteRadius.xl),
                child: Padding(
                  padding: const EdgeInsets.all(FluteSpace.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Attach',
                        onPressed: busy ? null : _showAttachMenu,
                        icon: const Icon(Icons.add, color: FluteColors.textSecondary),
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
                          style: FluteText.body.copyWith(fontSize: 16, height: 1.35, color: FluteColors.text),
                          decoration: InputDecoration(
                            hintText: 'Ask Flute',
                            hintStyle: FluteText.body.copyWith(fontSize: 16, height: 1.35, color: FluteColors.muted),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                        ),
                      ),
                      const SizedBox(width: FluteSpace.xs),
                      _DockAction(action: action, onPressed: onAction),
                    ],
                  ),
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
      title: Text(label, style: FluteText.body.copyWith(fontSize: 16)),
      onTap: () => Navigator.of(context).pop(source),
    );
  }
}

/// The dock's round button. Its states cross-fade. Send is the signature gradient with a soft glow,
/// the one glowing thing on the screen; mic and stop are neutral.
class _DockAction extends StatelessWidget {
  const _DockAction({required this.action, required this.onPressed});

  final _Action action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final send = action == _Action.send;
    final (icon, label, color) = switch (action) {
      _Action.voice => (Icons.mic_none_rounded, 'Voice', FluteColors.text),
      _Action.send => (Icons.arrow_upward_rounded, 'Send', FluteColors.onAccent),
      _Action.stop => (Icons.stop_rounded, 'Stop', FluteColors.text),
    };
    return Tooltip(
      message: label,
      child: SizedBox(
        width: 44,
        height: 44,
        child: AnimatedSwitcher(
          duration: motion(context, 200),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: Tween<double>(begin: 0.85, end: 1).animate(animation), child: child),
          ),
          child: DecoratedBox(
            key: ValueKey(action),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: send ? FluteGradients.signature : null,
              color: send ? null : FluteColors.surfaceTop,
              boxShadow: send
                  ? [BoxShadow(color: FluteColors.accent.withValues(alpha: 0.35), blurRadius: 16)]
                  : null,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPressed,
                child: Center(child: Icon(icon, size: 20, color: color)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
