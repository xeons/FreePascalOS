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
  The fetcher of a page: Fetch Standard's "fetch" (sections 4.1 to 4.6)
  as far as the engine needs it, over libhttp, everything decided on the
  page thread.

  Main fetch: the referrer (the request's policy, else the client's,
  else strict-origin-when-cross-origin), upgrade-insecure-requests and
  mixed content upgrades, HSTS, mixed content blocking, then by scheme:
  about:blank (an empty HTML document), data: (Web.Fetch.DataUrls),
  file: (Web.Fetch.LocalFiles; only from file: documents or the browser
  itself), http and https. The request's mode decides the response
  tainting: same-origin requests fail across origins, no-cors ones get
  an opaque response (the engine still reads it: images, style sheets),
  cors ones need the CORS check and, for unsafe methods or headers, a
  preflight (cached per origin and URL).

  HTTP fetch: Origin, Referer, Accept by destination, Accept-Language,
  Sec-Fetch-Dest/Mode/Site/User, the RFC 9218 priority, credentials
  (cookies and authentication) as the credentials mode says for that
  hop, SameSite context for the jar, the cache mode. Redirects are taken
  one at a time (at most 20, http and https only, no credentials in a
  CORS request's location, the CORS check for a cross-origin redirect,
  303 and POST rules from libhttp, a Referrer-Policy on the redirect
  applied), each new URL going through main fetch again.

  The response: its type, Strict-Transport-Security taken (https only),
  X-Content-Type-Options: nosniff blocking scripts and style sheets of
  the wrong type, the MIME type extracted and, when the request asks,
  sniffed from the first 1445 bytes before the consumer sees it.
}
unit Web.Fetch.Fetcher;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Generics.Collections,
  Url.Records,
  Url.Origins,
  Http.Client,
  Http.HeaderFields,
  Http.Messages,
  Http.Cookies,
  Http.Results,
  Web.EventLoop.Tasks,
  Web.EventLoop,
  Web.Fetch.Requests,
  Web.Fetch.Responses,
  Web.Fetch.Jobs,
  Web.Fetch.HttpHops,
  Web.Fetch.NetworkContexts;

const
  MaximumRedirectCount = 20;
  LocalFileChunkSize = 64 * 1024;

type
  THopKind = (HopMain, HopPreflight);

  THopRecord = record
    JobId: QWord;
    Kind: THopKind;
  end;

  TJobIdData = class
  public
    JobId: QWord;
    constructor Create(Id: QWord);
  end;

  TLocalFileReader = class
  public
    JobId: QWord;
    Stream: TFileStream;
    destructor Destroy; override;
  end;

  TFetcher = class
  private
    FLoop: TEventLoop;
    FNetwork: TNetworkContext;
    FJobs: specialize TDictionary<QWord, TFetchJob>;
    FHops: specialize TDictionary<QWord, THopRecord>;
    FRunner: THopRunner;
    FNextJobId: QWord;
    FNextHopId: QWord;
    FGarbage: TList;
    FCollectQueued: Boolean;
    FFileReaders: TList;
    function FindJob(Id: QWord; out Job: TFetchJob): Boolean;
    procedure StartQueued(Data: TObject);
    procedure MainFetch(Job: TFetchJob);
    procedure SchemeFetch(Job: TFetchJob);
    procedure HttpFetch(Job: TFetchJob);
    procedure StartPreflight(Job: TFetchJob);
    procedure StartHop(Job: TFetchJob; Kind: THopKind);
    function BuildHttpRequest(Job: TFetchJob; Kind: THopKind): THttpRequest;
    procedure AddRequestFields(Job: TFetchJob; Target: THttpRequest);
    procedure HandleHead(Message: THopHeadMessage);
    procedure HandleData(Message: THopDataMessage);
    procedure HandleDone(Message: THopDoneMessage);
    procedure HandlePreflightHead(Job: TFetchJob; Message: THopHeadMessage);
    procedure HandleRedirect(Job: TFetchJob; Message: THopHeadMessage);
    procedure HandleFinalHead(Job: TFetchJob; Message: THopHeadMessage);
    procedure FailJob(Job: TFetchJob; const Reason: string);
    procedure DeliverResponse(Job: TFetchJob; Response: TFetchResponse);
    procedure DeliverBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt);
    procedure FinishJob(Job: TFetchJob; Success: Boolean);
    procedure FlushSniffing(Job: TFetchJob);
    procedure CompleteWithBody(Job: TFetchJob; Response: TFetchResponse; const Body: string);
    procedure DeliverWholeBody(Data: TObject);
    procedure StartLocalFile(Job: TFetchJob);
    procedure ReadLocalChunk(Data: TObject);
    procedure ForgetJob(Job: TFetchJob);
    procedure CollectGarbage;
    function ComputeReferrer(Job: TFetchJob; out Referrer: string): Boolean;
    function CredentialsIncludedFor(Job: TFetchJob): Boolean;
    function SerializedRequestOrigin(Job: TFetchJob): string;
  public
    constructor Create(Loop: TEventLoop; Network: TNetworkContext);
    destructor Destroy; override;
    { Starts a fetch (the fetcher takes Request); results come to
      Consumer in later tasks. Group: what the job belongs to (a
      document), for CancelGroup. }
    function Fetch(Request: TFetchRequest; Consumer: TFetchConsumer; Group: Pointer = nil): TFetchJob;
    { No more callbacks for the job; freed later. }
    procedure Cancel(Job: TFetchJob);
    procedure CancelGroup(Group: Pointer);
    function ActiveJobCount: Integer;
    property Loop: TEventLoop read FLoop;
    property Network: TNetworkContext read FNetwork;
  end;

{ The Accept value a destination sends. }
function AcceptForDestination(Destination: TFetchDestination): string;

implementation

uses
  Http.Redirects,
  Http.StatusCodes,
  Http.Priorities,
  Http.RequestBodies,
  Url.Parser,
  Http.PublicSuffixes,
  Web.Fetch.MimeTypes,
  Web.Fetch.Sniffing,
  Web.Fetch.DataUrls,
  Web.Fetch.LocalFiles,
  Web.Fetch.Cors,
  Web.Fetch.MixedContent,
  Web.Fetch.ReferrerPolicy;

constructor TJobIdData.Create(Id: QWord);
begin
  inherited Create;
  JobId := Id;
end;

destructor TLocalFileReader.Destroy;
begin
  Stream.Free;
  inherited Destroy;
end;

type
  TWholeBody = class
  public
    JobId: QWord;
    Body: string;
  end;

function AcceptForDestination(Destination: TFetchDestination): string;
begin
  case Destination of
    DestinationDocument, DestinationIframe:
      Result := 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
    DestinationImage:
      Result := 'image/jxl,image/webp,image/png,image/svg+xml,image/*,*/*;q=0.8';
    DestinationStyle:
      Result := 'text/css,*/*;q=0.1';
  else
    Result := '*/*';
  end;
end;

function ListHasNoSniffValue(const Value: string): Boolean;
var
  Comma: Integer;
  First: string;
begin
  Comma := Pos(',', Value);
  if Comma > 0 then
    First := Copy(Value, 1, Comma - 1)
  else
    First := Value;
  Result := LowerCase(TrimHttpWhitespace(First)) = 'nosniff';
end;

constructor TFetcher.Create(Loop: TEventLoop; Network: TNetworkContext);
begin
  inherited Create;
  FLoop := Loop;
  FNetwork := Network;
  FJobs := specialize TDictionary<QWord, TFetchJob>.Create;
  FHops := specialize TDictionary<QWord, THopRecord>.Create;
  FRunner := THopRunner.Create(Loop, Self, @HandleHead, @HandleData, @HandleDone);
  FGarbage := TList.Create;
  FFileReaders := TList.Create;
end;

destructor TFetcher.Destroy;
var
  Job: TFetchJob;
  Index: Integer;
begin
  FRunner.Free;
  FLoop.DiscardTasks(Self);
  for Job in FJobs.Values do
    Job.Free;
  FJobs.Free;
  FHops.Free;
  for Index := 0 to FGarbage.Count - 1 do
    TFetchJob(FGarbage[Index]).Free;
  FGarbage.Free;
  for Index := 0 to FFileReaders.Count - 1 do
    TLocalFileReader(FFileReaders[Index]).Free;
  FFileReaders.Free;
  inherited Destroy;
end;

function TFetcher.FindJob(Id: QWord; out Job: TFetchJob): Boolean;
begin
  Result := FJobs.TryGetValue(Id, Job) and Job.Active;
end;

function TFetcher.Fetch(Request: TFetchRequest; Consumer: TFetchConsumer; Group: Pointer): TFetchJob;
begin
  Inc(FNextJobId);
  Result := TFetchJob.Create(FNextJobId, Request, Consumer, Group);
  FJobs.Add(Result.Id, Result);
  if Request.Client <> nil then
    Request.Origin := Request.Client.Origin;
  FLoop.QueueTask(TDataTask.Create(@StartQueued, TJobIdData.Create(Result.Id)), TaskSourceNetworking, Self);
end;

procedure TFetcher.StartQueued(Data: TObject);
var
  Job: TFetchJob;
begin
  if FindJob(TJobIdData(Data).JobId, Job) then
    MainFetch(Job);
end;

procedure TFetcher.Cancel(Job: TFetchJob);
begin
  if (Job = nil) or not Job.Active then
    Exit;
  Job.State := JobCanceled;
  if Job.CurrentHop <> 0 then
    FRunner.Cancel(Job.CurrentHop);
  ForgetJob(Job);
end;

procedure TFetcher.CancelGroup(Group: Pointer);
var
  Victims: array of TFetchJob;
  Job: TFetchJob;
  Index: Integer;
begin
  Victims := nil;
  for Job in FJobs.Values do
    if (Job.Group = Group) and Job.Active then
    begin
      SetLength(Victims, Length(Victims) + 1);
      Victims[High(Victims)] := Job;
    end;
  for Index := 0 to High(Victims) do
    Cancel(Victims[Index]);
end;

function TFetcher.ActiveJobCount: Integer;
begin
  Result := FJobs.Count;
end;

procedure TFetcher.ForgetJob(Job: TFetchJob);
begin
  FJobs.Remove(Job.Id);
  FGarbage.Add(Job);
  if not FCollectQueued then
  begin
    FCollectQueued := True;
    FLoop.QueueMethod(@CollectGarbage, TaskSourceNetworking, Self);
  end;
end;

procedure TFetcher.CollectGarbage;
var
  Index: Integer;
  Doomed: TList;
begin
  FCollectQueued := False;
  Doomed := FGarbage;
  FGarbage := TList.Create;
  try
    for Index := 0 to Doomed.Count - 1 do
      TFetchJob(Doomed[Index]).Free;
  finally
    Doomed.Free;
  end;
end;

function TFetcher.ComputeReferrer(Job: TFetchJob; out Referrer: string): Boolean;
var
  Request: TFetchRequest;
  Policy: TReferrerPolicy;
  Source: TUrlRecord;
begin
  Referrer := '';
  Request := Job.Request;
  case Request.ReferrerKind of
    ReferrerNone:
      Exit(False);
    ReferrerUrl:
      Source := Request.ReferrerUrl;
  else
    if (Request.Client = nil) or not Request.Client.HasCreationUrl then
      Exit(False);
    Source := Request.Client.CreationUrl;
  end;
  Policy := Request.ReferrerPolicy;
  if (Policy = ReferrerPolicyEmpty) and (Request.Client <> nil) then
    Policy := Request.Client.ReferrerPolicy;
  Result := DetermineReferrer(Source, Request.CurrentUrl, Policy, Referrer);
end;

function TFetcher.SerializedRequestOrigin(Job: TFetchJob): string;
begin
  Result := SerializeOrigin(Job.Request.Origin);
end;

function TFetcher.CredentialsIncludedFor(Job: TFetchJob): Boolean;
var
  Request: TFetchRequest;
begin
  Request := Job.Request;
  case Request.Credentials of
    FetchCredentialsInclude:
      Result := True;
    FetchCredentialsSameOrigin:
      Result := (Request.ResponseTainting = TaintingBasic) or
        SameOrigin(Request.Origin, OriginOfUrl(Request.CurrentUrl));
  else
    Result := False;
  end;
end;

procedure TFetcher.FailJob(Job: TFetchJob; const Reason: string);
begin
  if not Job.Active then
    Exit;
  if Job.CurrentHop <> 0 then
    FRunner.Cancel(Job.CurrentHop);
  Job.CurrentHop := 0;
  if Job.State in [JobSniffing, JobReceiving] then
  begin
    FinishJob(Job, False);
    Exit;
  end;
  DeliverResponse(Job, TFetchResponse.NetworkError(Reason));
  if Job.Active then
    FinishJob(Job, False);
end;

procedure TFetcher.DeliverResponse(Job: TFetchJob; Response: TFetchResponse);
begin
  if Length(Response.UrlList) = 0 then
    Response.UrlList := Copy(Job.Request.UrlList);
  if Response.ComputedEssence = '' then
    Response.ComputedEssence := MimeEssence(Response.MimeType);
  Job.SetResponse(Response);
  Job.State := JobReceiving;
  if Job.Consumer <> nil then
    Job.Consumer.ProcessResponse(Job, Response);
end;

procedure TFetcher.DeliverBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt);
begin
  if not Job.Active or (Count = 0) then
    Exit;
  Inc(Job.BytesReceived, Count);
  if Job.State = JobSniffing then
  begin
    SetLength(Job.SniffBuffer, Length(Job.SniffBuffer) + Count);
    Move(Data^, Job.SniffBuffer[Length(Job.SniffBuffer) - Count + 1], Count);
    if Length(Job.SniffBuffer) >= ResourceHeaderLength then
      FlushSniffing(Job);
    Exit;
  end;
  if Job.Consumer <> nil then
    Job.Consumer.ProcessBody(Job, Data, Count);
end;

procedure TFetcher.FlushSniffing(Job: TFetchJob);
var
  Response: TFetchResponse;
  Options: TSniffOptions;
  Header, Held: string;
begin
  if Job.State <> JobSniffing then
    Exit;
  Response := Job.Response;
  Header := Copy(Job.SniffBuffer, 1, ResourceHeaderLength);
  if Job.Request.Destination = DestinationImage then
    Response.ComputedEssence := SniffImageMimeType(MimeEssence(Response.MimeType), Header)
  else
  begin
    Options.NoSniff := ListHasNoSniffValue(Response.Headers.Combined('x-content-type-options'));
    Options.CheckForApacheBug := IsApacheBugContentType(Response.Headers.Value('content-type'));
    Response.ComputedEssence := SniffMimeType(MimeEssence(Response.MimeType), Header, Options);
  end;
  Held := Job.SniffBuffer;
  Job.SniffBuffer := '';
  Job.State := JobReceiving;
  if Job.Consumer <> nil then
    Job.Consumer.ProcessResponse(Job, Response);
  if Job.Active and (Held <> '') and (Job.Consumer <> nil) then
    Job.Consumer.ProcessBody(Job, PChar(Held), Length(Held));
end;

procedure TFetcher.FinishJob(Job: TFetchJob; Success: Boolean);
begin
  if not Job.Active then
    Exit;
  if Job.State = JobSniffing then
    FlushSniffing(Job);
  if not Job.Active then
    Exit;
  Job.State := JobFinished;
  Job.CurrentHop := 0;
  try
    if Job.Consumer <> nil then
      Job.Consumer.ProcessEndOfBody(Job, Success);
  finally
    ForgetJob(Job);
  end;
end;

{ ---- main fetch ---- }

procedure TFetcher.MainFetch(Job: TFetchJob);
var
  Request: TFetchRequest;
  Current: TUrlRecord;
  Referrer: string;
begin
  Request := Job.Request;
  if Request.ReferrerKind <> ReferrerNone then
  begin
    Request.Headers.Remove('referer');
    if ComputeReferrer(Job, Referrer) then
      Request.Headers.SetValue('referer', Referrer);
  end;
  UpgradeMixedContentRequest(Request);
  Current := Request.CurrentUrl;
  if FNetwork.Hsts.UpgradeUrl(Current) then
    Request.UrlList[High(Request.UrlList)] := Current;
  if ShouldBlockMixedContent(Request) then
  begin
    FailJob(Job, 'blocked: insecure content on a secure page (' + SerializeUrl(Current) + ')');
    Exit;
  end;
  if (Request.Mode = FetchModeSameOrigin) and (Current.Scheme <> 'data') and
     not SameOrigin(Request.Origin, OriginOfUrl(Current)) then
  begin
    FailJob(Job, 'blocked: a same-origin request to another origin');
    Exit;
  end;
  if (Current.Scheme = 'data') or (Current.Scheme = 'about') or (Request.Mode = FetchModeNavigate) or
     SameOrigin(Request.Origin, OriginOfUrl(Current)) and (Request.ResponseTainting = TaintingBasic) then
    SchemeFetch(Job)
  else if Request.Mode = FetchModeNoCors then
  begin
    if Request.Redirect <> FetchRedirectFollow then
    begin
      FailJob(Job, 'a no-cors request must follow redirects');
      Exit;
    end;
    Request.ResponseTainting := TaintingOpaque;
    SchemeFetch(Job);
  end
  else if (Current.Scheme <> 'http') and (Current.Scheme <> 'https') then
    FailJob(Job, 'blocked: a CORS request to ' + Current.Scheme + ':')
  else
  begin
    Request.ResponseTainting := TaintingCors;
    Job.UnsafeHeaderNames := CorsUnsafeRequestHeaderNames(Request.Headers);
    if CorsNeedsPreflight(Request.Method, Request.Headers, False) and
       not FNetwork.PreflightCache.HasMethod(TCorsPreflightCache.KeyFor(SerializedRequestOrigin(Job),
         SerializeUrl(Current), CredentialsIncludedFor(Job)), Request.Method, FLoop.Now) then
      StartPreflight(Job)
    else
      HttpFetch(Job);
  end;
end;

procedure TFetcher.SchemeFetch(Job: TFetchJob);
var
  Current: TUrlRecord;
  Response: TFetchResponse;
  DataUrl: TDataUrlResult;
  Path: string;
begin
  Current := Job.Request.CurrentUrl;
  if Current.Scheme = 'about' then
  begin
    if (Current.Path <> 'blank') and (Current.Path <> 'srcdoc') then
    begin
      FailJob(Job, 'about:' + Current.Path + ' is not a page');
      Exit;
    end;
    Response := TFetchResponse.Create;
    Response.ResponseType := ResponseTypeBasic;
    Response.StatusText := 'OK';
    Response.Headers.Add('content-type', 'text/html;charset=utf-8');
    Response.MimeType := ParseMimeType('text/html;charset=utf-8');
    Response.Protocol := 'about';
    CompleteWithBody(Job, Response, '');
  end
  else if Current.Scheme = 'data' then
  begin
    DataUrl := ProcessDataUrl(Current);
    if not DataUrl.Valid then
    begin
      FailJob(Job, 'a malformed data: URL');
      Exit;
    end;
    Response := TFetchResponse.Create;
    Response.ResponseType := ResponseTypeBasic;
    Response.StatusText := 'OK';
    Response.Headers.Add('content-type', SerializeMimeType(DataUrl.MimeType));
    Response.MimeType := DataUrl.MimeType;
    Response.Protocol := 'data';
    CompleteWithBody(Job, Response, DataUrl.Body);
  end
  else if Current.Scheme = 'file' then
  begin
    if not FNetwork.AllowFileAccess or
       (Job.Request.Client <> nil) and Job.Request.Client.HasCreationUrl and
       (Job.Request.Client.CreationUrl.Scheme <> 'file') then
    begin
      FailJob(Job, 'blocked: a local file from a page that is not local');
      Exit;
    end;
    if not LocalPathOfUrl(Current, Path) then
    begin
      FailJob(Job, 'a file: URL of another host');
      Exit;
    end;
    StartLocalFile(Job);
  end
  else if (Current.Scheme = 'http') or (Current.Scheme = 'https') then
    HttpFetch(Job)
  else
    FailJob(Job, 'the scheme ' + Current.Scheme + ': is not supported');
end;

procedure TFetcher.CompleteWithBody(Job: TFetchJob; Response: TFetchResponse; const Body: string);
var
  Whole: TWholeBody;
begin
  Response.UrlList := Copy(Job.Request.UrlList);
  Response.ComputedEssence := MimeEssence(Response.MimeType);
  Job.SetResponse(Response);
  Job.State := JobAwaitingResponse;
  Whole := TWholeBody.Create;
  Whole.JobId := Job.Id;
  Whole.Body := Body;
  FLoop.QueueTask(TDataTask.Create(@DeliverWholeBody, Whole), TaskSourceNetworking, Self);
end;

procedure TFetcher.DeliverWholeBody(Data: TObject);
var
  Job: TFetchJob;
  Whole: TWholeBody;
begin
  Whole := TWholeBody(Data);
  if not FindJob(Whole.JobId, Job) then
    Exit;
  if Job.Request.SniffContent and (Job.Response.ComputedEssence = '') then
    Job.State := JobSniffing
  else
  begin
    Job.State := JobReceiving;
    if Job.Consumer <> nil then
      Job.Consumer.ProcessResponse(Job, Job.Response);
  end;
  if Job.Active and (Whole.Body <> '') then
    DeliverBody(Job, PChar(Whole.Body), Length(Whole.Body));
  FinishJob(Job, True);
end;

procedure TFetcher.StartLocalFile(Job: TFetchJob);
var
  Path, Essence: string;
  Response: TFetchResponse;
  Reader: TLocalFileReader;
begin
  LocalPathOfUrl(Job.Request.CurrentUrl, Path);
  Response := TFetchResponse.Create;
  Response.ResponseType := ResponseTypeBasic;
  Response.StatusText := 'OK';
  Response.Protocol := 'file';
  if DirectoryExists(Path) then
  begin
    Response.Headers.Add('content-type', 'text/html;charset=utf-8');
    Response.MimeType := ParseMimeType('text/html;charset=utf-8');
    CompleteWithBody(Job, Response, FolderIndexPage(Path, Job.Request.CurrentUrl));
    Exit;
  end;
  Reader := TLocalFileReader.Create;
  Reader.JobId := Job.Id;
  try
    Reader.Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  except
    on Error: Exception do
    begin
      Reader.Free;
      Response.Free;
      FailJob(Job, 'cannot open ' + Path + ': ' + Error.Message);
      Exit;
    end;
  end;
  Essence := MimeTypeForFileName(Path);
  if Essence <> '' then
  begin
    Response.Headers.Add('content-type', Essence);
    Response.MimeType := ParseMimeType(Essence);
  end;
  Response.Headers.Add('content-length', IntToStr(Reader.Stream.Size));
  Response.UrlList := Copy(Job.Request.UrlList);
  Job.SetResponse(Response);
  if Job.Request.SniffContent then
    Job.State := JobSniffing
  else
    Job.State := JobAwaitingResponse;
  FFileReaders.Add(Reader);
  FLoop.QueueTask(TDataTask.Create(@ReadLocalChunk, TJobIdData.Create(Job.Id)), TaskSourceNetworking, Self);
end;

procedure TFetcher.ReadLocalChunk(Data: TObject);
var
  Job: TFetchJob;
  Reader: TLocalFileReader;
  Index, Count: Integer;
  Buffer: array of Byte;
begin
  Reader := nil;
  for Index := 0 to FFileReaders.Count - 1 do
    if TLocalFileReader(FFileReaders[Index]).JobId = TJobIdData(Data).JobId then
      Reader := TLocalFileReader(FFileReaders[Index]);
  if Reader = nil then
    Exit;
  if not FindJob(Reader.JobId, Job) then
  begin
    FFileReaders.Remove(Reader);
    Reader.Free;
    Exit;
  end;
  if Job.State = JobAwaitingResponse then
  begin
    Job.State := JobReceiving;
    Job.Response.ComputedEssence := MimeEssence(Job.Response.MimeType);
    if Job.Consumer <> nil then
      Job.Consumer.ProcessResponse(Job, Job.Response);
    if not Job.Active then
      Exit;
  end;
  Buffer := nil;
  SetLength(Buffer, LocalFileChunkSize);
  try
    Count := Reader.Stream.Read(Buffer[0], LocalFileChunkSize);
  except
    Count := -1;
  end;
  if Count > 0 then
    DeliverBody(Job, @Buffer[0], Count);
  if (Count <= 0) or (Reader.Stream.Position >= Reader.Stream.Size) then
  begin
    FFileReaders.Remove(Reader);
    Reader.Free;
    FinishJob(Job, Count >= 0);
    Exit;
  end;
  if Job.Active then
    FLoop.QueueTask(TDataTask.Create(@ReadLocalChunk, TJobIdData.Create(Job.Id)), TaskSourceNetworking, Self);
end;

{ ---- HTTP ---- }

procedure TFetcher.AddRequestFields(Job: TFetchJob; Target: THttpRequest);
var
  Request: TFetchRequest;
  Site, Value: string;
  Index: Integer;
begin
  Request := Job.Request;
  for Index := 0 to Request.Headers.Count - 1 do
    Target.Headers.Add(Request.Headers[Index].Name, Request.Headers[Index].Value);
  if not Target.Headers.Has('accept') then
    Target.Headers.SetValue('accept', AcceptForDestination(Request.Destination));
  if not Target.Headers.Has('accept-language') and (FNetwork.AcceptLanguage <> '') then
    Target.Headers.SetValue('accept-language', FNetwork.AcceptLanguage);
  { The Origin field: CORS requests, and other unsafe methods. }
  if Request.ResponseTainting = TaintingCors then
    Target.Headers.SetValue('origin', SerializedRequestOrigin(Job))
  else if (Request.Method <> 'GET') and (Request.Method <> 'HEAD') and (Request.Mode <> FetchModeNavigate) or
     (Request.Mode = FetchModeNavigate) and (Request.Method = 'POST') then
  begin
    Value := SerializedRequestOrigin(Job);
    if (Request.ReferrerPolicy = ReferrerPolicyNoReferrer) then
      Value := 'null';
    Target.Headers.SetValue('origin', Value);
  end;
  { Fetch Metadata. }
  if UrlIsPotentiallyTrustworthy(Request.CurrentUrl) then
  begin
    Value := DestinationName(Request.Destination);
    if Value = '' then
      Value := 'empty';
    Target.Headers.SetValue('sec-fetch-dest', Value);
    case Request.Mode of
      FetchModeNavigate: Target.Headers.SetValue('sec-fetch-mode', 'navigate');
      FetchModeSameOrigin: Target.Headers.SetValue('sec-fetch-mode', 'same-origin');
      FetchModeNoCors: Target.Headers.SetValue('sec-fetch-mode', 'no-cors');
      FetchModeCors: Target.Headers.SetValue('sec-fetch-mode', 'cors');
    end;
    if Request.UserInitiated or (Request.Client = nil) then
      Site := 'none'
    else if SameOrigin(Request.Origin, OriginOfUrl(Request.CurrentUrl)) then
      Site := 'same-origin'
    else if not Request.Origin.Opaque and (Request.CurrentUrl.Host.Kind = UrlHostDomain) and
       HostsAreSameSite(SerializeHost(Request.Origin.Host), Request.CurrentUrl.Host.Name) then
      Site := 'same-site'
    else
      Site := 'cross-site';
    Target.Headers.SetValue('sec-fetch-site', Site);
    if Request.UserInitiated and (Request.Mode = FetchModeNavigate) then
      Target.Headers.SetValue('sec-fetch-user', '?1');
  end;
end;

function TFetcher.BuildHttpRequest(Job: TFetchJob; Kind: THopKind): THttpRequest;
var
  Request: TFetchRequest;
  Current: TUrlRecord;
  Included: Boolean;
  TopHost: string;
begin
  Request := Job.Request;
  Current := Request.CurrentUrl;
  if Kind = HopPreflight then
  begin
    Result := THttpRequest.Create('OPTIONS', Current);
    Result.Headers.SetValue('accept', '*/*');
    Result.Headers.SetValue('access-control-request-method', Request.Method);
    if Length(Job.UnsafeHeaderNames) > 0 then
      Result.Headers.SetValue('access-control-request-headers', string.Join(',', Job.UnsafeHeaderNames));
    Result.Headers.SetValue('origin', SerializedRequestOrigin(Job));
    if Request.Headers.Has('referer') then
      Result.Headers.SetValue('referer', Request.Headers.Value('referer'));
    Result.CredentialsMode := CredentialsOmit;
    Result.CacheMode := CacheModeNoStore;
  end
  else
  begin
    Result := THttpRequest.Create(Request.Method, Current);
    AddRequestFields(Job, Result);
    if Request.HasBody then
      Result.SetBody(THttpBytesBody.Create(Request.Body, Request.Headers.Value('content-type')));
    Included := CredentialsIncludedFor(Job);
    if Included then
      Result.CredentialsMode := CredentialsInclude
    else
      Result.CredentialsMode := CredentialsOmit;
    Result.CacheMode := HttpCacheModeOf(Request.CacheMode);
  end;
  Result.RedirectMode := RedirectManual;
  Result.Priority := Request.Priority;
  Result.DecodeContent := True;
  Result.CookieContext.IsSecure := UrlIsPotentiallyTrustworthy(Current);
  Result.CookieContext.SafeMethod := (Result.Method = 'GET') or (Result.Method = 'HEAD') or
    (Result.Method = 'OPTIONS') or (Result.Method = 'TRACE');
  Result.CookieContext.HttpApi := True;
  Result.CookieContext.TopLevelNavigation := (Request.Mode = FetchModeNavigate) and
    (Request.Destination = DestinationDocument);
  if Request.UserInitiated or (Request.Client = nil) then
    Result.CookieContext.SameSite := True
  else if Request.Client.HasTopLevelOrigin and not Request.Client.TopLevelOrigin.Opaque and
     (Current.Host.Kind = UrlHostDomain) then
  begin
    TopHost := SerializeHost(Request.Client.TopLevelOrigin.Host);
    Result.CookieContext.SameSite := HostsAreSameSite(TopHost, Current.Host.Name) and
      (Request.Client.TopLevelOrigin.Scheme = Current.Scheme);
  end
  else
    Result.CookieContext.SameSite := False;
end;

procedure TFetcher.StartHop(Job: TFetchJob; Kind: THopKind);
var
  Hop: THopRecord;
begin
  Inc(FNextHopId);
  Hop.JobId := Job.Id;
  Hop.Kind := Kind;
  FHops.Add(FNextHopId, Hop);
  Job.CurrentHop := FNextHopId;
  if Kind = HopPreflight then
    Job.State := JobPreflight
  else
    Job.State := JobAwaitingResponse;
  FRunner.Start(FNetwork.Client, BuildHttpRequest(Job, Kind), FNextHopId);
end;

procedure TFetcher.StartPreflight(Job: TFetchJob);
begin
  StartHop(Job, HopPreflight);
end;

procedure TFetcher.HttpFetch(Job: TFetchJob);
begin
  StartHop(Job, HopMain);
end;

function HeadersFromFields(constref Fields: THttpHeaderFieldArray): THttpHeaders;
var
  Index: Integer;
begin
  Result := THttpHeaders.Create;
  for Index := 0 to High(Fields) do
    Result.Add(Fields[Index].Name, Fields[Index].Value);
end;

procedure TFetcher.HandleHead(Message: THopHeadMessage);
var
  Hop: THopRecord;
  Job: TFetchJob;
begin
  if not FHops.TryGetValue(Message.HopId, Hop) or not FindJob(Hop.JobId, Job) or
     (Job.CurrentHop <> Message.HopId) then
    Exit;
  if Hop.Kind = HopPreflight then
    HandlePreflightHead(Job, Message)
  else if StatusIsRedirect(Message.Status) and (Message.Status <> 304) and
     FieldsHave(Message.Fields, 'location') then
    HandleRedirect(Job, Message)
  else
    HandleFinalHead(Job, Message);
end;

procedure TFetcher.HandlePreflightHead(Job: TFetchJob; Message: THopHeadMessage);
var
  Headers: THttpHeaders;
  Reason, Key: string;
  Preflight: TCorsPreflightResult;
  Included: Boolean;
begin
  { The preflight's body is not wanted: the hop runs out unheard. }
  Job.CurrentHop := 0;
  Included := CredentialsIncludedFor(Job);
  Headers := HeadersFromFields(Message.Fields);
  try
    if not CorsCheck(Headers, SerializedRequestOrigin(Job), Included, Reason) then
    begin
      FailJob(Job, 'CORS preflight failed: ' + Reason);
      Exit;
    end;
    Preflight := CheckPreflightResponse(Headers, Message.Status, Job.Request.Method, Job.UnsafeHeaderNames,
      Included, False);
    if not Preflight.Ok then
    begin
      FailJob(Job, 'CORS preflight failed: ' + Preflight.Reason);
      Exit;
    end;
    Key := TCorsPreflightCache.KeyFor(SerializedRequestOrigin(Job), SerializeUrl(Job.Request.CurrentUrl), Included);
    FNetwork.PreflightCache.Add(Key, Preflight, Job.Request.Method, Job.UnsafeHeaderNames, FLoop.Now);
  finally
    Headers.Free;
  end;
  HttpFetch(Job);
end;

procedure TFetcher.HandleRedirect(Job: TFetchJob; Message: THopHeadMessage);
var
  Request: TFetchRequest;
  Headers: THttpHeaders;
  Location: TUrlRecord;
  Reason, NewMethod: string;
  Response: TFetchResponse;
  DropContent, CrossOrigin: Boolean;
  Policy: TReferrerPolicy;
begin
  Request := Job.Request;
  Headers := HeadersFromFields(Message.Fields);
  try
    if Request.Redirect = FetchRedirectError then
    begin
      FailJob(Job, 'the request does not follow redirects');
      Exit;
    end;
    if Request.Redirect = FetchRedirectManual then
    begin
      Response := TFetchResponse.Create;
      Response.Status := Message.Status;
      Response.StatusText := Message.Reason;
      Response.Headers.Assign(Headers);
      if Request.Mode = FetchModeNavigate then
        Response.ResponseType := ResponseTypeBasic
      else
        Response.ResponseType := ResponseTypeOpaqueRedirect;
      Job.CurrentHop := 0;
      DeliverResponse(Job, Response);
      FinishJob(Job, True);
      Exit;
    end;
    if not ResolveLocation(Request.CurrentUrl, Headers.Value('location'), Location) then
    begin
      FailJob(Job, 'a redirect to something that is not a URL');
      Exit;
    end;
    if (Location.Scheme <> 'http') and (Location.Scheme <> 'https') then
    begin
      FailJob(Job, 'a redirect to ' + Location.Scheme + ':');
      Exit;
    end;
    if Request.RedirectCount >= MaximumRedirectCount then
    begin
      FailJob(Job, 'too many redirects');
      Exit;
    end;
    if (Request.ResponseTainting = TaintingCors) and UrlIncludesCredentials(Location) then
    begin
      FailJob(Job, 'a CORS redirect to a URL with credentials');
      Exit;
    end;
    if (Request.ResponseTainting = TaintingCors) and
       not CorsCheck(Headers, SerializedRequestOrigin(Job), CredentialsIncludedFor(Job), Reason) then
    begin
      FailJob(Job, 'CORS check of a redirect failed: ' + Reason);
      Exit;
    end;
    CrossOrigin := not SameOriginUrl(Request.CurrentUrl, Location);
    { A CORS request redirected across origins: its origin becomes
      opaque ("null") from then on. }
    if CrossOrigin and (Request.ResponseTainting = TaintingCors) and
       not SameOrigin(Request.Origin, OriginOfUrl(Location)) then
      Request.Origin := NewOpaqueOrigin;
    NewMethod := RedirectedMethod(Message.Status, Request.Method, DropContent);
    if NewMethod <> Request.Method then
      Request.Method := NewMethod;
    if DropContent then
    begin
      Request.HasBody := False;
      Request.Body := nil;
    end;
    PrepareRedirectedFields(Request.Headers, DropContent, CrossOrigin);
    Policy := ParseReferrerPolicyField(Headers.Combined('referrer-policy'));
    if Policy <> ReferrerPolicyEmpty then
      Request.ReferrerPolicy := Policy;
    Inc(Request.RedirectCount);
    SetLength(Request.UrlList, Length(Request.UrlList) + 1);
    Request.UrlList[High(Request.UrlList)] := Location;
  finally
    Headers.Free;
  end;
  { The old hop's body is not wanted; the next request goes out. }
  Job.CurrentHop := 0;
  MainFetch(Job);
end;

procedure TFetcher.HandleFinalHead(Job: TFetchJob; Message: THopHeadMessage);
var
  Request: TFetchRequest;
  Response: TFetchResponse;
  Reason, Essence: string;
  Included, NoSniff: Boolean;
  Index: Integer;
begin
  Request := Job.Request;
  Response := TFetchResponse.Create;
  Response.Status := Message.Status;
  Response.StatusText := Message.Reason;
  Response.FromCache := Message.FromCache;
  Response.Protocol := Message.Protocol;
  Response.UrlList := Copy(Request.UrlList);
  for Index := 0 to High(Message.Fields) do
    Response.Headers.Add(Message.Fields[Index].Name, Message.Fields[Index].Value);
  Included := CredentialsIncludedFor(Job);
  case Request.ResponseTainting of
    TaintingCors:
      begin
        if not CorsCheck(Response.Headers, SerializedRequestOrigin(Job), Included, Reason) then
        begin
          Response.Free;
          FailJob(Job, 'CORS check failed: ' + Reason);
          Exit;
        end;
        Response.ResponseType := ResponseTypeCors;
        Response.ExposedHeaderNames := CorsExposedHeaderNames(Response.Headers, Included);
      end;
    TaintingOpaque:
      Response.ResponseType := ResponseTypeOpaque;
  else
    Response.ResponseType := ResponseTypeBasic;
  end;
  if Response.Url.Scheme = 'https' then
    FNetwork.Hsts.ProcessResponseField(Response.Url, Response.Headers.Value('strict-transport-security'));
  Response.MimeType := ExtractMimeType(Response.Headers.GetAll('content-type'));
  Essence := MimeEssence(Response.MimeType);
  NoSniff := ListHasNoSniffValue(Response.Headers.Combined('x-content-type-options'));
  if NoSniff and (IsScriptLikeDestination(Request.Destination) and not IsJavaScriptMimeType(Essence) or
     (Request.Destination = DestinationStyle) and not IsCssMimeType(Essence)) then
  begin
    Response.Free;
    FailJob(Job, 'blocked by nosniff: ' + Essence + ' for a ' + DestinationName(Request.Destination));
    Exit;
  end;
  Job.SetResponse(Response);
  if Request.SniffContent and (Response.Status <> 204) and (Response.Status <> 304) then
    Job.State := JobSniffing
  else
  begin
    Response.ComputedEssence := Essence;
    Job.State := JobReceiving;
    if Job.Consumer <> nil then
      Job.Consumer.ProcessResponse(Job, Response);
  end;
end;

procedure TFetcher.HandleData(Message: THopDataMessage);
var
  Hop: THopRecord;
  Job: TFetchJob;
begin
  if not FHops.TryGetValue(Message.HopId, Hop) or not FindJob(Hop.JobId, Job) or
     (Job.CurrentHop <> Message.HopId) or (Hop.Kind <> HopMain) then
    Exit;
  if Length(Message.Bytes) > 0 then
    DeliverBody(Job, @Message.Bytes[0], Length(Message.Bytes));
end;

procedure TFetcher.HandleDone(Message: THopDoneMessage);
var
  Hop: THopRecord;
  Job: TFetchJob;
  Known: Boolean;
begin
  Known := FHops.TryGetValue(Message.HopId, Hop);
  FHops.Remove(Message.HopId);
  FRunner.Release(Message.HopId);
  if not Known or not FindJob(Hop.JobId, Job) or (Job.CurrentHop <> Message.HopId) then
    Exit;
  Job.CurrentHop := 0;
  if Job.State in [JobPreflight, JobAwaitingResponse] then
  begin
    if HttpSucceeded(Message.Outcome) then
      FailJob(Job, 'no response')
    else
      FailJob(Job, Message.Outcome.Text);
    Exit;
  end;
  FinishJob(Job, HttpSucceeded(Message.Outcome));
end;

end.
