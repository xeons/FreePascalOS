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
  A growable buffer of bytes (UTF-8 text) that libweb appends to while
  decoding, tokenizing and serializing: appending is amortized constant
  time, and the text is handed over without a copy when done.
}
unit Web.TextBuffers;

{$mode objfpc}
{$H+}

interface

type
  TTextBuffer = class
  private
    FData: string;
    FLength: SizeInt;
    procedure Grow(MinimumCapacity: SizeInt);
  public
    procedure Clear; inline;
    procedure AppendChar(Value: Char); inline;
    procedure Append(Source: PChar; Count: SizeInt);
    procedure AppendString(const Source: string);
    { Appends the UTF-8 encoding of a code point. }
    procedure AppendCodePoint(CodePoint: LongWord);
    procedure Truncate(NewLength: SizeInt);
    { A copy of the contents. }
    function Text: string;
    { The contents; the buffer is left empty. }
    function TakeText: string;
    { The byte at Index (0 based). }
    function ByteAt(Index: SizeInt): Byte; inline;
    function Data: PChar; inline;
    function Equals(const Source: string): Boolean; reintroduce;
    property Length: SizeInt read FLength;
  end;

implementation

procedure TTextBuffer.Grow(MinimumCapacity: SizeInt);
var
  NewCapacity: SizeInt;
begin
  NewCapacity := System.Length(FData) * 2;
  if NewCapacity < 64 then
    NewCapacity := 64;
  if NewCapacity < MinimumCapacity then
    NewCapacity := MinimumCapacity;
  SetLength(FData, NewCapacity);
end;

procedure TTextBuffer.Clear;
begin
  FLength := 0;
end;

procedure TTextBuffer.AppendChar(Value: Char);
begin
  if FLength >= System.Length(FData) then
    Grow(FLength + 1);
  Inc(FLength);
  FData[FLength] := Value;
end;

procedure TTextBuffer.Append(Source: PChar; Count: SizeInt);
begin
  if Count <= 0 then
    Exit;
  if FLength + Count > System.Length(FData) then
    Grow(FLength + Count);
  Move(Source^, FData[FLength + 1], Count);
  Inc(FLength, Count);
end;

procedure TTextBuffer.AppendString(const Source: string);
begin
  if Source <> '' then
    Append(PChar(Source), System.Length(Source));
end;

procedure TTextBuffer.AppendCodePoint(CodePoint: LongWord);
begin
  if CodePoint < $80 then
    AppendChar(Chr(CodePoint))
  else if CodePoint < $800 then
  begin
    AppendChar(Chr($C0 or (CodePoint shr 6)));
    AppendChar(Chr($80 or (CodePoint and $3F)));
  end
  else if CodePoint < $10000 then
  begin
    AppendChar(Chr($E0 or (CodePoint shr 12)));
    AppendChar(Chr($80 or ((CodePoint shr 6) and $3F)));
    AppendChar(Chr($80 or (CodePoint and $3F)));
  end
  else
  begin
    AppendChar(Chr($F0 or (CodePoint shr 18)));
    AppendChar(Chr($80 or ((CodePoint shr 12) and $3F)));
    AppendChar(Chr($80 or ((CodePoint shr 6) and $3F)));
    AppendChar(Chr($80 or (CodePoint and $3F)));
  end;
end;

procedure TTextBuffer.Truncate(NewLength: SizeInt);
begin
  if (NewLength >= 0) and (NewLength < FLength) then
    FLength := NewLength;
end;

function TTextBuffer.Text: string;
begin
  Result := Copy(FData, 1, FLength);
end;

function TTextBuffer.TakeText: string;
begin
  if FLength = 0 then
    Exit('');
  if System.Length(FData) - FLength > 32 then
  begin
    { Much room to spare: the text gets a block of its own size (a
      shrunk string keeps its big block), and the buffer is reused. }
    Result := Copy(FData, 1, FLength);
    FLength := 0;
    Exit;
  end;
  SetLength(FData, FLength);
  Result := FData;
  FData := '';
  FLength := 0;
end;

function TTextBuffer.ByteAt(Index: SizeInt): Byte;
begin
  Result := Ord(FData[Index + 1]);
end;

function TTextBuffer.Data: PChar;
begin
  if FData = '' then
    Result := nil
  else
    Result := @FData[1];
end;

function TTextBuffer.Equals(const Source: string): Boolean;
begin
  Result := (System.Length(Source) = FLength) and ((FLength = 0) or (CompareByte(FData[1], Source[1], FLength) = 0));
end;

end.
