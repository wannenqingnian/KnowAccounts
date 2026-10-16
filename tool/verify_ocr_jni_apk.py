"""Validate JNI class and method ABI in a release APK after shrinking.

Usage: python tool/verify_ocr_jni_apk.py /path/to/app-arm64-v8a-release.apk
Parses actual DEX class definitions and encoded methods, not just strings or
R8 mapping entries. Catches the 0.9.0 TensorInfo JNI constructor removal.
This is a packaging check, not an Android device inference test.
"""
import argparse
import re
import struct
import sys
import zipfile


def dex_definitions(data):
    if data[:4] != b'dex\n':
        raise ValueError('Unsupported DEX format')
    def u32(offset):
        return struct.unpack_from('<I', data, offset)[0]
    def uleb(offset):
        value = shift = 0
        while True:
            byte = data[offset]; offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value, offset
            shift += 7
            if shift > 35:
                raise ValueError('Invalid DEX ULEB128')
    strings = []
    for i in range(u32(0x38)):
        pointer = u32(u32(0x3c) + i * 4)
        _, pointer = uleb(pointer)
        strings.append(data[pointer:data.index(b'\0', pointer)].decode('utf-8', 'replace'))
    types = [strings[u32(u32(0x44) + i * 4)] for i in range(u32(0x40))]
    prototypes = []
    for i in range(u32(0x48)):
        _, return_type, parameters = struct.unpack_from('<III', data, u32(0x4c) + 12 * i)
        indices = struct.unpack_from('<' + 'H' * u32(parameters), data, parameters + 4) if parameters else []
        prototypes.append('(' + ''.join(types[index] for index in indices) + ')' + types[return_type])
    references = []
    for i in range(u32(0x58)):
        class_index, proto_index, name_index = struct.unpack_from('<HHI', data, u32(0x5c) + i * 8)
        references.append((types[class_index], strings[name_index], prototypes[proto_index]))
    classes, methods = set(), set()
    for i in range(u32(0x60)):
        definition = struct.unpack_from('<8I', data, u32(0x64) + i * 32)
        classes.add(types[definition[0]])
        pointer = definition[6]
        if not pointer:
            continue
        counts = []
        for _ in range(4):
            count, pointer = uleb(pointer); counts.append(count)
        for _ in range(counts[0] + counts[1]):
            _, pointer = uleb(pointer); _, pointer = uleb(pointer)
        for count in counts[2:]:
            index = 0
            for _ in range(count):
                delta, pointer = uleb(pointer); index += delta
                _, pointer = uleb(pointer); _, pointer = uleb(pointer)
                methods.add(references[index])
    return classes, methods


# These constructors are invoked by name from OrtJniUtil.c in ORT 1.23.2.
REQUIRED_CONSTRUCTORS = {
    ('Lai/onnxruntime/TensorInfo;', '<init>', '([J[Ljava/lang/String;I)V'),
    ('Lai/onnxruntime/MapInfo;', '<init>', '(III)V'),
    ('Lai/onnxruntime/SequenceInfo;', '<init>', '(II)V'),
    ('Lai/onnxruntime/SequenceInfo;', '<init>', '(ILai/onnxruntime/MapInfo;)V'),
    ('Lai/onnxruntime/OnnxTensor;', '<init>', '(JJLai/onnxruntime/TensorInfo;)V'),
    ('Lai/onnxruntime/OnnxSparseTensor;', '<init>', '(JJILai/onnxruntime/TensorInfo;)V'),
    ('Lai/onnxruntime/OnnxSequence;', '<init>', '(JJLai/onnxruntime/SequenceInfo;)V'),
    ('Lai/onnxruntime/OnnxMap;', '<init>', '(JJLai/onnxruntime/MapInfo;)V'),
    ('Lai/onnxruntime/OrtException;', '<init>', '(ILjava/lang/String;)V'),
}


def verify(apk):
    classes, methods = set(), set()
    with zipfile.ZipFile(apk) as archive:
        for name in archive.namelist():
            if re.fullmatch(r'classes\d*\.dex', name):
                defined_classes, defined_methods = dex_definitions(archive.read(name))
                classes.update(defined_classes); methods.update(defined_methods)
        native = archive.read('lib/arm64-v8a/libonnxruntime4j_jni.so')
        expected_classes = {'L' + name.decode() + ';' for name in re.findall(rb'ai/onnxruntime/[A-Za-z0-9_$/]+', native)}
    missing_classes = sorted(expected_classes - classes)
    missing_methods = sorted(REQUIRED_CONSTRUCTORS - methods)
    if missing_classes or missing_methods:
        raise ValueError(f'Missing JNI class definitions: {missing_classes}; missing JNI constructors: {missing_methods}')
    return len(expected_classes), len(REQUIRED_CONSTRUCTORS)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk')
    args = parser.parse_args()
    try:
        class_count, constructor_count = verify(args.apk)
        print(f'PASS: {class_count} JNI classes and {constructor_count} JNI constructors retained in release DEX')
    except (ValueError, KeyError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
