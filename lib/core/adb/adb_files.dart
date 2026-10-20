import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/core/utils/shell_file_ops.dart';
import 'package:server_box/data/model/file/file_backend.dart';
import 'package:server_box/src/rust/api/files.dart' as files;


/// ADB sync v1 transfers bytes without shell quoting, base64 or whole-file
/// buffering. Metadata changes use the shared, quoted POSIX commands.
class AdbFileBackend implements FileBackend {
  AdbFileBackend(this.connection);
  final AdbConnection connection;
  bool _closed = false;
  final _active = <AdbStream>{};
  @override
  FileBackendTraits get traits => const FileBackendTraits(permissions: true, symlinks: true);
  @override
  Future<List<String>> reachableRoots() async => const ['/sdcard', '/data/local/tmp'];
  void _check() { if (_closed || connection.closed) throw StateError('ADB files closed'); }
  Future<void> _command(String command) async {
    _check();
    final result = await AdbExec(connection).run(command);
    if (!result.succeeded || result.outputIncomplete) throw StateError(result.combined);
  }
  Future<_SyncReader> _open() async {
    _check();
    final stream = await connection.open('sync:');
    if (_closed) { connection.release(stream); throw StateError('ADB files closed'); }
    _active.add(stream);
    return _SyncReader(stream);
  }
  void _release(_SyncReader reader) {
    reader.close(); _active.remove(reader.stream); connection.release(reader.stream);
  }
  @override
  Future<List<FileEntry>> list(String path) async {
    final reader = await _open();
    try {
      await reader.send('LIST', utf8.encode(path));
      final entries = <FileEntry>[];
      while (true) {
        final id = await reader.id();
        if (id == 'FAIL') throw await reader.failure();
        final header = ByteData.sublistView(await reader.take(16));
        if (id == 'DONE') return entries;
        if (id != 'DENT') throw const FormatException('Invalid ADB directory response');
        final length = header.getUint32(12, Endian.little);
        if (length > 4096 || entries.length >= 100000) throw const FormatException('ADB directory exceeds limit');
        final name = utf8.decode(await reader.take(length), allowMalformed: true);
        if (name == '.' || name == '..') continue;
        if (name.contains('/') || name.contains('\u0000')) throw const FormatException('Invalid ADB filename');
        final mode = header.getUint32(0, Endian.little);
        final kind = switch (mode & 0xf000) { 0x4000 => FileKind.dir, 0xa000 => FileKind.link, 0x8000 => FileKind.file, _ => FileKind.other };
        entries.add(FileEntry(name: name, kind: kind, size: header.getUint32(4, Endian.little),
          mode: mode & kFilePermMask, modified: DateTime.fromMillisecondsSinceEpoch(header.getUint32(8, Endian.little) * 1000)));
      }
    } finally { _release(reader); }
  }
  @override
  Future<FileEntry?> stat(String path) async {
    _check();
    final result = await AdbExec(connection).run(shellStatCommand(path));
    if (result.exitCode == kShellStatAbsent) return null;
    if (!result.succeeded || result.outputIncomplete) throw StateError(result.combined);
    final entries = parseShellFileRecords(result.stdout);
    if (entries.isEmpty) throw StateError('ADB stat returned no record');
    return entries.single;
  }
  @override
  Future<void> mkdir(String path) => _command(files.filesMkdirCommand(path: path, parents: false));
  @override
  Future<void> remove(String path, {bool recursive = false}) => _command(files.filesRemoveCommand(path: path, recursive: recursive, force: false));
  @override
  Future<void> rename(String from, String to) => _command(shellRenameCommand(from, to));
  @override
  Future<void> chmod(String path, int mode) => _command(files.filesChmodCommand(path: path, mode: mode));
  @override
  Stream<List<int>> read(String path, {int offset = 0}) async* {
    if (offset < 0) throw const FormatException('Negative file offset');
    final reader = await _open();
    var skip = offset;
    try {
      await reader.send('RECV', utf8.encode(path));
      while (true) {
        final id = await reader.id();
        if (id == 'FAIL') throw await reader.failure();
        final length = await reader.length();
        if (id == 'DONE') return;
        if (id != 'DATA' || length > 65536) throw const FormatException('Invalid ADB file response');
        final data = await reader.take(length);
        if (skip >= data.length) { skip -= data.length; continue; }
        yield data.sublist(skip); skip = 0;
      }
    } finally { _release(reader); }
  }
  @override
  Future<void> write(String path, Stream<List<int>> data, {int? size, void Function(String staging)? onStaging, Stream<List<int>> Function()? replayData}) async {
    final staging = stagingNameFor(path);
    onStaging?.call(staging);
    final reader = await _open();
    var committed = false;
    try {
      await reader.send('SEND', utf8.encode('$staging,33188'));
      var count = 0;
      await for (final chunk in data) {
        _check();
        for (var at = 0; at < chunk.length; at += 65536) {
          final bytes = chunk.sublist(at, (at + 65536).clamp(0, chunk.length));
          await reader.send('DATA', bytes); count += bytes.length;
        }
      }
      if (size != null && count != size) throw StateError('ADB upload length changed');
      await reader.header('DONE', DateTime.now().millisecondsSinceEpoch ~/ 1000);
      final id = await reader.id();
      if (id == 'FAIL') throw await reader.failure();
      if (id != 'OKAY' || await reader.length() != 0) throw const FormatException('Invalid ADB upload result');
      await carryModeToStaging(this, staging, path);
      await rename(staging, path);
      committed = true;
    } finally {
      _release(reader);
      if (!committed && !_closed && !connection.closed) {
        try { await remove(staging); } catch (_) {}
      }
    }
  }
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final stream in _active.toList()) { connection.release(stream); }
    _active.clear();
  }
}

class _SyncReader {
  _SyncReader(this.stream) : _iterator = StreamIterator(stream.bytes);
  final AdbStream stream;
  final StreamIterator<Uint8List> _iterator;
  Uint8List _pending = Uint8List(0);
  Future<Uint8List> take(int count) async {
    if (count > 1024 * 1024) throw const FormatException('ADB sync frame exceeds limit');
    final builder = BytesBuilder(copy: false);
    while (builder.length < count) {
      if (_pending.isEmpty) {
        if (!await _iterator.moveNext().timeout(const Duration(seconds: 30))) throw StateError('ADB sync ended early');
        _pending = _iterator.current;
      }
      final n = (count - builder.length).clamp(0, _pending.length);
      builder.add(_pending.sublist(0, n)); _pending = _pending.sublist(n);
    }
    return builder.takeBytes();
  }
  Future<String> id() async => ascii.decode(await take(4));
  Future<int> length() async => ByteData.sublistView(await take(4)).getUint32(0, Endian.little);
  Future<StateError> failure() async => StateError(utf8.decode(await take(await length()), allowMalformed: true));
  Future<void> header(String id, int length) async {
    final bytes = Uint8List(8)..setRange(0, 4, ascii.encode(id));
    ByteData.sublistView(bytes).setUint32(4, length, Endian.little);
    await stream.write(bytes);
  }
  Future<void> send(String id, List<int> bytes) async { await header(id, bytes.length); await stream.write(bytes); }
  void close() { stream.close(); unawaited(_iterator.cancel()); }
}
