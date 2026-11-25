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
  Edit boxes: one line of text to type.

  The caret and the selection are character positions (the text is
  UTF-8). Typing replaces the selection; Backspace and Delete remove a
  character or the selection; the arrows, Home and End move the caret
  (with Shift they extend the selection). The edit commands
  (Controls.EditCommands) cut, copy and paste through the clipboard and
  select everything, from their keys or the context menu a right click
  shows; pasted text stops at its first line break, as the box has one
  line. A click puts the caret at the nearest character boundary,
  dragging selects. The text scrolls sideways to keep the caret in view.
  Enter is left for the window (its default button). Every change of
  the text is announced (OnChange, NotifyChanged). A box that hides its
  text (HidesText: a password) shows a dot for each character and never
  lets it be copied or cut.
}
unit Controls.EditBox;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.DragData,
  Controls.Base,
  Controls.EditCommands;

type
  TEditBox = class(TControl)
  private
    FCaret: LongInt;
    FAnchor: LongInt;
    FScroll: LongInt;
    FSelecting: Boolean;
    FMaximumLength: LongInt;
    FReadOnly: Boolean;
    FHidesText: Boolean;
    FBorderless: Boolean;
    FPlaceholder: string;
    procedure SetBorderless(Value: Boolean);
    procedure SetPlaceholder(const Value: string);
    function TextLeft: LongInt;
    function ShownText: string;
    procedure SetHidesText(Value: Boolean);
    function CaretX(Position: LongInt): LongInt;
    function PositionAt(X: LongInt): LongInt;
    procedure MoveCaret(Position: LongInt; Extend: Boolean);
    procedure ReplaceSelection(const Inserted: string);
    procedure ScrollToCaret;
    function SelectionStart: LongInt;
    function SelectionEnd: LongInt;
    function HasSelection: Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure TextChanged; override;
    { Text (or files, as their paths) dropped goes where it is let go. }
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; override;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); override;
  public
    constructor Create(AParent: TControl); override;
    function PreferredSize: TSize; override;
    procedure SelectAll;
    { Selects Count characters from character First (the caret at their
      end). }
    procedure SelectRange(First, Count: LongInt);
    function SelectedText: string;
    procedure CutToClipboard;
    procedure CopyToClipboard;
    procedure PasteFromClipboard;
    procedure RunEditCommand(Command: TEditCommand);
    property CaretPosition: LongInt read FCaret;
    { 0: no limit (characters). }
    property MaximumLength: LongInt read FMaximumLength write FMaximumLength;
    property ReadOnly: Boolean read FReadOnly write FReadOnly;
    { Shows dots instead of the characters (a password box). }
    property HidesText: Boolean read FHidesText write SetHidesText;
    { No bevel of its own: the field inside a control that draws the
      frame (an address bar with buttons in it). }
    property Borderless: Boolean read FBorderless write SetBorderless;
    { Shown greyed while the box is empty and has not the focus (what
      a search box searches with). }
    property Placeholder: string read FPlaceholder write SetPlaceholder;
  end;

implementation

uses
  SysUtils,
  Controls.TextPositions,
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Clipboard,
  Controls.SystemDrag,
  Controls.LayoutRules,
  Controls.Painting;

constructor TEditBox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  PointerShape := PointerTextBeam;
end;

const
  { Logical units: the width a box without one of its own gets, and the
    room above and below a line of text (the bevel and a gap). }
  DefaultEditWidth = 120;
  EditRoomDown = 8;
  MinimumEditHeight = 22;

{ Its width is the program's (what it is now); its height fits a line. }
function TEditBox.PreferredSize: TSize;
var
  Width: LongInt;
  Height: LongInt;
begin
  Width := RectangleWidth(Bounds);
  if Width <= 0 then
    Width := DefaultEditWidth;
  Height := PixelsToLogicalCeiling(TextHeight(ControlFace)) + EditRoomDown;
  if Height < MinimumEditHeight then
    Height := MinimumEditHeight;
  Result := MakeSize(Width, Height);
end;

function TEditBox.TextLeft: LongInt;
begin
  if FBorderless then
    Result := Scaled(2)
  else
    Result := Scaled(4);
end;

procedure TEditBox.SetBorderless(Value: Boolean);
begin
  FBorderless := Value;
  Invalidate;
end;

procedure TEditBox.SetPlaceholder(const Value: string);
begin
  FPlaceholder := Value;
  Invalidate;
end;

const
  { U+2022, the bullet, in UTF-8. }
  HiddenCharacter = #$E2#$80#$A2;

function TEditBox.ShownText: string;
var
  Index: LongInt;
begin
  if not FHidesText then
    Exit(Text);
  Result := '';
  for Index := 1 to CharacterCountOf(Text) do
    Result := Result + HiddenCharacter;
end;

procedure TEditBox.SetHidesText(Value: Boolean);
begin
  FHidesText := Value;
  Invalidate;
end;

function TEditBox.CaretX(Position: LongInt): LongInt;
begin
  Result := TextLeft - FScroll + TextWidth(ControlFace, CharactersOf(ShownText, 0, Position));
end;

function TEditBox.PositionAt(X: LongInt): LongInt;
var
  Count: LongInt;
  Position: LongInt;
begin
  Count := CharacterCountOf(Text);
  for Position := 0 to Count - 1 do
    { Past the middle of the character: after it. }
    if X < (CaretX(Position) + CaretX(Position + 1)) div 2 then
      Exit(Position);
  Result := Count;
end;

function TEditBox.SelectionStart: LongInt;
begin
  if FAnchor < FCaret then
    Result := FAnchor
  else
    Result := FCaret;
end;

function TEditBox.SelectionEnd: LongInt;
begin
  if FAnchor > FCaret then
    Result := FAnchor
  else
    Result := FCaret;
end;

function TEditBox.SelectedText: string;
begin
  Result := CharactersOf(Text, SelectionStart, SelectionEnd - SelectionStart);
end;

function TEditBox.HasSelection: Boolean;
begin
  Result := FAnchor <> FCaret;
end;

procedure TEditBox.CopyToClipboard;
begin
  if HasSelection and not FHidesText then
    SetClipboardText(SelectedText);
end;

procedure TEditBox.CutToClipboard;
begin
  if not HasSelection or FReadOnly or FHidesText then
    Exit;
  SetClipboardText(SelectedText);
  ReplaceSelection('');
end;

{ The clipboard's text up to its first line break: a line of it. }
function FirstLineOf(const Text: string): string;
var
  Index: LongInt;
begin
  for Index := 1 to Length(Text) do
    if (Text[Index] = #10) or (Text[Index] = #13) then
      Exit(Copy(Text, 1, Index - 1));
  Result := Text;
end;

procedure TEditBox.PasteFromClipboard;
var
  Pasted: string;
begin
  if FReadOnly then
    Exit;
  Pasted := ClipboardText;
  if Pasted <> '' then
    ReplaceSelection(FirstLineOf(Pasted));
end;

function TEditBox.DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
var
  Dropped: string;
begin
  Result := DropNone;
  { (Its own text is not dragged out of it.) }
  if FReadOnly or not Enabled or (Data.Source = Self) or not DragDataAsText(Data, Dropped) then
    Exit;
  Result := DropCopy;
end;

procedure TEditBox.DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Dropped: string;
begin
  if FReadOnly or not DragDataAsText(Data, Dropped) then
    Exit;
  SetFocus;
  MoveCaret(PositionAt(X), False);
  ReplaceSelection(FirstLineOf(StringReplace(Dropped, #10, ' ', [rfReplaceAll])));
end;

procedure TEditBox.RunEditCommand(Command: TEditCommand);
begin
  case Command of
    EditCommandCut: CutToClipboard;
    EditCommandCopy: CopyToClipboard;
    EditCommandPaste: PasteFromClipboard;
    EditCommandSelectAll: SelectAll;
  end;
end;

procedure TEditBox.SelectAll;
begin
  FAnchor := 0;
  FCaret := CharacterCountOf(Text);
  ScrollToCaret;
  Invalidate;
end;

procedure TEditBox.SelectRange(First, Count: LongInt);
begin
  MoveCaret(First, False);
  MoveCaret(First + Count, True);
end;

procedure TEditBox.ScrollToCaret;
var
  X: LongInt;
  Width: LongInt;
begin
  Width := RectangleWidth(PixelBounds);
  X := CaretX(FCaret);
  if X < TextLeft then
    FScroll := FScroll - (TextLeft - X)
  else if X > Width - TextLeft then
    FScroll := FScroll + (X - (Width - TextLeft));
  if FScroll < 0 then
    FScroll := 0;
end;

procedure TEditBox.MoveCaret(Position: LongInt; Extend: Boolean);
begin
  if Position < 0 then
    Position := 0;
  if Position > CharacterCountOf(Text) then
    Position := CharacterCountOf(Text);
  FCaret := Position;
  if not Extend then
    FAnchor := Position;
  ScrollToCaret;
  Invalidate;
end;

procedure TEditBox.ReplaceSelection(const Inserted: string);
var
  Count: LongInt;
  NewText: string;
  Start: LongInt;
begin
  if FReadOnly then
    Exit;
  Count := CharacterCountOf(Text);
  Start := SelectionStart;
  if (FMaximumLength > 0) and (Count - (SelectionEnd - Start) + CharacterCountOf(Inserted) > FMaximumLength) then
    Exit;
  NewText := CharactersOf(Text, 0, Start) + Inserted + CharactersOf(Text, SelectionEnd, Count);
  FCaret := Start + CharacterCountOf(Inserted);
  FAnchor := FCaret;
  { Text's setter announces the change; the caret is set already. }
  Text := NewText;
  ScrollToCaret;
end;

procedure TEditBox.TextChanged;
var
  Count: LongInt;
begin
  Count := CharacterCountOf(Text);
  if FCaret > Count then
    FCaret := Count;
  if FAnchor > Count then
    FAnchor := Count;
  Changed;
end;

function TEditBox.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Extend: Boolean;
  Command: TEditCommand;
begin
  Result := True;
  Extend := (Modifiers and ModifierShift) <> 0;
  if EditCommandOfKey(Code, Modifiers, Command) then
  begin
    RunEditCommand(Command);
    Exit;
  end;
  case Code of
    KeyArrowLeft: MoveCaret(FCaret - 1, Extend);
    KeyArrowRight: MoveCaret(FCaret + 1, Extend);
    KeyHome: MoveCaret(0, Extend);
    KeyEnd: MoveCaret(CharacterCountOf(Text), Extend);
    KeyBackspace:
      begin
        if FAnchor = FCaret then
          FAnchor := FCaret - 1;
        if FAnchor < 0 then
          FAnchor := 0;
        ReplaceSelection('');
      end;
    KeyDelete:
      begin
        if FAnchor = FCaret then
          FAnchor := FCaret + 1;
        if FAnchor > CharacterCountOf(Text) then
          FAnchor := CharacterCountOf(Text);
        ReplaceSelection('');
      end;
  else
    if (Character >= 32) and (Character <> 127) and ((Modifiers and ModifierControl) = 0) then
      ReplaceSelection(Utf8Of(Character))
    else
      Result := False;
  end;
end;

procedure TEditBox.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  FSelecting := True;
  MoveCaret(PositionAt(X), False);
end;

procedure TEditBox.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if FSelecting then
    MoveCaret(PositionAt(X), True);
end;

procedure TEditBox.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FSelecting := False;
  { The context menu opens as the button is let go, so the release does
    not land on the menu. }
  if Button = ButtonRight then
    ShowEditMenu(Self, X, Y, AvailableEditCommands(HasSelection and not FHidesText, FReadOnly), @RunEditCommand);
end;

procedure TEditBox.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Face: TRectangle;
  TextTop: LongInt;
  SelectionLeft: LongInt;
  SelectionRight: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if Enabled and not FReadOnly then
    FillRectangle(Canvas, Box, Theme.Field)
  else
    FillRectangle(Canvas, Box, Theme.Face);
  if not FBorderless then
    DrawSunkenBevel(Canvas, Box);
  if ControlFace = nil then
    Exit;
  { Text stays inside the bevel. }
  Inner := Canvas;
  if FBorderless then
    Face := Box
  else
    Face := InflateRectangle(Box, -BevelWidth);
  NarrowCanvasClip(Inner, Face);
  TextTop := (RectangleHeight(Box) - TextHeight(ControlFace)) div 2;
  if (Text = '') and not Focused and (FPlaceholder <> '') then
  begin
    DrawTextInBox(Inner, ControlFace, FPlaceholder, MakeRectangle(TextLeft, TextTop, RectangleWidth(Face),
      TextHeight(ControlFace)), AlignTextLeft, Theme.DisabledText);
    Exit;
  end;
  if Enabled then
    DrawTextInBox(Inner, ControlFace, ShownText, MakeRectangle(TextLeft - FScroll, TextTop, 1 shl 20,
      TextHeight(ControlFace)), AlignTextLeft, Theme.FieldText)
  else
    DrawDisabledText(Inner, ControlFace, ShownText, TextLeft - FScroll, TextTop);
  if Focused and (SelectionStart <> SelectionEnd) then
  begin
    SelectionLeft := CaretX(SelectionStart);
    SelectionRight := CaretX(SelectionEnd);
    FillRectangle(Inner, MakeRectangle(SelectionLeft, TextTop, SelectionRight - SelectionLeft, TextHeight(ControlFace)),
      Theme.Selection);
    DrawTextInBox(Inner, ControlFace, CharactersOf(ShownText, SelectionStart, SelectionEnd - SelectionStart),
      MakeRectangle(SelectionLeft, TextTop, 1 shl 20,
      TextHeight(ControlFace)), AlignTextLeft, Theme.SelectionText);
  end;
  if Focused then
    FillRectangle(Inner, MakeRectangle(CaretX(FCaret), TextTop, Scaled(1), TextHeight(ControlFace)), Theme.FieldText);
end;

end.
