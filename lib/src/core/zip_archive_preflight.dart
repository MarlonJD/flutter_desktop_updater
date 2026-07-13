import "dart:convert";
import "dart:io";
import "dart:math" as math;
import "dart:typed_data";

import "package:desktop_updater/src/io/archive_path.dart";

const _eocdSignature = 0x06054b50;
const _zip64EocdSignature = 0x06064b50;
const _zip64LocatorSignature = 0x07064b50;
const _centralFileHeaderSignature = 0x02014b50;
const _localFileHeaderSignature = 0x04034b50;
const _dataDescriptorSignature = 0x08074b50;
const _zip64ExtraFieldId = 0x0001;
const _maximumSignedInt64 = 0x7fffffffffffffff;

/// Validates ZIP central-directory metadata without decompressing entries.
Future<void> preflightZipArchive({
  required File archiveFile,
  required int maximumArchiveEntries,
  required int maximumUncompressedBytes,
  required int maximumSingleEntryBytes,
  bool rejectSymlinks = false,
}) async {
  final fileLength = await archiveFile.length();
  if (fileLength < 22) {
    throw const FormatException("ZIP end-of-central-directory is missing.");
  }

  final input = await archiveFile.open();
  try {
    final eocd = await _readEndOfCentralDirectory(input, fileLength);
    final directory = await _readDirectoryLocation(input, eocd);
    if (directory.entries > maximumArchiveEntries) {
      throw FormatException(
        "ZIP contains ${directory.entries} entries; limit is "
        "$maximumArchiveEntries.",
      );
    }
    if (_overflowsSignedInt64(directory.offset) ||
        _overflowsSignedInt64(directory.size)) {
      throw const FormatException("ZIP64 directory metadata overflows.");
    }
    final directoryEnd = directory.offset + directory.size;
    if (directory.offset < 0 ||
        directoryEnd < directory.offset ||
        directoryEnd > directory.boundary) {
      throw const FormatException("ZIP central-directory range is invalid.");
    }

    var cursor = directory.offset;
    var totalUncompressedBytes = 0;
    final localRecords = <_LocalRecord>[];
    for (var index = 0; index < directory.entries; index += 1) {
      if (cursor + 46 > directoryEnd) {
        throw const FormatException("ZIP central directory is truncated.");
      }
      final header = await _readAt(input, cursor, 46);
      if (_uint32(header, 0) != _centralFileHeaderSignature) {
        throw const FormatException("ZIP central-file header is malformed.");
      }

      final versionMadeBy = _uint16(header, 4);
      final generalPurposeFlags = _uint16(header, 8);
      final compressionMethod = _uint16(header, 10);
      final crc32 = _uint32(header, 16);
      final compressed32 = _uint32(header, 20);
      final uncompressed32 = _uint32(header, 24);
      final nameLength = _uint16(header, 28);
      final extraLength = _uint16(header, 30);
      final commentLength = _uint16(header, 32);
      final diskStart16 = _uint16(header, 34);
      final externalAttributes = _uint32(header, 38);
      final localOffset32 = _uint32(header, 42);
      final variableLength = nameLength + extraLength + commentLength;
      if (cursor + 46 + variableLength > directoryEnd) {
        throw const FormatException("ZIP central-file metadata is truncated.");
      }
      final nameBytes = await _readAt(input, cursor + 46, nameLength);
      final extra = await _readAt(input, cursor + 46 + nameLength, extraLength);
      final needsUncompressed = uncompressed32 == 0xffffffff;
      final needsCompressed = compressed32 == 0xffffffff;
      final needsLocalOffset = localOffset32 == 0xffffffff;
      final needsDiskStart = diskStart16 == 0xffff;
      final zip64 = _readZip64Extra(
        extra,
        needsUncompressed: needsUncompressed,
        needsCompressed: needsCompressed,
        needsLocalOffset: needsLocalOffset,
        needsDiskStart: needsDiskStart,
      );
      final uncompressedBytes =
          needsUncompressed ? zip64.uncompressed! : uncompressed32;
      final compressedBytes =
          needsCompressed ? zip64.compressed! : compressed32;
      final localOffset = needsLocalOffset ? zip64.localOffset! : localOffset32;
      final diskStart = needsDiskStart ? zip64.diskStart! : diskStart16;
      if (diskStart != 0) {
        throw const FormatException("Multi-disk ZIP archives are unsupported.");
      }
      if (_overflowsSignedInt64(uncompressedBytes) ||
          _overflowsSignedInt64(compressedBytes) ||
          _overflowsSignedInt64(localOffset)) {
        throw const FormatException("ZIP64 entry metadata overflows.");
      }
      if (uncompressedBytes > maximumSingleEntryBytes) {
        throw FormatException(
          "ZIP entry exceeds the $maximumSingleEntryBytes-byte limit.",
        );
      }
      totalUncompressedBytes += uncompressedBytes;
      if (totalUncompressedBytes > maximumUncompressedBytes) {
        throw FormatException(
          "ZIP entries exceed the $maximumUncompressedBytes-byte cumulative "
          "limit.",
        );
      }

      final name = generalPurposeFlags & 0x0800 != 0
          ? utf8.decode(nameBytes, allowMalformed: false)
          : String.fromCharCodes(nameBytes);
      normalizeArchivePath(name);
      final isUnixEntry = versionMadeBy >> 8 == 3;
      final fileType = (externalAttributes >> 16) & 0xf000;
      if (rejectSymlinks && isUnixEntry && fileType == 0xa000) {
        throw FormatException("ZIP entry is a symbolic link: $name");
      }
      localRecords.add(
        _LocalRecord(
          offset: localOffset,
          generalPurposeFlags: generalPurposeFlags,
          compressionMethod: compressionMethod,
          crc32: crc32,
          compressedBytes: compressedBytes,
          uncompressedBytes: uncompressedBytes,
          nameBytes: nameBytes,
          usesZip64Descriptor: needsUncompressed || needsCompressed,
        ),
      );
      cursor += 46 + variableLength;
    }
    if (cursor != directoryEnd) {
      throw const FormatException(
        "ZIP central-directory size is inconsistent.",
      );
    }

    localRecords.sort((first, second) => first.offset.compareTo(second.offset));
    for (var index = 0; index < localRecords.length; index += 1) {
      final record = localRecords[index];
      final nextStructureOffset = index + 1 < localRecords.length
          ? localRecords[index + 1].offset
          : directory.offset;
      if (record.offset == nextStructureOffset) {
        throw const FormatException("ZIP local-file offsets overlap.");
      }
      await _validateLocalRecord(
        input,
        record,
        nextStructureOffset: nextStructureOffset,
      );
    }
  } on FormatException {
    rethrow;
  } on FileSystemException catch (error) {
    throw FormatException("Unable to read ZIP metadata: ${error.message}");
  } on RangeError {
    throw const FormatException("ZIP metadata contains an invalid range.");
  } finally {
    await input.close();
  }
}

Future<_EndOfCentralDirectory> _readEndOfCentralDirectory(
  RandomAccessFile input,
  int fileLength,
) async {
  final tailLength = math.min(fileLength, 22 + 0xffff);
  final tailOffset = fileLength - tailLength;
  final tail = await _readAt(input, tailOffset, tailLength);
  for (var index = tail.length - 22; index >= 0; index -= 1) {
    if (_uint32(tail, index) != _eocdSignature) {
      continue;
    }
    final commentLength = _uint16(tail, index + 20);
    if (tailOffset + index + 22 + commentLength != fileLength) {
      continue;
    }
    final diskNumber = _uint16(tail, index + 4);
    final directoryDisk = _uint16(tail, index + 6);
    final entriesOnDisk = _uint16(tail, index + 8);
    final entries = _uint16(tail, index + 10);
    if (diskNumber != 0 || directoryDisk != 0 || entriesOnDisk != entries) {
      throw const FormatException("Multi-disk ZIP archives are unsupported.");
    }
    return _EndOfCentralDirectory(
      offset: tailOffset + index,
      entries: entries,
      size: _uint32(tail, index + 12),
      directoryOffset: _uint32(tail, index + 16),
    );
  }
  throw const FormatException("ZIP end-of-central-directory is malformed.");
}

Future<_DirectoryLocation> _readDirectoryLocation(
  RandomAccessFile input,
  _EndOfCentralDirectory eocd,
) async {
  final needsZip64 = eocd.entries == 0xffff ||
      eocd.size == 0xffffffff ||
      eocd.directoryOffset == 0xffffffff;
  if (!needsZip64) {
    return _DirectoryLocation(
      entries: eocd.entries,
      size: eocd.size,
      offset: eocd.directoryOffset,
      boundary: eocd.offset,
    );
  }
  if (eocd.offset < 20) {
    throw const FormatException("ZIP64 locator is missing.");
  }
  final locator = await _readAt(input, eocd.offset - 20, 20);
  if (_uint32(locator, 0) != _zip64LocatorSignature ||
      _uint32(locator, 4) != 0 ||
      _uint32(locator, 16) != 1) {
    throw const FormatException("ZIP64 locator is malformed.");
  }
  final zip64Offset = _uint64(locator, 8);
  if (_overflowsSignedInt64(zip64Offset) ||
      zip64Offset + 56 > eocd.offset - 20) {
    throw const FormatException("ZIP64 directory record range is invalid.");
  }
  final zip64 = await _readAt(input, zip64Offset, 56);
  final recordSize = _uint64(zip64, 4);
  final recordEnd = zip64Offset + 12 + recordSize;
  if (_uint32(zip64, 0) != _zip64EocdSignature ||
      recordSize < 44 ||
      _overflowsSignedInt64(recordSize) ||
      recordEnd < zip64Offset ||
      recordEnd > eocd.offset - 20 ||
      _uint32(zip64, 16) != 0 ||
      _uint32(zip64, 20) != 0) {
    throw const FormatException("ZIP64 directory record is malformed.");
  }
  final entriesOnDisk = _uint64(zip64, 24);
  final entries = _uint64(zip64, 32);
  if (entriesOnDisk != entries || _overflowsSignedInt64(entries)) {
    throw const FormatException("ZIP64 entry count is invalid.");
  }
  return _DirectoryLocation(
    entries: entries,
    size: _uint64(zip64, 40),
    offset: _uint64(zip64, 48),
    boundary: zip64Offset,
  );
}

_Zip64Extra _readZip64Extra(
  Uint8List extra, {
  required bool needsUncompressed,
  required bool needsCompressed,
  required bool needsLocalOffset,
  required bool needsDiskStart,
}) {
  if (!needsUncompressed &&
      !needsCompressed &&
      !needsLocalOffset &&
      !needsDiskStart) {
    return const _Zip64Extra();
  }
  var cursor = 0;
  while (cursor < extra.length) {
    if (cursor + 4 > extra.length) {
      throw const FormatException("ZIP extra field is truncated.");
    }
    final id = _uint16(extra, cursor);
    final size = _uint16(extra, cursor + 2);
    cursor += 4;
    if (cursor + size > extra.length) {
      throw const FormatException("ZIP extra field length is invalid.");
    }
    if (id != _zip64ExtraFieldId) {
      cursor += size;
      continue;
    }
    final end = cursor + size;
    int? uncompressed;
    int? compressed;
    int? localOffset;
    int? diskStart;
    if (needsUncompressed) {
      if (cursor + 8 > end) {
        throw const FormatException("ZIP64 uncompressed size is missing.");
      }
      uncompressed = _uint64(extra, cursor);
      cursor += 8;
    }
    if (needsCompressed) {
      if (cursor + 8 > end) {
        throw const FormatException("ZIP64 compressed size is missing.");
      }
      compressed = _uint64(extra, cursor);
      cursor += 8;
    }
    if (needsLocalOffset) {
      if (cursor + 8 > end) {
        throw const FormatException("ZIP64 local-header offset is missing.");
      }
      localOffset = _uint64(extra, cursor);
      cursor += 8;
    }
    if (needsDiskStart) {
      if (cursor + 4 > end) {
        throw const FormatException("ZIP64 disk number is missing.");
      }
      diskStart = _uint32(extra, cursor);
    }
    return _Zip64Extra(
      uncompressed: uncompressed,
      compressed: compressed,
      localOffset: localOffset,
      diskStart: diskStart,
    );
  }
  throw const FormatException("Required ZIP64 entry metadata is missing.");
}

Future<void> _validateLocalRecord(
  RandomAccessFile input,
  _LocalRecord record, {
  required int nextStructureOffset,
}) async {
  if (record.offset + 30 > nextStructureOffset) {
    throw const FormatException("ZIP local-file header range is invalid.");
  }
  final header = await _readAt(input, record.offset, 30);
  if (_uint32(header, 0) != _localFileHeaderSignature) {
    throw const FormatException("ZIP local-file header is malformed.");
  }
  final generalPurposeFlags = _uint16(header, 6);
  final compressionMethod = _uint16(header, 8);
  final crc32 = _uint32(header, 14);
  final compressed32 = _uint32(header, 18);
  final uncompressed32 = _uint32(header, 22);
  final nameLength = _uint16(header, 26);
  final extraLength = _uint16(header, 28);
  if (generalPurposeFlags != record.generalPurposeFlags) {
    throw const FormatException(
      "ZIP local and central general-purpose flags differ.",
    );
  }
  if (compressionMethod != record.compressionMethod) {
    throw const FormatException(
      "ZIP local and central compression methods differ.",
    );
  }
  final contentOffset = record.offset + 30 + nameLength + extraLength;
  final contentEnd = contentOffset + record.compressedBytes;
  if (contentOffset < record.offset || contentEnd > nextStructureOffset) {
    throw const FormatException("ZIP local-file data range is invalid.");
  }
  final localName = await _readAt(input, record.offset + 30, nameLength);
  if (!_equalBytes(localName, record.nameBytes)) {
    throw const FormatException("ZIP local and central filenames differ.");
  }
  final localExtra = await _readAt(
    input,
    record.offset + 30 + nameLength,
    extraLength,
  );
  final needsUncompressed = uncompressed32 == 0xffffffff;
  final needsCompressed = compressed32 == 0xffffffff;
  final zip64 = _readZip64Extra(
    localExtra,
    needsUncompressed: needsUncompressed,
    needsCompressed: needsCompressed,
    needsLocalOffset: false,
    needsDiskStart: false,
  );
  final uncompressedBytes =
      needsUncompressed ? zip64.uncompressed! : uncompressed32;
  final compressedBytes = needsCompressed ? zip64.compressed! : compressed32;
  if (_overflowsSignedInt64(uncompressedBytes) ||
      _overflowsSignedInt64(compressedBytes)) {
    throw const FormatException("ZIP64 local entry metadata overflows.");
  }
  final usesDataDescriptor = generalPurposeFlags & 0x08 != 0;
  if (usesDataDescriptor) {
    if (crc32 != 0 && crc32 != record.crc32) {
      throw const FormatException("ZIP local and central CRC values differ.");
    }
    _validateDescriptorLocalSize(
      local32: compressed32,
      resolvedLocal: compressedBytes,
      central: record.compressedBytes,
      label: "compressed",
    );
    _validateDescriptorLocalSize(
      local32: uncompressed32,
      resolvedLocal: uncompressedBytes,
      central: record.uncompressedBytes,
      label: "uncompressed",
    );
    await _validateDataDescriptor(
      input,
      record,
      offset: contentEnd,
      nextStructureOffset: nextStructureOffset,
    );
    return;
  }

  if (crc32 != record.crc32) {
    throw const FormatException("ZIP local and central CRC values differ.");
  }
  if (compressedBytes != record.compressedBytes) {
    throw const FormatException(
      "ZIP local and central compressed sizes differ.",
    );
  }
  if (uncompressedBytes != record.uncompressedBytes) {
    throw const FormatException(
      "ZIP local and central uncompressed sizes differ.",
    );
  }
}

Future<void> _validateDataDescriptor(
  RandomAccessFile input,
  _LocalRecord record, {
  required int offset,
  required int nextStructureOffset,
}) async {
  final unsignedLength = record.usesZip64Descriptor ? 20 : 12;
  final signedLength = unsignedLength + 4;
  final available = nextStructureOffset - offset;
  if (available < unsignedLength) {
    throw const FormatException("ZIP data descriptor is truncated.");
  }

  final bytes = await _readAt(input, offset, math.min(available, signedLength));
  final firstValue = _uint32(bytes, 0);
  final candidates = <_DataDescriptorCandidate>[];
  if (firstValue == _dataDescriptorSignature && bytes.length >= signedLength) {
    candidates.add(
      _readDataDescriptorCandidate(
        bytes,
        hasSignature: true,
        usesZip64: record.usesZip64Descriptor,
      ),
    );
  }
  candidates.add(
    _readDataDescriptorCandidate(
      bytes,
      hasSignature: false,
      usesZip64: record.usesZip64Descriptor,
    ),
  );

  for (final candidate in candidates) {
    if (!_overflowsSignedInt64(candidate.compressedBytes) &&
        !_overflowsSignedInt64(candidate.uncompressedBytes) &&
        candidate.crc32 == record.crc32 &&
        candidate.compressedBytes == record.compressedBytes &&
        candidate.uncompressedBytes == record.uncompressedBytes) {
      return;
    }
  }
  if (candidates.any(
    (candidate) =>
        _overflowsSignedInt64(candidate.compressedBytes) ||
        _overflowsSignedInt64(candidate.uncompressedBytes),
  )) {
    throw const FormatException("ZIP64 data descriptor metadata overflows.");
  }
  if (firstValue == _dataDescriptorSignature && bytes.length < signedLength) {
    throw const FormatException("ZIP data descriptor is truncated.");
  }
  throw const FormatException(
    "ZIP data descriptor and central metadata differ.",
  );
}

_DataDescriptorCandidate _readDataDescriptorCandidate(
  Uint8List bytes, {
  required bool hasSignature,
  required bool usesZip64,
}) {
  final crcOffset = hasSignature ? 4 : 0;
  final compressedOffset = crcOffset + 4;
  final uncompressedOffset = compressedOffset + (usesZip64 ? 8 : 4);
  return _DataDescriptorCandidate(
    crc32: _uint32(bytes, crcOffset),
    compressedBytes: usesZip64
        ? _uint64(bytes, compressedOffset)
        : _uint32(bytes, compressedOffset),
    uncompressedBytes: usesZip64
        ? _uint64(bytes, uncompressedOffset)
        : _uint32(bytes, uncompressedOffset),
  );
}

void _validateDescriptorLocalSize({
  required int local32,
  required int resolvedLocal,
  required int central,
  required String label,
}) {
  if (local32 != 0 && resolvedLocal != central) {
    throw FormatException(
      "ZIP local and central $label sizes differ.",
    );
  }
}

Future<Uint8List> _readAt(
  RandomAccessFile input,
  int offset,
  int length,
) async {
  if (offset < 0 || length < 0 || offset > _maximumSignedInt64) {
    throw const FormatException("ZIP metadata range is invalid.");
  }
  await input.setPosition(offset);
  final bytes = await input.read(length);
  if (bytes.length != length) {
    throw const FormatException("ZIP metadata is truncated.");
  }
  return bytes;
}

int _uint16(Uint8List bytes, int offset) {
  return ByteData.sublistView(bytes, offset, offset + 2)
      .getUint16(0, Endian.little);
}

int _uint32(Uint8List bytes, int offset) {
  return ByteData.sublistView(bytes, offset, offset + 4)
      .getUint32(0, Endian.little);
}

int _uint64(Uint8List bytes, int offset) {
  return ByteData.sublistView(bytes, offset, offset + 8)
      .getUint64(0, Endian.little);
}

bool _equalBytes(List<int> first, List<int> second) {
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index += 1) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}

bool _overflowsSignedInt64(int value) {
  return value < 0 || value > _maximumSignedInt64;
}

class _EndOfCentralDirectory {
  const _EndOfCentralDirectory({
    required this.offset,
    required this.entries,
    required this.size,
    required this.directoryOffset,
  });

  final int offset;
  final int entries;
  final int size;
  final int directoryOffset;
}

class _DirectoryLocation {
  const _DirectoryLocation({
    required this.entries,
    required this.size,
    required this.offset,
    required this.boundary,
  });

  final int entries;
  final int size;
  final int offset;
  final int boundary;
}

class _Zip64Extra {
  const _Zip64Extra({
    this.uncompressed,
    this.compressed,
    this.localOffset,
    this.diskStart,
  });

  final int? uncompressed;
  final int? compressed;
  final int? localOffset;
  final int? diskStart;
}

class _LocalRecord {
  const _LocalRecord({
    required this.offset,
    required this.generalPurposeFlags,
    required this.compressionMethod,
    required this.crc32,
    required this.compressedBytes,
    required this.uncompressedBytes,
    required this.nameBytes,
    required this.usesZip64Descriptor,
  });

  final int offset;
  final int generalPurposeFlags;
  final int compressionMethod;
  final int crc32;
  final int compressedBytes;
  final int uncompressedBytes;
  final Uint8List nameBytes;
  final bool usesZip64Descriptor;
}

class _DataDescriptorCandidate {
  const _DataDescriptorCandidate({
    required this.crc32,
    required this.compressedBytes,
    required this.uncompressedBytes,
  });

  final int crc32;
  final int compressedBytes;
  final int uncompressedBytes;
}
