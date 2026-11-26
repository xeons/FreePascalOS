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
  Matroska blocks: a Block or SimpleBlock's track number (a variable-
  length integer), its timestamp relative to the cluster's (16-bit
  signed), its flags (key frame 0x80, invisible 0x08, lacing 0x06,
  discardable 0x01) and its frames.

  Lacing puts several frames in one block: Xiph lacing gives the sizes
  of all but the last in 255-byte steps, EBML lacing the first size and
  then signed differences, fixed-size lacing nothing (equal parts).
}
unit Media.Matroska.Blocks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TBlockFrame = record
    Offset, Size: Integer;
  end;

  TMatroskaBlock = record
    TrackNumber: Int64;
    RelativeTime: Integer;
    Flags: Byte;
    Frames: array of TBlockFrame;
  end;

const
  BlockFlagKey = $80;
  MaximumLacedFrames = 256;

{ Splits a block's bytes; raises EMediaError if they do not add up. }
function ParseBlock(const Data: TBytes): TMatroskaBlock;

implementation

uses
  Media.Errors,
  Media.Ebml;

function ParseBlock(const Data: TBytes): TMatroskaBlock;
var
  Offset, Count, Index, Total, Size, Value: Integer;
  Previous: Int64;
  Lacing: Integer;
begin
  Result := Default(TMatroskaBlock);
  Result.Frames := nil;
  Offset := 0;
  Result.TrackNumber := ReadVintAt(Data, Offset, Length(Data));
  if Offset + 3 > Length(Data) then
    MediaFail('block cut short');
  Result.RelativeTime := SmallInt((Data[Offset] shl 8) or Data[Offset + 1]);
  Result.Flags := Data[Offset + 2];
  Inc(Offset, 3);
  Lacing := (Result.Flags shr 1) and 3;
  if Lacing = 0 then
  begin
    SetLength(Result.Frames, 1);
    Result.Frames[0].Offset := Offset;
    Result.Frames[0].Size := Length(Data) - Offset;
    Exit;
  end;
  if Offset >= Length(Data) then
    MediaFail('block cut short');
  Count := Data[Offset] + 1;
  Inc(Offset);
  SetLength(Result.Frames, Count);
  Total := 0;
  case Lacing of
    1:
      for Index := 0 to Count - 2 do
      begin
        Size := 0;
        repeat
          if Offset >= Length(Data) then
            MediaFail('block lacing cut short');
          Value := Data[Offset];
          Inc(Size, Value);
          Inc(Offset);
        until Value <> 255;
        Result.Frames[Index].Size := Size;
        Inc(Total, Size);
      end;
    3:
      begin
        Previous := ReadVintAt(Data, Offset, Length(Data));
        if (Previous < 0) or (Previous > Length(Data)) then
          MediaFail('bad lace size');
        Result.Frames[0].Size := Previous;
        Total := Previous;
        for Index := 1 to Count - 2 do
        begin
          Previous := Previous + ReadSignedVintAt(Data, Offset, Length(Data));
          if (Previous < 0) or (Previous > Length(Data)) then
            MediaFail('bad lace size');
          Result.Frames[Index].Size := Previous;
          Inc(Total, Previous);
        end;
      end;
    2:
      begin
        if (Length(Data) - Offset) mod Count <> 0 then
          MediaFail('fixed lacing does not divide the block');
        for Index := 0 to Count - 2 do
        begin
          Result.Frames[Index].Size := (Length(Data) - Offset) div Count;
          Inc(Total, Result.Frames[Index].Size);
        end;
      end;
  end;
  if Total > Length(Data) - Offset then
    MediaFail('laced frames run past the block');
  Result.Frames[Count - 1].Size := Length(Data) - Offset - Total;
  for Index := 0 to Count - 1 do
  begin
    Result.Frames[Index].Offset := Offset;
    Inc(Offset, Result.Frames[Index].Size);
  end;
end;

end.
