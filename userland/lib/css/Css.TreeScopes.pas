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
  A shadow tree's style scope (CSS Scoping): the author style sheets of
  one shadow tree (its <style> elements and adopted sheets) indexed on
  their own. The style engine matches an element of the shadow tree
  against its scope's rules only (and the user agent's), its host
  against the scope's :host rules, the elements assigned to the
  scope's slots against its ::slotted() rules, and the outer tree's
  ::part() rules against the parts inside. Depth is the shadow tree
  nesting the cascade's context compares (the document is 0).
}
unit Css.TreeScopes;

{$mode objfpc}
{$H+}

interface

uses
  Css.Stylesheets, Css.MediaQueries, Css.RuleIndex, Css.ElementAdapter;

type
  TCssTreeScope = class
  private
    FIndex: TCssRuleIndex;
    FSheets: array of TCssStyleSheet;
    FHost: TCssElement;
    FDepth: Integer;
    FDirty: Boolean;
    FEnvironment: TCssMediaEnvironment;
    FHasEnvironment: Boolean;
  public
    constructor Create(Host: TCssElement; Depth: Integer);
    destructor Destroy; override;
    { The scope's sheets in order (the host keeps them). }
    procedure SetSheets(const Sheets: array of TCssStyleSheet);
    { The rules changed: indexed again before the next use. }
    procedure Invalidate;
    { The index for Environment (built again when out of date). }
    function Rules(const Environment: TCssMediaEnvironment): TCssRuleIndex;
    function SheetCount: Integer;
    property Host: TCssElement read FHost write FHost;
    property Depth: Integer read FDepth write FDepth;
  end;

implementation

uses
  SysUtils;

constructor TCssTreeScope.Create(Host: TCssElement; Depth: Integer);
begin
  inherited Create;
  FHost := Host;
  FDepth := Depth;
  FIndex := TCssRuleIndex.Create;
  FDirty := True;
end;

destructor TCssTreeScope.Destroy;
begin
  FIndex.Free;
  inherited Destroy;
end;

procedure TCssTreeScope.SetSheets(const Sheets: array of TCssStyleSheet);
var
  Index: Integer;
  Same: Boolean;
begin
  Same := Length(Sheets) = Length(FSheets);
  if Same then
    for Index := 0 to High(Sheets) do
      if Sheets[Index] <> FSheets[Index] then
        Same := False;
  if Same then
    Exit;
  SetLength(FSheets, Length(Sheets));
  for Index := 0 to High(Sheets) do
    FSheets[Index] := Sheets[Index];
  FDirty := True;
end;

procedure TCssTreeScope.Invalidate;
begin
  FDirty := True;
end;

function SameEnvironment(const A, B: TCssMediaEnvironment): Boolean;
begin
  Result := CompareByte(A, B, SizeOf(TCssMediaEnvironment)) = 0;
end;

function TCssTreeScope.Rules(const Environment: TCssMediaEnvironment): TCssRuleIndex;
begin
  if FDirty or not FHasEnvironment or not SameEnvironment(FEnvironment, Environment) then
  begin
    FEnvironment := Environment;
    FHasEnvironment := True;
    FIndex.Build(FSheets, Environment);
    FDirty := False;
  end;
  Result := FIndex;
end;

function TCssTreeScope.SheetCount: Integer;
begin
  Result := Length(FSheets);
end;

end.
