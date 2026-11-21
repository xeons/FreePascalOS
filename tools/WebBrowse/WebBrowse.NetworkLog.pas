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
  webbrowse's network log: a fetch monitor that records each request
  the page makes (method, URL, destination, status, protocol, cache,
  bytes, when it started and how long it took, why it failed) and
  prints them as a table, or live as they finish.
}
unit WebBrowse.NetworkLog;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.Fetch.Jobs,
  Web.Fetch.Monitors,
  Web.Fetch.Responses;

type
  TRequestClock = function: Double of object;

  TRequestRecord = class
  public
    Id: QWord;
    Method, Url, Destination: string;
    Started, Responded, Ended: Double;
    Status: Integer;
    Protocol: string;
    FromCache: Boolean;
    Bytes: Int64;
    Outcome: string;
    Finished: Boolean;
  end;

  TNetworkLog = class(TFetchMonitor)
  private
    FRecords: TList;
    FClock: TRequestClock;
    FLive: Boolean;
    function Find(Job: TFetchJob): TRequestRecord;
    procedure Finish(Job: TFetchJob; const Outcome: string);
  public
    constructor Create(Clock: TRequestClock);
    destructor Destroy; override;
    procedure FetchStarted(Job: TFetchJob); override;
    procedure FetchResponded(Job: TFetchJob; Response: TFetchResponse); override;
    procedure FetchFailed(Job: TFetchJob; const Reason: string); override;
    procedure FetchFinished(Job: TFetchJob; Success: Boolean); override;
    procedure FetchCanceled(Job: TFetchJob); override;
    function Describe(Item: TRequestRecord): string;
    procedure Print(var Output: Text);
    function Count: Integer;
    function UnfinishedCount: Integer;
    function TotalBytes: Int64;
    { Print each request as it ends (to standard error). }
    property Live: Boolean read FLive write FLive;
  end;

implementation

uses
  Url.Records,
  Web.Fetch.Requests;

constructor TNetworkLog.Create(Clock: TRequestClock);
begin
  inherited Create;
  FRecords := TList.Create;
  FClock := Clock;
end;

destructor TNetworkLog.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FRecords.Count - 1 do
    TRequestRecord(FRecords[Index]).Free;
  FRecords.Free;
  inherited Destroy;
end;

function TNetworkLog.Find(Job: TFetchJob): TRequestRecord;
var
  Index: Integer;
begin
  for Index := FRecords.Count - 1 downto 0 do
    if TRequestRecord(FRecords[Index]).Id = Job.Id then
      Exit(TRequestRecord(FRecords[Index]));
  Result := nil;
end;

procedure TNetworkLog.FetchStarted(Job: TFetchJob);
var
  Item: TRequestRecord;
begin
  Item := TRequestRecord.Create;
  Item.Id := Job.Id;
  Item.Method := Job.Request.Method;
  Item.Url := SerializeUrl(Job.Request.CurrentUrl);
  Item.Destination := DestinationName(Job.Request.Destination);
  if Item.Destination = '' then
    Item.Destination := 'fetch';
  Item.Started := FClock();
  Item.Responded := -1;
  Item.Ended := -1;
  FRecords.Add(Item);
end;

procedure TNetworkLog.FetchResponded(Job: TFetchJob; Response: TFetchResponse);
var
  Item: TRequestRecord;
begin
  Item := Find(Job);
  if Item = nil then
    Exit;
  Item.Responded := FClock();
  Item.Status := Response.Status;
  Item.Protocol := Response.Protocol;
  Item.FromCache := Response.FromCache;
  Item.Url := SerializeUrl(Job.Request.CurrentUrl);
end;

procedure TNetworkLog.Finish(Job: TFetchJob; const Outcome: string);
var
  Item: TRequestRecord;
begin
  Item := Find(Job);
  if (Item = nil) or Item.Finished then
    Exit;
  Item.Finished := True;
  Item.Ended := FClock();
  Item.Bytes := Job.BytesReceived;
  if Item.Outcome = '' then
    Item.Outcome := Outcome;
  if FLive then
    WriteLn(StdErr, 'net: ', Describe(Item));
end;

procedure TNetworkLog.FetchFailed(Job: TFetchJob; const Reason: string);
var
  Item: TRequestRecord;
begin
  Item := Find(Job);
  if Item <> nil then
    Item.Outcome := 'failed: ' + Reason;
end;

procedure TNetworkLog.FetchFinished(Job: TFetchJob; Success: Boolean);
begin
  if Success then
    Finish(Job, 'ok')
  else
    Finish(Job, 'incomplete');
end;

procedure TNetworkLog.FetchCanceled(Job: TFetchJob);
begin
  Finish(Job, 'canceled');
end;

function TNetworkLog.Describe(Item: TRequestRecord): string;
var
  Took, Waited: string;
  Status: string;
begin
  if Item.Ended >= 0 then
    Took := Format('%7.0f', [Item.Ended - Item.Started])
  else
    Took := '      -';
  if Item.Responded >= 0 then
    Waited := Format('%7.0f', [Item.Responded - Item.Started])
  else
    Waited := '      -';
  if Item.Status <> 0 then
    Status := IntToStr(Item.Status)
  else
    Status := '---';
  if Item.FromCache then
    Status := Status + 'c';
  Result := Format('%8.0f %s %s %4s %-6s %-9s %9d %s %s', [Item.Started, Waited, Took, Status, Item.Protocol,
    Item.Destination, Item.Bytes, Item.Outcome, Item.Url]);
  if not Item.Finished then
    Result := Result + ' (unfinished)';
end;

procedure TNetworkLog.Print(var Output: Text);
var
  Index: Integer;
begin
  WriteLn(Output, '   start    head    took stat proto  dest          bytes outcome url (milliseconds)');
  for Index := 0 to FRecords.Count - 1 do
    WriteLn(Output, Describe(TRequestRecord(FRecords[Index])));
end;

function TNetworkLog.Count: Integer;
begin
  Result := FRecords.Count;
end;

function TNetworkLog.UnfinishedCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to FRecords.Count - 1 do
    if not TRequestRecord(FRecords[Index]).Finished then
      Inc(Result);
end;

function TNetworkLog.TotalBytes: Int64;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to FRecords.Count - 1 do
    Inc(Result, TRequestRecord(FRecords[Index]).Bytes);
end;

end.
