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
  What the archive test's parts share: tab-separated fields, CRC-32 in
  hexadecimal, a member's extracted data, files read whole, and a
  progress handler that counts (and can cancel).
}
unit ArchiveTest.Support;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Archive.Entries,
  Archive.Readers;

type
  TStringArray = array of string;

  TProgressRecorder = class
  public
    Calls: Integer;
    LastBytes: QWord;
    CancelAfter: QWord;
    procedure Record_(BytesDone: QWord; var Cancel: Boolean);
  end;

function SplitTabs(const Line: string): TStringArray;
function CrcHex(const Data: string): string;
function OctalText(Value: LongWord): string;
{ The member's data as a string (raises what extraction raises). }
function ExtractedData(Reader: TArchiveReader; Index: Integer): string;
function ReadWholeFile(const Path: string): string;
procedure WriteWholeFile(const Path, Data: string);
{ Deletes a folder and everything in it (links are not followed). }
procedure RemoveTree(const Path: string);
{ Deterministic data: half text, half pseudo-random bytes. }
function MixedData(Size: Integer; Seed: LongWord): string;
function RandomData(Size: Integer; Seed: LongWord): string;

implementation

uses
  BaseUnix,
  Compression.Checksums;

procedure TProgressRecorder.Record_(BytesDone: QWord; var Cancel: Boolean);
begin
  Inc(Calls);
  LastBytes := BytesDone;
  if (CancelAfter > 0) and (BytesDone >= CancelAfter) then
    Cancel := True;
end;

function SplitTabs(const Line: string): TStringArray;
var
  Start, Index, Count: Integer;
begin
  Result := nil;
  Count := 0;
  Start := 1;
  for Index := 1 to Length(Line) + 1 do
    if (Index > Length(Line)) or (Line[Index] = #9) then
    begin
      SetLength(Result, Count + 1);
      Result[Count] := Copy(Line, Start, Index - Start);
      Inc(Count);
      Start := Index + 1;
    end;
end;

function CrcHex(const Data: string): string;
var
  Crc: LongWord;
begin
  if Data = '' then
    Crc := Crc32(Crc32Initial, nil, 0)
  else
    Crc := Crc32(Crc32Initial, PByte(@Data[1]), Length(Data));
  Result := LowerCase(IntToHex(Crc, 8));
end;

function OctalText(Value: LongWord): string;
begin
  Result := '';
  repeat
    Result := Chr(Ord('0') + (Value and 7)) + Result;
    Value := Value shr 3;
  until Value = 0;
end;

function ExtractedData(Reader: TArchiveReader; Index: Integer): string;
var
  Output: TStringStream;
begin
  Output := TStringStream.Create('');
  try
    Reader.ExtractToStream(Index, Output);
    Result := Output.DataString;
  finally
    Output.Free;
  end;
end;

function ReadWholeFile(const Path: string): string;
var
  Input: TFileStream;
begin
  Result := '';
  Input := TFileStream.Create(Path, fmOpenRead);
  try
    SetLength(Result, Input.Size);
    if Input.Size > 0 then
      Input.ReadBuffer(Result[1], Input.Size);
  finally
    Input.Free;
  end;
end;

procedure WriteWholeFile(const Path, Data: string);
var
  Output: TFileStream;
begin
  Output := TFileStream.Create(Path, fmCreate);
  try
    if Data <> '' then
      Output.WriteBuffer(Data[1], Length(Data));
  finally
    Output.Free;
  end;
end;

procedure RemoveTree(const Path: string);
var
  Search: TSearchRec;
  Status: Stat;
  Child: string;
begin
  if FpLstat(Path, Status) <> 0 then
    Exit;
  if not FpS_ISDIR(Status.st_mode) then
  begin
    FpUnlink(Path);
    Exit;
  end;
  FpChmod(Path, &755);
  if FindFirst(Path + '/*', faAnyFile, Search) = 0 then
  begin
    repeat
      if (Search.Name <> '.') and (Search.Name <> '..') then
      begin
        Child := Path + '/' + Search.Name;
        RemoveTree(Child);
      end;
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  FpRmdir(Path);
end;

function NextRandom(var State: LongWord): Byte;
begin
  State := LongWord((QWord(State) * 1103515245 + 12345) and $FFFFFFFF);
  Result := Byte(State shr 16);
end;

function RandomData(Size: Integer; Seed: LongWord): string;
var
  Index: Integer;
  State: LongWord;
begin
  Result := '';
  SetLength(Result, Size);
  State := Seed;
  for Index := 1 to Size do
    Result[Index] := Chr(NextRandom(State));
end;

function MixedData(Size: Integer; Seed: LongWord): string;
var
  State: LongWord;
  Piece: string;
begin
  Result := '';
  State := Seed;
  while Length(Result) < Size do
  begin
    if NextRandom(State) < 128 then
      Piece := Format('line %d of the written archive, ', [NextRandom(State)])
    else
      Piece := RandomData(150, NextRandom(State) + LongWord(Length(Result)));
    Result := Result + Piece;
  end;
  SetLength(Result, Size);
end;

end.
