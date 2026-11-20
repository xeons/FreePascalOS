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
  Taking an HTTP/3 stream apart into frames as its bytes arrive, in any
  pieces. A DATA frame's payload comes out as it arrives, in pieces,
  without being collected first (bodies stream through); every other
  frame comes out whole, at most MaximumPayload bytes (a larger one is
  H3_EXCESSIVE_LOAD's business: Next says FrameTooLarge). Frames of
  reserved and unknown types are passed over as they arrive, however
  long they are (RFC 9114 section 9).
}
unit Http3.FrameParser;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  THttp3ParseResult = (ParseNeedMore, ParseData, ParseFrame, ParseFrameTooLarge);

  THttp3FrameParser = class
  private
    FBuffer: array of Byte;
    FStart: Integer;
    FFinish: Integer;
    FDataRemaining: QWord;
    FSkipRemaining: QWord;
    FMaximumPayload: QWord;
  public
    constructor Create(MaximumPayload: QWord);
    procedure Append(Data: PByte; Count: PtrUInt);
    { The next thing on the stream: a piece of DATA payload (Data,
      Length; valid until the next call), a whole other frame
      (FrameType, Data, Length), or ParseNeedMore. }
    function Next(out FrameType: QWord; out Data: PByte; out Length: PtrUInt): THttp3ParseResult;
    { No partial frame is waiting (the stream may end here). }
    function AtFrameBoundary: Boolean;
    { Bytes appended and not yet taken. }
    function Buffered: Integer;
  end;

implementation

uses
  Http3.Constants,
  Quic.VariableIntegers;

constructor THttp3FrameParser.Create(MaximumPayload: QWord);
begin
  inherited Create;
  FMaximumPayload := MaximumPayload;
end;

procedure THttp3FrameParser.Append(Data: PByte; Count: PtrUInt);
begin
  if Count = 0 then
    Exit;
  { Move what is left to the front before growing. }
  if (FStart > 0) and (FFinish + Integer(Count) > System.Length(FBuffer)) then
  begin
    if FFinish > FStart then
      Move(FBuffer[FStart], FBuffer[0], FFinish - FStart);
    FFinish := FFinish - FStart;
    FStart := 0;
  end;
  if FFinish + Integer(Count) > System.Length(FBuffer) then
    SetLength(FBuffer, (FFinish + Integer(Count)) * 2 + 256);
  Move(Data^, FBuffer[FFinish], Count);
  FFinish := FFinish + Integer(Count);
end;

function THttp3FrameParser.Buffered: Integer;
begin
  Result := FFinish - FStart;
end;

function THttp3FrameParser.AtFrameBoundary: Boolean;
begin
  Result := (FDataRemaining = 0) and (FSkipRemaining = 0) and (FFinish = FStart);
end;

function THttp3FrameParser.Next(out FrameType: QWord; out Data: PByte; out Length: PtrUInt): THttp3ParseResult;
var
  TypeLength, LengthLength: Integer;
  PayloadLength, Take: QWord;
begin
  FrameType := 0;
  Data := nil;
  Length := 0;
  while True do
  begin
    if FSkipRemaining > 0 then
    begin
      Take := FFinish - FStart;
      if Take > FSkipRemaining then
        Take := FSkipRemaining;
      FStart := FStart + Integer(Take);
      FSkipRemaining := FSkipRemaining - Take;
      if FSkipRemaining > 0 then
        Exit(ParseNeedMore);
    end;
    if FDataRemaining > 0 then
    begin
      if FFinish = FStart then
        Exit(ParseNeedMore);
      Take := FFinish - FStart;
      if Take > FDataRemaining then
        Take := FDataRemaining;
      FrameType := Http3FrameData;
      Data := @FBuffer[FStart];
      Length := Take;
      FStart := FStart + Integer(Take);
      FDataRemaining := FDataRemaining - Take;
      Exit(ParseData);
    end;
    if FFinish = FStart then
      Exit(ParseNeedMore);
    TypeLength := DecodeVariableInteger(@FBuffer[FStart], FFinish - FStart, FrameType);
    if TypeLength = 0 then
      Exit(ParseNeedMore);
    LengthLength := DecodeVariableInteger(@FBuffer[FStart + TypeLength], FFinish - FStart - TypeLength,
      PayloadLength);
    if LengthLength = 0 then
      Exit(ParseNeedMore);
    if FrameType = Http3FrameData then
    begin
      FStart := FStart + TypeLength + LengthLength;
      FDataRemaining := PayloadLength;
      Continue;
    end;
    { Known types come out whole (HTTP/2's 0x02, 0x06, 0x08 and 0x09
      too: they are errors for the caller to find). }
    if (FrameType > $0D) or not (Byte(FrameType) in [Http3FrameHeaders, Http3FrameCancelPush, Http3FrameSettings,
      Http3FramePushPromise, Http3FrameGoaway, Http3FrameMaxPushId, $02, $06, $08, $09]) then
    begin
      { Unknown or reserved: passed over. }
      FStart := FStart + TypeLength + LengthLength;
      FSkipRemaining := PayloadLength;
      Continue;
    end;
    if PayloadLength > FMaximumPayload then
      Exit(ParseFrameTooLarge);
    if QWord(FFinish - FStart - TypeLength - LengthLength) < PayloadLength then
      Exit(ParseNeedMore);
    Data := @FBuffer[FStart + TypeLength + LengthLength];
    Length := PayloadLength;
    FStart := FStart + TypeLength + LengthLength + Integer(PayloadLength);
    Exit(ParseFrame);
  end;
end;

end.
