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
  UTF-8 decoding a byte at a time, for output that arrives in pieces: a
  character may be split between two reads.

  A byte that cannot continue the character being decoded ends it as
  U+FFFD (and is then looked at again on its own), and so does a
  sequence that is too long for its value or names a surrogate.
}
unit Terminal.Utf8Stream;

{$mode objfpc}

interface

const
  ReplacementCharacter = $FFFD;

type
  TUtf8Stream = record
    CodePoint: LongWord;
    Remaining: LongInt;
    Smallest: LongWord;
  end;

  TUtf8Result = (
    { Nothing yet: the byte began or continued a character. }
    Utf8Incomplete,
    { CodePoint is a whole character. }
    Utf8Character,
    { CodePoint is U+FFFD for a broken sequence, and the byte must be
      decoded again. }
    Utf8BrokenBeforeByte);

procedure ResetUtf8Stream(out Stream: TUtf8Stream);
function DecodeUtf8Byte(var Stream: TUtf8Stream; Value: Byte; out CodePoint: LongWord): TUtf8Result;
{ Whether a character is being decoded. }
function Utf8StreamIsInside(const Stream: TUtf8Stream): Boolean;

implementation

procedure ResetUtf8Stream(out Stream: TUtf8Stream);
begin
  Stream.CodePoint := 0;
  Stream.Remaining := 0;
  Stream.Smallest := 0;
end;

function Utf8StreamIsInside(const Stream: TUtf8Stream): Boolean;
begin
  Result := Stream.Remaining > 0;
end;

{ A byte that starts a character (no character is being decoded). }
function StartCharacter(var Stream: TUtf8Stream; Value: Byte; out CodePoint: LongWord): TUtf8Result;
begin
  Result := Utf8Incomplete;
  CodePoint := 0;
  if Value < $80 then
  begin
    CodePoint := Value;
    Exit(Utf8Character);
  end;
  if (Value and $E0) = $C0 then
  begin
    Stream.CodePoint := Value and $1F;
    Stream.Remaining := 1;
    Stream.Smallest := $80;
  end
  else if (Value and $F0) = $E0 then
  begin
    Stream.CodePoint := Value and $0F;
    Stream.Remaining := 2;
    Stream.Smallest := $800;
  end
  else if (Value and $F8) = $F0 then
  begin
    Stream.CodePoint := Value and $07;
    Stream.Remaining := 3;
    Stream.Smallest := $10000;
  end
  else
  begin
    { A continuation byte or a byte UTF-8 never has. }
    CodePoint := ReplacementCharacter;
    Result := Utf8Character;
  end;
end;

function DecodeUtf8Byte(var Stream: TUtf8Stream; Value: Byte; out CodePoint: LongWord): TUtf8Result;
begin
  if Stream.Remaining = 0 then
    Exit(StartCharacter(Stream, Value, CodePoint));
  if (Value and $C0) <> $80 then
  begin
    Stream.Remaining := 0;
    CodePoint := ReplacementCharacter;
    Exit(Utf8BrokenBeforeByte);
  end;
  Stream.CodePoint := (Stream.CodePoint shl 6) or (Value and $3F);
  Dec(Stream.Remaining);
  CodePoint := 0;
  if Stream.Remaining > 0 then
    Exit(Utf8Incomplete);
  CodePoint := Stream.CodePoint;
  if (CodePoint < Stream.Smallest) or (CodePoint > $10FFFF) or ((CodePoint >= $D800) and (CodePoint <= $DFFF)) then
    CodePoint := ReplacementCharacter;
  Result := Utf8Character;
end;

end.
