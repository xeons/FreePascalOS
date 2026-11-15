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
  Multi-line edit boxes: text in lines, to type and change.

  Positions are a line and a character in it (UTF-8 by characters). The
  keys of the one line edit box work across lines: the arrows (up and
  down keep the column as near as they can), Home and End within the
  line, Page Up and Down by a screenful, Shift with any of them to
  select; Enter splits the line (so the window's default button is not
  pressed), Backspace and Delete join lines at their ends. The edit
  commands (Controls.EditCommands: cut, copy, paste, select all) work
  from their keys and from the context menu of a right click; the
  clipboard holds lines joined with line feeds. Tab moves to the next control unless AcceptTabs. A
  vertical scroll bar shows when the lines do not fit, and the text
  scrolls sideways to keep the caret in view.
}
unit Controls.TextEdit;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Windowing.Messages,
  Controls.Base,
  Controls.ScrollBar,
  Controls.EditCommands;

type
  TTextPosition = record
    Line: LongInt;
    Column: LongInt;
  end;

  TTextEdit = class(TControl)
  private
    FLines: TStringList;
    FCaret: TTextPosition;
    FAnchor: TTextPosition;
    FTopLine: LongInt;
    FScrollX: LongInt;
    FScrollBar: TScrollBar;
    FSelecting: Boolean;
    FAcceptTabs: Boolean;
    FReadOnly: Boolean;
    FChanging: Boolean;
    function LineHeight: LongInt;
    function VisibleLines: LongInt;
    function TextLeft: LongInt;
    function ColumnX(Line, Column: LongInt): LongInt;
    function PositionAt(X, Y: LongInt): TTextPosition;
    function LineLength(Line: LongInt): LongInt;
    procedure MoveCaret(Line, Column: LongInt; Extend: Boolean);
    procedure ScrollToCaret;
    procedure SetTopLine(Value: LongInt);
    procedure UpdateScrollBar;
    function SelectionStart: TTextPosition;
    function SelectionEnd: TTextPosition;
    function HasSelection: Boolean;
    procedure DeleteSelection;
    procedure InsertText(const Inserted: string);
    procedure LinesChanged(Sender: TObject);
    procedure TextEdited;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    procedure SelectAll;
    function SelectedText: string;
    procedure CutToClipboard;
    procedure CopyToClipboard;
    procedure PasteFromClipboard;
    procedure RunEditCommand(Command: TEditCommand);
    { The whole text, lines joined with line feeds. }
    function AllText: string;
    procedure SetAllText(const Value: string);
    property Lines: TStringList read FLines;
    property CaretLine: LongInt read FCaret.Line;
    property CaretColumn: LongInt read FCaret.Column;
    property AcceptTabs: Boolean read FAcceptTabs write FAcceptTabs;
    property ReadOnly: Boolean read FReadOnly write FReadOnly;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Clipboard;

const
  TabCharacter = 9;

function MakePosition(Line, Column: LongInt): TTextPosition;
begin
  Result.Line := Line;
  Result.Column := Column;
end;

function PositionBefore(const First, Second: TTextPosition): Boolean;
begin
  Result := (First.Line < Second.Line) or ((First.Line = Second.Line) and (First.Column < Second.Column));
end;

{ A code point as UTF-8. }
function Utf8Of(CodePoint: LongWord): string;
begin
  if CodePoint < $80 then
    Result := Char(CodePoint)
  else if CodePoint < $800 then
    Result := Char($C0 or (CodePoint shr 6)) + Char($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Result := Char($E0 or (CodePoint shr 12)) + Char($80 or ((CodePoint shr 6) and $3F)) +
      Char($80 or (CodePoint and $3F))
  else
    Result := Char($F0 or (CodePoint shr 18)) + Char($80 or ((CodePoint shr 12) and $3F)) +
      Char($80 or ((CodePoint shr 6) and $3F)) + Char($80 or (CodePoint and $3F));
end;

constructor TTextEdit.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  PointerShape := PointerTextBeam;
  FLines := TStringList.Create;
  FLines.Add('');
  FLines.OnChange := @LinesChanged;
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Visible := False;
end;

destructor TTextEdit.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

function TTextEdit.LineHeight: LongInt;
begin
  Result := TextHeight(ControlFace);
  if Result < 1 then
    Result := 1;
end;

function TTextEdit.VisibleLines: LongInt;
begin
  Result := (RectangleHeight(PixelBounds) - 4) div LineHeight;
  if Result < 1 then
    Result := 1;
end;

function TTextEdit.TextLeft: LongInt;
begin
  Result := Scaled(4);
end;

function TTextEdit.LineLength(Line: LongInt): LongInt;
begin
  Result := CharacterCountOf(FLines[Line]);
end;

function TTextEdit.ColumnX(Line, Column: LongInt): LongInt;
begin
  Result := TextLeft - FScrollX + TextWidth(ControlFace, CharactersOf(FLines[Line], 0, Column));
end;

function TTextEdit.PositionAt(X, Y: LongInt): TTextPosition;
var
  Column: LongInt;
  Count: LongInt;
begin
  Result.Line := FTopLine + (Y - 2) div LineHeight;
  if Y < 2 then
    Result.Line := FTopLine - 1;
  if Result.Line < 0 then
    Result.Line := 0;
  if Result.Line >= FLines.Count then
    Result.Line := FLines.Count - 1;
  Count := LineLength(Result.Line);
  Result.Column := Count;
  for Column := 0 to Count - 1 do
    if X < (ColumnX(Result.Line, Column) + ColumnX(Result.Line, Column + 1)) div 2 then
    begin
      Result.Column := Column;
      Exit;
    end;
end;

procedure TTextEdit.Layout;
var
  Width: LongInt;
begin
  Width := Scaled(Theme.ScrollBarWidth);
  FScrollBar.AssignBounds(Unscaled(RectangleWidth(PixelBounds) - 2 - Width), Unscaled(2), Unscaled(Width),
    Unscaled(RectangleHeight(PixelBounds) - 4));
  UpdateScrollBar;
  inherited Layout;
end;

procedure TTextEdit.UpdateScrollBar;
var
  Needed: Boolean;
begin
  Needed := FLines.Count > VisibleLines;
  FScrollBar.SetRange(0, FLines.Count, VisibleLines);
  FScrollBar.Position := FTopLine;
  if FScrollBar.Visible <> Needed then
    FScrollBar.Visible := Needed;
end;

procedure TTextEdit.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and (TControl(Message.Parameter1) = FScrollBar) then
  begin
    if (Message.Parameter2 = NotifyChanged) and (FScrollBar.Position <> FTopLine) then
    begin
      FTopLine := FScrollBar.Position;
      Invalidate;
    end;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TTextEdit.SetTopLine(Value: LongInt);
begin
  if Value > FLines.Count - VisibleLines then
    Value := FLines.Count - VisibleLines;
  if Value < 0 then
    Value := 0;
  if Value = FTopLine then
    Exit;
  FTopLine := Value;
  FScrollBar.Position := Value;
  Invalidate;
end;

procedure TTextEdit.ScrollToCaret;
var
  X: LongInt;
  Right: LongInt;
begin
  if FCaret.Line < FTopLine then
    SetTopLine(FCaret.Line)
  else if FCaret.Line >= FTopLine + VisibleLines then
    SetTopLine(FCaret.Line - VisibleLines + 1);
  Right := RectangleWidth(PixelBounds) - TextLeft;
  if FScrollBar.Visible then
    Right := Right - RectangleWidth(FScrollBar.PixelBounds);
  X := ColumnX(FCaret.Line, FCaret.Column);
  if X < TextLeft then
    FScrollX := FScrollX - (TextLeft - X)
  else if X > Right then
    FScrollX := FScrollX + (X - Right);
  if FScrollX < 0 then
    FScrollX := 0;
end;

procedure TTextEdit.MoveCaret(Line, Column: LongInt; Extend: Boolean);
begin
  if Line < 0 then
    Line := 0;
  if Line >= FLines.Count then
    Line := FLines.Count - 1;
  if Column < 0 then
    Column := 0;
  if Column > LineLength(Line) then
    Column := LineLength(Line);
  FCaret := MakePosition(Line, Column);
  if not Extend then
    FAnchor := FCaret;
  ScrollToCaret;
  Invalidate;
end;

function TTextEdit.SelectionStart: TTextPosition;
begin
  if PositionBefore(FAnchor, FCaret) then
    Result := FAnchor
  else
    Result := FCaret;
end;

function TTextEdit.SelectionEnd: TTextPosition;
begin
  if PositionBefore(FAnchor, FCaret) then
    Result := FCaret
  else
    Result := FAnchor;
end;

function TTextEdit.HasSelection: Boolean;
begin
  Result := (FAnchor.Line <> FCaret.Line) or (FAnchor.Column <> FCaret.Column);
end;

function TTextEdit.SelectedText: string;
var
  First: TTextPosition;
  Last: TTextPosition;
  Line: LongInt;
begin
  First := SelectionStart;
  Last := SelectionEnd;
  if First.Line = Last.Line then
    Exit(CharactersOf(FLines[First.Line], First.Column, Last.Column - First.Column));
  Result := CharactersOf(FLines[First.Line], First.Column, MaxInt);
  for Line := First.Line + 1 to Last.Line - 1 do
    Result := Result + #10 + FLines[Line];
  Result := Result + #10 + CharactersOf(FLines[Last.Line], 0, Last.Column);
end;

procedure TTextEdit.SelectAll;
begin
  FAnchor := MakePosition(0, 0);
  FCaret := MakePosition(FLines.Count - 1, LineLength(FLines.Count - 1));
  ScrollToCaret;
  Invalidate;
end;

function TTextEdit.AllText: string;
var
  Line: LongInt;
begin
  Result := '';
  for Line := 0 to FLines.Count - 1 do
  begin
    if Line > 0 then
      Result := Result + #10;
    Result := Result + FLines[Line];
  end;
end;

procedure TTextEdit.SetAllText(const Value: string);
var
  Start: LongInt;
  Index: LongInt;
begin
  FChanging := True;
  FLines.Clear;
  Start := 1;
  for Index := 1 to Length(Value) do
    if Value[Index] = #10 then
    begin
      FLines.Add(Copy(Value, Start, Index - Start));
      Start := Index + 1;
    end;
  FLines.Add(Copy(Value, Start, Length(Value) - Start + 1));
  FChanging := False;
  FCaret := MakePosition(0, 0);
  FAnchor := FCaret;
  FTopLine := 0;
  FScrollX := 0;
  LinesChanged(nil);
end;

procedure TTextEdit.LinesChanged(Sender: TObject);
begin
  if FChanging then
    Exit;
  if FLines.Count = 0 then
  begin
    FChanging := True;
    FLines.Add('');
    FChanging := False;
  end;
  if FCaret.Line >= FLines.Count then
    FCaret := MakePosition(FLines.Count - 1, 0);
  if FAnchor.Line >= FLines.Count then
    FAnchor := FCaret;
  UpdateScrollBar;
  Invalidate;
end;

procedure TTextEdit.TextEdited;
begin
  UpdateScrollBar;
  ScrollToCaret;
  Invalidate;
  Changed;
end;

procedure TTextEdit.DeleteSelection;
var
  First: TTextPosition;
  Last: TTextPosition;
  Joined: string;
  Line: LongInt;
begin
  if not HasSelection then
    Exit;
  First := SelectionStart;
  Last := SelectionEnd;
  FChanging := True;
  Joined := CharactersOf(FLines[First.Line], 0, First.Column) + CharactersOf(FLines[Last.Line], Last.Column, MaxInt);
  for Line := Last.Line downto First.Line + 1 do
    FLines.Delete(Line);
  FLines[First.Line] := Joined;
  FChanging := False;
  FCaret := First;
  FAnchor := First;
end;

{ Inserted split at its line feeds (carriage returns are dropped). }
procedure SplitLines(const Inserted: string; Pieces: TStringList);
var
  Piece: string;
  Index: LongInt;
begin
  Piece := '';
  for Index := 1 to Length(Inserted) do
    if Inserted[Index] = #10 then
    begin
      Pieces.Add(Piece);
      Piece := '';
    end
    else if Inserted[Index] <> #13 then
      Piece := Piece + Inserted[Index];
  Pieces.Add(Piece);
end;

procedure TTextEdit.InsertText(const Inserted: string);
var
  Line: string;
  Before: string;
  After: string;
  Pieces: TStringList;
  Index: LongInt;
  LastPiece: LongInt;
begin
  if FReadOnly then
    Exit;
  DeleteSelection;
  FChanging := True;
  Line := FLines[FCaret.Line];
  Before := CharactersOf(Line, 0, FCaret.Column);
  After := CharactersOf(Line, FCaret.Column, MaxInt);
  Pieces := TStringList.Create;
  SplitLines(Inserted, Pieces);
  { The first piece ends the caret's line; the last starts what was
    after the caret; any between are lines of their own. }
  LastPiece := Pieces.Count - 1;
  if LastPiece = 0 then
  begin
    FLines[FCaret.Line] := Before + Pieces[0] + After;
    FCaret.Column := FCaret.Column + CharacterCountOf(Pieces[0]);
  end
  else
  begin
    FLines[FCaret.Line] := Before + Pieces[0];
    for Index := 1 to LastPiece - 1 do
      FLines.Insert(FCaret.Line + Index, Pieces[Index]);
    FLines.Insert(FCaret.Line + LastPiece, Pieces[LastPiece] + After);
    FCaret := MakePosition(FCaret.Line + LastPiece, CharacterCountOf(Pieces[LastPiece]));
  end;
  Pieces.Free;
  FChanging := False;
  FAnchor := FCaret;
  TextEdited;
end;

procedure TTextEdit.CopyToClipboard;
begin
  if HasSelection then
    SetClipboardText(SelectedText);
end;

procedure TTextEdit.CutToClipboard;
begin
  if not HasSelection or FReadOnly then
    Exit;
  SetClipboardText(SelectedText);
  DeleteSelection;
  TextEdited;
end;

procedure TTextEdit.PasteFromClipboard;
begin
  if FReadOnly or not ClipboardHasText then
    Exit;
  InsertText(ClipboardText);
end;

procedure TTextEdit.RunEditCommand(Command: TEditCommand);
begin
  case Command of
    EditCommandCut: CutToClipboard;
    EditCommandCopy: CopyToClipboard;
    EditCommandPaste: PasteFromClipboard;
    EditCommandSelectAll: SelectAll;
  end;
end;

function TTextEdit.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
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
    KeyArrowLeft:
      if FCaret.Column > 0 then
        MoveCaret(FCaret.Line, FCaret.Column - 1, Extend)
      else if FCaret.Line > 0 then
        MoveCaret(FCaret.Line - 1, LineLength(FCaret.Line - 1), Extend);
    KeyArrowRight:
      if FCaret.Column < LineLength(FCaret.Line) then
        MoveCaret(FCaret.Line, FCaret.Column + 1, Extend)
      else if FCaret.Line < FLines.Count - 1 then
        MoveCaret(FCaret.Line + 1, 0, Extend);
    KeyArrowUp: MoveCaret(FCaret.Line - 1, FCaret.Column, Extend);
    KeyArrowDown: MoveCaret(FCaret.Line + 1, FCaret.Column, Extend);
    KeyPageUp: MoveCaret(FCaret.Line - VisibleLines, FCaret.Column, Extend);
    KeyPageDown: MoveCaret(FCaret.Line + VisibleLines, FCaret.Column, Extend);
    KeyHome: MoveCaret(FCaret.Line, 0, Extend);
    KeyEnd: MoveCaret(FCaret.Line, LineLength(FCaret.Line), Extend);
    KeyBackspace:
      if not FReadOnly then
      begin
        if not HasSelection then
          KeyDown(KeyArrowLeft, 0, ModifierShift);
        DeleteSelection;
        TextEdited;
      end;
    KeyDelete:
      if not FReadOnly then
      begin
        if not HasSelection then
          KeyDown(KeyArrowRight, 0, ModifierShift);
        DeleteSelection;
        TextEdited;
      end;
  else
    if IsEnterKey(Code) then
      InsertText(#10)
    else if (Character = TabCharacter) and FAcceptTabs then
      InsertText(#9)
    else if (Character >= 32) and (Character <> 127) and ((Modifiers and ModifierControl) = 0) then
      InsertText(Utf8Of(Character))
    else
      Result := False;
  end;
end;

procedure TTextEdit.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Position: TTextPosition;
begin
  if Button <> ButtonLeft then
    Exit;
  FSelecting := True;
  Position := PositionAt(X, Y);
  MoveCaret(Position.Line, Position.Column, False);
end;

procedure TTextEdit.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Position: TTextPosition;
begin
  if not FSelecting then
    Exit;
  Position := PositionAt(X, Y);
  MoveCaret(Position.Line, Position.Column, True);
end;

procedure TTextEdit.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FSelecting := False;
  { Opened as the button is let go, so the release does not land on the
    menu. }
  if Button = ButtonRight then
    ShowEditMenu(Self, X, Y, AvailableEditCommands(HasSelection, FReadOnly), @RunEditCommand);
end;

procedure TTextEdit.Wheel(Steps: LongInt);
begin
  SetTopLine(FTopLine - Steps * 3);
end;

procedure TTextEdit.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Line: LongInt;
  Top: LongInt;
  Right: LongInt;
  First: TTextPosition;
  Last: TTextPosition;
  FromColumn: LongInt;
  ToColumn: LongInt;
  Left: LongInt;
  Width: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if Enabled and not FReadOnly then
    FillRectangle(Canvas, Box, Theme.Field)
  else
    FillRectangle(Canvas, Box, Theme.Face);
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  if ControlFace = nil then
    Exit;
  Right := RectangleWidth(Box) - 2;
  if FScrollBar.Visible then
    Right := Right - RectangleWidth(FScrollBar.PixelBounds);
  Inner := Canvas;
  NarrowCanvasClip(Inner, MakeRectangle(2, 2, Right - 2, RectangleHeight(Box) - 4));
  First := SelectionStart;
  Last := SelectionEnd;
  for Line := FTopLine to FLines.Count - 1 do
  begin
    Top := 2 + (Line - FTopLine) * LineHeight;
    if Top >= RectangleHeight(Box) then
      Break;
    DrawTextInBox(Inner, ControlFace, FLines[Line], MakeRectangle(TextLeft - FScrollX, Top, 1 shl 20, LineHeight),
      AlignTextLeft, Theme.FieldText);
    if Focused and HasSelection and (Line >= First.Line) and (Line <= Last.Line) then
    begin
      FromColumn := 0;
      ToColumn := LineLength(Line);
      if Line = First.Line then
        FromColumn := First.Column;
      if Line = Last.Line then
        ToColumn := Last.Column;
      Left := ColumnX(Line, FromColumn);
      Width := ColumnX(Line, ToColumn) - Left;
      { A line break selected shows as a little space. }
      if Line < Last.Line then
        Width := Width + Scaled(4);
      FillRectangle(Inner, MakeRectangle(Left, Top, Width, LineHeight), Theme.Selection);
      DrawTextInBox(Inner, ControlFace, CharactersOf(FLines[Line], FromColumn, ToColumn - FromColumn),
        MakeRectangle(Left, Top, 1 shl 20, LineHeight), AlignTextLeft, Theme.SelectionText);
    end;
  end;
  if Focused then
    FillRectangle(Inner, MakeRectangle(ColumnX(FCaret.Line, FCaret.Column), 2 + (FCaret.Line - FTopLine) * LineHeight,
      Scaled(1), LineHeight), Theme.FieldText);
end;

end.
