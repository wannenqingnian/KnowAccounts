import 'dart:typed_data';
import 'models.dart';

const maxAttachments = 5;
const maxAttachmentBytes = 4 * 1024 * 1024;

class ImageAttachment {
  const ImageAttachment({
    required this.id,
    required this.name,
    required this.data,
  });
  final String id, name;
  final Uint8List data;
  void validate() {
    final png =
        data.length >= 24 &&
        data[0] == 137 &&
        data[1] == 80 &&
        data[2] == 78 &&
        data[3] == 71 &&
        data[4] == 13 &&
        data[5] == 10 &&
        data[6] == 26 &&
        data[7] == 10;
    final jpeg =
        data.length >= 4 && data[0] == 255 && data[1] == 216 && data[2] == 255;
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id) ||
        name.trim().isEmpty ||
        name.length > 120 ||
        data.length > maxAttachmentBytes ||
        (!png && !jpeg)) {
      throw const LedgerException('图片无效，仅支持不超过4 MB的PNG/JPEG图片');
    }
    final dimensions = png ? _pngDimensions(data) : _jpegDimensions(data);
    if (dimensions == null) throw const LedgerException('图片编码无效');
    final (w, h) = dimensions;
    if (w == 0 || h == 0 || w > 10000 || h > 10000 || w * h > 24000000) {
      throw const LedgerException('图片尺寸过大');
    }
  }
}

(int, int)? _pngDimensions(Uint8List data) {
  if (data.length < 33 ||
      data[12] != 73 ||
      data[13] != 72 ||
      data[14] != 68 ||
      data[15] != 82) {
    return null;
  }
  final bytes = ByteData.sublistView(data);
  if (bytes.getUint32(8) != 13) return null;
  return (bytes.getUint32(16), bytes.getUint32(20));
}

(int, int)? _jpegDimensions(Uint8List data) {
  var offset = 2;
  while (offset + 3 < data.length) {
    if (data[offset++] != 255) return null;
    while (offset < data.length && data[offset] == 255) {
      offset++;
    }
    if (offset >= data.length) return null;
    final marker = data[offset++];
    if (marker == 217 || marker == 218) return null;
    if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
    if (offset + 2 > data.length) return null;
    final length = (data[offset] << 8) | data[offset + 1];
    if (length < 2 || offset + length > data.length) return null;
    if ([
      192,
      193,
      194,
      195,
      197,
      198,
      199,
      201,
      202,
      203,
      205,
      206,
      207,
    ].contains(marker)) {
      if (length < 8) return null;
      final height = (data[offset + 3] << 8) | data[offset + 4];
      final width = (data[offset + 5] << 8) | data[offset + 6];
      return (width, height);
    }
    offset += length;
  }
  return null;
}
