{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The 121 word transforms of brotli (RFC 7932 section 8, appendix B).

  A static dictionary reference names a base word and a transform; the
  word copied out is the transform's prefix, the word changed by its
  elementary transform, then its suffix. The elementary transforms:
  none, the first letter or every letter in upper case (the RFC's
  "Ferment": ASCII letters flip case, and in a UTF-8 sequence a later
  byte is changed), or the first or last 1 to 9 bytes left out.

  Kind numbers the elementary transforms as the RFC does to give the
  table's check value: serialized as prefix, zero, kind, suffix, zero
  for each transform, the table is 648 bytes with CRC-32 $3D965F81
  (checked by tools/CompressionTest).
}
unit Compression.BrotliTransforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

const
  BrotliTransformCount = 121;
  { The longest word a transform makes: 24 bytes and 13 added. }
  BrotliLongestTransformedWord = 37;

  TransformIdentity = 0;
  TransformUppercaseFirst = 1;
  TransformUppercaseAll = 2;
  { Plus 1 to 9: that many bytes left out at the start or the end. }
  TransformOmitFirst = 2;
  TransformOmitLast = 11;

type
  TBrotliTransform = record
    Prefix: string[5];
    Kind: Byte;
    Suffix: string[8];
  end;

const
  BrotliTransforms: array[0..BrotliTransformCount - 1] of TBrotliTransform = (
    (Prefix: ''; Kind: TransformIdentity; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' '),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: ' '),
    (Prefix: ''; Kind: TransformOmitFirst + 1; Suffix: ''),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: ' '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' the '),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: ''),
    (Prefix: 's '; Kind: TransformIdentity; Suffix: ' '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' of '),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' and '),
    (Prefix: ''; Kind: TransformOmitFirst + 2; Suffix: ''),
    (Prefix: ''; Kind: TransformOmitLast + 1; Suffix: ''),
    (Prefix: ', '; Kind: TransformIdentity; Suffix: ' '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ', '),
    (Prefix: ' '; Kind: TransformUppercaseFirst; Suffix: ' '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' in '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' to '),
    (Prefix: 'e '; Kind: TransformIdentity; Suffix: ' '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '"'),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '.'),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '">'),
    (Prefix: ''; Kind: TransformIdentity; Suffix: #10),
    (Prefix: ''; Kind: TransformOmitLast + 3; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ']'),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' for '),
    (Prefix: ''; Kind: TransformOmitFirst + 3; Suffix: ''),
    (Prefix: ''; Kind: TransformOmitLast + 2; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' a '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' that '),
    (Prefix: ' '; Kind: TransformUppercaseFirst; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '. '),
    (Prefix: '.'; Kind: TransformIdentity; Suffix: ''),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: ', '),
    (Prefix: ''; Kind: TransformOmitFirst + 4; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' with '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: #39),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' from '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' by '),
    (Prefix: ''; Kind: TransformOmitFirst + 5; Suffix: ''),
    (Prefix: ''; Kind: TransformOmitFirst + 6; Suffix: ''),
    (Prefix: ' the '; Kind: TransformIdentity; Suffix: ''),
    (Prefix: ''; Kind: TransformOmitLast + 4; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '. The '),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' on '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' as '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' is '),
    (Prefix: ''; Kind: TransformOmitLast + 7; Suffix: ''),
    (Prefix: ''; Kind: TransformOmitLast + 1; Suffix: 'ing '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: #10#9),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ':'),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: '. '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'ed '),
    (Prefix: ''; Kind: TransformOmitFirst + 9; Suffix: ''),
    (Prefix: ''; Kind: TransformOmitFirst + 7; Suffix: ''),
    (Prefix: ''; Kind: TransformOmitLast + 6; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '('),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: ', '),
    (Prefix: ''; Kind: TransformOmitLast + 8; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' at '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'ly '),
    (Prefix: ' the '; Kind: TransformIdentity; Suffix: ' of '),
    (Prefix: ''; Kind: TransformOmitLast + 5; Suffix: ''),
    (Prefix: ''; Kind: TransformOmitLast + 9; Suffix: ''),
    (Prefix: ' '; Kind: TransformUppercaseFirst; Suffix: ', '),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: '"'),
    (Prefix: '.'; Kind: TransformIdentity; Suffix: '('),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: ' '),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: '">'),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '="'),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: '.'),
    (Prefix: '.com/'; Kind: TransformIdentity; Suffix: ''),
    (Prefix: ' the '; Kind: TransformIdentity; Suffix: ' of the '),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: #39),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '. This '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ','),
    (Prefix: '.'; Kind: TransformIdentity; Suffix: ' '),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: '('),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: '.'),
    (Prefix: ''; Kind: TransformIdentity; Suffix: ' not '),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: '="'),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'er '),
    (Prefix: ' '; Kind: TransformUppercaseAll; Suffix: ' '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'al '),
    (Prefix: ' '; Kind: TransformUppercaseAll; Suffix: ''),
    (Prefix: ''; Kind: TransformIdentity; Suffix: '='#39),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: '"'),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: '. '),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: '('),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'ful '),
    (Prefix: ' '; Kind: TransformUppercaseFirst; Suffix: '. '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'ive '),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'less '),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: #39),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'est '),
    (Prefix: ' '; Kind: TransformUppercaseFirst; Suffix: '.'),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: '">'),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: '='#39),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: ','),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'ize '),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: '.'),
    (Prefix: #194#160; Kind: TransformIdentity; Suffix: ''),
    (Prefix: ' '; Kind: TransformIdentity; Suffix: ','),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: '="'),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: '="'),
    (Prefix: ''; Kind: TransformIdentity; Suffix: 'ous '),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: ', '),
    (Prefix: ''; Kind: TransformUppercaseFirst; Suffix: '='#39),
    (Prefix: ' '; Kind: TransformUppercaseFirst; Suffix: ','),
    (Prefix: ' '; Kind: TransformUppercaseAll; Suffix: '="'),
    (Prefix: ' '; Kind: TransformUppercaseAll; Suffix: ', '),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: ','),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: '('),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: '. '),
    (Prefix: ' '; Kind: TransformUppercaseAll; Suffix: '.'),
    (Prefix: ''; Kind: TransformUppercaseAll; Suffix: '='#39),
    (Prefix: ' '; Kind: TransformUppercaseAll; Suffix: '. '),
    (Prefix: ' '; Kind: TransformUppercaseFirst; Suffix: '="'),
    (Prefix: ' '; Kind: TransformUppercaseAll; Suffix: '='#39),
    (Prefix: ' '; Kind: TransformUppercaseFirst; Suffix: '='#39)
  );

{ Writes Word (WordLength bytes) changed by transform Index (0 to 120)
  to Target, which has room for BrotliLongestTransformedWord bytes;
  the length written. }
function TransformBrotliWord(Target: PByte; Word: PByte; WordLength: Integer; Index: Integer): Integer;

implementation

{ Puts the character at Text[0] (Count bytes left) in upper case as RFC
  7932 does; how many bytes the character takes. }
function UppercaseCharacter(Text: PByte; Count: Integer): Integer;
begin
  if Text[0] < 192 then
  begin
    if (Text[0] >= 97) and (Text[0] <= 122) then
      Text[0] := Text[0] xor 32;
    Result := 1;
  end
  else if Text[0] < 224 then
  begin
    if Count > 1 then
      Text[1] := Text[1] xor 32;
    Result := 2;
  end
  else
  begin
    if Count > 2 then
      Text[2] := Text[2] xor 5;
    Result := 3;
  end;
end;

function TransformBrotliWord(Target: PByte; Word: PByte; WordLength: Integer; Index: Integer): Integer;
var
  Transform: ^TBrotliTransform;
  Kind: Integer;
  Skip: Integer;
  Count: Integer;
  WordStart: Integer;
  Position: Integer;
  SuffixLength: Integer;
begin
  Transform := @BrotliTransforms[Index];
  Result := Length(Transform^.Prefix);
  if Result > 0 then
    Move(Transform^.Prefix[1], Target^, Result);

  Kind := Transform^.Kind;
  Skip := 0;
  Count := WordLength;
  if (Kind > TransformOmitFirst) and (Kind <= TransformOmitFirst + 9) then
    Skip := Kind - TransformOmitFirst
  else if (Kind > TransformOmitLast) and (Kind <= TransformOmitLast + 9) then
    Dec(Count, Kind - TransformOmitLast);
  Dec(Count, Skip);
  if Count < 0 then
    Count := 0;
  WordStart := Result;
  if Count > 0 then
    Move(Word[Skip], Target[Result], Count);
  Inc(Result, Count);

  if Kind = TransformUppercaseFirst then
  begin
    if Count > 0 then
      UppercaseCharacter(Target + WordStart, Count);
  end
  else if Kind = TransformUppercaseAll then
  begin
    Position := 0;
    while Position < Count do
      Inc(Position, UppercaseCharacter(Target + WordStart + Position, Count - Position));
  end;

  SuffixLength := Length(Transform^.Suffix);
  if SuffixLength > 0 then
  begin
    Move(Transform^.Suffix[1], Target[Result], SuffixLength);
    Inc(Result, SuffixLength);
  end;
end;

end.
