// Encoding Standard: TextEncoder and TextDecoder over libweb's decoders.
// Implemented in Web.Bindings.Encoding.

dictionary TextDecoderOptions {
  boolean fatal = false;
  boolean ignoreBOM = false;
};

dictionary TextDecodeOptions {
  boolean stream = false;
};

[Exposed=*]
interface TextDecoder {
  constructor(optional DOMString label = "utf-8", optional TextDecoderOptions options = {});
  readonly attribute DOMString encoding;
  readonly attribute boolean fatal;
  readonly attribute boolean ignoreBOM;
  USVString decode(optional any input, optional TextDecodeOptions options = {});
};

dictionary TextEncoderEncodeIntoResult {
  unsigned long long read;
  unsigned long long written;
};

[Exposed=*]
interface TextEncoder {
  constructor();
  readonly attribute DOMString encoding;
  [NewObject] any encode(optional USVString input = "");
  any encodeInto(USVString source, object destination);
};
