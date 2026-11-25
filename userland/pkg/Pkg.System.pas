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
  The system's side of a package context: scripts run by /bin/sh (the
  script written to a file in the database folder, with PKG_NAME,
  PKG_VERSION, PKG_ROOT and PKG_PREFIX set), and URLs fetched through
  libhttp (http and https, the server's certificate checked against the
  system's), or copied from a local folder (file:///path, /path).
}
unit Pkg.System;

{$mode objfpc}
{$H+}

interface

uses
  Pkg.Context,
  Pkg.Manifests;

type
  TSystemServices = class
  public
    function RunScript(const Kind, Text: string; Manifest: TPackageManifest; const Root: string): Integer;
    function FetchUrl(const Url, TargetPath: string; out Problem: string): Boolean;
    procedure PrintMessage(const Text: string);
    procedure PrintWarning(const Text: string);
  end;

{ A context for Root with the system's services (Services stays alive
  as long as the context). }
function CreateSystemContext(const Root: string; Services: TSystemServices): TPackageContext;

implementation

uses
  Classes,
  SysUtils,
  Sys.Environment,
  Sys.Processes,
  Http.BodySinks,
  Http.Client,
  Http.Messages,
  Http.Observers,
  Http.Results,
  Http.SocketConnector,
  Pkg.Database,
  Pkg.FileSystem,
  Pkg.Paths;

function TSystemServices.RunScript(const Kind, Text: string; Manifest: TPackageManifest; const Root: string): Integer;
var
  Folder, ScriptPath, RootText: string;
  Arguments: array[0..2] of PChar;
  Made: TStringArray;
begin
  Folder := RootedPath(Root, DatabaseFolder);
  Made := nil;
  MakeFolders(Folder, Made);
  ScriptPath := Folder + '/.script-' + Manifest.Name + '-' + Kind;
  WriteTextFile(ScriptPath, Text + #10);
  RootText := Root;
  if RootText = '' then
    RootText := '/';
  SetVariable('PKG_NAME', Manifest.Name);
  SetVariable('PKG_VERSION', Manifest.FullVersion);
  SetVariable('PKG_ROOT', RootText);
  SetVariable('PKG_PREFIX', RootedPath(Root, Manifest.Prefix));
  Arguments[0] := '/bin/sh';
  Arguments[1] := PChar(ScriptPath);
  Arguments[2] := nil;
  try
    Result := RunProgram('/bin/sh', @Arguments[0]);
  finally
    DeleteFile(ScriptPath);
  end;
end;

function CopyLocalFile(const Source, TargetPath: string; out Problem: string): Boolean;
var
  Input, Output: TFileStream;
begin
  Problem := '';
  try
    Input := TFileStream.Create(Source, fmOpenRead or fmShareDenyNone);
    try
      Output := TFileStream.Create(TargetPath, fmCreate);
      try
        Output.CopyFrom(Input, 0);
      finally
        Output.Free;
      end;
    finally
      Input.Free;
    end;
    Result := True;
  except
    on Error: Exception do
    begin
      Problem := Error.Message;
      Result := False;
    end;
  end;
end;

function FetchOverHttp(const Url, TargetPath: string; out Problem: string): Boolean;
var
  Settings: THttpClientSettings;
  Client: THttpClient;
  Request: THttpRequest;
  Response: THttpResponse;
  Output: TFileStream;
  Sink: THttpStreamSink;
  Outcome: THttpResult;
begin
  Problem := '';
  Result := False;
  Settings := DefaultClientSettings;
  { Packages are compressed already; take them as they are. }
  Settings.AcceptEncoding := '';
  Settings.AllowHttp3 := False;
  if not THttpRequest.FromText('GET', Url, Request) then
  begin
    Problem := 'not a URL: ' + Url;
    Exit;
  end;
  Response := nil;
  Client := CreateSystemClient(Settings);
  Output := TFileStream.Create(TargetPath, fmCreate);
  Sink := THttpStreamSink.Create(Output);
  try
    Outcome := Client.Fetch(Request, Sink, Response);
    if not HttpSucceeded(Outcome) then
      Problem := Outcome.Text
    else if (Response = nil) or (Response.Status <> 200) then
    begin
      if Response <> nil then
        Problem := Format('the server answered %d', [Response.Status])
      else
        Problem := 'no answer';
    end
    else
      Result := True;
  finally
    Response.Free;
    Sink.Free;
    Output.Free;
    Request.Free;
    Client.Free;
  end;
  if not Result then
    DeleteFile(TargetPath);
end;

function TSystemServices.FetchUrl(const Url, TargetPath: string; out Problem: string): Boolean;
begin
  if Copy(Url, 1, 7) = 'file://' then
    Result := CopyLocalFile(Copy(Url, 8, MaxInt), TargetPath, Problem)
  else if (Url <> '') and (Url[1] = '/') then
    Result := CopyLocalFile(Url, TargetPath, Problem)
  else
    Result := FetchOverHttp(Url, TargetPath, Problem);
end;

procedure TSystemServices.PrintMessage(const Text: string);
begin
  WriteLn(Text);
end;

procedure TSystemServices.PrintWarning(const Text: string);
begin
  WriteLn(StdErr, Text);
end;

function CreateSystemContext(const Root: string; Services: TSystemServices): TPackageContext;
begin
  Result := TPackageContext.Create(Root);
  Result.OnMessage := @Services.PrintMessage;
  Result.OnWarning := @Services.PrintWarning;
  Result.RunScript := @Services.RunScript;
  Result.FetchUrl := @Services.FetchUrl;
end;

end.
