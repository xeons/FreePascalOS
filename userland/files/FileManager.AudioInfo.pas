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
  What a sound file says about itself, for the Length column, the
  details pane and the preview: a WAV file's (RIFF "WAVE") format chunk
  and data size give its rate, channels, bits and length. Other formats
  are not read yet (their length stays unknown). ParseWaveHeader works
  on bytes, so the host checks it (make files-test).
}
unit FileManager.AudioInfo;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TAudioInfo = record
    SampleRate: LongWord;
    Channels: Word;
    BitsPerSample: Word;
    DurationSeconds: LongInt;
  end;

{ Reads a WAV file's header from its first bytes; False if it is not
  one. }
function ParseWaveHeader(const Bytes: TBytes; out Info: TAudioInfo): Boolean;
function ReadAudioInfo(const Path: string; out Info: TAudioInfo): Boolean;

implementation

uses
  Classes;

function LittleWord(const Bytes: TBytes; Offset: LongInt): LongWord;
begin
  Result := Bytes[Offset] or (LongWord(Bytes[Offset + 1]) shl 8);
end;

function LittleLong(const Bytes: TBytes; Offset: LongInt): LongWord;
begin
  Result := LittleWord(Bytes, Offset) or (LittleWord(Bytes, Offset + 2) shl 16);
end;

function TagAt(const Bytes: TBytes; Offset: LongInt; const Tag: string): Boolean;
var
  Index: LongInt;
begin
  if Offset + 4 > Length(Bytes) then
    Exit(False);
  for Index := 0 to 3 do
    if Chr(Bytes[Offset + Index]) <> Tag[Index + 1] then
      Exit(False);
  Result := True;
end;

function ParseWaveHeader(const Bytes: TBytes; out Info: TAudioInfo): Boolean;
var
  Offset: LongInt;
  ChunkSize: LongWord;
  ByteRate: LongWord;
  HaveFormat: Boolean;
begin
  Info := Default(TAudioInfo);
  Info.DurationSeconds := -1;
  Result := False;
  if (Length(Bytes) < 12) or not TagAt(Bytes, 0, 'RIFF') or not TagAt(Bytes, 8, 'WAVE') then
    Exit;
  Offset := 12;
  ByteRate := 0;
  HaveFormat := False;
  while Offset + 8 <= Length(Bytes) do
  begin
    ChunkSize := LittleLong(Bytes, Offset + 4);
    if TagAt(Bytes, Offset, 'fmt ') and (Offset + 24 <= Length(Bytes)) then
    begin
      Info.Channels := LittleWord(Bytes, Offset + 10);
      Info.SampleRate := LittleLong(Bytes, Offset + 12);
      ByteRate := LittleLong(Bytes, Offset + 16);
      Info.BitsPerSample := LittleWord(Bytes, Offset + 22);
      HaveFormat := True;
    end
    else if TagAt(Bytes, Offset, 'data') then
    begin
      if HaveFormat and (ByteRate > 0) then
        Info.DurationSeconds := LongInt(QWord(ChunkSize) div ByteRate);
      Exit(HaveFormat);
    end;
    Offset := Offset + 8 + LongInt(ChunkSize) + LongInt(ChunkSize and 1);
  end;
  Result := HaveFormat;
end;

function ReadAudioInfo(const Path: string; out Info: TAudioInfo): Boolean;
var
  Stream: TFileStream;
  Bytes: TBytes;
  Count: LongInt;
begin
  Info := Default(TAudioInfo);
  Info.DurationSeconds := -1;
  Bytes := nil;
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Count := Stream.Size;
      if Count > 4096 then
        Count := 4096;
      SetLength(Bytes, Count);
      if Count > 0 then
        Stream.ReadBuffer(Bytes[0], Count);
    finally
      Stream.Free;
    end;
  except
    on Exception do
      Exit(False);
  end;
  Result := ParseWaveHeader(Bytes, Info);
end;

end.
