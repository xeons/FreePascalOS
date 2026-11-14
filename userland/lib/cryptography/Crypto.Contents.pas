{
  The contents of libcryptography.so: hashes, checksums, ciphers and
  random numbers. Compiling this unit compiles all of them.
}
unit Crypto.Contents;

{$mode objfpc}

interface

uses
  Crypto.Bits,
  Crypto.Md5,
  Crypto.Sha1,
  Crypto.Sha256,
  Crypto.Sha512,
  Crypto.Blake2b,
  Crypto.Digests,
  Crypto.Hmac,
  Crypto.Checksums,
  Crypto.ChaCha20,
  Crypto.Aes,
  Crypto.Random;

implementation

end.
