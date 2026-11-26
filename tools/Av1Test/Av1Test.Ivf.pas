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
  IVF files, the container the AV1 encoders on the host write: a
  32-byte file header ("DKIF", the codec's FourCC, size, time base),
  then frames of a 12-byte header (size, 64-bit timestamp) and the
  frame's data (here a temporal unit of OBUs).
}
unit Av1Test.Ivf;

{$mode objfpc}
{$H+}

interface

uses
  Classes, SysUtils;

type
  TIvfFrame = record
    Data: TBytes;
    Timestamp: Int64;
  end;
  TIvfFrames = array of TIvfFrame;

function ReadIvfFile(const FileName: string; out Width, Height: Integer): TIvfFrames;

implementation

function ReadLittleEndian32(const Data: TBytes; Offset: Integer): LongWord;
begin
  Result := Data[Offset] or (Data[Offset + 1] shl 8) or (Data[Offset + 2] shl 16) or
    (LongWord(Data[Offset + 3]) shl 24);
end;

function ReadIvfFile(const FileName: string; out Width, Height: Integer): TIvfFrames;
var
  Stream: TFileStream;
  Data: TBytes;
  Offset, HeaderSize, FrameSize, Count: Integer;
begin
  Result := nil;
  Data := nil;
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Data, Stream.Size);
    if Length(Data) > 0 then
      Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  if (Length(Data) < 32) or (Data[0] <> Ord('D')) or (Data[1] <> Ord('K')) or (Data[2] <> Ord('I')) or
    (Data[3] <> Ord('F')) then
    raise Exception.Create(FileName + ' is not an IVF file');
  HeaderSize := Data[6] or (Data[7] shl 8);
  Width := Data[12] or (Data[13] shl 8);
  Height := Data[14] or (Data[15] shl 8);
  Offset := HeaderSize;
  Count := 0;
  while Offset + 12 <= Length(Data) do
  begin
    FrameSize := ReadLittleEndian32(Data, Offset);
    if Offset + 12 + FrameSize > Length(Data) then
      raise Exception.Create(FileName + ': frame cut short');
    SetLength(Result, Count + 1);
    Result[Count].Timestamp := Int64(ReadLittleEndian32(Data, Offset + 4)) or
      (Int64(ReadLittleEndian32(Data, Offset + 8)) shl 32);
    SetLength(Result[Count].Data, FrameSize);
    if FrameSize > 0 then
      Move(Data[Offset + 12], Result[Count].Data[0], FrameSize);
    Inc(Count);
    Inc(Offset, 12 + FrameSize);
  end;
end;

end.
