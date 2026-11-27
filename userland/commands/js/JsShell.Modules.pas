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
  The js shell's modules: files. A module's key is its path; "./" and
  "../" specifiers resolve against the importing file's directory (the
  engine's default resolver), and the fetcher reads the file at once.
  import.meta gets filename and dirname besides url, as in Node.
}
unit JsShell.Modules;

{$mode objfpc}{$H+}

interface

uses
  Js.Engine;

{ Lets the engine load modules from files. }
procedure InstallFileModules(Engine: TJsEngine);

implementation

uses
  SysUtils,
  Sys.Streams,
  Util.Input,
  Js.Values,
  Js.Objects;

type
  TFileModules = class
  public
    Engine: TJsEngine;
    procedure Fetch(Request: TJsModuleFetch);
    procedure FillMeta(const Key: string; Meta: TJsObject);
  end;

var
  Modules: TFileModules;

procedure TFileModules.Fetch(Request: TJsModuleFetch);
var
  Stream: PInputStream;
  Text: string;
begin
  Stream := nil;
  if FileExists(Request.Key) then
    Stream := OpenInput(Request.Key);
  if Stream = nil then
  begin
    Request.Fail('Cannot find module ''' + Request.Key + '''');
    Exit;
  end;
  Text := ReadAllText(Stream);
  CloseInput(Stream);
  Request.Succeed(Text);
end;

procedure TFileModules.FillMeta(const Key: string; Meta: TJsObject);
var
  Directory: string;
begin
  Directory := ExtractFileDir(Key);
  if Directory = '' then
    Directory := '.';
  Meta.DefineData(Engine.Realm, Engine.Realm.Intern('filename'), Engine.NewString(Key));
  Meta.DefineData(Engine.Realm, Engine.Realm.Intern('dirname'), Engine.NewString(Directory));
end;

procedure InstallFileModules(Engine: TJsEngine);
begin
  if Modules = nil then
    Modules := TFileModules.Create;
  Modules.Engine := Engine;
  Engine.ModuleFetcher := @Modules.Fetch;
  Engine.ModuleMetaHook := @Modules.FillMeta;
end;

finalization
  Modules.Free;
end.
