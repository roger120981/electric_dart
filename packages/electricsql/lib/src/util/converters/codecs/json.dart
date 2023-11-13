import 'dart:convert' hide JsonCodec;

final class JsonCodec extends Codec<Object, String> {
  const JsonCodec();

  @override
  Converter<String, Object> get decoder => const _Decoder();

  @override
  Converter<Object, String> get encoder => const _Encoder();
}

final class _Decoder extends Converter<String, Object> {
  const _Decoder();

  @override
  Object convert(String input) {
    // TODO(dart): Can we check json.decode == null?
    if (input == json.encode(null)) return {'__is_electric_json_null__': true};
    return json.decode(input) as Object;
  }
}

final class _Encoder extends Converter<Object, String> {
  const _Encoder();

  @override
  String convert(Object input) {
    if (isJsonNull(input)) {
      // user provided the special Prisma.JsonNull value
      // to indicate a JSON null value rather than a DB NULL
      return json.encode(null);
    } else {
      return json.encode(input);
    }
  }
}

bool isJsonNull(Object v) {
  return v is Map<String, dynamic> &&
      v.containsKey('__is_electric_json_null__') &&
      v['__is_electric_json_null__'] == true;
}

const Object kJsonNull = {'__is_electric_json_null__': true};
