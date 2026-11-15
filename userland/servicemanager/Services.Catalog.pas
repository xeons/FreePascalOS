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
  The table of services: every NAME.service of the services directory,
  read once at start, with what the manager knows about each while it
  runs (Services.Supervisor changes that).

  Loading also checks what the services need of each other: a service
  that needs one that does not exist, or that is part of a circle of
  needs (directly or through others), gets a problem and is never
  started, like one whose file is wrong. The start order (StartOrder) is
  the order of the needs: a service comes after everything it needs,
  otherwise by name. The manager does not follow that list - it starts
  every service as soon as what it needs is ready, so independent ones
  start together - but it is the order they become able to start in,
  and what `servicemanager --check` prints.
}
unit Services.Catalog;

{$mode objfpc}
{$H+}

interface

uses
  Services.Definitions;

type
  TService = class
  public
    Definition: TServiceDefinition;
    { Why it can never start (a wrong file, an unknown need, a circle of
      needs); '' when it can. }
    Problem: string;
    { --- While the manager runs --- }
    { ServiceState* (Sys.ServiceControl). }
    State: LongWord;
    { It should be running: it is part of the boot mode, or was started
      by hand. }
    Wanted: Boolean;
    InBootMode: Boolean;
    ProcessHandle: Int64;
    ProcessId: QWord;
    LogHandle: Int64;
    { Restarts in a row, counted against the limit (reset by a long
      run, or by starting it by hand), and all of them. }
    RestartsInARow: LongInt;
    TotalRestarts: LongInt;
    LastExitCode: LongInt;
    HasEnded: Boolean;
    { Uptime in milliseconds. }
    StartedAt: QWord;
    ReadyAt: QWord;
    { When a restart is due, or the wait for readiness ends; 0: none. }
    DeadlineAt: QWord;
    { Stopped by `service restart`: start again once it has ended. }
    StartWhenStopped: Boolean;
    { Why it waits or failed, or what happened last. }
    Reason: string;
    constructor Create(const ADefinition: TServiceDefinition);
    function HasProcess: Boolean;
  end;

  TServiceList = array of TService;

var
  { Every service read, by name. }
  ServiceTable: array of TService;

{ Reads every NAME.service in Directory (by name) and checks their needs.
  Files that cannot be used are kept, with their problem. }
procedure LoadServices(const Directory: string);
function FindService(const Name: string): TService;
{ True if Service needs Other (directly). }
function Needs(Service, Other: TService): Boolean;
{ Every service that can start, after what it needs (see above): those
  of Mode and what they need, or every one when Mode is ''. }
function StartOrder(const Mode: string): TServiceList;
{ Where Service is in ServiceTable. }
function PositionOf(Service: TService): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.ServiceControl;

constructor TService.Create(const ADefinition: TServiceDefinition);
begin
  inherited Create;
  Definition := ADefinition;
  Problem := '';
  State := ServiceStateStopped;
  ProcessHandle := NoHandle;
  LogHandle := NoHandle;
end;

function TService.HasProcess: Boolean;
begin
  Result := ProcessHandle <> NoHandle;
end;

function FindService(const Name: string): TService;
var
  Index: LongInt;
begin
  for Index := 0 to High(ServiceTable) do
    if ServiceTable[Index].Definition.Name = Name then
      Exit(ServiceTable[Index]);
  Result := nil;
end;

function PositionOf(Service: TService): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(ServiceTable) do
    if ServiceTable[Index] = Service then
      Exit(Index);
  Result := -1;
end;

function Needs(Service, Other: TService): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(Service.Definition.Needs) do
    if Service.Definition.Needs[Index] = Other.Definition.Name then
      Exit(True);
  Result := False;
end;

{ The names of the service files in Directory, sorted. }
function ServiceFileNames(const Directory: string): TStringArray;
var
  Search: TSearchRec;
  Name: string;
  Index: LongInt;
  Other: LongInt;
  Swap: string;
begin
  Result := nil;
  if FindFirst(Directory + '/*' + ServiceFileSuffix, faAnyFile, Search) = 0 then
  begin
    repeat
      Name := Search.Name;
      if (Length(Name) > Length(ServiceFileSuffix)) and
         (Copy(Name, Length(Name) - Length(ServiceFileSuffix) + 1, Length(ServiceFileSuffix)) = ServiceFileSuffix) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Name;
      end;
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  { Few files: a simple sort keeps the order the same on every boot. }
  for Index := 0 to High(Result) do
    for Other := Index + 1 to High(Result) do
      if Result[Other] < Result[Index] then
      begin
        Swap := Result[Index];
        Result[Index] := Result[Other];
        Result[Other] := Swap;
      end;
end;

procedure CheckNeedsExist;
var
  Index: LongInt;
  NeedIndex: LongInt;
  Service: TService;
begin
  for Index := 0 to High(ServiceTable) do
  begin
    Service := ServiceTable[Index];
    if Service.Problem <> '' then
      Continue;
    for NeedIndex := 0 to High(Service.Definition.Needs) do
      if FindService(Service.Definition.Needs[NeedIndex]) = nil then
      begin
        Service.Problem := 'needs ' + Service.Definition.Needs[NeedIndex] + ', which does not exist';
        Break;
      end;
  end;
end;

type
  TVisitState = (NotVisited, BeingVisited, Visited);

{ Depth-first through the needs: a service met again while it is being
  visited closes a circle. }
function FindsCircle(Service: TService; var States: array of TVisitState): Boolean;
var
  Position: LongInt;
  NeedIndex: LongInt;
  Needed: TService;
begin
  Result := False;
  Position := PositionOf(Service);
  if States[Position] = Visited then
    Exit;
  if States[Position] = BeingVisited then
    Exit(True);
  States[Position] := BeingVisited;
  for NeedIndex := 0 to High(Service.Definition.Needs) do
  begin
    Needed := FindService(Service.Definition.Needs[NeedIndex]);
    if Needed = nil then
      Continue;
    if FindsCircle(Needed, States) then
      Result := True;
  end;
  States[Position] := Visited;
end;

procedure CheckForCircles;
var
  Index: LongInt;
  States: array of TVisitState;
  Other: LongInt;
begin
  SetLength(States, Length(ServiceTable));
  for Index := 0 to High(ServiceTable) do
  begin
    for Other := 0 to High(States) do
      States[Other] := NotVisited;
    if (ServiceTable[Index].Problem = '') and FindsCircle(ServiceTable[Index], States) then
      ServiceTable[Index].Problem := 'its needs go round in a circle';
  end;
end;

{ A service whose need cannot start cannot start either. }
procedure PassProblemsOn;
var
  Changed: Boolean;
  Index: LongInt;
  NeedIndex: LongInt;
  Needed: TService;
begin
  repeat
    Changed := False;
    for Index := 0 to High(ServiceTable) do
    begin
      if ServiceTable[Index].Problem <> '' then
        Continue;
      for NeedIndex := 0 to High(ServiceTable[Index].Definition.Needs) do
      begin
        Needed := FindService(ServiceTable[Index].Definition.Needs[NeedIndex]);
        if (Needed <> nil) and (Needed.Problem <> '') then
        begin
          ServiceTable[Index].Problem := 'needs ' + Needed.Definition.Name + ', which cannot start';
          Changed := True;
          Break;
        end;
      end;
    end;
  until not Changed;
end;

procedure LoadServices(const Directory: string);
var
  Names: TStringArray;
  Index: LongInt;
  Name: string;
  Definition: TServiceDefinition;
  Problem: string;
  Service: TService;
begin
  ServiceTable := nil;
  Names := ServiceFileNames(Directory);
  for Index := 0 to High(Names) do
  begin
    Name := Copy(Names[Index], 1, Length(Names[Index]) - Length(ServiceFileSuffix));
    if not IsServiceName(Name) then
      Continue;
    if not ReadDefinitionFile(Directory + '/' + Names[Index], Name, Definition, Problem) then
    begin
      DefaultDefinition(Name, Definition);
      Service := TService.Create(Definition);
      Service.Problem := Problem;
    end
    else
      Service := TService.Create(Definition);
    SetLength(ServiceTable, Length(ServiceTable) + 1);
    ServiceTable[High(ServiceTable)] := Service;
  end;
  CheckNeedsExist;
  CheckForCircles;
  PassProblemsOn;
end;

{ True when every service ServiceTable[Index] needs is placed. }
function NeedsArePlaced(Index: LongInt; const Placed: array of Boolean): Boolean;
var
  NeedIndex: LongInt;
begin
  for NeedIndex := 0 to High(ServiceTable[Index].Definition.Needs) do
    if not Placed[PositionOf(FindService(ServiceTable[Index].Definition.Needs[NeedIndex]))] then
      Exit(False);
  Result := True;
end;

function StartOrder(const Mode: string): TServiceList;
var
  Chosen: array of Boolean;
  Placed: array of Boolean;
  Changed: Boolean;
  Index: LongInt;
  NeedIndex: LongInt;
  Position: LongInt;
begin
  Result := nil;
  SetLength(Chosen, Length(ServiceTable));
  SetLength(Placed, Length(ServiceTable));
  for Index := 0 to High(ServiceTable) do
  begin
    Chosen[Index] := (ServiceTable[Index].Problem = '') and
      ((Mode = '') or BelongsToMode(ServiceTable[Index].Definition, Mode));
    Placed[Index] := False;
  end;
  { What the chosen ones need is started for them, in any mode. }
  repeat
    Changed := False;
    for Index := 0 to High(ServiceTable) do
      if Chosen[Index] then
        for NeedIndex := 0 to High(ServiceTable[Index].Definition.Needs) do
        begin
          Position := PositionOf(FindService(ServiceTable[Index].Definition.Needs[NeedIndex]));
          if not Chosen[Position] then
          begin
            Chosen[Position] := True;
            Changed := True;
          end;
        end;
  until not Changed;
  { Each round places, by name, every service whose needs are placed. }
  repeat
    Changed := False;
    for Index := 0 to High(ServiceTable) do
      if Chosen[Index] and not Placed[Index] and NeedsArePlaced(Index, Placed) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := ServiceTable[Index];
        Placed[Index] := True;
        Changed := True;
      end;
  until not Changed;
end;

end.
