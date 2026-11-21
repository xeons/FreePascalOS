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
  Who watches a fetcher's traffic (a network log, a developer tool):
  told on the page thread when a fetch starts, when its response comes
  (a network error is a response too), when it fails and when it ends
  or is cancelled. The job is valid during each call only.
}
unit Web.Fetch.Monitors;

{$mode objfpc}
{$H+}

interface

uses
  Web.Fetch.Jobs,
  Web.Fetch.Responses;

type
  TFetchMonitor = class
  public
    procedure FetchStarted(Job: TFetchJob); virtual;
    procedure FetchResponded(Job: TFetchJob; Response: TFetchResponse); virtual;
    procedure FetchFailed(Job: TFetchJob; const Reason: string); virtual;
    { Success False: the body was cut short or the response was an error. }
    procedure FetchFinished(Job: TFetchJob; Success: Boolean); virtual;
    procedure FetchCanceled(Job: TFetchJob); virtual;
  end;

implementation

procedure TFetchMonitor.FetchStarted(Job: TFetchJob);
begin
end;

procedure TFetchMonitor.FetchResponded(Job: TFetchJob; Response: TFetchResponse);
begin
end;

procedure TFetchMonitor.FetchFailed(Job: TFetchJob; const Reason: string);
begin
end;

procedure TFetchMonitor.FetchFinished(Job: TFetchJob; Success: Boolean);
begin
end;

procedure TFetchMonitor.FetchCanceled(Job: TFetchJob);
begin
end;

end.
