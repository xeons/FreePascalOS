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
  The HTML parser's input stream: decoded text (UTF-8) as it arrives,
  with newlines normalized (CR LF and lone CR become LF, also across
  pieces) and the input stream preprocessing errors counted (control
  characters and noncharacters). The tokenizer reads it byte by byte:
  all of HTML's syntax is ASCII, so a multi-byte character only ever
  passes through as data.

  The insertion point (document.write) is a position in the stream;
  text written there goes in before it, and a nested tokenizer run stops
  at it. Text already read is dropped from the front now and then.
}
unit Web.Html.InputStream;

{$mode objfpc}
{$H+}

interface

const
  NoInsertionPoint = -1;

type
  { The bytes that end a run (ScanRun). }
  TStopTable = array[0..255] of Boolean;

  { An insertion point and limit put aside while a nested script or
    document.write runs (offsets kept up to date as text moves). }
  TInsertionState = record
    InsertionPoint: SizeInt;
    Limit: SizeInt;
  end;

  THtmlInputStream = class
  private
    FBuffer: string;
    FLength: SizeInt;
    FPosition: SizeInt;
    FEnded: Boolean;
    FLastWasCarriageReturn: Boolean;
    FInsertionPoint: SizeInt;
    FLimit: SizeInt;
    FSavedStates: array of TInsertionState;
    FSavedCount: Integer;
    FPreprocessingErrors: SizeInt;
    procedure Reserve(Extra: SizeInt);
    procedure Compact;
    procedure CountPreprocessingErrors(Text: PChar; Count: SizeInt);
    { Normalizes Count bytes into the buffer at Offset (already made
      room for); the number of bytes written. }
    function NormalizeInto(Offset: SizeInt; Text: PChar; Count: SizeInt; var LastWasCarriageReturn: Boolean): SizeInt;
  public
    constructor Create;
    { Adds decoded text at the end of the stream. }
    procedure Append(Text: PChar; Count: SizeInt);
    procedure AppendString(const Text: string);
    { Inserts text just before the insertion point, which moves after it. }
    procedure InsertAtInsertionPoint(const Text: string);
    { No more text will come. }
    procedure MarkEnded;
    { Whether a byte is available (before the limit). }
    function HasByte: Boolean; inline;
    { Whether the end of the stream has been reached (not merely the
      limit of a nested run). }
    function AtEnd: Boolean; inline;
    { Whether no more input can arrive before the end of what is
      available (the stream ended and no nested run's limit). }
    function NoMoreInputComing: Boolean; inline;
    function PeekByte: Byte; inline;
    function NextByte: Byte; inline;
    procedure Back; inline;
    procedure Skip(Count: SizeInt); inline;
    { Bytes available from the position (before the limit). }
    function Available: SizeInt; inline;
    function CurrentPointer: PChar; inline;
    { The run from the position up to (not including) the first of the
      stop bytes or the limit. }
    function ScanRun(const StopTable: TStopTable): SizeInt;
    { Runs read up to the insertion point (document.write's nested run). }
    procedure LimitToInsertionPoint;
    procedure RemoveLimit;
    procedure SetInsertionPointHere;
    procedure ClearInsertionPoint;
    function HasInsertionPoint: Boolean; inline;
    { Puts the insertion point and the limit aside, and brings them back
      (the standard's "old insertion point" of nested scripts and
      document.write calls). }
    procedure SaveInsertionState;
    procedure RestoreInsertionState;
    property Ended: Boolean read FEnded;
    property PreprocessingErrors: SizeInt read FPreprocessingErrors;
  end;

implementation

constructor THtmlInputStream.Create;
begin
  inherited Create;
  FInsertionPoint := NoInsertionPoint;
  FLimit := -1;
end;

procedure THtmlInputStream.Reserve(Extra: SizeInt);
var
  Capacity: SizeInt;
begin
  if FLength + Extra <= Length(FBuffer) then
    Exit;
  Capacity := Length(FBuffer) * 2;
  if Capacity < FLength + Extra then
    Capacity := FLength + Extra + 4096;
  SetLength(FBuffer, Capacity);
end;

procedure THtmlInputStream.Compact;
var
  Shift: SizeInt;
  Index: Integer;
begin
  Shift := FPosition;
  if (Shift < 65536) or (Shift < FLength div 2) then
    Exit;
  if (FInsertionPoint <> NoInsertionPoint) and (FInsertionPoint < Shift) then
    Exit;
  for Index := 1 to FSavedCount do
    if (FSavedStates[Index - 1].InsertionPoint <> NoInsertionPoint) and
      (FSavedStates[Index - 1].InsertionPoint < Shift) then
      Exit;
  if FInsertionPoint <> NoInsertionPoint then
    Dec(FInsertionPoint, Shift);
  if FLimit >= 0 then
    Dec(FLimit, Shift);
  for Index := 1 to FSavedCount do
  begin
    if FSavedStates[Index - 1].InsertionPoint <> NoInsertionPoint then
      Dec(FSavedStates[Index - 1].InsertionPoint, Shift);
    if FSavedStates[Index - 1].Limit >= 0 then
      Dec(FSavedStates[Index - 1].Limit, Shift);
  end;
  Move(FBuffer[Shift + 1], FBuffer[1], FLength - Shift);
  Dec(FLength, Shift);
  FPosition := 0;
end;

procedure THtmlInputStream.CountPreprocessingErrors(Text: PChar; Count: SizeInt);
var
  Index: SizeInt;
  Value, Second, Third: Byte;
begin
  Index := 0;
  while Index < Count do
  begin
    Value := Ord(Text[Index]);
    if Value < $80 then
    begin
      if (Value in [$01..$08, $0B, $0E..$1F, $7F]) then
        Inc(FPreprocessingErrors);
      Inc(Index);
      Continue;
    end;
    { C1 controls: C2 80..9F. Noncharacters: U+FDD0..FDEF (EF B7 90..AF)
      and U+xFFFE/xFFFF (the last two bytes BF BE or BF BF). }
    if (Value = $C2) and (Index + 1 < Count) and (Ord(Text[Index + 1]) <= $9F) then
      Inc(FPreprocessingErrors)
    else if (Value = $EF) and (Index + 2 < Count) then
    begin
      Second := Ord(Text[Index + 1]);
      Third := Ord(Text[Index + 2]);
      if ((Second = $B7) and (Third >= $90) and (Third <= $AF)) or ((Second = $BF) and (Third >= $BE)) then
        Inc(FPreprocessingErrors);
    end
    else if (Value >= $F0) and (Index + 3 < Count) and ((Ord(Text[Index + 1]) and $0F) = $0F) and
      (Ord(Text[Index + 2]) = $BF) and (Ord(Text[Index + 3]) >= $BE) then
      Inc(FPreprocessingErrors);
    Inc(Index);
  end;
end;

function THtmlInputStream.NormalizeInto(Offset: SizeInt; Text: PChar; Count: SizeInt;
  var LastWasCarriageReturn: Boolean): SizeInt;
var
  Index: SizeInt;
  Value: Char;
begin
  Result := 0;
  for Index := 1 to Count do
  begin
    Value := Text[Index - 1];
    if Value = #13 then
    begin
      FBuffer[Offset + Result + 1] := #10;
      Inc(Result);
      LastWasCarriageReturn := True;
      Continue;
    end;
    if (Value = #10) and LastWasCarriageReturn then
    begin
      LastWasCarriageReturn := False;
      Continue;
    end;
    LastWasCarriageReturn := False;
    FBuffer[Offset + Result + 1] := Value;
    Inc(Result);
  end;
end;

procedure THtmlInputStream.Append(Text: PChar; Count: SizeInt);
begin
  if Count <= 0 then
    Exit;
  Compact;
  CountPreprocessingErrors(Text, Count);
  Reserve(Count);
  Inc(FLength, NormalizeInto(FLength, Text, Count, FLastWasCarriageReturn));
end;

procedure THtmlInputStream.AppendString(const Text: string);
begin
  Append(PChar(Text), Length(Text));
end;

procedure THtmlInputStream.InsertAtInsertionPoint(const Text: string);
var
  Index: Integer;
  Normalized: string;
  Written: SizeInt;
  LastWasCarriageReturn: Boolean;
  Saved: string;
  SavedLength: SizeInt;
begin
  if Text = '' then
    Exit;
  if FInsertionPoint = NoInsertionPoint then
  begin
    AppendString(Text);
    Exit;
  end;
  CountPreprocessingErrors(PChar(Text), Length(Text));
  { Normalize into the tail of the buffer, then move it into place. }
  SavedLength := FLength;
  Reserve(Length(Text));
  LastWasCarriageReturn := False;
  Written := NormalizeInto(FLength, PChar(Text), Length(Text), LastWasCarriageReturn);
  Normalized := Copy(FBuffer, FLength + 1, Written);
  Saved := Copy(FBuffer, FInsertionPoint + 1, SavedLength - FInsertionPoint);
  Reserve(Written);
  Move(Normalized[1], FBuffer[FInsertionPoint + 1], Written);
  if Saved <> '' then
    Move(Saved[1], FBuffer[FInsertionPoint + Written + 1], Length(Saved));
  FLength := SavedLength + Written;
  if (FLimit >= 0) and (FLimit >= FInsertionPoint) then
    Inc(FLimit, Written);
  for Index := 1 to FSavedCount do
  begin
    if (FSavedStates[Index - 1].InsertionPoint <> NoInsertionPoint) and
      (FSavedStates[Index - 1].InsertionPoint >= FInsertionPoint) then
      Inc(FSavedStates[Index - 1].InsertionPoint, Written);
    if (FSavedStates[Index - 1].Limit >= 0) and (FSavedStates[Index - 1].Limit >= FInsertionPoint) then
      Inc(FSavedStates[Index - 1].Limit, Written);
  end;
  Inc(FInsertionPoint, Written);
end;

procedure THtmlInputStream.MarkEnded;
begin
  FEnded := True;
end;

function THtmlInputStream.HasByte: Boolean;
begin
  if FLimit >= 0 then
    Result := FPosition < FLimit
  else
    Result := FPosition < FLength;
end;

function THtmlInputStream.AtEnd: Boolean;
begin
  Result := FEnded and (FLimit < 0) and (FPosition >= FLength);
end;

function THtmlInputStream.NoMoreInputComing: Boolean;
begin
  Result := FEnded and (FLimit < 0);
end;

function THtmlInputStream.PeekByte: Byte;
begin
  Result := Ord(FBuffer[FPosition + 1]);
end;

function THtmlInputStream.NextByte: Byte;
begin
  Inc(FPosition);
  Result := Ord(FBuffer[FPosition]);
end;

procedure THtmlInputStream.Back;
begin
  Dec(FPosition);
end;

procedure THtmlInputStream.Skip(Count: SizeInt);
begin
  Inc(FPosition, Count);
end;

function THtmlInputStream.Available: SizeInt;
begin
  if FLimit >= 0 then
    Result := FLimit - FPosition
  else
    Result := FLength - FPosition;
end;

function THtmlInputStream.CurrentPointer: PChar;
begin
  Result := PChar(FBuffer) + FPosition;
end;

function THtmlInputStream.ScanRun(const StopTable: TStopTable): SizeInt;
var
  Stop, Index: SizeInt;
  Value: Byte;
begin
  if FLimit >= 0 then
    Stop := FLimit
  else
    Stop := FLength;
  Index := FPosition;
  while Index < Stop do
  begin
    Value := Ord(FBuffer[Index + 1]);
    if StopTable[Value] then
      Break;
    Inc(Index);
  end;
  Result := Index - FPosition;
end;

procedure THtmlInputStream.LimitToInsertionPoint;
begin
  FLimit := FInsertionPoint;
end;

procedure THtmlInputStream.RemoveLimit;
begin
  FLimit := -1;
end;

procedure THtmlInputStream.SetInsertionPointHere;
begin
  FInsertionPoint := FPosition;
end;

procedure THtmlInputStream.ClearInsertionPoint;
begin
  FInsertionPoint := NoInsertionPoint;
end;

function THtmlInputStream.HasInsertionPoint: Boolean;
begin
  Result := FInsertionPoint <> NoInsertionPoint;
end;

procedure THtmlInputStream.SaveInsertionState;
begin
  if FSavedCount >= Length(FSavedStates) then
    SetLength(FSavedStates, FSavedCount * 2 + 4);
  FSavedStates[FSavedCount].InsertionPoint := FInsertionPoint;
  FSavedStates[FSavedCount].Limit := FLimit;
  Inc(FSavedCount);
end;

procedure THtmlInputStream.RestoreInsertionState;
begin
  if FSavedCount = 0 then
    Exit;
  Dec(FSavedCount);
  FInsertionPoint := FSavedStates[FSavedCount].InsertionPoint;
  FLimit := FSavedStates[FSavedCount].Limit;
end;

end.
