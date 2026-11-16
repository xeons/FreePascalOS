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
  A PNG picture's data, compressed as it is written: filtered lines go
  into libcompression's TDeflater (zlib, at the level asked for) one
  at a time, and its output goes out as chunks of up to ChunkCapacity
  bytes, IDAT for the default image or fdAT (each with the next
  sequence number in front) for an APNG frame. The picture is never
  held whole in its filtered form.
}
unit Image.Png.DataWriter;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.ByteWriters,
  Compression.Formats,
  Compression.Deflater;

type
  TPngDataWriter = class
  private
    FWriter: TImageByteWriter;
    FDeflater: TDeflater;
    FChunkType: LongWord;
    FSequence: PLongWord;
    FBuffer: TBytes;
    FFilled: PtrInt;
    procedure EmitChunk;
    procedure Drain(Finish: Boolean);
  public
    { Chunks of ChunkType into Writer; for fdAT, Sequence is the APNG
      sequence number, taken and advanced for each chunk. }
    constructor Create(Writer: TImageByteWriter; Level: Integer; ChunkType: LongWord; Sequence: PLongWord);
    destructor Destroy; override;
    procedure Write(Data: PByte; Count: PtrInt);
    { Ends the stream and writes what is left. }
    procedure Finish;
  end;

implementation

uses
  Image.Png.Chunks;

const
  ChunkCapacity = 256 * 1024;
  SequencePrefix = 4;

constructor TPngDataWriter.Create(Writer: TImageByteWriter; Level: Integer; ChunkType: LongWord; Sequence: PLongWord);
begin
  inherited Create;
  FWriter := Writer;
  FChunkType := ChunkType;
  FSequence := Sequence;
  FDeflater := TDeflater.Create(FormatZlib, Level);
  SetLength(FBuffer, SequencePrefix + ChunkCapacity);
  FFilled := 0;
end;

destructor TPngDataWriter.Destroy;
begin
  FDeflater.Free;
  inherited Destroy;
end;

procedure TPngDataWriter.EmitChunk;
var
  Sequence: LongWord;
begin
  if FFilled = 0 then
    Exit;
  if FChunkType = PngChunkFrameData then
  begin
    Sequence := FSequence^;
    Inc(FSequence^);
    FBuffer[0] := Sequence shr 24;
    FBuffer[1] := (Sequence shr 16) and $FF;
    FBuffer[2] := (Sequence shr 8) and $FF;
    FBuffer[3] := Sequence and $FF;
    WritePngChunk(FWriter, FChunkType, @FBuffer[0], SequencePrefix + FFilled);
  end
  else
    WritePngChunk(FWriter, FChunkType, @FBuffer[SequencePrefix], FFilled);
  FFilled := 0;
end;

procedure TPngDataWriter.Drain(Finish: Boolean);
var
  Written: SizeInt;
  Outcome: TDeflateResult;
begin
  repeat
    Outcome := FDeflater.Compress(@FBuffer[SequencePrefix + FFilled], ChunkCapacity - FFilled, Written, Finish);
    Inc(FFilled, Written);
    if (FFilled = ChunkCapacity) or (Outcome = DeflateOutputFull) then
      EmitChunk;
  until (Outcome = DeflateFinished) or ((Outcome = DeflateNeedsInput) and not Finish);
end;

procedure TPngDataWriter.Write(Data: PByte; Count: PtrInt);
begin
  if Count <= 0 then
    Exit;
  FDeflater.SetInput(Data, Count);
  Drain(False);
end;

procedure TPngDataWriter.Finish;
begin
  Drain(True);
  EmitChunk;
end;

end.
