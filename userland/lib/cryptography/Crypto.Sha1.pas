{
  The SHA-1 compression function (FIPS 180-4).

  SHA-1 is no longer collision resistant; it is here for sha1sum and
  compatibility. Use Crypto.Digests for whole messages.
}
unit Crypto.Sha1;

{$mode objfpc}
{$pointermath on}

interface

type
  TSha1State = array[0..4] of LongWord;

const
  Sha1InitialState: TSha1State = ($67452301, $EFCDAB89, $98BADCFE, $10325476, $C3D2E1F0);

{ Mixes one 64-byte block into State. }
procedure Sha1Compress(var State: TSha1State; Block: PByte);

implementation

uses
  Crypto.Bits;

procedure Sha1Compress(var State: TSha1State; Block: PByte);
var
  Words: array[0..79] of LongWord;
  A, B, C, D, E: LongWord;
  Mixed: LongWord;
  Constant: LongWord;
  Temporary: LongWord;
  Round: Integer;
begin
  for Round := 0 to 15 do
    Words[Round] := LoadBigEndian32(Block + Round * 4);
  for Round := 16 to 79 do
    Words[Round] := RotateLeft32(Words[Round - 3] xor Words[Round - 8] xor Words[Round - 14] xor
      Words[Round - 16], 1);
  A := State[0];
  B := State[1];
  C := State[2];
  D := State[3];
  E := State[4];
  for Round := 0 to 79 do
  begin
    case Round div 20 of
      0:
        begin
          Mixed := (B and C) or ((not B) and D);
          Constant := $5A827999;
        end;
      1:
        begin
          Mixed := B xor C xor D;
          Constant := $6ED9EBA1;
        end;
      2:
        begin
          Mixed := (B and C) or (B and D) or (C and D);
          Constant := $8F1BBCDC;
        end;
    else
      begin
        Mixed := B xor C xor D;
        Constant := $CA62C1D6;
      end;
    end;
    Temporary := RotateLeft32(A, 5) + Mixed + E + Constant + Words[Round];
    E := D;
    D := C;
    C := RotateLeft32(B, 30);
    B := A;
    A := Temporary;
  end;
  State[0] := State[0] + A;
  State[1] := State[1] + B;
  State[2] := State[2] + C;
  State[3] := State[3] + D;
  State[4] := State[4] + E;
end;

end.
