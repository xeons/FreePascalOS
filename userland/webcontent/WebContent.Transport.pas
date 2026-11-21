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
  The content process's network: libweb's transport
  (Web.Fetch.Transports) over the channel to the browser's network
  service. Each HTTP exchange gets a number of its own on the wire (the
  pages' fetchers number theirs apart); its head, body and outcome come
  back as messages the loop hands to Deliver, on the page thread.
  document.cookie and local files are asked for and waited on.
}
unit WebContent.Transport;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Http.Messages,
  Web.Fetch.Transports,
  WebIpc.Messages,
  WebContent.Connection;

type
  TContentTransport = class(TNetworkTransport)
  private
    FConnection: TContentConnection;
    FRoutes: TList;
    FNextWireId: QWord;
    function FindRoute(WireId: QWord): Integer;
  public
    constructor Create(Connection: TContentConnection);
    destructor Destroy; override;
    procedure StartHop(Request: THttpRequest; HopId: QWord; Urgent: Boolean; Sink: THopResultSink); override;
    procedure CancelHop(Sink: THopResultSink; HopId: QWord); override;
    procedure ForgetSink(Sink: THopResultSink); override;
    function DocumentCookie(constref Url: TUrlRecord; Secure: Boolean): string; override;
    procedure SetDocumentCookie(constref Url: TUrlRecord; const Cookie: string; Secure: Boolean); override;
    function ReadLocalFile(constref Url: TUrlRecord; out Contents: TBytes; out IsFolder: Boolean;
      out Error: string): Boolean; override;
    { A hop's head, piece or outcome from the browser (True when it was
      one; the caller frees the message). }
    function Deliver(Message: TIpcMessage): Boolean;
  end;

implementation

uses
  Url.Parser,
  Http.HeaderFields,
  Http.Results,
  Http.RequestBodies,
  WebIpc.ViewMessages,
  WebIpc.NetworkMessages;

const
  CookieTimeout = 10000;
  FileTimeout = 60000;

type
  TRoute = class
  public
    WireId: QWord;
    HopId: QWord;
    Sink: THopResultSink;
  end;

constructor TContentTransport.Create(Connection: TContentConnection);
begin
  inherited Create;
  FConnection := Connection;
  FRoutes := TList.Create;
end;

destructor TContentTransport.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FRoutes.Count - 1 do
    TRoute(FRoutes[Index]).Free;
  FRoutes.Free;
  inherited Destroy;
end;

function TContentTransport.FindRoute(WireId: QWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FRoutes.Count - 1 do
    if TRoute(FRoutes[Index]).WireId = WireId then
      Exit(Index);
  Result := -1;
end;

function BodyBytes(Body: THttpRequestBody): TBytes;
var
  Buffer: array[0..16383] of Byte;
  Count, Filled: Integer;
begin
  Result := nil;
  if Body = nil then
    Exit;
  Body.Rewind;
  Filled := 0;
  repeat
    Count := Body.Read(@Buffer[0], SizeOf(Buffer));
    if Count <= 0 then
      Break;
    SetLength(Result, Filled + Count);
    Move(Buffer[0], Result[Filled], Count);
    Inc(Filled, Count);
  until False;
end;

procedure TContentTransport.StartHop(Request: THttpRequest; HopId: QWord; Urgent: Boolean; Sink: THopResultSink);
var
  Wire: TIpcHopRequest;
  Route: TRoute;
  Index: Integer;
begin
  Inc(FNextWireId);
  Route := TRoute.Create;
  Route.WireId := FNextWireId;
  Route.HopId := HopId;
  Route.Sink := Sink;
  FRoutes.Add(Route);
  Wire := Default(TIpcHopRequest);
  Wire.HopId := FNextWireId;
  Wire.Method := Request.Method;
  Wire.Url := SerializeUrl(Request.Url);
  SetLength(Wire.Fields, Request.Headers.Count);
  for Index := 0 to Request.Headers.Count - 1 do
  begin
    Wire.Fields[Index].Name := Request.Headers[Index].Name;
    Wire.Fields[Index].Value := Request.Headers[Index].Value;
  end;
  Wire.HasBody := Request.Body <> nil;
  if Wire.HasBody then
  begin
    Wire.Body := BodyBytes(Request.Body);
    Wire.BodyType := Request.Body.ContentType;
  end;
  Wire.PriorityUrgency := Request.Priority.Urgency;
  Wire.PriorityIncremental := Request.Priority.Incremental;
  Wire.RedirectMode := Ord(Request.RedirectMode);
  Wire.MaximumRedirects := Request.MaximumRedirects;
  Wire.CacheMode := Ord(Request.CacheMode);
  Wire.CredentialsMode := Ord(Request.CredentialsMode);
  Wire.DecodeContent := Request.DecodeContent;
  Wire.CookieSecure := Request.CookieContext.IsSecure;
  Wire.CookieSameSite := Request.CookieContext.SameSite;
  Wire.CookieTopLevelNavigation := Request.CookieContext.TopLevelNavigation;
  Wire.CookieSafeMethod := Request.CookieContext.SafeMethod;
  Wire.Urgent := Urgent;
  Request.Free;
  FConnection.Send(IpcHopStart, 0, EncodeHopRequest(Wire));
end;

procedure TContentTransport.CancelHop(Sink: THopResultSink; HopId: QWord);
var
  Index: Integer;
  Route: TRoute;
begin
  for Index := 0 to FRoutes.Count - 1 do
  begin
    Route := TRoute(FRoutes[Index]);
    if (Route.Sink = Sink) and (Route.HopId = HopId) then
    begin
      FRoutes.Delete(Index);
      FConnection.Send(IpcHopCancel, 0, EncodeHopId(Route.WireId));
      Route.Free;
      Sink.HopDone(HopId, HttpFailure(HttpCanceled, 'canceled'));
      Exit;
    end;
  end;
end;

procedure TContentTransport.ForgetSink(Sink: THopResultSink);
var
  Index: Integer;
  Route: TRoute;
begin
  for Index := FRoutes.Count - 1 downto 0 do
  begin
    Route := TRoute(FRoutes[Index]);
    if Route.Sink = Sink then
    begin
      FRoutes.Delete(Index);
      FConnection.Send(IpcHopCancel, 0, EncodeHopId(Route.WireId));
      Route.Free;
    end;
  end;
end;

function TContentTransport.Deliver(Message: TIpcMessage): Boolean;
var
  Head: TIpcHopHead;
  Outcome: TIpcHopOutcome;
  Fields: THttpHeaderFieldArray;
  Url: TUrlRecord;
  Index, Place: Integer;
  WireId: QWord;
  Data: TBytes;
  Route: TRoute;
  Result_: THttpResult;
begin
  Result := True;
  case Message.Kind of
    IpcHopHead:
      begin
        Head := DecodeHopHead(Message.Payload);
        Place := FindRoute(Head.HopId);
        if Place < 0 then
          Exit;
        Route := TRoute(FRoutes[Place]);
        Fields := nil;
        SetLength(Fields, Length(Head.Fields));
        for Index := 0 to High(Head.Fields) do
        begin
          Fields[Index].Name := Head.Fields[Index].Name;
          Fields[Index].Value := Head.Fields[Index].Value;
        end;
        if not ParseUrl(Head.Url, Url) then
          Url := EmptyUrl;
        Route.Sink.HopHead(Route.HopId, Head.Status, Head.Reason, Fields, Url, Head.FromCache, Head.Protocol);
      end;
    IpcHopData:
      begin
        DecodeHopData(Message.Payload, WireId, Data);
        Place := FindRoute(WireId);
        if (Place < 0) or (Length(Data) = 0) then
          Exit;
        Route := TRoute(FRoutes[Place]);
        Route.Sink.HopData(Route.HopId, @Data[0], Length(Data));
      end;
    IpcHopDone:
      begin
        Outcome := DecodeHopOutcome(Message.Payload);
        Place := FindRoute(Outcome.HopId);
        if Place < 0 then
          Exit;
        Route := TRoute(FRoutes[Place]);
        FRoutes.Delete(Place);
        if (Outcome.Code >= Ord(Low(THttpResultCode))) and (Outcome.Code <= Ord(High(THttpResultCode))) then
          Result_ := HttpFailure(THttpResultCode(Outcome.Code), Outcome.Text, Outcome.ErrorCode)
        else
          Result_ := HttpFailure(HttpProtocolError, Outcome.Text, Outcome.ErrorCode);
        Result_.Retryable := Outcome.Retryable;
        Route.Sink.HopDone(Route.HopId, Result_);
        Route.Free;
      end;
  else
    Result := False;
  end;
end;

function TContentTransport.DocumentCookie(constref Url: TUrlRecord; Secure: Boolean): string;
var
  Answer: TIpcMessage;
begin
  Result := '';
  Answer := FConnection.Call(IpcCookieGet, 0, EncodeCookieAccess(SerializeUrl(Url), '', Secure), CookieTimeout);
  if Answer = nil then
    Exit;
  try
    Result := DecodeText(Answer.Payload);
  finally
    Answer.Free;
  end;
end;

procedure TContentTransport.SetDocumentCookie(constref Url: TUrlRecord; const Cookie: string; Secure: Boolean);
begin
  FConnection.Send(IpcCookieSet, 0, EncodeCookieAccess(SerializeUrl(Url), Cookie, Secure));
end;

function TContentTransport.ReadLocalFile(constref Url: TUrlRecord; out Contents: TBytes; out IsFolder: Boolean;
  out Error: string): Boolean;
var
  Answer: TIpcMessage;
  Wire: TIpcLocalFile;
begin
  Contents := nil;
  IsFolder := False;
  Error := 'the browser did not answer';
  Answer := FConnection.Call(IpcReadLocalFile, 0, EncodeText(SerializeUrl(Url)), FileTimeout);
  if Answer = nil then
    Exit(False);
  try
    Wire := DecodeLocalFile(Answer.Payload);
  finally
    Answer.Free;
  end;
  Contents := Wire.Contents;
  IsFolder := Wire.IsFolder;
  Error := Wire.Error;
  Result := Wire.Found;
end;

end.
