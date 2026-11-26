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
  Choosing a navigable by name among the frames this page's script can
  see (HTML Standard 7.3.1.7, "the rules for choosing a navigable"):
  "" and _self are this window, _parent and _top its ancestors, any
  other name the first frame so named among this window's descendants,
  then among those of each ancestor up to the top. A form's target and
  window.open's name navigate the frame found; a name no frame has is
  the host's (a new window or tab).
}
unit Web.Bindings.NamedTargets;

{$mode objfpc}
{$H+}

interface

uses
  Web.Bindings.Context;

{ The window (context) Name chooses; nil when no frame here has it. }
function ChooseTargetContext(Context: TBindingContext; const Name: string): TBindingContext;

implementation

uses
  SysUtils;

function FrameName(Frame: TBindingContext): string;
begin
  Result := ValueToText(Frame.Engine.Realm, Frame.Singleton(SingletonWindowName));
end;

function FindDescendant(Context: TBindingContext; const Name: string): TBindingContext;
var
  Index: Integer;
  Child: TBindingContext;
begin
  for Index := 0 to Context.FrameCount - 1 do
  begin
    Child := Context.FrameAt(Index);
    if (Child <> nil) and not Child.Closed and (FrameName(Child) = Name) then
      Exit(Child);
  end;
  for Index := 0 to Context.FrameCount - 1 do
  begin
    Child := Context.FrameAt(Index);
    if (Child = nil) or Child.Closed then
      Continue;
    Result := FindDescendant(Child, Name);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function ChooseTargetContext(Context: TBindingContext; const Name: string): TBindingContext;
var
  Lower: string;
  Ancestor: TBindingContext;
begin
  Lower := LowerCase(Name);
  if (Name = '') or (Lower = '_self') then
    Exit(Context);
  if Lower = '_parent' then
  begin
    if Context.ParentContext <> nil then
      Exit(Context.ParentContext);
    Exit(Context);
  end;
  if Lower = '_top' then
    Exit(Context.TopContext);
  if Lower = '_blank' then
    Exit(nil);
  if FrameName(Context) = Name then
    Exit(Context);
  Result := FindDescendant(Context, Name);
  Ancestor := Context.ParentContext;
  while (Result = nil) and (Ancestor <> nil) do
  begin
    if FrameName(Ancestor) = Name then
      Exit(Ancestor);
    Result := FindDescendant(Ancestor, Name);
    Ancestor := Ancestor.ParentContext;
  end;
end;

end.
