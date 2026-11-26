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
  The WebSocket opening handshake of a client (RFC 6455 section 4.1,
  and the Fetch Standard's "obtain a WebSocket connection"): the GET
  with Upgrade: websocket, a random 16-byte Sec-WebSocket-Key,
  Sec-WebSocket-Version: 13, the protocols and the extension offered,
  and the checks of the server's answer - status 101, Upgrade and
  Connection, Sec-WebSocket-Accept (base64 of the SHA-1 of the key and
  the protocol's GUID), the extensions (Http.WebSocketDeflate) and a
  subprotocol that was offered (none when none was).

  Plain Pascal (libcryptography's digests), checked on the host by
  tools/HttpTest.
}
unit Http.WebSocketHandshake;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http.ResponseHeads,
  Http.WebSocketDeflate;

const
  WebSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

type
  TWebSocketHandshakeOffer = record
    { The request target ("/chat?x=1") and Host field. }
    Target: string;
    Authority: string;
    Key: string;
    Origin: string;
    Protocols: array of string;
    OfferDeflate: Boolean;
    UserAgent: string;
    Cookie: string;
    { Other fields, "Name: value" each (Accept-Language...). }
    ExtraFields: array of string;
  end;

  TWebSocketHandshakeOutcome = record
    Protocol: string;
    { What Sec-WebSocket-Extensions said ('' for none), and the
      permessage-deflate parameters when it is on. }
    Extensions: string;
    Deflate: Boolean;
    DeflateParameters: TPerMessageDeflateParameters;
  end;

{ 16 random bytes in base64. }
function NewWebSocketKey: string;
{ base64(SHA-1(Key + GUID)). }
function WebSocketAcceptFor(const Key: string): string;
function Base64Of(Data: PByte; Count: Integer): string;
{ The request's head, up to and including the empty line. }
function BuildHandshakeRequest(constref Offer: TWebSocketHandshakeOffer): string;
{ The server's answer: True and the outcome when it accepted; False with
  the reason why the connection fails. }
function CheckHandshakeResponse(constref Offer: TWebSocketHandshakeOffer; constref Head: THttpResponseHead;
  out Outcome: TWebSocketHandshakeOutcome; out Reason: string): Boolean;
{ A subprotocol token (RFC 7230's tchar, non-empty). }
function IsProtocolToken(const Text: string): Boolean;

implementation

uses
  Crypto.Digests,
  Crypto.Random;

const
  Base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function Base64Of(Data: PByte; Count: Integer): string;
var
  Index, Remaining: Integer;
  Group: LongWord;
begin
  Result := '';
  Index := 0;
  while Index < Count do
  begin
    Remaining := Count - Index;
    Group := LongWord(Data[Index]) shl 16;
    if Remaining > 1 then
      Group := Group or (LongWord(Data[Index + 1]) shl 8);
    if Remaining > 2 then
      Group := Group or LongWord(Data[Index + 2]);
    Result := Result + Base64Alphabet[((Group shr 18) and 63) + 1] + Base64Alphabet[((Group shr 12) and 63) + 1];
    if Remaining > 1 then
      Result := Result + Base64Alphabet[((Group shr 6) and 63) + 1]
    else
      Result := Result + '=';
    if Remaining > 2 then
      Result := Result + Base64Alphabet[(Group and 63) + 1]
    else
      Result := Result + '=';
    Inc(Index, 3);
  end;
end;

function NewWebSocketKey: string;
var
  Nonce: array[0..15] of Byte;
begin
  RandomBytes(@Nonce[0], SizeOf(Nonce));
  Result := Base64Of(@Nonce[0], SizeOf(Nonce));
end;

function WebSocketAcceptFor(const Key: string): string;
var
  Text: string;
  Digest: TDigestOutput;
begin
  Text := Key + WebSocketGuid;
  ComputeDigest(DigestSha1, PByte(PChar(Text)), Length(Text), Digest);
  Result := Base64Of(@Digest[0], 20);
end;

function IsProtocolToken(const Text: string): Boolean;
var
  Index: Integer;
begin
  if Text = '' then
    Exit(False);
  for Index := 1 to Length(Text) do
    if not (Text[Index] in ['!', '#'..'''', '*', '+', '-', '.', '0'..'9', 'A'..'Z', '^'..'z', '|', '~']) then
      Exit(False);
  Result := True;
end;

function BuildHandshakeRequest(constref Offer: TWebSocketHandshakeOffer): string;
var
  Index: Integer;
  Protocols: string;
begin
  Result := 'GET ' + Offer.Target + ' HTTP/1.1'#13#10 +
    'Host: ' + Offer.Authority + #13#10 +
    'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Key: ' + Offer.Key + #13#10 +
    'Sec-WebSocket-Version: 13'#13#10;
  if Offer.Origin <> '' then
    Result := Result + 'Origin: ' + Offer.Origin + #13#10;
  if Length(Offer.Protocols) > 0 then
  begin
    Protocols := '';
    for Index := 0 to High(Offer.Protocols) do
    begin
      if Index > 0 then
        Protocols := Protocols + ', ';
      Protocols := Protocols + Offer.Protocols[Index];
    end;
    Result := Result + 'Sec-WebSocket-Protocol: ' + Protocols + #13#10;
  end;
  if Offer.OfferDeflate then
    Result := Result + 'Sec-WebSocket-Extensions: ' + PerMessageDeflateOffer + #13#10;
  if Offer.UserAgent <> '' then
    Result := Result + 'User-Agent: ' + Offer.UserAgent + #13#10;
  if Offer.Cookie <> '' then
    Result := Result + 'Cookie: ' + Offer.Cookie + #13#10;
  for Index := 0 to High(Offer.ExtraFields) do
    Result := Result + Offer.ExtraFields[Index] + #13#10;
  Result := Result + 'Pragma: no-cache'#13#10'Cache-Control: no-cache'#13#10#13#10;
end;

{ Every value of a field, joined with ",". }
function CombinedField(constref Head: THttpResponseHead; const Name: string; out Present: Boolean): string;
var
  Index: Integer;
begin
  Result := '';
  Present := False;
  for Index := 0 to High(Head.Fields) do
    if Head.Fields[Index].Name = Name then
    begin
      if Present then
        Result := Result + ', ';
      Result := Result + Head.Fields[Index].Value;
      Present := True;
    end;
end;

function HasToken(const Value, Token: string): Boolean;
var
  Parts: TStringArray;
  Index: Integer;
begin
  Parts := Value.Split([',']);
  for Index := 0 to High(Parts) do
    if SameText(Trim(Parts[Index]), Token) then
      Exit(True);
  Result := False;
end;

function CheckHandshakeResponse(constref Offer: TWebSocketHandshakeOffer; constref Head: THttpResponseHead;
  out Outcome: TWebSocketHandshakeOutcome; out Reason: string): Boolean;
var
  Present: Boolean;
  Value: string;
  Index: Integer;
  Offered: Boolean;
begin
  Outcome := Default(TWebSocketHandshakeOutcome);
  Reason := '';
  Result := False;
  if Head.StatusCode <> 101 then
  begin
    Reason := 'the server answered ' + IntToStr(Head.StatusCode) + ' instead of 101';
    Exit;
  end;
  if not SameText(Trim(CombinedField(Head, 'upgrade', Present)), 'websocket') then
  begin
    Reason := 'no Upgrade: websocket in the answer';
    Exit;
  end;
  if not HasToken(CombinedField(Head, 'connection', Present), 'upgrade') then
  begin
    Reason := 'no Connection: Upgrade in the answer';
    Exit;
  end;
  if CombinedField(Head, 'sec-websocket-accept', Present) <> WebSocketAcceptFor(Offer.Key) then
  begin
    Reason := 'a wrong Sec-WebSocket-Accept';
    Exit;
  end;
  Value := CombinedField(Head, 'sec-websocket-extensions', Present);
  if Present and (Trim(Value) <> '') then
  begin
    if not Offer.OfferDeflate then
    begin
      Reason := 'the server chose an extension not offered';
      Exit;
    end;
    if not ParseExtensionsAnswer(Value, Outcome.Deflate, Outcome.DeflateParameters, Reason) then
      Exit;
    Outcome.Extensions := Trim(Value);
  end;
  Value := Trim(CombinedField(Head, 'sec-websocket-protocol', Present));
  if Present then
  begin
    Offered := False;
    for Index := 0 to High(Offer.Protocols) do
      if Offer.Protocols[Index] = Value then
        Offered := True;
    if not Offered then
    begin
      Reason := 'the server chose a subprotocol not offered';
      Exit;
    end;
    Outcome.Protocol := Value;
  end;
  Result := True;
end;

end.
