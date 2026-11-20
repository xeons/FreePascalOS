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
  Fetches that run on threads of their own, for programs that must not
  wait (the browser renders a page as its bytes come): a task runs
  THttpClient.Fetch and tells its owner, on the task's thread,

    OnHead   the final response head (before any content)
    OnData   each piece of decoded content as it arrives
    OnDone   how the fetch ended

  Cancel stops it from any thread (an HTTP/2 stream is reset, an
  HTTP/1.1 connection closed); WaitFor waits for the end. Many tasks
  share one client and its connections: requests to one HTTP/2 origin
  go as streams of one connection.

  Plain Pascal (the RTL and Classes), checked on the host by
  tools/HttpTest.
}
unit Http.FetchTasks;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Http.BodySinks,
  Http.Client,
  Http.Messages,
  Http.Results;

type
  THttpFetchTask = class;

  THttpTaskHeadEvent = procedure(Task: THttpFetchTask; Response: THttpResponse) of object;
  THttpTaskDataEvent = procedure(Task: THttpFetchTask; Data: Pointer; Count: PtrUInt) of object;
  THttpTaskDoneEvent = procedure(Task: THttpFetchTask; constref Outcome: THttpResult) of object;

  THttpFetchTask = class(TThread)
  private
    FClient: THttpClient;
    FRequest: THttpRequest;
    FResponse: THttpResponse;
    FToken: THttpCancelToken;
    FOutcome: THttpResult;
    FOnHead: THttpTaskHeadEvent;
    FOnData: THttpTaskDataEvent;
    FOnDone: THttpTaskDoneEvent;
    FTag: PtrInt;
    function HeadArrived(Response: THttpResponse): Boolean;
    procedure DataArrived(Data: Pointer; Count: PtrUInt);
  protected
    procedure Execute; override;
  public
    { Takes over the request; starts at once. }
    constructor Create(Client: THttpClient; Request: THttpRequest; OnHead: THttpTaskHeadEvent;
      OnData: THttpTaskDataEvent; OnDone: THttpTaskDoneEvent; Tag: PtrInt = 0);
    destructor Destroy; override;
    procedure Cancel;
    property Request: THttpRequest read FRequest;
    { After the end: the final response (its content read). }
    property Response: THttpResponse read FResponse;
    property Outcome: THttpResult read FOutcome;
    { For the owner to tell its tasks apart. }
    property Tag: PtrInt read FTag;
  end;

implementation

constructor THttpFetchTask.Create(Client: THttpClient; Request: THttpRequest; OnHead: THttpTaskHeadEvent;
  OnData: THttpTaskDataEvent; OnDone: THttpTaskDoneEvent; Tag: PtrInt);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := Client;
  FRequest := Request;
  FOnHead := OnHead;
  FOnData := OnData;
  FOnDone := OnDone;
  FTag := Tag;
  FToken := THttpCancelToken.Create;
  Start;
end;

destructor THttpFetchTask.Destroy;
begin
  Cancel;
  WaitFor;
  FResponse.Free;
  FRequest.Free;
  FToken.Free;
  inherited Destroy;
end;

procedure THttpFetchTask.Cancel;
begin
  FToken.Cancel;
end;

function THttpFetchTask.HeadArrived(Response: THttpResponse): Boolean;
begin
  if Assigned(FOnHead) then
    FOnHead(Self, Response);
  Result := not FToken.Canceled;
end;

procedure THttpFetchTask.DataArrived(Data: Pointer; Count: PtrUInt);
begin
  if Assigned(FOnData) then
    FOnData(Self, Data, Count);
end;

procedure THttpFetchTask.Execute;
var
  Sink: THttpCallbackSink;
begin
  Sink := THttpCallbackSink.Create(@DataArrived);
  try
    try
      FOutcome := FClient.Fetch(FRequest, Sink, FResponse, @HeadArrived, FToken);
    except
      on Error: Exception do
        FOutcome := HttpFailure(HttpProtocolError, Error.Message);
    end;
    { The fetch is over (an exception may have left an exchange tracked):
      a later Cancel must not reach what it used. }
    FToken.Untrack;
    if FResponse <> nil then
      FResponse.Finish;
  finally
    Sink.Free;
  end;
  if Assigned(FOnDone) then
    FOnDone(Self, FOutcome);
end;

end.
