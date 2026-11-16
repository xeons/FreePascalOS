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
  The edit box a list view puts over an item's name to rename it in
  place (TListView.EditItem).

  Enter takes the new name, Escape keeps the old one; the box losing the
  focus (a click elsewhere) takes it too, as people expect. Either way
  OnFinished is told once. The box is only hidden afterwards, never
  freed while one of its own handlers runs: the list view keeps it for
  the next rename.
}
unit Controls.ListEditing;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.EditBox;

type
  TCaptionEditor = class;
  TCaptionEditorEvent = procedure(Sender: TCaptionEditor; Accepted: Boolean) of object;

  TCaptionEditor = class(TEditBox)
  private
    FEditing: Boolean;
    FOnFinished: TCaptionEditorEvent;
    procedure Finish(Accepted: Boolean);
  protected
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure FocusChanged; override;
  public
    constructor Create(AParent: TControl); override;
    { Shows Caption in the box, selected (only the part before the last
      dot, the name without its extension, if SelectWithoutExtension),
      and gives it the focus. }
    procedure StartEditing(const Caption: string; SelectWithoutExtension: Boolean);
    { Ends the editing as Enter (Accepted) or Escape would. }
    procedure StopEditing(Accepted: Boolean);
    property Editing: Boolean read FEditing;
    property OnFinished: TCaptionEditorEvent read FOnFinished write FOnFinished;
  end;

implementation

uses
  Controls.Keys;

constructor TCaptionEditor.Create(AParent: TControl);
begin
  inherited Create(AParent);
  Visible := False;
end;

{ The characters before the last dot of Caption (all of it if the only
  dot starts the name, as in ".profile"). }
function CharactersBeforeExtension(const Caption: string): LongInt;
var
  Index: LongInt;
  DotAt: LongInt;
begin
  DotAt := 0;
  for Index := Length(Caption) downto 2 do
    if Caption[Index] = '.' then
    begin
      DotAt := Index;
      Break;
    end;
  if DotAt = 0 then
    DotAt := Length(Caption) + 1;
  { Characters, not bytes: count the bytes that start one. }
  Result := 0;
  for Index := 1 to DotAt - 1 do
    if (Ord(Caption[Index]) and $C0) <> $80 then
      Inc(Result);
end;

procedure TCaptionEditor.StartEditing(const Caption: string; SelectWithoutExtension: Boolean);
begin
  Text := Caption;
  FEditing := True;
  Visible := True;
  SetFocus;
  if SelectWithoutExtension then
    SelectRange(0, CharactersBeforeExtension(Caption))
  else
    SelectAll;
end;

procedure TCaptionEditor.Finish(Accepted: Boolean);
begin
  if not FEditing then
    Exit;
  FEditing := False;
  Visible := False;
  if Assigned(FOnFinished) then
    FOnFinished(Self, Accepted);
end;

procedure TCaptionEditor.StopEditing(Accepted: Boolean);
begin
  Finish(Accepted);
end;

function TCaptionEditor.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  if FEditing and IsEnterKey(Code) then
  begin
    Finish(True);
    Exit(True);
  end;
  if FEditing and (Code = KeyEscape) then
  begin
    Finish(False);
    Exit(True);
  end;
  Result := inherited KeyDown(Code, Character, Modifiers);
end;

procedure TCaptionEditor.FocusChanged;
begin
  inherited FocusChanged;
  if FEditing and not Focused then
    Finish(True);
end;

end.
