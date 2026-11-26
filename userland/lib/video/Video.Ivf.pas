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
  IVF files: the simple container the VP8 and VP9 reference tools write
  (a 32-byte header with the codec's four character code, the size and
  the time base, then each frame's size, timestamp and data).
}
unit Video.Ivf;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  EIvfError = class(Exception);

  TIvfFrame = record
    Data: TBytes;
    Timestamp: Int64;
  end;

  TIvfReader = class
  private
    FData: TBytes;
    FPosition: PtrInt;
    FFourCC: string;
    FWidth, FHeight: LongInt;
    FRate, FScale: LongWord;
    FFrameCount: LongWord;
  public
    { Reads an IVF file held in Data. Raises EIvfError when it is not
      one. }
    constructor Create(const Data: TBytes);
    { The next frame; False at the end. }
    function ReadFrame(out Frame: TIvfFrame): Boolean;
    { 'VP80', 'VP90', 'AV01'. }
    property FourCC: string read FFourCC;
    property Width: LongInt read FWidth;
    property Height: LongInt read FHeight;
    { The time base: timestamps count Scale / Rate seconds. }
    property Rate: LongWord read FRate;
    property Scale: LongWord read FScale;
    property FrameCount: LongWord read FFrameCount;
  end;

implementation

function ReadLittle16(const Data: TBytes; Position: PtrInt): LongWord;
begin
  Result := Data[Position] or (LongWord(Data[Position + 1]) shl 8);
end;

function ReadLittle32(const Data: TBytes; Position: PtrInt): LongWord;
begin
  Result := ReadLittle16(Data, Position) or (ReadLittle16(Data, Position + 2) shl 16);
end;

constructor TIvfReader.Create(const Data: TBytes);
var
  HeaderSize: LongWord;
begin
  inherited Create;
  FData := Data;
  if (Length(Data) < 32) or (Data[0] <> Ord('D')) or (Data[1] <> Ord('K')) or
    (Data[2] <> Ord('I')) or (Data[3] <> Ord('F')) then
    raise EIvfError.Create('not an IVF file');
  HeaderSize := ReadLittle16(Data, 6);
  if (HeaderSize < 32) or (HeaderSize > LongWord(Length(Data))) then
    raise EIvfError.Create('bad IVF header size');
  SetLength(FFourCC, 4);
  Move(Data[8], FFourCC[1], 4);
  FWidth := ReadLittle16(Data, 12);
  FHeight := ReadLittle16(Data, 14);
  FRate := ReadLittle32(Data, 16);
  FScale := ReadLittle32(Data, 20);
  FFrameCount := ReadLittle32(Data, 24);
  FPosition := HeaderSize;
end;

function TIvfReader.ReadFrame(out Frame: TIvfFrame): Boolean;
var
  Size: LongWord;
begin
  Frame.Data := nil;
  Frame.Timestamp := 0;
  if FPosition + 12 > Length(FData) then
    Exit(False);
  Size := ReadLittle32(FData, FPosition);
  Frame.Timestamp := Int64(ReadLittle32(FData, FPosition + 4)) or
    (Int64(ReadLittle32(FData, FPosition + 8)) shl 32);
  Inc(FPosition, 12);
  if FPosition + Size > Length(FData) then
    raise EIvfError.Create('truncated IVF frame');
  SetLength(Frame.Data, Size);
  if Size > 0 then
    Move(FData[FPosition], Frame.Data[0], Size);
  Inc(FPosition, Size);
  Result := True;
end;

end.
