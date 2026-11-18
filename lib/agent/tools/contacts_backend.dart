import 'package:flutter_contacts/flutter_contacts.dart';

import 'tool_support.dart';

/// A contact as the tools see it: plain strings, no platform types. [name] is the full display name.
class ContactInfo {
  const ContactInfo({
    this.id,
    required this.name,
    this.phones = const [],
    this.emails = const [],
    this.company,
    this.note,
  });

  final String? id;
  final String name;
  final List<String> phones;
  final List<String> emails;
  final String? company;
  final String? note;
}

/// The device contacts, as the tools need them. Implemented by [DeviceContactsBackend]; tests use a
/// fake.
abstract class ContactsBackend {
  Future<bool> hasAccess();

  /// Shows the system dialog when access is missing. True when granted (or limited).
  Future<bool> requestAccess();

  /// Access is held, or was just granted.
  Future<bool> ensureAccess() async => await hasAccess() || await requestAccess();

  /// Every contact with its name, numbers, emails, company and note.
  Future<List<ContactInfo>> all();

  Future<ContactInfo?> get(String id);

  /// Returns the new contact's id.
  Future<String> create(ContactInfo contact);

  /// Writes name, numbers, emails, company and note. [ContactInfo.id] must be set.
  Future<void> update(ContactInfo contact);

  Future<void> delete(String id);
}

const Set<ContactProperty> _readProperties = <ContactProperty>{
  ContactProperty.name,
  ContactProperty.phone,
  ContactProperty.email,
  ContactProperty.organization,
  ContactProperty.note,
};

/// [ContactsBackend] over flutter_contacts.
class DeviceContactsBackend extends ContactsBackend {
  @override
  Future<bool> hasAccess() => FlutterContacts.permissions.has(PermissionType.readWrite);

  @override
  Future<bool> requestAccess() async {
    final status = await FlutterContacts.permissions.request(PermissionType.readWrite);
    return status == PermissionStatus.granted || status == PermissionStatus.limited;
  }

  @override
  Future<List<ContactInfo>> all() async {
    final contacts = await FlutterContacts.getAll(properties: _readProperties);
    return [for (final contact in contacts) _fromNative(contact)];
  }

  @override
  Future<ContactInfo?> get(String id) async {
    final contact = await FlutterContacts.get(id, properties: _readProperties);
    return contact == null ? null : _fromNative(contact);
  }

  @override
  Future<String> create(ContactInfo contact) => FlutterContacts.create(_toNative(contact));

  @override
  Future<void> update(ContactInfo contact) async {
    final id = contact.id;
    if (id == null) throw ArgumentError.value(contact, 'contact', 'Missing contact id');
    // flutter_contacts only writes the properties it fetched, and it needs their metadata to tell
    // existing rows from new ones, so the current contact is fetched and merged into.
    final existing = await FlutterContacts.get(id, properties: _readProperties);
    if (existing == null) throw ToolError('No contact with id $id.');
    await FlutterContacts.update(_toNative(contact, existing: existing));
  }

  @override
  Future<void> delete(String id) => FlutterContacts.delete(id);
}

ContactInfo _fromNative(Contact contact) {
  final organization = _firstOrNull(contact.organizations);
  final note = _firstOrNull(contact.notes);
  return ContactInfo(
    id: contact.id,
    name: _displayName(contact),
    phones: [for (final phone in contact.phones) phone.number],
    emails: [for (final email in contact.emails) email.address],
    company: _nonBlank(organization?.name),
    note: _nonBlank(note?.note),
  );
}

String _displayName(Contact contact) {
  final shown = contact.displayName?.trim();
  if (shown != null && shown.isNotEmpty) return shown;
  final name = contact.name;
  return [name?.first, name?.last]
      .whereType<String>()
      .where((part) => part.trim().isNotEmpty)
      .join(' ');
}

/// Builds the native contact. With [existing], native metadata and the parts the tools do not
/// edit (middle name, prefix, labels, job title) are carried over.
Contact _toNative(ContactInfo contact, {Contact? existing}) {
  final oldOrganization = existing == null ? null : _firstOrNull(existing.organizations);
  final oldNote = existing == null ? null : _firstOrNull(existing.notes);
  final company = _nonBlank(contact.company);
  final note = _nonBlank(contact.note);
  return Contact(
    id: existing?.id,
    name: _nameOf(contact, existing),
    phones: [
      for (final number in contact.phones)
        _existingBy(existing?.phones ?? const <Phone>[], (p) => p.number == number) ??
            Phone(number: number),
    ],
    emails: [
      for (final address in contact.emails)
        _existingBy(existing?.emails ?? const <Email>[], (e) => e.address == address) ??
            Email(address: address),
    ],
    organizations: company == null
        ? const []
        : [
            Organization(
              name: company,
              jobTitle: oldOrganization?.jobTitle,
              departmentName: oldOrganization?.departmentName,
            ),
          ],
    notes: note == null ? const [] : [Note(note: note, metadata: oldNote?.metadata)],
    metadata: existing?.metadata,
  );
}

/// The name as flutter_contacts stores it. The last word is the family name and the rest is the
/// given name, which covers the common case. An unchanged display name keeps the stored name.
Name? _nameOf(ContactInfo contact, Contact? existing) {
  final old = existing?.name;
  if (old != null && existing?.displayName == contact.name) return old;
  final words = contact.name.trim().split(RegExp(r'\s+'));
  if (words.isEmpty || words.first.isEmpty) throw const ToolError('name is required.');
  final hasLast = words.length > 1;
  return Name(
    first: hasLast ? words.sublist(0, words.length - 1).join(' ') : words.first,
    last: hasLast ? words.last : null,
    middle: old?.middle,
    prefix: old?.prefix,
    suffix: old?.suffix,
    nickname: old?.nickname,
    metadata: old?.metadata,
  );
}

T? _existingBy<T>(List<T> items, bool Function(T item) matches) {
  for (final item in items) {
    if (matches(item)) return item;
  }
  return null;
}

T? _firstOrNull<T>(List<T> items) => items.isEmpty ? null : items.first;

String? _nonBlank(String? value) => value == null || value.trim().isEmpty ? null : value.trim();
