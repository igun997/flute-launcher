import 'email_models.dart';

/// Newest previews kept in the merged summary.
const int emailLatestLimit = 10;

/// Marks "no refresh has completed yet".
final DateTime emailNeverFetched = DateTime.fromMillisecondsSinceEpoch(
  0,
  isUtc: true,
);

/// Outcome of fetching one account. Input to [mergeEmailSummary].
class EmailAccountResult {
  const EmailAccountResult({
    required this.accountId,
    required this.label,
    required this.fetchedAt,
    this.unread = 0,
    this.latest = const [],
    this.error,
  });

  final String accountId;
  final String label;
  final DateTime fetchedAt;
  final int unread;
  final List<EmailPreview> latest;

  /// Human-readable failure, already free of credentials. Null on success.
  final String? error;
}

/// Pure merge of per-account results: sums unread counts, keeps the newest
/// previews first (ties by account id, then uid), and joins per-account errors
/// as `label: error`.
EmailSummary mergeEmailSummary(
  Iterable<EmailAccountResult> results, {
  int limit = emailLatestLimit,
}) {
  var unread = 0;
  var fetchedAt = emailNeverFetched;
  final previews = <EmailPreview>[];
  final errors = <String>[];

  for (final result in results) {
    unread += result.unread;
    if (result.fetchedAt.isAfter(fetchedAt)) {
      fetchedAt = result.fetchedAt;
    }
    final error = result.error;
    if (error != null) {
      errors.add('${result.label}: $error');
    }
    previews.addAll(result.latest);
  }

  previews.sort(_newestFirst);

  return EmailSummary(
    unread: unread,
    latest: previews.take(limit).toList(growable: false),
    fetchedAt: fetchedAt,
    error: errors.isEmpty ? null : errors.join('; '),
  );
}

int _newestFirst(EmailPreview a, EmailPreview b) {
  final byDate = b.date.compareTo(a.date);
  if (byDate != 0) return byDate;
  final byAccount = a.accountId.compareTo(b.accountId);
  if (byAccount != 0) return byAccount;
  return a.uid.compareTo(b.uid);
}
