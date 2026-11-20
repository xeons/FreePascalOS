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
  A fetch in progress and the one who gets its results. A consumer is
  told, always on the page thread and never from inside the call that
  started the fetch: ProcessResponse once (the response, possibly a
  network error), then ProcessBody for each piece of the body as it
  arrives, then ProcessEndOfBody once (Success False when the body was
  cut short or the response was a network error). Nothing more comes
  after a job is cancelled. The job and its response stay valid until
  ProcessEndOfBody returns (or until the cancel); the fetcher frees
  them afterwards.
}
unit Web.Fetch.Jobs;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Fetch.Requests,
  Web.Fetch.Responses;

type
  TFetchJob = class;

  TFetchConsumer = class
  public
    procedure ProcessResponse(Job: TFetchJob; Response: TFetchResponse); virtual;
    procedure ProcessBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt); virtual;
    procedure ProcessEndOfBody(Job: TFetchJob; Success: Boolean); virtual;
  end;

  TFetchJobState = (JobQueued, JobPreflight, JobAwaitingResponse, JobSniffing, JobReceiving, JobFinished,
    JobCanceled);

  TFetchJob = class
  private
    FId: QWord;
    FRequest: TFetchRequest;
    FResponse: TFetchResponse;
    FConsumer: TFetchConsumer;
    FGroup: Pointer;
  public
    State: TFetchJobState;
    { The HTTP exchange whose results count (older ones are ignored). }
    CurrentHop: QWord;
    { Bytes held back for sniffing. }
    SniffBuffer: string;
    { The CORS-unsafe header names (for the preflight and its cache). }
    UnsafeHeaderNames: TStringArray;
    { For the consumer. }
    Tag: PtrInt;
    BytesReceived: Int64;
    { The Referer of the current hop ('' for none). }
    Referrer: string;
    constructor Create(Id: QWord; Request: TFetchRequest; Consumer: TFetchConsumer; Group: Pointer);
    destructor Destroy; override;
    procedure SetResponse(Response: TFetchResponse);
    function Active: Boolean;
    property Id: QWord read FId;
    property Request: TFetchRequest read FRequest;
    property Response: TFetchResponse read FResponse;
    property Consumer: TFetchConsumer read FConsumer;
    property Group: Pointer read FGroup;
  end;

implementation

procedure TFetchConsumer.ProcessResponse(Job: TFetchJob; Response: TFetchResponse);
begin
end;

procedure TFetchConsumer.ProcessBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt);
begin
end;

procedure TFetchConsumer.ProcessEndOfBody(Job: TFetchJob; Success: Boolean);
begin
end;

constructor TFetchJob.Create(Id: QWord; Request: TFetchRequest; Consumer: TFetchConsumer; Group: Pointer);
begin
  inherited Create;
  FId := Id;
  FRequest := Request;
  FConsumer := Consumer;
  FGroup := Group;
  State := JobQueued;
end;

destructor TFetchJob.Destroy;
begin
  FResponse.Free;
  FRequest.Free;
  inherited Destroy;
end;

procedure TFetchJob.SetResponse(Response: TFetchResponse);
begin
  if FResponse <> Response then
    FResponse.Free;
  FResponse := Response;
end;

function TFetchJob.Active: Boolean;
begin
  Result := not (State in [JobFinished, JobCanceled]);
end;

end.
