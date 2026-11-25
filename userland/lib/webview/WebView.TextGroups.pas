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
  Where the text of a transformed or position: sticky group is shown, for
  the text index (WebView.TextIndex): the display list's transform and
  sticky groups as a tree, each run of text knowing the innermost group
  it is in. A transform maps the group's coordinates to its parent's
  (a matrix of document coordinates); a sticky group is moved by the
  offset its box has at the viewport's scroll offset now
  (Web.Paint.Sticky), as painting and hit testing (Web.Paint.Painter)
  move it.
}
unit WebView.TextGroups;

{$mode objfpc}
{$H+}

interface

uses
  Css.TransformMatrices,
  Web.Paint.DisplayList;

type
  TTextGroupKind = (tgTransform, tgSticky);

  TTextGroup = record
    Kind: TTextGroupKind;
    { -1 at the top. }
    Parent: Integer;
    Matrix, Inverse: TCssMatrix2D;
    { The transform flattens to nothing: nothing in it is shown. }
    Singular: Boolean;
    Sticky: TStickyRun;
    { The sticky box's border box. }
    BoxX, BoxY, BoxWidth, BoxHeight: Single;
    { Inside a fixed group: the sticky offset is taken at scroll 0. }
    InFixed: Boolean;
  end;

  { The viewport the groups are shown in (CSS px). }
  TTextViewport = record
    ScrollX, ScrollY, Width, Height: Single;
  end;

  TTextGroups = class
  private
    FGroups: array of TTextGroup;
    FCount: Integer;
    { The open groups while the list is read. }
    FOpen: array of Integer;
    FOpenCount: Integer;
    procedure StickyShift(constref Group: TTextGroup; constref View: TTextViewport; out X, Y: Single);
  public
    procedure Clear;
    { The list's items one at a time, in order: groups open and close. }
    procedure PushTransform(constref Matrix: TCssMatrix2D);
    procedure PushSticky(constref Sticky: TStickyRun; X, Y, Width, Height: Single; InFixed: Boolean);
    procedure Pop;
    { The innermost open group (-1: none). }
    function Current: Integer;
    { A point of Group's coordinates in the page's (document CSS px, or
      viewport for fixed text). }
    procedure ToPage(Group: Integer; constref View: TTextViewport; var X, Y: Single);
    { A page point in Group's coordinates; False when the group shows
      nothing. }
    function ToGroup(Group: Integer; constref View: TTextViewport; var X, Y: Single): Boolean;
    { The page's bounding box of a rectangle of Group's coordinates. }
    procedure RectangleToPage(Group: Integer; constref View: TTextViewport; var X, Y, Width, Height: Single);
    property Count: Integer read FCount;
  end;

implementation

uses
  Math,
  Web.Paint.Sticky;

function InvertMatrix(const Matrix: TCssMatrix2D; out Inverse: TCssMatrix2D): Boolean;
var
  Determinant: Double;
begin
  Inverse := IdentityMatrix;
  Determinant := Matrix.A * Matrix.D - Matrix.B * Matrix.C;
  Result := Abs(Determinant) > 1E-12;
  if not Result then
    Exit;
  Inverse.A := Matrix.D / Determinant;
  Inverse.B := -Matrix.B / Determinant;
  Inverse.C := -Matrix.C / Determinant;
  Inverse.D := Matrix.A / Determinant;
  Inverse.E := (Matrix.C * Matrix.F - Matrix.D * Matrix.E) / Determinant;
  Inverse.F := (Matrix.B * Matrix.E - Matrix.A * Matrix.F) / Determinant;
end;

procedure Apply(constref Matrix: TCssMatrix2D; var X, Y: Single);
var
  NewX, NewY: Double;
begin
  NewX := Matrix.A * X + Matrix.C * Y + Matrix.E;
  NewY := Matrix.B * X + Matrix.D * Y + Matrix.F;
  X := NewX;
  Y := NewY;
end;

procedure TTextGroups.Clear;
begin
  FGroups := nil;
  FCount := 0;
  FOpen := nil;
  FOpenCount := 0;
end;

function TTextGroups.Current: Integer;
begin
  if FOpenCount = 0 then
    Result := -1
  else
    Result := FOpen[FOpenCount - 1];
end;

procedure TTextGroups.PushTransform(constref Matrix: TCssMatrix2D);
var
  Group: ^TTextGroup;
begin
  if FCount = Length(FGroups) then
    SetLength(FGroups, FCount * 2 + 4);
  Group := @FGroups[FCount];
  Group^ := Default(TTextGroup);
  Group^.Kind := tgTransform;
  Group^.Parent := Current;
  Group^.Matrix := Matrix;
  Group^.Singular := not InvertMatrix(Matrix, Group^.Inverse);
  if FOpenCount = Length(FOpen) then
    SetLength(FOpen, FOpenCount * 2 + 4);
  FOpen[FOpenCount] := FCount;
  Inc(FOpenCount);
  Inc(FCount);
end;

procedure TTextGroups.PushSticky(constref Sticky: TStickyRun; X, Y, Width, Height: Single; InFixed: Boolean);
var
  Group: ^TTextGroup;
begin
  if FCount = Length(FGroups) then
    SetLength(FGroups, FCount * 2 + 4);
  Group := @FGroups[FCount];
  Group^ := Default(TTextGroup);
  Group^.Kind := tgSticky;
  Group^.Parent := Current;
  Group^.Sticky := Sticky;
  Group^.BoxX := X;
  Group^.BoxY := Y;
  Group^.BoxWidth := Width;
  Group^.BoxHeight := Height;
  Group^.InFixed := InFixed;
  if FOpenCount = Length(FOpen) then
    SetLength(FOpen, FOpenCount * 2 + 4);
  FOpen[FOpenCount] := FCount;
  Inc(FOpenCount);
  Inc(FCount);
end;

procedure TTextGroups.Pop;
begin
  if FOpenCount > 0 then
    Dec(FOpenCount);
end;

{ As the painter's hit test: the scrollport at the scroll offset (at 0
  inside a fixed group). }
procedure TTextGroups.StickyShift(constref Group: TTextGroup; constref View: TTextViewport; out X, Y: Single);
var
  PortX, PortY: Single;
begin
  PortX := View.ScrollX;
  PortY := View.ScrollY;
  if Group.InFixed then
  begin
    PortX := 0;
    PortY := 0;
  end;
  StickyOffset(Group.Sticky, Group.BoxX, Group.BoxY, Group.BoxWidth, Group.BoxHeight, PortX, PortY, View.Width,
    View.Height, X, Y);
end;

procedure TTextGroups.ToPage(Group: Integer; constref View: TTextViewport; var X, Y: Single);
var
  ShiftX, ShiftY: Single;
begin
  while (Group >= 0) and (Group < FCount) do
  begin
    if FGroups[Group].Kind = tgTransform then
      Apply(FGroups[Group].Matrix, X, Y)
    else
    begin
      StickyShift(FGroups[Group], View, ShiftX, ShiftY);
      X := X + ShiftX;
      Y := Y + ShiftY;
    end;
    Group := FGroups[Group].Parent;
  end;
end;

function TTextGroups.ToGroup(Group: Integer; constref View: TTextViewport; var X, Y: Single): Boolean;
var
  Chain: array of Integer;
  Depth, Index: Integer;
  ShiftX, ShiftY: Single;
begin
  Result := True;
  Chain := nil;
  Depth := 0;
  while (Group >= 0) and (Group < FCount) do
  begin
    SetLength(Chain, Depth + 1);
    Chain[Depth] := Group;
    Inc(Depth);
    Group := FGroups[Group].Parent;
  end;
  { Outermost first. }
  for Index := Depth - 1 downto 0 do
    if FGroups[Chain[Index]].Kind = tgTransform then
    begin
      if FGroups[Chain[Index]].Singular then
        Exit(False);
      Apply(FGroups[Chain[Index]].Inverse, X, Y);
    end
    else
    begin
      StickyShift(FGroups[Chain[Index]], View, ShiftX, ShiftY);
      X := X - ShiftX;
      Y := Y - ShiftY;
    end;
end;

procedure TTextGroups.RectangleToPage(Group: Integer; constref View: TTextViewport; var X, Y, Width,
  Height: Single);
var
  CornerX, CornerY: array[0..3] of Single;
  Corner: Integer;
  Left, Top, Right, Bottom: Single;
begin
  if Group < 0 then
    Exit;
  CornerX[0] := X;
  CornerY[0] := Y;
  CornerX[1] := X + Width;
  CornerY[1] := Y;
  CornerX[2] := X;
  CornerY[2] := Y + Height;
  CornerX[3] := X + Width;
  CornerY[3] := Y + Height;
  for Corner := 0 to 3 do
    ToPage(Group, View, CornerX[Corner], CornerY[Corner]);
  Left := MinValue(CornerX);
  Top := MinValue(CornerY);
  Right := MaxValue(CornerX);
  Bottom := MaxValue(CornerY);
  X := Left;
  Y := Top;
  Width := Right - Left;
  Height := Bottom - Top;
end;

end.
