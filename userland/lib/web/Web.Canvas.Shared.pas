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
  Canvas objects that more than one owner holds: a gradient or pattern
  is a context's fill style and a script's value at once, a context is
  its canvas's and its wrapper's, an offscreen canvas its wrapper's and
  a placeholder canvas element's. They count references; the last
  Release frees them. A script wrapper holds its reference through a
  handle (the wrapper's owned native object) and the object remembers
  that wrapper while it lives, so script sees one wrapper per object.
}
unit Web.Canvas.Shared;

{$mode objfpc}
{$H+}

interface

type
  TCanvasSharedObject = class
  private
    FReferences: LongInt;
  public
    { The script wrapper showing it (a TBindingWrapper), nil when none
      lives; set and cleared by the bindings' handle. }
    ScriptWrapper: Pointer;
    constructor Create;
    function Retain: TCanvasSharedObject;
    procedure Release;
    property References: LongInt read FReferences;
  end;

  { The native object of a wrapper of a shared object: it holds one
    reference, and the wrapper going lets go of it. }
  TCanvasObjectHandle = class
  public
    Target: TCanvasSharedObject;
    constructor Create(ATarget: TCanvasSharedObject);
    destructor Destroy; override;
  end;

{ Releases Target when it is not nil and sets it to nil. }
procedure ReleaseShared(var Target);

implementation

constructor TCanvasSharedObject.Create;
begin
  inherited Create;
  FReferences := 1;
end;

function TCanvasSharedObject.Retain: TCanvasSharedObject;
begin
  Inc(FReferences);
  Result := Self;
end;

procedure TCanvasSharedObject.Release;
begin
  Dec(FReferences);
  if FReferences <= 0 then
    Free;
end;

constructor TCanvasObjectHandle.Create(ATarget: TCanvasSharedObject);
begin
  inherited Create;
  Target := ATarget;
  Target.Retain;
end;

destructor TCanvasObjectHandle.Destroy;
begin
  if Target <> nil then
  begin
    Target.ScriptWrapper := nil;
    Target.Release;
    Target := nil;
  end;
  inherited Destroy;
end;

procedure ReleaseShared(var Target);
var
  Shared: TCanvasSharedObject;
begin
  Shared := TCanvasSharedObject(Target);
  TCanvasSharedObject(Target) := nil;
  if Shared <> nil then
    Shared.Release;
end;

end.
