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
  PCM WAV files: a RIFF file with a "fmt " chunk (format 1, PCM) and a
  "data" chunk holding the samples. Only 16-bit samples are read; other
  chunks are skipped.
}
unit Audio.Wave;

{$mode objfpc}
{$pointermath on}

interface

type
  TWaveFile = record
    Handle: Int64;
    Rate: LongWord;
    Channels: LongWord;
    BitsPerSample: LongWord;
    { Bytes of samples left to read. }
    DataBytes: QWord;
  end;

  TWaveStatus = (WaveOk, WaveCannotOpen, WaveNotWave, WaveUnsupported);

{ Opens Path and reads up to its samples. }
function OpenWaveFile(Path: PChar; out Wave: TWaveFile): TWaveStatus;
{ Reads the next samples (at most Capacity bytes); 0 at the end. }
function ReadWaveSamples(var Wave: TWaveFile; Buffer: Pointer; Capacity: QWord): QWord;
procedure CloseWaveFile(var Wave: TWaveFile);
function WaveStatusText(Status: TWaveStatus): PChar;

{ The 44-byte header of a 16-bit PCM WAV file with DataBytes of samples. }
procedure MakeWaveHeader(Header: PByte; Rate, Channels: LongWord; DataBytes: LongWord);

const
  WaveHeaderSize = 44;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Sys.Files;

const
  FormatPcm = 1;

function ReadExactly(Handle: Int64; Buffer: Pointer; Count: QWord): Boolean;
begin
  Result := ReadFile(Handle, Buffer, Count) = Int64(Count);
end;

function TagIs(Tag: PByte; Expected: PChar): Boolean;
begin
  Result := MemoryIsEqual(Tag, Expected, 4);
end;

function OpenWaveFile(Path: PChar; out Wave: TWaveFile): TWaveStatus;
var
  Riff: array[0..11] of Byte;
  ChunkHeader: array[0..7] of Byte;
  Format: array[0..15] of Byte;
  ChunkSize: LongWord;
  HaveFormat: Boolean;
begin
  FillMemory(@Wave, SizeOf(Wave), 0);
  Wave.Handle := OpenFile(Path, OpenRead);
  if Wave.Handle < 0 then
    Exit(WaveCannotOpen);
  Result := WaveNotWave;
  if not ReadExactly(Wave.Handle, @Riff[0], SizeOf(Riff)) or not TagIs(@Riff[0], 'RIFF') or
     not TagIs(@Riff[8], 'WAVE') then
    Exit;
  HaveFormat := False;
  while ReadExactly(Wave.Handle, @ChunkHeader[0], SizeOf(ChunkHeader)) do
  begin
    ChunkSize := PLongWord(@ChunkHeader[4])^;
    if TagIs(@ChunkHeader[0], 'fmt ') and (ChunkSize >= 16) then
    begin
      if not ReadExactly(Wave.Handle, @Format[0], 16) then
        Exit;
      if PWord(@Format[0])^ <> FormatPcm then
        Exit(WaveUnsupported);
      Wave.Channels := PWord(@Format[2])^;
      Wave.Rate := PLongWord(@Format[4])^;
      Wave.BitsPerSample := PWord(@Format[14])^;
      HaveFormat := True;
      { Chunks are padded to an even size. }
      SeekFile(Wave.Handle, (ChunkSize - 16) + (ChunkSize and 1), SeekFromCurrent);
    end
    else if TagIs(@ChunkHeader[0], 'data') then
    begin
      if not HaveFormat then
        Exit;
      if Wave.BitsPerSample <> 16 then
        Exit(WaveUnsupported);
      Wave.DataBytes := ChunkSize;
      Exit(WaveOk);
    end
    else
      SeekFile(Wave.Handle, ChunkSize + (ChunkSize and 1), SeekFromCurrent);
  end;
end;

function ReadWaveSamples(var Wave: TWaveFile; Buffer: Pointer; Capacity: QWord): QWord;
var
  Count: Int64;
begin
  if Capacity > Wave.DataBytes then
    Capacity := Wave.DataBytes;
  Count := ReadFile(Wave.Handle, Buffer, Capacity);
  if Count <= 0 then
    Exit(0);
  Result := QWord(Count);
  Wave.DataBytes := Wave.DataBytes - Result;
end;

procedure CloseWaveFile(var Wave: TWaveFile);
begin
  if Wave.Handle >= 0 then
    CloseFile(Wave.Handle);
  Wave.Handle := -1;
end;

function WaveStatusText(Status: TWaveStatus): PChar;
begin
  case Status of
    WaveOk: Result := 'ok';
    WaveCannotOpen: Result := 'cannot open';
    WaveNotWave: Result := 'not a WAV file';
  else
    Result := 'not 16-bit PCM';
  end;
end;

procedure MakeWaveHeader(Header: PByte; Rate, Channels: LongWord; DataBytes: LongWord);
begin
  CopyMemory(Header, PChar('RIFF'), 4);
  PLongWord(Header + 4)^ := 36 + DataBytes;
  CopyMemory(Header + 8, PChar('WAVEfmt '), 8);
  PLongWord(Header + 16)^ := 16;
  PWord(Header + 20)^ := FormatPcm;
  PWord(Header + 22)^ := Channels;
  PLongWord(Header + 24)^ := Rate;
  PLongWord(Header + 28)^ := Rate * Channels * 2;
  PWord(Header + 32)^ := Channels * 2;
  PWord(Header + 34)^ := 16;
  CopyMemory(Header + 36, PChar('data'), 4);
  PLongWord(Header + 40)^ := DataBytes;
end;

end.
