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
  A debugging script run in every document's realm before the page's
  own scripts (the top document and every src frame, whatever its
  origin): webbrowse --preload FILE. It is how a site's scripts are
  watched from inside a cross-origin frame (wrapping DOM methods,
  logging to the console).
}
unit WebBrowse.Preload;

{$mode objfpc}
{$H+}

interface

procedure InstallPreloadScript(const FileName: string);

implementation

uses
  SysUtils,
  Classes,
  Js.Values,
  Web.Bindings.Context,
  Web.Script.Context,
  Web.Script.PageScripting;

var
  PreloadSource: string;
  PreviousContextStarted: TPageContextStartedHook;

procedure RunPreload(Context: TBindingContext);
var
  ScriptContext: TScriptContext;
  Value: TJsValue;
  ErrorText: string;
begin
  if Assigned(PreviousContextStarted) then
    PreviousContextStarted(Context);
  if not (Context is TScriptContext) then
    Exit;
  ScriptContext := TScriptContext(Context);
  ScriptContext.EnterScript;
  try
    if not ScriptContext.Engine.TryEvaluate(PreloadSource, '<preload>', Value, ErrorText) then
      WriteLn(StdErr, 'preload: error: ', ErrorText);
  finally
    ScriptContext.LeaveScript;
  end;
end;

procedure InstallPreloadScript(const FileName: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    PreloadSource := Lines.Text;
  finally
    Lines.Free;
  end;
  PreviousContextStarted := PageContextStartedHook;
  PageContextStartedHook := @RunPreload;
end;

end.
