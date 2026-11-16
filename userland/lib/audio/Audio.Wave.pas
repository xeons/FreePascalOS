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
  WAV files: a RIFF file with a "fmt " chunk and a "data" chunk holding
  the samples; other chunks are skipped. Read: integer PCM (8, 16, 24 or
  32 bits), 32-bit float, and the extensible format (more channels,
  integer or float). Written: integer PCM or float.
}
unit Audio.Wave;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TWaveFile = record
    Handle: Int64;
    Rate: LongWord;
    Channels: LongWord;
    BitsPerSample: LongWord;
    { One of the Sample* kinds of Audio.Formats. }
    Kind: LongWord;
    { Bytes of samples left to read. }
    DataBytes: QWord;
  end;

  TWaveStatus = (WaveOk, WaveCannotOpen, WaveNotWave, WaveUnsupported);

{ Opens Path and reads up to its samples. }
function OpenWaveFile(const Path: string; out Wave: TWaveFile): TWaveStatus;
{ Reads the next samples (at most Capacity bytes); 0 at the end. }
function ReadWaveSamples(var Wave: TWaveFile; Buffer: Pointer; Capacity: QWord): QWord;
procedure CloseWaveFile(var Wave: TWaveFile);
function WaveStatusText(Status: TWaveStatus): PChar;

{ The 44-byte header of a WAV file of samples of Kind, DataBytes of them. }
procedure MakeWaveHeader(Header: PByte; Rate, Channels, Kind: LongWord; DataBytes: LongWord);

const
  WaveHeaderSize = 44;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Sys.Files,
  Audio.Formats;

const
  FormatPcm = 1;
  FormatFloat = 3;
  FormatExtensible = $FFFE;

{ The sample kind of a format tag and sample size; 0 if not supported. }
function KindOf(Tag, Bits: LongWord): LongWord;
begin
  Result := 0;
  if Tag = FormatFloat then
  begin
    if Bits = 32 then
      Result := SampleFloat32;
  end
  else if Tag = FormatPcm then
    case Bits of
      8: Result := SampleUnsigned8;
      16: Result := SampleSigned16;
      24: Result := SampleSigned24;
      32: Result := SampleSigned32;
    end;
end;

function ReadExactly(Handle: Int64; Buffer: Pointer; Count: QWord): Boolean;
begin
  Result := ReadFile(Handle, Buffer, Count) = Int64(Count);
end;

function TagIs(Tag: PByte; Expected: PChar): Boolean;
begin
  Result := MemoryIsEqual(Tag, Expected, 4);
end;

function OpenWaveFile(const Path: string; out Wave: TWaveFile): TWaveStatus;
var
  Riff: array[0..11] of Byte;
  ChunkHeader: array[0..7] of Byte;
  Format: array[0..39] of Byte;
  ChunkSize: LongWord;
  HaveFormat: Boolean;
  Tag: LongWord;
  FormatSize: LongWord;
begin
  FillMemory(@Wave, SizeOf(Wave), 0);
  Wave.Handle := OpenFile(PChar(Path), OpenRead);
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
      FormatSize := ChunkSize;
      if FormatSize > SizeOf(Format) then
        FormatSize := SizeOf(Format);
      if not ReadExactly(Wave.Handle, @Format[0], FormatSize) then
        Exit;
      Tag := PWord(@Format[0])^;
      { The extensible format names the real one in its sub-format. }
      if (Tag = FormatExtensible) and (FormatSize >= 26) then
        Tag := PWord(@Format[24])^;
      Wave.Channels := PWord(@Format[2])^;
      Wave.Rate := PLongWord(@Format[4])^;
      Wave.BitsPerSample := PWord(@Format[14])^;
      Wave.Kind := KindOf(Tag, Wave.BitsPerSample);
      if Wave.Kind = 0 then
        Exit(WaveUnsupported);
      HaveFormat := True;
      { Chunks are padded to an even size. }
      SeekFile(Wave.Handle, (ChunkSize - FormatSize) + (ChunkSize and 1), SeekFromCurrent);
    end
    else if TagIs(@ChunkHeader[0], 'data') then
    begin
      if not HaveFormat then
        Exit;
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
    Result := 'an unsupported sample format';
  end;
end;

procedure MakeWaveHeader(Header: PByte; Rate, Channels, Kind: LongWord; DataBytes: LongWord);
var
  SampleBytes: LongWord;
begin
  SampleBytes := BytesPerSample(Kind);
  CopyMemory(Header, PChar('RIFF'), 4);
  PLongWord(Header + 4)^ := 36 + DataBytes;
  CopyMemory(Header + 8, PChar('WAVEfmt '), 8);
  PLongWord(Header + 16)^ := 16;
  if Kind = SampleFloat32 then
    PWord(Header + 20)^ := FormatFloat
  else
    PWord(Header + 20)^ := FormatPcm;
  PWord(Header + 22)^ := Channels;
  PLongWord(Header + 24)^ := Rate;
  PLongWord(Header + 28)^ := Rate * Channels * SampleBytes;
  PWord(Header + 32)^ := Channels * SampleBytes;
  PWord(Header + 34)^ := SampleBytes * 8;
  CopyMemory(Header + 36, PChar('data'), 4);
  PLongWord(Header + 40)^ := DataBytes;
end;

end.
