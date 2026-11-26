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
  Service workers' records (Service Workers, section 2): registrations
  by storage key (the origin) and scope URL, their installing, waiting
  and active workers, the scripts each worker was installed with, and
  the clients (windows) of the process. Lookups: "Match Service Worker
  Registration" (the longest scope that is a prefix of a URL), a worker
  or registration by id, the clients of an origin and the ones a worker
  controls.

  An origin's registrations are loaded from OriginDataBackend the first
  time it is looked at and saved by SaveRegistrations after a change
  (scope, script URL, update-via-cache, the newest installed worker with
  its script and imported scripts, whether it handles fetch); a
  registration whose worker was only installing is not kept.

  Running workers (their agents) and the jobs are Web.Workers.
  ServiceWorkerJobs'; this unit has no behaviour.
}
unit Web.Workers.ServiceWorkerModel;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.Bindings.Context;

const
  ServiceWorkersKind = 'service-workers';

type
  TServiceWorkerState = (WorkerParsed, WorkerInstalling, WorkerInstalled, WorkerActivating, WorkerActivated,
    WorkerRedundant);

  TServiceWorkerRegistration = class;

  TServiceWorkerRecord = class
  public
    Id: QWord;
    Registration: TServiceWorkerRegistration;
    ScriptUrl: string;
    State: TServiceWorkerState;
    Source: string;
    ImportUrls: TStringArray;
    ImportSources: TStringArray;
    { "Set of event types to handle" has fetch. }
    HandlesFetch: Boolean;
    SkipWaitingFlag: Boolean;
    { The agent running it (TWorkerAgent; nil when not running) and
      what Web.Workers.ServiceWorkerJobs keeps with it. }
    Agent: TObject;
    Running: TObject;
    function ImportSource(const Url: string; out Text: string): Boolean;
  end;

  TServiceWorkerRegistration = class
  public
    Id: QWord;
    StorageKey: string;
    Scope: string;
    UpdateViaCache: string;
    Installing: TServiceWorkerRecord;
    Waiting: TServiceWorkerRecord;
    Active: TServiceWorkerRecord;
    { Unregistered: no longer matched; cleared when no client uses it. }
    Uninstalling: Boolean;
    LastUpdateCheck: TDateTime;
    NavigationPreloadEnabled: Boolean;
    NavigationPreloadHeader: string;
    { The newest of installing, waiting, active (nil if none). }
    function Newest: TServiceWorkerRecord;
  end;

  TServiceWorkerClient = class
  public
    Id: string;
    Context: TBindingContext;
    Origin: string;
    { 'window' or 'nested' (an iframe's). }
    FrameType: string;
    CreationOrder: QWord;
  end;

{ Registrations }
function MatchRegistration(const Origin, Url: string): TServiceWorkerRegistration;
function RegistrationForScope(const Origin, Scope: string): TServiceWorkerRegistration;
function RegistrationById(Id: QWord): TServiceWorkerRegistration;
function NewRegistration(const Origin, Scope, UpdateViaCache: string): TServiceWorkerRegistration;
{ Takes a registration out of the scope map and frees it and its workers
  (the caller retired their agents). }
procedure RemoveRegistration(Registration: TServiceWorkerRegistration);
{ The registrations (not uninstalling) of an origin, in creation order. }
function RegistrationsOf(const Origin: string): TList;
procedure SaveRegistrations(const Origin: string);

{ Workers }
function NewWorker(Registration: TServiceWorkerRegistration; const ScriptUrl: string): TServiceWorkerRecord;
function WorkerById(Id: QWord): TServiceWorkerRecord;
{ A worker no registration slot holds any more is forgotten. }
procedure ForgetWorker(Worker: TServiceWorkerRecord);
function StateName(State: TServiceWorkerState): string;

{ Clients }
function AddClient(Context: TBindingContext; const Id, Origin, FrameType: string): TServiceWorkerClient;
procedure RemoveClient(Client: TServiceWorkerClient);
function ClientByContext(Context: TBindingContext): TServiceWorkerClient;
function ClientById(const Id: string): TServiceWorkerClient;
function ClientCount: Integer;
function ClientAt(Index: Integer): TServiceWorkerClient;

{ Scope URL helpers }
{ The URL without its fragment. }
function UrlWithoutFragment(const Url: string): string;
{ The directory of a script URL (its path up to the last slash). }
function DirectoryOf(const Url: string): string;

{ Forgets everything in memory (tests); nothing is saved. }
procedure ForgetAllRegistrations;

implementation

uses
  Web.Storage.OriginData;

var
  Registrations: TList;
  Workers: TList;
  Clients: TList;
  LoadedOrigins: TStringList;
  NextRegistrationId: QWord = 0;
  NextWorkerId: QWord = 0;
  NextClientOrder: QWord = 0;

function TServiceWorkerRecord.ImportSource(const Url: string; out Text: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(ImportUrls) do
    if ImportUrls[Index] = Url then
    begin
      Text := ImportSources[Index];
      Exit(True);
    end;
  Text := '';
  Result := False;
end;

function TServiceWorkerRegistration.Newest: TServiceWorkerRecord;
begin
  if Installing <> nil then
    Exit(Installing);
  if Waiting <> nil then
    Exit(Waiting);
  Result := Active;
end;

function StateName(State: TServiceWorkerState): string;
const
  Names: array[TServiceWorkerState] of string = ('parsed', 'installing', 'installed', 'activating', 'activated',
    'redundant');
begin
  Result := Names[State];
end;

function UrlWithoutFragment(const Url: string): string;
var
  Hash: Integer;
begin
  Hash := Pos('#', Url);
  if Hash > 0 then
    Result := Copy(Url, 1, Hash - 1)
  else
    Result := Url;
end;

function DirectoryOf(const Url: string): string;
var
  Index: Integer;
begin
  Result := UrlWithoutFragment(Url);
  Index := Pos('?', Result);
  if Index > 0 then
    Result := Copy(Result, 1, Index - 1);
  Index := Length(Result);
  while (Index > 0) and (Result[Index] <> '/') do
    Dec(Index);
  Result := Copy(Result, 1, Index);
end;

{ ---- persistence ---- }

procedure LoadOrigin(const Origin: string); forward;

procedure EnsureLoaded(const Origin: string);
begin
  if LoadedOrigins.IndexOf(Origin) >= 0 then
    Exit;
  LoadedOrigins.Add(Origin);
  LoadOrigin(Origin);
end;

procedure WriteWorker(Writer: TOriginDataWriter; Worker: TServiceWorkerRecord);
var
  Index: Integer;
begin
  Writer.WriteText(Worker.ScriptUrl);
  Writer.WriteText(Worker.Source);
  Writer.WriteInteger(Ord(Worker.HandlesFetch));
  Writer.WriteInteger(Length(Worker.ImportUrls));
  for Index := 0 to High(Worker.ImportUrls) do
  begin
    Writer.WriteText(Worker.ImportUrls[Index]);
    Writer.WriteText(Worker.ImportSources[Index]);
  end;
end;

procedure ReadWorker(Reader: TOriginDataReader; Worker: TServiceWorkerRecord);
var
  Count, Index: Int64;
begin
  Worker.Source := Reader.ReadText;
  Worker.HandlesFetch := Reader.ReadInteger <> 0;
  Count := Reader.ReadInteger;
  if (Count < 0) or (Count > 1000) then
    Count := 0;
  SetLength(Worker.ImportUrls, Count);
  SetLength(Worker.ImportSources, Count);
  for Index := 0 to Count - 1 do
  begin
    Worker.ImportUrls[Index] := Reader.ReadText;
    Worker.ImportSources[Index] := Reader.ReadText;
  end;
end;

procedure SaveRegistrations(const Origin: string);
var
  Writer: TOriginDataWriter;
  Kept: TList;
  Index: Integer;
  Registration: TServiceWorkerRegistration;
  Worker: TServiceWorkerRecord;
begin
  if OriginDataBackend = nil then
    Exit;
  Kept := TList.Create;
  Writer := TOriginDataWriter.Create;
  try
    for Index := 0 to Registrations.Count - 1 do
    begin
      Registration := TServiceWorkerRegistration(Registrations[Index]);
      if (Registration.StorageKey = Origin) and not Registration.Uninstalling and
         ((Registration.Active <> nil) or (Registration.Waiting <> nil)) then
        Kept.Add(Registration);
    end;
    if Kept.Count = 0 then
    begin
      OriginDataBackend.Save(ServiceWorkersKind, Origin, nil);
      Exit;
    end;
    Writer.WriteInteger(1);
    Writer.WriteInteger(Kept.Count);
    for Index := 0 to Kept.Count - 1 do
    begin
      Registration := TServiceWorkerRegistration(Kept[Index]);
      Writer.WriteText(Registration.Scope);
      Writer.WriteText(Registration.UpdateViaCache);
      Writer.WriteNumber(Registration.LastUpdateCheck);
      Writer.WriteInteger(Ord(Registration.NavigationPreloadEnabled));
      Writer.WriteText(Registration.NavigationPreloadHeader);
      { The worker that controls pages after a restart: the waiting one
        if there is one (it would have become active), else the active. }
      Worker := Registration.Waiting;
      if Worker = nil then
        Worker := Registration.Active;
      WriteWorker(Writer, Worker);
    end;
    OriginDataBackend.Save(ServiceWorkersKind, Origin, Writer.Data);
  finally
    Writer.Free;
    Kept.Free;
  end;
end;

procedure LoadOrigin(const Origin: string);
var
  Reader: TOriginDataReader;
  Count, Index: Int64;
  Scope, UpdateViaCache, ScriptUrl: string;
  Registration: TServiceWorkerRegistration;
  Worker: TServiceWorkerRecord;
begin
  if OriginDataBackend = nil then
    Exit;
  Reader := TOriginDataReader.Create(OriginDataBackend.Load(ServiceWorkersKind, Origin));
  try
    if Reader.AtEnd or (Reader.ReadInteger <> 1) then
      Exit;
    Count := Reader.ReadInteger;
    Index := 0;
    while (Index < Count) and not Reader.Failed do
    begin
      Scope := Reader.ReadText;
      UpdateViaCache := Reader.ReadText;
      Registration := NewRegistration(Origin, Scope, UpdateViaCache);
      Registration.LastUpdateCheck := Reader.ReadNumber;
      Registration.NavigationPreloadEnabled := Reader.ReadInteger <> 0;
      Registration.NavigationPreloadHeader := Reader.ReadText;
      ScriptUrl := Reader.ReadText;
      Worker := NewWorker(Registration, ScriptUrl);
      ReadWorker(Reader, Worker);
      Worker.State := WorkerActivated;
      Registration.Active := Worker;
      if Reader.Failed then
        RemoveRegistration(Registration);
      Inc(Index);
    end;
  finally
    Reader.Free;
  end;
end;

{ ---- registrations ---- }

function MatchRegistration(const Origin, Url: string): TServiceWorkerRegistration;
var
  Index: Integer;
  Registration: TServiceWorkerRegistration;
  Target: string;
begin
  EnsureLoaded(Origin);
  Target := UrlWithoutFragment(Url);
  Result := nil;
  for Index := 0 to Registrations.Count - 1 do
  begin
    Registration := TServiceWorkerRegistration(Registrations[Index]);
    if (Registration.StorageKey <> Origin) or Registration.Uninstalling then
      Continue;
    if (Copy(Target, 1, Length(Registration.Scope)) = Registration.Scope) and
       ((Result = nil) or (Length(Registration.Scope) > Length(Result.Scope))) then
      Result := Registration;
  end;
end;

function RegistrationForScope(const Origin, Scope: string): TServiceWorkerRegistration;
var
  Index: Integer;
  Registration: TServiceWorkerRegistration;
begin
  EnsureLoaded(Origin);
  for Index := 0 to Registrations.Count - 1 do
  begin
    Registration := TServiceWorkerRegistration(Registrations[Index]);
    if (Registration.StorageKey = Origin) and (Registration.Scope = Scope) and not Registration.Uninstalling then
      Exit(Registration);
  end;
  Result := nil;
end;

function RegistrationById(Id: QWord): TServiceWorkerRegistration;
var
  Index: Integer;
begin
  for Index := 0 to Registrations.Count - 1 do
    if TServiceWorkerRegistration(Registrations[Index]).Id = Id then
      Exit(TServiceWorkerRegistration(Registrations[Index]));
  Result := nil;
end;

function NewRegistration(const Origin, Scope, UpdateViaCache: string): TServiceWorkerRegistration;
begin
  Result := TServiceWorkerRegistration.Create;
  Inc(NextRegistrationId);
  Result.Id := NextRegistrationId;
  Result.StorageKey := Origin;
  Result.Scope := Scope;
  Result.UpdateViaCache := UpdateViaCache;
  Result.NavigationPreloadHeader := 'true';
  Registrations.Add(Result);
end;

procedure FreeWorkerOf(Registration: TServiceWorkerRegistration; Worker: TServiceWorkerRecord);
begin
  if (Worker <> nil) and (Worker.Registration = Registration) then
  begin
    Workers.Remove(Worker);
    Worker.Free;
  end;
end;

procedure RemoveRegistration(Registration: TServiceWorkerRegistration);
var
  Index: Integer;
  Worker: TServiceWorkerRecord;
begin
  Registrations.Remove(Registration);
  for Index := Workers.Count - 1 downto 0 do
  begin
    Worker := TServiceWorkerRecord(Workers[Index]);
    if Worker.Registration = Registration then
    begin
      Workers.Delete(Index);
      Worker.Free;
    end;
  end;
  Registration.Free;
end;

function RegistrationsOf(const Origin: string): TList;
var
  Index: Integer;
  Registration: TServiceWorkerRegistration;
begin
  EnsureLoaded(Origin);
  Result := TList.Create;
  for Index := 0 to Registrations.Count - 1 do
  begin
    Registration := TServiceWorkerRegistration(Registrations[Index]);
    if (Registration.StorageKey = Origin) and not Registration.Uninstalling then
      Result.Add(Registration);
  end;
end;

{ ---- workers ---- }

function NewWorker(Registration: TServiceWorkerRegistration; const ScriptUrl: string): TServiceWorkerRecord;
begin
  Result := TServiceWorkerRecord.Create;
  Inc(NextWorkerId);
  Result.Id := NextWorkerId;
  Result.Registration := Registration;
  Result.ScriptUrl := ScriptUrl;
  Result.State := WorkerParsed;
  Workers.Add(Result);
end;

function WorkerById(Id: QWord): TServiceWorkerRecord;
var
  Index: Integer;
begin
  for Index := 0 to Workers.Count - 1 do
    if TServiceWorkerRecord(Workers[Index]).Id = Id then
      Exit(TServiceWorkerRecord(Workers[Index]));
  Result := nil;
end;

procedure ForgetWorker(Worker: TServiceWorkerRecord);
begin
  if Workers.IndexOf(Worker) < 0 then
    Exit;
  Workers.Remove(Worker);
  Worker.Free;
end;

{ ---- clients ---- }

function AddClient(Context: TBindingContext; const Id, Origin, FrameType: string): TServiceWorkerClient;
begin
  Result := TServiceWorkerClient.Create;
  Result.Context := Context;
  Result.Id := Id;
  Result.Origin := Origin;
  Result.FrameType := FrameType;
  Inc(NextClientOrder);
  Result.CreationOrder := NextClientOrder;
  Clients.Add(Result);
end;

procedure RemoveClient(Client: TServiceWorkerClient);
begin
  Clients.Remove(Client);
  Client.Free;
end;

function ClientByContext(Context: TBindingContext): TServiceWorkerClient;
var
  Index: Integer;
begin
  for Index := 0 to Clients.Count - 1 do
    if TServiceWorkerClient(Clients[Index]).Context = Context then
      Exit(TServiceWorkerClient(Clients[Index]));
  Result := nil;
end;

function ClientById(const Id: string): TServiceWorkerClient;
var
  Index: Integer;
begin
  for Index := 0 to Clients.Count - 1 do
    if TServiceWorkerClient(Clients[Index]).Id = Id then
      Exit(TServiceWorkerClient(Clients[Index]));
  Result := nil;
end;

function ClientCount: Integer;
begin
  Result := Clients.Count;
end;

function ClientAt(Index: Integer): TServiceWorkerClient;
begin
  Result := TServiceWorkerClient(Clients[Index]);
end;

procedure ForgetAllRegistrations;
begin
  while Registrations.Count > 0 do
    RemoveRegistration(TServiceWorkerRegistration(Registrations[0]));
  while Workers.Count > 0 do
  begin
    TServiceWorkerRecord(Workers[0]).Free;
    Workers.Delete(0);
  end;
  LoadedOrigins.Clear;
end;

initialization
  Registrations := TList.Create;
  Workers := TList.Create;
  Clients := TList.Create;
  LoadedOrigins := TStringList.Create;
finalization
  ForgetAllRegistrations;
  while Clients.Count > 0 do
    RemoveClient(TServiceWorkerClient(Clients[0]));
  FreeAndNil(Registrations);
  FreeAndNil(Workers);
  FreeAndNil(Clients);
  FreeAndNil(LoadedOrigins);
end.
