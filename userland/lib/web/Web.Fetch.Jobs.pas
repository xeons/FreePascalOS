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

  A job and its consumer know each other. A consumer that is freed
  (even from inside one of its own calls) cancels each job still
  running for it and leaves every one of its jobs without a consumer,
  so a late answer (a CORS failure, the end of the body) reaches no
  one. A job that is freed tells its consumer (JobReleased), so the
  consumer can forget the pointer it kept.
}
unit Web.Fetch.Jobs;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.Fetch.Requests,
  Web.Fetch.Responses;

type
  TFetchJob = class;

  { Stops a job that is still running (the fetcher's Cancel). }
  TFetchJobCancelEvent = procedure(Job: TFetchJob) of object;

  TFetchConsumer = class
  private
    { The jobs that have this consumer (not owned). }
    FJobs: TFPList;
    procedure AttachJob(Job: TFetchJob);
    procedure ForgetJob(Job: TFetchJob);
  protected
    { Job is being freed: a pointer to it kept by the consumer is no
      longer valid. }
    procedure JobReleased(Job: TFetchJob); virtual;
  public
    { Cancels each of its jobs still running and detaches all of them. }
    destructor Destroy; override;
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
    FOnCancel: TFetchJobCancelEvent;
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
    { The service workers had their chance at the request. }
    ServiceWorkerDone: Boolean;
    { OnCancel: how the job is stopped when its consumer goes first. }
    constructor Create(Id: QWord; Request: TFetchRequest; Consumer: TFetchConsumer; Group: Pointer;
      OnCancel: TFetchJobCancelEvent);
    destructor Destroy; override;
    procedure SetResponse(Response: TFetchResponse);
    function Active: Boolean;
    { The consumer went: nothing more is delivered, and a running job is
      cancelled. }
    procedure ConsumerGone;
    { Stops the job if it is still running (as the fetcher's Cancel). }
    procedure Cancel;
    property Id: QWord read FId;
    property Request: TFetchRequest read FRequest;
    property Response: TFetchResponse read FResponse;
    property Consumer: TFetchConsumer read FConsumer;
    property Group: Pointer read FGroup;
  end;

implementation

destructor TFetchConsumer.Destroy;
var
  Job: TFetchJob;
begin
  if FJobs <> nil then
  begin
    while FJobs.Count > 0 do
    begin
      Job := TFetchJob(FJobs[FJobs.Count - 1]);
      FJobs.Delete(FJobs.Count - 1);
      Job.ConsumerGone;
    end;
    FreeAndNil(FJobs);
  end;
  inherited Destroy;
end;

procedure TFetchConsumer.AttachJob(Job: TFetchJob);
begin
  if FJobs = nil then
    FJobs := TFPList.Create;
  FJobs.Add(Job);
end;

procedure TFetchConsumer.ForgetJob(Job: TFetchJob);
begin
  if FJobs <> nil then
    FJobs.Remove(Job);
  JobReleased(Job);
end;

procedure TFetchConsumer.JobReleased(Job: TFetchJob);
begin
end;

procedure TFetchConsumer.ProcessResponse(Job: TFetchJob; Response: TFetchResponse);
begin
end;

procedure TFetchConsumer.ProcessBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt);
begin
end;

procedure TFetchConsumer.ProcessEndOfBody(Job: TFetchJob; Success: Boolean);
begin
end;

constructor TFetchJob.Create(Id: QWord; Request: TFetchRequest; Consumer: TFetchConsumer; Group: Pointer;
  OnCancel: TFetchJobCancelEvent);
begin
  inherited Create;
  FId := Id;
  FRequest := Request;
  FConsumer := Consumer;
  FGroup := Group;
  FOnCancel := OnCancel;
  State := JobQueued;
  if FConsumer <> nil then
    FConsumer.AttachJob(Self);
end;

destructor TFetchJob.Destroy;
begin
  if FConsumer <> nil then
    FConsumer.ForgetJob(Self);
  FConsumer := nil;
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

procedure TFetchJob.Cancel;
begin
  if Active and Assigned(FOnCancel) then
    FOnCancel(Self);
end;

procedure TFetchJob.ConsumerGone;
begin
  FConsumer := nil;
  if Active and Assigned(FOnCancel) then
    FOnCancel(Self);
end;

end.
