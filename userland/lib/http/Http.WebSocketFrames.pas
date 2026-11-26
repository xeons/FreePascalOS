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
  WebSocket frames (RFC 6455 section 5): the frame header with its
  three payload length forms, masking, and the reader a client puts the
  server's bytes through.

  The reader takes bytes in pieces of any size and gives back whole
  items: a data message (its frames joined, the compressed bit of its
  first frame kept for permessage-deflate), a ping, a pong or a close
  (code and reason). It fails the connection as section 7.1.7 says,
  with the close code to send:

    1002  a reserved opcode, RSV2/RSV3, RSV1 without an extension that
          gives it a meaning or on a continuation or control frame, a
          masked frame from the server, a control frame that is
          fragmented or longer than 125 bytes, a continuation with no
          message or a new message inside one, a 64-bit length with the
          top bit set, a close payload of one byte or with a code that
          may not be sent
    1007  a close reason that is not UTF-8
    1009  a message longer than MaximumMessageBytes

  Text messages are checked as UTF-8 by the connection once they are
  decompressed (IsValidUtf8).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.WebSocketFrames;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

const
  WebSocketOpContinuation = 0;
  WebSocketOpText = 1;
  WebSocketOpBinary = 2;
  WebSocketOpClose = 8;
  WebSocketOpPing = 9;
  WebSocketOpPong = 10;

  { Close codes (section 7.4.1). }
  WebSocketCloseNormal = 1000;
  WebSocketCloseGoingAway = 1001;
  WebSocketCloseProtocolError = 1002;
  WebSocketCloseUnsupportedData = 1003;
  WebSocketCloseNoStatus = 1005;
  WebSocketCloseAbnormal = 1006;
  WebSocketCloseInvalidData = 1007;
  WebSocketClosePolicyViolation = 1008;
  WebSocketCloseTooBig = 1009;
  WebSocketCloseMandatoryExtension = 1010;
  WebSocketCloseInternalError = 1011;
  WebSocketCloseTlsFailure = 1015;

  { The most a control frame's payload may hold. }
  WebSocketControlPayloadLimit = 125;
  DefaultWebSocketMessageLimit = 256 * 1024 * 1024;

type
  TWebSocketMaskKey = array[0..3] of Byte;

  TWebSocketFrameHeader = record
    Fin, Rsv1, Rsv2, Rsv3: Boolean;
    Opcode: Byte;
    Masked: Boolean;
    MaskKey: TWebSocketMaskKey;
    PayloadLength: QWord;
  end;

  THeaderParse = (HeaderIncomplete, HeaderParsed, HeaderMalformed);

  TWebSocketItemKind = (WebSocketItemMessage, WebSocketItemPing, WebSocketItemPong, WebSocketItemClose);

  TWebSocketItem = record
    Kind: TWebSocketItemKind;
    { Messages: text or binary, and whether its first frame had RSV1. }
    IsText: Boolean;
    Compressed: Boolean;
    Payload: TBytes;
    { Close: whether a code came, the code and the reason. }
    HasCode: Boolean;
    Code: Word;
    Reason: string;
  end;

  TReaderStep = (ReaderNeedsMore, ReaderItem, ReaderFailed);

  TWebSocketFrameReader = class
  private
    FBuffer: TBytes;
    FStart, FEnd: PtrUInt;
    FInMessage: Boolean;
    FMessageIsText: Boolean;
    FMessageCompressed: Boolean;
    FMessage: TBytes;
    FMessageLength: PtrUInt;
    FFailed: Boolean;
    FFailCode: Word;
    FFailReason: string;
    FAllowRsv1: Boolean;
    FMaximumMessageBytes: QWord;
    function Fail(Code: Word; const Reason: string): TReaderStep;
    procedure AppendToMessage(Data: PByte; Count: PtrUInt);
    function TakeControl(constref Header: TWebSocketFrameHeader; Data: PByte; out Item: TWebSocketItem): TReaderStep;
  public
    constructor Create;
    { Bytes from the server, in order. }
    procedure Feed(Data: Pointer; Count: PtrUInt);
    { The next whole item, if one is there. After ReaderFailed the
      reader stays failed (FailCode, FailReason). }
    function Next(out Item: TWebSocketItem): TReaderStep;
    { RSV1 means a compressed message (permessage-deflate). }
    property AllowRsv1: Boolean read FAllowRsv1 write FAllowRsv1;
    property MaximumMessageBytes: QWord read FMaximumMessageBytes write FMaximumMessageBytes;
    property FailCode: Word read FFailCode;
    property FailReason: string read FFailReason;
  end;

{ Header (2 to 14 bytes) and payload of one frame; Mask: masked with
  MaskKey (every frame a client sends is). }
function EncodeWebSocketFrame(Opcode: Byte; Fin, Rsv1: Boolean; Payload: PByte; Count: PtrUInt; Mask: Boolean;
  constref MaskKey: TWebSocketMaskKey): TBytes;
{ XORs Data with the key, Offset bytes into the payload. }
procedure ApplyWebSocketMask(Data: PByte; Count: PtrUInt; constref MaskKey: TWebSocketMaskKey; Offset: QWord = 0);
function ParseWebSocketFrameHeader(Data: PByte; Available: PtrUInt; out Header: TWebSocketFrameHeader;
  out HeaderLength: Integer): THeaderParse;
{ A close frame's payload: the code (big-endian) and the reason; no code
  (0) gives an empty payload. }
function EncodeClosePayload(Code: Word; const Reason: string): TBytes;
{ A code an endpoint may put in a close frame (1000-1003, 1007-1014,
  3000-4999). }
function IsSendableCloseCode(Code: Word): Boolean;
{ Well-formed UTF-8 (no overlongs, surrogates or code points past
  U+10FFFF). }
function IsValidUtf8(Data: PByte; Count: PtrUInt): Boolean;

implementation

function EncodeWebSocketFrame(Opcode: Byte; Fin, Rsv1: Boolean; Payload: PByte; Count: PtrUInt; Mask: Boolean;
  constref MaskKey: TWebSocketMaskKey): TBytes;
var
  HeaderLength, Index: Integer;
  First: Byte;
  Length_: QWord;
begin
  Result := nil;
  Length_ := Count;
  if Length_ <= 125 then
    HeaderLength := 2
  else if Length_ <= $FFFF then
    HeaderLength := 4
  else
    HeaderLength := 10;
  if Mask then
    Inc(HeaderLength, 4);
  SetLength(Result, HeaderLength + Count);
  First := Opcode and $0F;
  if Fin then
    First := First or $80;
  if Rsv1 then
    First := First or $40;
  Result[0] := First;
  if Length_ <= 125 then
    Result[1] := Byte(Length_)
  else if Length_ <= $FFFF then
  begin
    Result[1] := 126;
    Result[2] := Byte(Length_ shr 8);
    Result[3] := Byte(Length_);
  end
  else
  begin
    Result[1] := 127;
    for Index := 0 to 7 do
      Result[2 + Index] := Byte(Length_ shr (8 * (7 - Index)));
  end;
  if Mask then
  begin
    Result[1] := Result[1] or $80;
    Move(MaskKey[0], Result[HeaderLength - 4], 4);
  end;
  if Count > 0 then
  begin
    Move(Payload^, Result[HeaderLength], Count);
    if Mask then
      ApplyWebSocketMask(@Result[HeaderLength], Count, MaskKey);
  end;
end;

procedure ApplyWebSocketMask(Data: PByte; Count: PtrUInt; constref MaskKey: TWebSocketMaskKey; Offset: QWord);
var
  Index: PtrUInt;
begin
  Index := 0;
  while Index < Count do
  begin
    Data[Index] := Data[Index] xor MaskKey[(Offset + Index) and 3];
    Inc(Index);
  end;
end;

function ParseWebSocketFrameHeader(Data: PByte; Available: PtrUInt; out Header: TWebSocketFrameHeader;
  out HeaderLength: Integer): THeaderParse;
var
  Short: Byte;
  Index: Integer;
  Length_: QWord;
begin
  Header := Default(TWebSocketFrameHeader);
  HeaderLength := 2;
  if Available < 2 then
    Exit(HeaderIncomplete);
  Header.Fin := (Data[0] and $80) <> 0;
  Header.Rsv1 := (Data[0] and $40) <> 0;
  Header.Rsv2 := (Data[0] and $20) <> 0;
  Header.Rsv3 := (Data[0] and $10) <> 0;
  Header.Opcode := Data[0] and $0F;
  Header.Masked := (Data[1] and $80) <> 0;
  Short := Data[1] and $7F;
  if Short = 126 then
    Inc(HeaderLength, 2)
  else if Short = 127 then
    Inc(HeaderLength, 8);
  if Header.Masked then
    Inc(HeaderLength, 4);
  if Available < PtrUInt(HeaderLength) then
    Exit(HeaderIncomplete);
  if Short = 126 then
    Length_ := (QWord(Data[2]) shl 8) or Data[3]
  else if Short = 127 then
  begin
    if (Data[2] and $80) <> 0 then
      Exit(HeaderMalformed);
    Length_ := 0;
    for Index := 0 to 7 do
      Length_ := (Length_ shl 8) or Data[2 + Index];
  end
  else
    Length_ := Short;
  Header.PayloadLength := Length_;
  if Header.Masked then
    Move(Data[HeaderLength - 4], Header.MaskKey[0], 4);
  Result := HeaderParsed;
end;

function EncodeClosePayload(Code: Word; const Reason: string): TBytes;
begin
  Result := nil;
  if Code = 0 then
    Exit;
  SetLength(Result, 2 + Length(Reason));
  Result[0] := Byte(Code shr 8);
  Result[1] := Byte(Code);
  if Reason <> '' then
    Move(Reason[1], Result[2], Length(Reason));
end;

function IsSendableCloseCode(Code: Word): Boolean;
begin
  Result := ((Code >= 1000) and (Code <= 1003)) or ((Code >= 1007) and (Code <= 1014)) or
    ((Code >= 3000) and (Code <= 4999));
end;

function IsValidUtf8(Data: PByte; Count: PtrUInt): Boolean;
var
  Index: PtrUInt;
  Lead, Next: Byte;
  Needed, Step: Integer;
  Low_, High_: Byte;
begin
  Index := 0;
  while Index < Count do
  begin
    Lead := Data[Index];
    if Lead < $80 then
    begin
      Inc(Index);
      Continue;
    end;
    Low_ := $80;
    High_ := $BF;
    if (Lead >= $C2) and (Lead <= $DF) then
      Needed := 1
    else if (Lead >= $E0) and (Lead <= $EF) then
    begin
      Needed := 2;
      if Lead = $E0 then
        Low_ := $A0
      else if Lead = $ED then
        High_ := $9F;
    end
    else if (Lead >= $F0) and (Lead <= $F4) then
    begin
      Needed := 3;
      if Lead = $F0 then
        Low_ := $90
      else if Lead = $F4 then
        High_ := $8F;
    end
    else
      Exit(False);
    if Index + PtrUInt(Needed) >= Count then
      Exit(False);
    for Step := 1 to Needed do
    begin
      Next := Data[Index + PtrUInt(Step)];
      if Step = 1 then
      begin
        if (Next < Low_) or (Next > High_) then
          Exit(False);
      end
      else if (Next < $80) or (Next > $BF) then
        Exit(False);
    end;
    Inc(Index, PtrUInt(Needed) + 1);
  end;
  Result := True;
end;

{ ---- TWebSocketFrameReader ---- }

constructor TWebSocketFrameReader.Create;
begin
  inherited Create;
  FMaximumMessageBytes := DefaultWebSocketMessageLimit;
end;

procedure TWebSocketFrameReader.Feed(Data: Pointer; Count: PtrUInt);
var
  Pending: PtrUInt;
begin
  if Count = 0 then
    Exit;
  Pending := FEnd - FStart;
  if (FStart > 0) and (FStart >= PtrUInt(Length(FBuffer)) div 2) then
  begin
    if Pending > 0 then
      Move((PByte(FBuffer) + FStart)^, FBuffer[0], Pending);
    FStart := 0;
    FEnd := Pending;
  end;
  if FEnd + Count > PtrUInt(Length(FBuffer)) then
    SetLength(FBuffer, (FEnd + Count) * 2);
  Move(Data^, FBuffer[FEnd], Count);
  Inc(FEnd, Count);
end;

function TWebSocketFrameReader.Fail(Code: Word; const Reason: string): TReaderStep;
begin
  FFailed := True;
  FFailCode := Code;
  FFailReason := Reason;
  Result := ReaderFailed;
end;

procedure TWebSocketFrameReader.AppendToMessage(Data: PByte; Count: PtrUInt);
begin
  if Count = 0 then
    Exit;
  if FMessageLength + Count > PtrUInt(Length(FMessage)) then
    SetLength(FMessage, (FMessageLength + Count) * 2);
  Move(Data^, (PByte(FMessage) + FMessageLength)^, Count);
  Inc(FMessageLength, Count);
end;

function TWebSocketFrameReader.TakeControl(constref Header: TWebSocketFrameHeader; Data: PByte;
  out Item: TWebSocketItem): TReaderStep;
var
  Count: PtrUInt;
begin
  Item := Default(TWebSocketItem);
  Count := Header.PayloadLength;
  case Header.Opcode of
    WebSocketOpPing: Item.Kind := WebSocketItemPing;
    WebSocketOpPong: Item.Kind := WebSocketItemPong;
  else
    Item.Kind := WebSocketItemClose;
  end;
  if Item.Kind <> WebSocketItemClose then
  begin
    SetLength(Item.Payload, Count);
    if Count > 0 then
      Move(Data^, Item.Payload[0], Count);
    Exit(ReaderItem);
  end;
  if Count = 1 then
    Exit(Fail(WebSocketCloseProtocolError, 'a close frame of one byte'));
  if Count >= 2 then
  begin
    Item.HasCode := True;
    Item.Code := (Word(Data[0]) shl 8) or Data[1];
    if not IsSendableCloseCode(Item.Code) then
      Exit(Fail(WebSocketCloseProtocolError, 'a close code that may not be sent'));
    if not IsValidUtf8(@Data[2], Count - 2) then
      Exit(Fail(WebSocketCloseInvalidData, 'a close reason that is not UTF-8'));
    SetString(Item.Reason, PChar(@Data[2]), Count - 2);
  end;
  Result := ReaderItem;
end;

function TWebSocketFrameReader.Next(out Item: TWebSocketItem): TReaderStep;
var
  Header: TWebSocketFrameHeader;
  HeaderLength: Integer;
  Available: PtrUInt;
  Payload: PByte;
  IsControl: Boolean;
begin
  Item := Default(TWebSocketItem);
  if FFailed then
    Exit(ReaderFailed);
  repeat
    Available := FEnd - FStart;
    if Available < 2 then
      Exit(ReaderNeedsMore);
    case ParseWebSocketFrameHeader(PByte(FBuffer) + FStart, Available, Header, HeaderLength) of
      HeaderIncomplete: Exit(ReaderNeedsMore);
      HeaderMalformed: Exit(Fail(WebSocketCloseProtocolError, 'a frame length with the top bit set'));
    end;
    if Header.Masked then
      Exit(Fail(WebSocketCloseProtocolError, 'a masked frame from the server'));
    if Header.Rsv2 or Header.Rsv3 then
      Exit(Fail(WebSocketCloseProtocolError, 'a reserved bit set'));
    IsControl := Header.Opcode >= 8;
    if not (Header.Opcode in [WebSocketOpContinuation, WebSocketOpText, WebSocketOpBinary, WebSocketOpClose,
      WebSocketOpPing, WebSocketOpPong]) then
      Exit(Fail(WebSocketCloseProtocolError, 'a reserved opcode'));
    if IsControl then
    begin
      if not Header.Fin then
        Exit(Fail(WebSocketCloseProtocolError, 'a fragmented control frame'));
      if Header.PayloadLength > WebSocketControlPayloadLimit then
        Exit(Fail(WebSocketCloseProtocolError, 'a control frame longer than 125 bytes'));
      if Header.Rsv1 then
        Exit(Fail(WebSocketCloseProtocolError, 'RSV1 on a control frame'));
    end
    else if Header.Opcode = WebSocketOpContinuation then
    begin
      if not FInMessage then
        Exit(Fail(WebSocketCloseProtocolError, 'a continuation frame with no message'));
      if Header.Rsv1 then
        Exit(Fail(WebSocketCloseProtocolError, 'RSV1 on a continuation frame'));
    end
    else
    begin
      if FInMessage then
        Exit(Fail(WebSocketCloseProtocolError, 'a new message inside a fragmented one'));
      if Header.Rsv1 and not FAllowRsv1 then
        Exit(Fail(WebSocketCloseProtocolError, 'RSV1 without an extension'));
    end;
    if not IsControl and (FMessageLength + Header.PayloadLength > FMaximumMessageBytes) then
      Exit(Fail(WebSocketCloseTooBig, 'a message too large'));
    if Available - PtrUInt(HeaderLength) < Header.PayloadLength then
      Exit(ReaderNeedsMore);
    Payload := PByte(FBuffer) + FStart + PtrUInt(HeaderLength);
    Inc(FStart, PtrUInt(HeaderLength) + Header.PayloadLength);
    if IsControl then
      Exit(TakeControl(Header, Payload, Item));
    if Header.Opcode <> WebSocketOpContinuation then
    begin
      FInMessage := True;
      FMessageIsText := Header.Opcode = WebSocketOpText;
      FMessageCompressed := Header.Rsv1;
      FMessageLength := 0;
    end;
    AppendToMessage(Payload, Header.PayloadLength);
    if Header.Fin then
    begin
      Item.Kind := WebSocketItemMessage;
      Item.IsText := FMessageIsText;
      Item.Compressed := FMessageCompressed;
      SetLength(FMessage, FMessageLength);
      Item.Payload := FMessage;
      FMessage := nil;
      FMessageLength := 0;
      FInMessage := False;
      Exit(ReaderItem);
    end;
  until False;
end;

end.
