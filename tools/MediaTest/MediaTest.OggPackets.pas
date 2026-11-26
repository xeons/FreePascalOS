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
  A minimal Ogg reader for the codec tests: the packets of a file with
  one logical stream, joined across pages from the lacing values, and
  the last page's granule position. It lets a decoder be tested without
  libmedia's own Ogg demuxer (whose tests are its own).
}
unit MediaTest.OggPackets;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TOggPacketList = array of TBytes;

{ The packets of the Ogg file in Bytes; LastGranule is the final page's
  granule position. Raises on a broken page. }
function SplitOggPackets(const Bytes: TBytes; out LastGranule: Int64): TOggPacketList;

implementation

function SplitOggPackets(const Bytes: TBytes; out LastGranule: Int64): TOggPacketList;
var
  Position, SegmentCount, Segment, DataPosition, Size, Count, Index: Integer;
  Current: TBytes;
  CurrentLength: Integer;
  Granule: Int64;
begin
  Result := nil;
  Count := 0;
  Current := nil;
  CurrentLength := 0;
  LastGranule := 0;
  Position := 0;
  while Position + 27 <= Length(Bytes) do
  begin
    if (Bytes[Position] <> Ord('O')) or (Bytes[Position + 1] <> Ord('g')) or (Bytes[Position + 2] <> Ord('g')) or
      (Bytes[Position + 3] <> Ord('S')) then
      raise Exception.Create('Ogg capture pattern missing');
    Granule := 0;
    for Index := 7 downto 0 do
      Granule := (Granule shl 8) or Bytes[Position + 6 + Index];
    SegmentCount := Bytes[Position + 26];
    DataPosition := Position + 27 + SegmentCount;
    for Segment := 0 to SegmentCount - 1 do
    begin
      Size := Bytes[Position + 27 + Segment];
      if DataPosition + Size > Length(Bytes) then
        raise Exception.Create('Ogg page cut short');
      if CurrentLength + Size > Length(Current) then
        SetLength(Current, (CurrentLength + Size) * 2);
      if Size > 0 then
        Move(Bytes[DataPosition], Current[CurrentLength], Size);
      Inc(CurrentLength, Size);
      Inc(DataPosition, Size);
      if Size < 255 then
      begin
        SetLength(Current, CurrentLength);
        if Count >= Length(Result) then
          SetLength(Result, Count * 2 + 16);
        Result[Count] := Current;
        Inc(Count);
        Current := nil;
        CurrentLength := 0;
      end;
    end;
    if Granule <> -1 then
      LastGranule := Granule;
    Position := DataPosition;
  end;
  SetLength(Result, Count);
end;

end.
