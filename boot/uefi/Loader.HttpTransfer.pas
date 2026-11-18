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
  Reading a file over HTTP with the firmware's HTTP client.

  Each file gets a fresh HTTP child of the interface (a simple server
  closes the connection after each response). The headers come first,
  without a body, so the file's size (Content-Length, which the server
  must send) is known before its memory is allocated; then the body is
  received straight into that memory.

  The firmware's HTTP client runs only while it is polled, so every wait
  polls it, and gives up when nothing completes for a while.
}
unit Loader.HttpTransfer;

{$mode objfpc}
{$pointermath on}

interface

uses
  Uefi.Base,
  Loader.FileLoading,
  Loader.NetworkInterface;

{ Reads Url (an http:// URL) into LoadedFile, in memory of MemoryType
  (TemporaryFileMemory for a temporary buffer). EfiNotFound if the
  server has no such file. }
function FetchFileOverHttp(const NetworkInterface: TNetworkInterface; Url: PChar;
  MemoryType: LongWord; out LoadedFile: TLoadedFile): TEfiStatus;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Uefi.Http,
  Uefi.SystemTable,
  Loader.Firmware,
  Loader.Console;

const
  MaximumUrlLength = 512;
  MaximumHostLength = 128;
  { How long one step (connecting, a piece of the body) may take. }
  StepTimeoutMicroseconds = 20 * 1000 * 1000;
  PollIntervalMicroseconds = 50;
  { The most asked for in one receive. }
  MaximumPieceBytes = 4 * 1024 * 1024;
  ProgressStepBytes = 8 * 1024 * 1024;
  HttpTimeoutMilliseconds = 20 * 1000;

type
  THttpSession = record
    ServiceBinding: PEfiServiceBindingProtocol;
    ChildHandle: TEfiHandle;
    Http: PEfiHttpProtocol;
    Event: TEfiEvent;
  end;

function WaitForToken(var Session: THttpSession; var Token: TEfiHttpToken): TEfiStatus;
var
  Waited: QWord;
begin
  Waited := 0;
  while Waited < StepTimeoutMicroseconds do
  begin
    Session.Http^.Poll(Session.Http);
    if FirmwareBootServices^.CheckEvent(Session.Event) = EfiSuccess then
      Exit(Token.Status);
    FirmwareBootServices^.Stall(PollIntervalMicroseconds);
    Waited := Waited + PollIntervalMicroseconds;
  end;
  Session.Http^.Cancel(Session.Http, @Token);
  Result := EfiTimeout;
end;

{ The host[:port] part of an http:// URL, for the Host header. }
procedure ExtractUrlAuthority(Url: PChar; Authority: PChar; Capacity: PtrUInt);
var
  Start: PChar;
  Length: PtrUInt;
begin
  Start := Url;
  while (Start^ <> #0) and (Start^ <> ':') do
    Inc(Start);
  while Start^ in [':', '/'] do
    Inc(Start);
  Length := 0;
  while (Start[Length] <> #0) and (Start[Length] <> '/') and (Length + 1 < Capacity) do
  begin
    Authority[Length] := Start[Length];
    Inc(Length);
  end;
  Authority[Length] := #0;
end;

function OpenSession(const NetworkInterface: TNetworkInterface; out Session: THttpSession): TEfiStatus;
var
  AccessPoint: TEfiHttpv4AccessPoint;
  Configuration: TEfiHttpConfigData;
begin
  FillMemory(@Session, SizeOf(Session), 0);
  Result := FirmwareBootServices^.HandleProtocol(NetworkInterface.Handle,
    @HttpServiceBindingProtocolGuid, @Session.ServiceBinding);
  if EfiIsError(Result) then
    Exit;
  Result := Session.ServiceBinding^.CreateChild(Session.ServiceBinding, @Session.ChildHandle);
  if EfiIsError(Result) then
    Exit;
  Result := FirmwareBootServices^.HandleProtocol(Session.ChildHandle, @HttpProtocolGuid,
    @Session.Http);
  if EfiIsError(Result) then
    Exit;
  Result := FirmwareBootServices^.CreateEvent(0, 0, nil, nil, @Session.Event);
  if EfiIsError(Result) then
    Exit;

  FillMemory(@AccessPoint, SizeOf(AccessPoint), 0);
  AccessPoint.UseDefaultAddress := 1;
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.HttpVersion := HttpVersion11;
  Configuration.TimeOutMilliseconds := HttpTimeoutMilliseconds;
  Configuration.Ipv4Node := @AccessPoint;
  Result := Session.Http^.Configure(Session.Http, @Configuration);
  if EfiIsError(Result) then
  begin
    { Some HTTP clients want the address spelled out. }
    AccessPoint.UseDefaultAddress := 0;
    CopyMemory(@AccessPoint.LocalAddress[0], @NetworkInterface.StationAddress[0], 4);
    CopyMemory(@AccessPoint.LocalSubnet[0], @NetworkInterface.SubnetMask[0], 4);
    Result := Session.Http^.Configure(Session.Http, @Configuration);
  end;
end;

procedure CloseSession(var Session: THttpSession);
begin
  if Session.Http <> nil then
    Session.Http^.Configure(Session.Http, nil);
  if Session.Event <> nil then
    FirmwareBootServices^.CloseEvent(Session.Event);
  if Session.ChildHandle <> nil then
    Session.ServiceBinding^.DestroyChild(Session.ServiceBinding, Session.ChildHandle);
  FillMemory(@Session, SizeOf(Session), 0);
end;

function SendRequest(var Session: THttpSession; Url: PChar): TEfiStatus;
var
  WideUrl: array[0..MaximumUrlLength] of WideChar;
  Authority: array[0..MaximumHostLength - 1] of Char;
  Headers: array[0..1] of TEfiHttpHeader;
  RequestData: TEfiHttpRequestData;
  Message: TEfiHttpMessage;
  Token: TEfiHttpToken;
begin
  if not ConvertAsciiToUtf16(Url, @WideUrl[0], Length(WideUrl)) then
    Exit(EfiInvalidParameter);
  ExtractUrlAuthority(Url, @Authority[0], Length(Authority));
  Headers[0].FieldName := 'Host';
  Headers[0].FieldValue := @Authority[0];
  Headers[1].FieldName := 'Accept';
  Headers[1].FieldValue := '*/*';

  RequestData.Method := HttpMethodGet;
  RequestData.Url := @WideUrl[0];
  FillMemory(@Message, SizeOf(Message), 0);
  Message.Data := @RequestData;
  Message.HeaderCount := Length(Headers);
  Message.Headers := @Headers[0];
  Token.Event := Session.Event;
  Token.Status := EfiNotReady;
  Token.Message := @Message;
  Result := Session.Http^.Request(Session.Http, @Token);
  if not EfiIsError(Result) then
    Result := WaitForToken(Session, Token);
end;

function UpperCase(Character: Char): Char;
begin
  if Character in ['a'..'z'] then
    Result := Char(Ord(Character) - 32)
  else
    Result := Character;
end;

function NamesAreEqualIgnoringCase(First, Second: PChar): Boolean;
begin
  while (First^ <> #0) and (UpperCase(First^) = UpperCase(Second^)) do
  begin
    Inc(First);
    Inc(Second);
  end;
  Result := (First^ = #0) and (Second^ = #0);
end;

function FindContentLength(Headers: PEfiHttpHeader; HeaderCount: QWord;
  out ContentLength: QWord): Boolean;
var
  Index: QWord;
  Digit: PChar;
begin
  ContentLength := 0;
  Index := 0;
  while Index < HeaderCount do
  begin
    if NamesAreEqualIgnoringCase(Headers[Index].FieldName, 'Content-Length') then
    begin
      Digit := Headers[Index].FieldValue;
      while Digit^ = ' ' do
        Inc(Digit);
      if not (Digit^ in ['0'..'9']) then
        Exit(False);
      while Digit^ in ['0'..'9'] do
      begin
        ContentLength := ContentLength * 10 + QWord(Ord(Digit^) - Ord('0'));
        Inc(Digit);
      end;
      Exit(True);
    end;
    Inc(Index);
  end;
  Result := False;
end;

{ Receives the status line and the headers. }
function ReceiveHeaders(var Session: THttpSession; out ContentLength: QWord): TEfiStatus;
var
  ResponseData: TEfiHttpResponseData;
  Message: TEfiHttpMessage;
  Token: TEfiHttpToken;
  HasLength: Boolean;
begin
  ContentLength := 0;
  ResponseData.StatusCode := 0;
  FillMemory(@Message, SizeOf(Message), 0);
  Message.Data := @ResponseData;
  Token.Event := Session.Event;
  Token.Status := EfiNotReady;
  Token.Message := @Message;
  Result := Session.Http^.Response(Session.Http, @Token);
  if not EfiIsError(Result) then
    Result := WaitForToken(Session, Token);
  if EfiIsError(Result) then
    Exit;

  HasLength := FindContentLength(Message.Headers, Message.HeaderCount, ContentLength);
  if Message.Headers <> nil then
    FirmwareBootServices^.FreePool(Message.Headers);

  if ResponseData.StatusCode = HttpStatus404NotFound then
    Exit(EfiNotFound);
  if ResponseData.StatusCode <> HttpStatus200Ok then
  begin
    PrintText('HTTP: the server answered with status ');
    PrintDecimal(ResponseData.StatusCode);
    PrintLine(' (UEFI numbering)');
    Exit(EfiHttpError);
  end;
  if not HasLength then
  begin
    PrintLine('HTTP: the server sent no Content-Length');
    Exit(EfiUnsupported);
  end;
  Result := EfiSuccess;
end;

function ReceiveBody(var Session: THttpSession; Destination: PByte; ContentLength: QWord): TEfiStatus;
var
  Message: TEfiHttpMessage;
  Token: TEfiHttpToken;
  Received: QWord;
  Piece: QWord;
  NextProgress: QWord;
begin
  Received := 0;
  NextProgress := ProgressStepBytes;
  Result := EfiSuccess;
  while Received < ContentLength do
  begin
    Piece := ContentLength - Received;
    if Piece > MaximumPieceBytes then
      Piece := MaximumPieceBytes;
    FillMemory(@Message, SizeOf(Message), 0);
    Message.BodyLength := Piece;
    Message.Body := Destination + Received;
    Token.Event := Session.Event;
    Token.Status := EfiNotReady;
    Token.Message := @Message;
    Result := Session.Http^.Response(Session.Http, @Token);
    if not EfiIsError(Result) then
      Result := WaitForToken(Session, Token);
    if EfiIsError(Result) then
      Exit;
    if (Message.BodyLength = 0) or (Message.BodyLength > Piece) then
      Exit(EfiDeviceError);
    Received := Received + Message.BodyLength;
    if Received >= NextProgress then
    begin
      PrintText('.');
      NextProgress := NextProgress + ProgressStepBytes;
    end;
  end;
  if ContentLength >= ProgressStepBytes then
    PrintLine('');
end;

function FetchFileOverHttp(const NetworkInterface: TNetworkInterface; Url: PChar;
  MemoryType: LongWord; out LoadedFile: TLoadedFile): TEfiStatus;
var
  Session: THttpSession;
  ContentLength: QWord;
begin
  FillMemory(@LoadedFile, SizeOf(LoadedFile), 0);
  Result := OpenSession(NetworkInterface, Session);
  if not EfiIsError(Result) then
    Result := SendRequest(Session, Url);
  if not EfiIsError(Result) then
    Result := ReceiveHeaders(Session, ContentLength);
  if not EfiIsError(Result) then
  begin
    { One byte more than the file, so an empty file still gets memory. }
    if not AllocateLoadedFile(LoadedFile, ContentLength + 1, MemoryType) then
      Result := EfiOutOfResources;
  end;
  if not EfiIsError(Result) then
  begin
    Result := ReceiveBody(Session, PByte(LoadedFile.Contents), ContentLength);
    if EfiIsError(Result) then
      ReleaseLoadedFile(LoadedFile)
    else
      LoadedFile.SizeInBytes := ContentLength;
  end;
  CloseSession(Session);
end;

end.
