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
  A fetch whose body is wanted whole (style sheets, imports, scripts,
  fonts, icons, images): the body gathered as it arrives, what matters
  of the response copied (status, type, MIME essence and charset, final
  URL), and one OnComplete call at the end. The owner frees the object
  after OnComplete or after Cancel; the job pointer is dropped at the
  end, so Cancel is safe at any time.

  The preload cache (Web.Loading.Preloads) can feed one from a fetch
  that was started earlier (Adopt).
}
unit Web.Loading.BufferedFetches;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Web.Fetch.Requests,
  Web.Fetch.Responses,
  Web.Fetch.Jobs,
  Web.Fetch.Fetcher;

type
  TBufferedFetch = class;

  TBufferedFetchEvent = procedure(Fetch: TBufferedFetch; Success: Boolean) of object;

  { A completion delivered in a later task (a preload already done when
    it was claimed); unlinked if either side goes first. }
  TLateCompletion = class
  public
    Fetch: TBufferedFetch;
    Success: Boolean;
    destructor Destroy; override;
    procedure Deliver;
  end;

  TBufferedFetch = class(TFetchConsumer)
  private
    FFetcher: TFetcher;
    FJob: TFetchJob;
    FBody: string;
    FBodyLength: Integer;
    FOnComplete: TBufferedFetchEvent;
    FCompleted: Boolean;
  public
    Status: Integer;
    ResponseType: TFetchResponseType;
    Essence: string;
    Charset: string;
    FinalUrl: TUrlRecord;
    ErrorText: string;
    { For the owner. }
    Data: TObject;
    Tag: PtrInt;
    { A pending TLateCompletion for this fetch. }
    PendingLate: TLateCompletion;
    constructor Create(OnComplete: TBufferedFetchEvent);
    destructor Destroy; override;
    { Starts Request (taken) on Fetcher, Group as the fetcher's group. }
    procedure Start(Fetcher: TFetcher; Request: TFetchRequest; Group: Pointer);
    procedure Cancel;
    procedure ProcessResponse(Job: TFetchJob; Response: TFetchResponse); override;
    procedure ProcessBody(Job: TFetchJob; Data_: Pointer; Count: PtrUInt); override;
    procedure ProcessEndOfBody(Job: TFetchJob; Success: Boolean); override;
    { The body so far. }
    function Body: string;
    { A network error, or a status that is not ok. }
    function Failed: Boolean;
    property Completed: Boolean read FCompleted;
    property OnComplete: TBufferedFetchEvent read FOnComplete write FOnComplete;
  end;

implementation

destructor TLateCompletion.Destroy;
begin
  if Fetch <> nil then
    Fetch.PendingLate := nil;
  inherited Destroy;
end;

procedure TLateCompletion.Deliver;
var
  Target: TBufferedFetch;
begin
  Target := Fetch;
  if Target = nil then
    Exit;
  Target.PendingLate := nil;
  Fetch := nil;
  if Assigned(Target.FOnComplete) then
    Target.FOnComplete(Target, Success);
end;

destructor TBufferedFetch.Destroy;
begin
  if PendingLate <> nil then
    PendingLate.Fetch := nil;
  inherited Destroy;
end;

constructor TBufferedFetch.Create(OnComplete: TBufferedFetchEvent);
begin
  inherited Create;
  FOnComplete := OnComplete;
  ResponseType := ResponseTypeError;
end;

procedure TBufferedFetch.Start(Fetcher: TFetcher; Request: TFetchRequest; Group: Pointer);
begin
  FFetcher := Fetcher;
  FJob := Fetcher.Fetch(Request, Self, Group);
end;

procedure TBufferedFetch.Cancel;
begin
  if FJob <> nil then
    FFetcher.Cancel(FJob);
  FJob := nil;
end;

procedure TBufferedFetch.ProcessResponse(Job: TFetchJob; Response: TFetchResponse);
begin
  Status := Response.Status;
  ResponseType := Response.ResponseType;
  Essence := Response.ComputedEssence;
  Charset := Response.Charset;
  ErrorText := Response.ErrorText;
  if Response.HasUrl then
    FinalUrl := Response.Url;
end;

procedure TBufferedFetch.ProcessBody(Job: TFetchJob; Data_: Pointer; Count: PtrUInt);
begin
  if FBodyLength + Integer(Count) > Length(FBody) then
    SetLength(FBody, (FBodyLength + Integer(Count)) * 2);
  Move(Data_^, FBody[FBodyLength + 1], Count);
  Inc(FBodyLength, Count);
end;

procedure TBufferedFetch.ProcessEndOfBody(Job: TFetchJob; Success: Boolean);
begin
  FJob := nil;
  FCompleted := True;
  SetLength(FBody, FBodyLength);
  if Assigned(FOnComplete) then
    FOnComplete(Self, Success and not Failed);
end;

function TBufferedFetch.Body: string;
begin
  Result := Copy(FBody, 1, FBodyLength);
end;

function TBufferedFetch.Failed: Boolean;
begin
  { Opaque responses keep their real status inside the engine. }
  Result := (ResponseType = ResponseTypeError) or (Status < 200) or (Status > 299);
end;

end.
