{
  The MD5 compression function (RFC 1321).

  MD5 is broken as a security measure; it is here for md5sum and for
  checking existing checksums. Use Crypto.Digests for whole messages.
}
unit Crypto.Md5;

{$mode objfpc}
{$pointermath on}

interface

type
  TMd5State = array[0..3] of LongWord;

const
  Md5InitialState: TMd5State = ($67452301, $efcdab89, $98badcfe, $10325476);

{ Mixes one 64-byte block into State. }
procedure Md5Compress(var State: TMd5State; Block: PByte);

implementation

uses
  Crypto.Bits;

const
  Md5Shifts: array[0..63] of Byte = (
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21);

  Md5Constants: array[0..63] of LongWord = (
    $d76aa478, $e8c7b756, $242070db, $c1bdceee, $f57c0faf, $4787c62a, $a8304613, $fd469501,
    $698098d8, $8b44f7af, $ffff5bb1, $895cd7be, $6b901122, $fd987193, $a679438e, $49b40821,
    $f61e2562, $c040b340, $265e5a51, $e9b6c7aa, $d62f105d, $02441453, $d8a1e681, $e7d3fbc8,
    $21e1cde6, $c33707d6, $f4d50d87, $455a14ed, $a9e3e905, $fcefa3f8, $676f02d9, $8d2a4c8a,
    $fffa3942, $8771f681, $6d9d6122, $fde5380c, $a4beea44, $4bdecfa9, $f6bb4b60, $bebfbc70,
    $289b7ec6, $eaa127fa, $d4ef3085, $04881d05, $d9d4d039, $e6db99e5, $1fa27cf8, $c4ac5665,
    $f4292244, $432aff97, $ab9423a7, $fc93a039, $655b59c3, $8f0ccc92, $ffeff47d, $85845dd1,
    $6fa87e4f, $fe2ce6e0, $a3014314, $4e0811a1, $f7537e82, $bd3af235, $2ad7d2bb, $eb86d391);

procedure Md5Compress(var State: TMd5State; Block: PByte);
var
  Words: array[0..15] of LongWord;
  A, B, C, D: LongWord;
  Mixed: LongWord;
  Temporary: LongWord;
  Round: Integer;
  WordIndex: Integer;
begin
  for Round := 0 to 15 do
    Words[Round] := LoadLittleEndian32(Block + Round * 4);
  A := State[0];
  B := State[1];
  C := State[2];
  D := State[3];
  for Round := 0 to 63 do
  begin
    case Round div 16 of
      0:
        begin
          Mixed := (B and C) or ((not B) and D);
          WordIndex := Round;
        end;
      1:
        begin
          Mixed := (D and B) or ((not D) and C);
          WordIndex := (5 * Round + 1) mod 16;
        end;
      2:
        begin
          Mixed := B xor C xor D;
          WordIndex := (3 * Round + 5) mod 16;
        end;
    else
      begin
        Mixed := C xor (B or (not D));
        WordIndex := (7 * Round) mod 16;
      end;
    end;
    Temporary := D;
    D := C;
    C := B;
    B := B + RotateLeft32(LongWord(A + Mixed + Md5Constants[Round] + Words[WordIndex]), Md5Shifts[Round]);
    A := Temporary;
  end;
  State[0] := State[0] + A;
  State[1] := State[1] + B;
  State[2] := State[2] + C;
  State[3] := State[3] + D;
end;

end.
