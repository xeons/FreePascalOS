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
  The Programs tab's pictures: each listed window's icon, in an image
  list its rows show. The server lists each window with its icon's
  version (Windowing.WindowList); when that is new the icon is asked
  for (Windowing.WindowIcons): a name of the icon theme goes in once
  with every size its file has, a window's own pictures as the server
  gives them.
}
unit TaskManager.ProgramIcons;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.ImageList;

type
  TProgramIcons = class
  private
    FImages: TImageList;
    { Theme names to their pictures' indexes. }
    FNamed: TStringList;
    FWindowIds: array of LongWord;
    FVersions: array of LongWord;
    FIndexes: array of LongInt;
    function IndexOfWindow(WindowId: LongWord): LongInt;
    function PictureFor(WindowId: LongWord): LongInt;
  public
    constructor Create;
    destructor Destroy; override;
    { The picture of window WindowId's icon (Version as listed), asked
      for if new; -1 if it has none. }
    function ImageIndexOf(WindowId, Version: LongWord): LongInt;
    property Images: TImageList read FImages;
  end;

implementation

uses
  Image.Model,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.WindowIcons,
  Controls.IconTheme,
  Controls.WindowIcons;

const
  { Logical units: the rows' pictures. }
  IconSize = 16;

constructor TProgramIcons.Create;
begin
  inherited Create;
  FImages := TImageList.Create(IconSize, IconSize);
  FNamed := TStringList.Create;
  FNamed.Sorted := True;
end;

destructor TProgramIcons.Destroy;
begin
  FNamed.Free;
  FImages.Free;
  inherited Destroy;
end;

function TProgramIcons.IndexOfWindow(WindowId: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(FWindowIds) do
    if FWindowIds[Index] = WindowId then
      Exit(Index);
  Result := -1;
end;

function TProgramIcons.PictureFor(WindowId: LongWord): LongInt;
var
  Described: TDescribedIcon;
  Picture: TImage;
  Place: LongInt;
begin
  Result := -1;
  if not DescribeWindowIcon(WindowId, Scaled(IconSize), Described) then
    Exit;
  if (Described.Flags and WindowIconNamed) <> 0 then
  begin
    Place := FNamed.IndexOf(Described.Name);
    if Place >= 0 then
      Exit(LongInt(PtrInt(FNamed.Objects[Place])));
    Result := AddThemeIcon(FImages, Described.Name);
    FNamed.AddObject(Described.Name, TObject(PtrInt(Result)));
    Exit;
  end;
  Picture := ImageOfIconPicture(Described.Picture);
  if Picture = nil then
    Exit;
  Result := FImages.Add(Picture);
  Picture.Free;
end;

function TProgramIcons.ImageIndexOf(WindowId, Version: LongWord): LongInt;
var
  Index: LongInt;
begin
  Index := IndexOfWindow(WindowId);
  if (Index >= 0) and (FVersions[Index] = Version) then
    Exit(FIndexes[Index]);
  if Index < 0 then
  begin
    Index := Length(FWindowIds);
    SetLength(FWindowIds, Index + 1);
    SetLength(FVersions, Index + 1);
    SetLength(FIndexes, Index + 1);
    FWindowIds[Index] := WindowId;
  end;
  FVersions[Index] := Version;
  FIndexes[Index] := -1;
  if Version <> 0 then
    FIndexes[Index] := PictureFor(WindowId);
  Result := FIndexes[Index];
end;

end.
