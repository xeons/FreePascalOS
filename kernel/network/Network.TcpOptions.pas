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
  TCP options: reading them from a segment and writing them into one.

    2  maximum segment size (SYN only)           RFC 9293
    3  window scale (SYN only)                   RFC 7323
    4  SACK permitted (SYN only)                 RFC 2018
    5  SACK blocks (any segment but a SYN)       RFC 2018
    8  timestamps (TSval, TSecr)                 RFC 7323

  Written in the layout most stacks use, so that every option falls on
  the alignment the RFCs suggest: on a SYN the MSS, SACK permitted and
  timestamps together (or each padded with two no-operations), then a
  no-operation and the window scale - 20 bytes with everything; on
  other segments two no-operations and the timestamps (12 bytes), then
  two no-operations and the SACK blocks (4 + 8 per block). The whole is
  a multiple of four bytes, as the data offset needs.

  Reading stops at the end-of-options byte or at a malformed length; an
  option of the wrong length is passed over. A window scale above 14 is
  taken as 14 (RFC 7323 2.3).

  Pure: no kernel units, so the host test (tools/TcpTest) builds it.
}
unit Network.TcpOptions;

{$mode objfpc}
{$pointermath on}

interface

const
  TcpOptionEnd = 0;
  TcpOptionNoOperation = 1;
  TcpOptionMaximumSegment = 2;
  TcpOptionWindowScale = 3;
  TcpOptionSackPermitted = 4;
  TcpOptionSack = 5;
  TcpOptionTimestamps = 8;

  { The most option bytes a header has room for. }
  MaximumTcpOptionBytes = 40;
  MaximumWindowShift = 14;
  { The most SACK blocks a segment carries (four without timestamps,
    three beside them). }
  MaximumSackBlocks = 4;
  { The timestamps option with its two no-operations. }
  TimestampOptionBytes = 12;

type
  { A stretch of sequence space: from Start up to (not including)
    Finish - a SACK block's left and right edges. }
  TSackBlock = record
    Start: LongWord;
    Finish: LongWord;
  end;

  TTcpOptions = record
    HasMaximumSegment: Boolean;
    MaximumSegment: Word;
    HasWindowScale: Boolean;
    WindowShift: Byte;
    SackPermitted: Boolean;
    HasTimestamps: Boolean;
    TimestampValue: LongWord;
    TimestampEcho: LongWord;
    SackBlockCount: LongWord;
    SackBlocks: array[0..MaximumSackBlocks - 1] of TSackBlock;
  end;

procedure ClearTcpOptions(out Options: TTcpOptions);
procedure ParseTcpOptions(Source: PByte; Length: LongWord; out Options: TTcpOptions);
{ The bytes WriteTcpOptions writes (a multiple of four). The SYN-only
  options are written only when IsSyn, the SACK blocks only when not. }
function TcpOptionsLength(constref Options: TTcpOptions; IsSyn: Boolean): LongWord;
function WriteTcpOptions(Destination: PByte; constref Options: TTcpOptions; IsSyn: Boolean): LongWord;
{ How many SACK blocks fit in Room option bytes beside the rest of
  Options (at most MaximumSackBlocks). }
function SackBlocksThatFit(constref Options: TTcpOptions; Room: LongWord): LongWord;

implementation

uses
  Runtime.Memory,
  Network.ByteOrder;

const
  MaximumSegmentLength = 4;
  WindowScaleLength = 3;
  SackPermittedLength = 2;
  TimestampsLength = 10;
  SackBlockBytes = 8;

procedure ClearTcpOptions(out Options: TTcpOptions);
begin
  FillMemory(@Options, SizeOf(Options), 0);
end;

procedure ReadSackBlocks(Source: PByte; Length: LongWord; var Options: TTcpOptions);
var
  Count: LongWord;
  Index: LongWord;
begin
  if (Length < 2 + SackBlockBytes) or (((Length - 2) mod SackBlockBytes) <> 0) then
    Exit;
  Count := (Length - 2) div SackBlockBytes;
  if Count > MaximumSackBlocks then
    Count := MaximumSackBlocks;
  Index := 0;
  while Index < Count do
  begin
    Options.SackBlocks[Index].Start := ReadBigEndian32(Source + 2 + Index * SackBlockBytes);
    Options.SackBlocks[Index].Finish := ReadBigEndian32(Source + 6 + Index * SackBlockBytes);
    Inc(Index);
  end;
  Options.SackBlockCount := Count;
end;

procedure ReadOneOption(Source: PByte; Length: LongWord; var Options: TTcpOptions);
begin
  case Source[0] of
    TcpOptionMaximumSegment:
      if Length = MaximumSegmentLength then
      begin
        Options.HasMaximumSegment := True;
        Options.MaximumSegment := ReadBigEndian16(Source + 2);
      end;
    TcpOptionWindowScale:
      if Length = WindowScaleLength then
      begin
        Options.HasWindowScale := True;
        Options.WindowShift := Source[2];
        if Options.WindowShift > MaximumWindowShift then
          Options.WindowShift := MaximumWindowShift;
      end;
    TcpOptionSackPermitted:
      if Length = SackPermittedLength then
        Options.SackPermitted := True;
    TcpOptionSack:
      ReadSackBlocks(Source, Length, Options);
    TcpOptionTimestamps:
      if Length = TimestampsLength then
      begin
        Options.HasTimestamps := True;
        Options.TimestampValue := ReadBigEndian32(Source + 2);
        Options.TimestampEcho := ReadBigEndian32(Source + 6);
      end;
  end;
end;

procedure ParseTcpOptions(Source: PByte; Length: LongWord; out Options: TTcpOptions);
var
  Position: LongWord;
  OptionLength: LongWord;
begin
  ClearTcpOptions(Options);
  Position := 0;
  while Position < Length do
  begin
    case Source[Position] of
      TcpOptionEnd:
        Exit;
      TcpOptionNoOperation:
        Inc(Position);
    else
      begin
        if Position + 1 >= Length then
          Exit;
        OptionLength := Source[Position + 1];
        if (OptionLength < 2) or (Position + OptionLength > Length) then
          Exit;
        ReadOneOption(Source + Position, OptionLength, Options);
        Position := Position + OptionLength;
      end;
    end;
  end;
end;

{ The bytes of everything but the SACK blocks. }
function FixedOptionsLength(constref Options: TTcpOptions; IsSyn: Boolean): LongWord;
begin
  Result := 0;
  if IsSyn then
  begin
    if Options.HasMaximumSegment then
      Result := Result + MaximumSegmentLength;
    { SACK permitted and timestamps share their padding. }
    if Options.SackPermitted and Options.HasTimestamps then
      Result := Result + SackPermittedLength + TimestampsLength
    else if Options.HasTimestamps then
      Result := Result + TimestampOptionBytes
    else if Options.SackPermitted then
      Result := Result + 2 + SackPermittedLength;
    if Options.HasWindowScale then
      Result := Result + 1 + WindowScaleLength;
  end
  else if Options.HasTimestamps then
    Result := Result + TimestampOptionBytes;
end;

function SackBytes(Count: LongWord): LongWord;
begin
  if Count = 0 then
    Exit(0);
  Result := 2 + 2 + Count * SackBlockBytes;
end;

function TcpOptionsLength(constref Options: TTcpOptions; IsSyn: Boolean): LongWord;
begin
  Result := FixedOptionsLength(Options, IsSyn);
  if not IsSyn then
    Result := Result + SackBytes(Options.SackBlockCount);
end;

function SackBlocksThatFit(constref Options: TTcpOptions; Room: LongWord): LongWord;
var
  Fixed: LongWord;
begin
  Fixed := FixedOptionsLength(Options, False);
  if Room > MaximumTcpOptionBytes then
    Room := MaximumTcpOptionBytes;
  if Room < Fixed + SackBytes(1) then
    Exit(0);
  Result := (Room - Fixed - 4) div SackBlockBytes;
  if Result > MaximumSackBlocks then
    Result := MaximumSackBlocks;
end;

function WriteTimestamps(Destination: PByte; constref Options: TTcpOptions): LongWord;
begin
  Destination[0] := TcpOptionTimestamps;
  Destination[1] := TimestampsLength;
  WriteBigEndian32(Destination + 2, Options.TimestampValue);
  WriteBigEndian32(Destination + 6, Options.TimestampEcho);
  Result := TimestampsLength;
end;

function WriteSynOptions(Destination: PByte; constref Options: TTcpOptions): LongWord;
var
  Position: LongWord;
begin
  Position := 0;
  if Options.HasMaximumSegment then
  begin
    Destination[0] := TcpOptionMaximumSegment;
    Destination[1] := MaximumSegmentLength;
    WriteBigEndian16(Destination + 2, Options.MaximumSegment);
    Position := MaximumSegmentLength;
  end;
  if Options.SackPermitted and Options.HasTimestamps then
  begin
    Destination[Position] := TcpOptionSackPermitted;
    Destination[Position + 1] := SackPermittedLength;
    Position := Position + SackPermittedLength;
    Position := Position + WriteTimestamps(Destination + Position, Options);
  end
  else if Options.HasTimestamps then
  begin
    Destination[Position] := TcpOptionNoOperation;
    Destination[Position + 1] := TcpOptionNoOperation;
    Position := Position + 2;
    Position := Position + WriteTimestamps(Destination + Position, Options);
  end
  else if Options.SackPermitted then
  begin
    Destination[Position] := TcpOptionNoOperation;
    Destination[Position + 1] := TcpOptionNoOperation;
    Destination[Position + 2] := TcpOptionSackPermitted;
    Destination[Position + 3] := SackPermittedLength;
    Position := Position + 4;
  end;
  if Options.HasWindowScale then
  begin
    Destination[Position] := TcpOptionNoOperation;
    Destination[Position + 1] := TcpOptionWindowScale;
    Destination[Position + 2] := WindowScaleLength;
    Destination[Position + 3] := Options.WindowShift;
    Position := Position + 4;
  end;
  Result := Position;
end;

function WriteOtherOptions(Destination: PByte; constref Options: TTcpOptions): LongWord;
var
  Position: LongWord;
  Index: LongWord;
  Count: LongWord;
begin
  Position := 0;
  if Options.HasTimestamps then
  begin
    Destination[0] := TcpOptionNoOperation;
    Destination[1] := TcpOptionNoOperation;
    Position := 2 + WriteTimestamps(Destination + 2, Options);
  end;
  Count := Options.SackBlockCount;
  if Count > MaximumSackBlocks then
    Count := MaximumSackBlocks;
  if Count > 0 then
  begin
    Destination[Position] := TcpOptionNoOperation;
    Destination[Position + 1] := TcpOptionNoOperation;
    Destination[Position + 2] := TcpOptionSack;
    Destination[Position + 3] := Byte(2 + Count * SackBlockBytes);
    Position := Position + 4;
    Index := 0;
    while Index < Count do
    begin
      WriteBigEndian32(Destination + Position, Options.SackBlocks[Index].Start);
      WriteBigEndian32(Destination + Position + 4, Options.SackBlocks[Index].Finish);
      Position := Position + SackBlockBytes;
      Inc(Index);
    end;
  end;
  Result := Position;
end;

function WriteTcpOptions(Destination: PByte; constref Options: TTcpOptions; IsSyn: Boolean): LongWord;
begin
  if IsSyn then
    Result := WriteSynOptions(Destination, Options)
  else
    Result := WriteOtherOptions(Destination, Options);
end;

end.
